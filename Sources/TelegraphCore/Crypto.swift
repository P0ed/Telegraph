import Foundation
import Security
import CryptoKit
import CommonCrypto

enum Crypto {
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TelegraphError.invalid("System random generator failed") }
        return data
    }
    static func randomID() throws -> Int64 {
        var r = BinaryReader(data: try random(8)); return try r.integer()
    }
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func pbkdf2(_ password: Data, salt: Data, rounds: UInt32 = 100_000) throws -> Data {
        var output = Data(count: 64)
        let result = output.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pass in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress!.assumingMemoryBound(to: Int8.self), pass.count,
                        salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds,
                        out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count)
                }
            }
        }
        guard result == kCCSuccess else { throw TelegraphError.invalid("Password derivation failed") }
        return output
    }
    static func aesIGE(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard data.count.isMultiple(of: 16), key.count == 32, iv.count == 32 else { throw TelegraphError.invalid("Invalid AES-IGE parameters") }
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes {
            CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), $0.baseAddress, key.count, nil, &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { throw TelegraphError.invalid("Could not initialize AES") }
        defer { CCCryptorRelease(cryptor) }
        var previousCipher = iv.slice(0..<16), previousPlain = iv.slice(16..<32), output = Data()
        output.reserveCapacity(data.count)
        for offset in stride(from: 0, to: data.count, by: 16) {
            let block = data.slice(offset..<offset+16)
            let input = Data.xor(block, encrypt ? previousCipher : previousPlain)
            var transformed = Data(count: 16), moved = 0
            let result = transformed.withUnsafeMutableBytes { out in
                input.withUnsafeBytes { bytes in
                    CCCryptorUpdate(cryptor, bytes.baseAddress, 16, out.baseAddress, 16, &moved)
                }
            }
            guard result == kCCSuccess, moved == 16 else { throw TelegraphError.invalid("AES block operation failed") }
            let final = Data.xor(transformed, encrypt ? previousPlain : previousCipher)
            output.append(final)
            previousCipher = encrypt ? final : block
            previousPlain = encrypt ? block : final
        }
        return output
    }
    static func messageKeys(authKey: Data, messageKey: Data, incoming: Bool) -> (Data, Data) {
        let x = incoming ? 8 : 0
        let a = sha256(messageKey + authKey.slice(x..<x+36))
        let b = sha256(authKey.slice(40+x..<76+x) + messageKey)
        return (a.slice(0..<8) + b.slice(8..<24) + a.slice(24..<32),
                b.slice(0..<8) + a.slice(8..<24) + b.slice(24..<32))
    }
    static func encryptMessage(_ plaintext: Data, authKey: Data, incoming: Bool = false) throws -> Data {
        guard authKey.count == 256 else { throw TelegraphError.invalid("Invalid authorization key") }
        var padded = plaintext
        var padding = (16 - plaintext.count % 16) % 16
        if padding < 12 { padding += 16 }
        padded.append(try random(padding))
        let x = incoming ? 8 : 0
        let messageKey = sha256(authKey.slice(88+x..<120+x) + padded).slice(8..<24)
        let (key, iv) = messageKeys(authKey: authKey, messageKey: messageKey, incoming: incoming)
        return sha1(authKey).suffix(8) + messageKey + (try aesIGE(padded, key: key, iv: iv, encrypt: true))
    }
    static func decryptMessage(_ packet: Data, authKey: Data, incoming: Bool = true) throws -> Data {
        guard authKey.count == 256, packet.count >= 56, (packet.count - 24) % 16 == 0,
              packet.slice(0..<8).constantEquals(Data(sha1(authKey).suffix(8))) else {
            throw TelegraphError.invalid("Invalid encrypted Telegram packet")
        }
        let messageKey = packet.slice(8..<24)
        let (key, iv) = messageKeys(authKey: authKey, messageKey: messageKey, incoming: incoming)
        let plain = try aesIGE(packet.slice(24..<packet.count), key: key, iv: iv, encrypt: false)
        let x = incoming ? 8 : 0
        guard sha256(authKey.slice(88+x..<120+x) + plain).slice(8..<24).constantEquals(messageKey) else {
            throw TelegraphError.invalid("Telegram packet integrity check failed")
        }
        return plain
    }

    static let dhPrimeHex = """
    C71CAEB9C6B1C9048E6C522F70F13F73980D40238E3E21C14934D037563D930F
    48198A0AA7C14058229493D22530F4DBFA336F6E0AC925139543AED44CCE7C37
    20FD51F69458705AC68CD4FE6B6B13ABDC9746512969328454F18FAF8C595F64
    2477FE96BB2A941D5BCD1D4AC8CC49880708FA9B378E3C4F3A9060BEE67CF9A4
    A4A695811051907E162753B56B0F6B410DBA74D8A84B2A14B3144E0EF1284754
    FD17ED950D5965B4B9DD46582DB1178D169C6BC465B0D6FF9CA3928FEF5B9AE4
    E418FC15E83EBEA0F87FA9FF5EED70050DED2849F47BF959D956850CE929851F
    0D8115F635B105EE2E4E15D04B2454BF6F4FADF034B10403119CD8E3B92FCC5B
    """
    static func validateDH(prime: Data, generator: Int32) throws -> Montgomery {
        guard prime.constantEquals(try Data(hex: dhPrimeHex)), (2...7).contains(generator) else {
            throw TelegraphError.invalid("Unknown Telegram DH parameters; update Telegraph")
        }
        let p = BigUInt(data: prime)
        let valid: Bool
        switch generator {
        case 2: valid = p.remainder(8) == 7
        case 3: valid = p.remainder(3) == 2
        case 4: valid = true
        case 5: valid = [1, 4].contains(p.remainder(5))
        case 6: valid = [19, 23].contains(p.remainder(24))
        default: valid = [3, 5, 6].contains(p.remainder(7))
        }
        guard valid else { throw TelegraphError.invalid("Invalid Telegram DH generator") }
        return try Montgomery(p)
    }
    static func validatePublic(_ value: BigUInt, modulus: BigUInt) throws {
        let margin = BigUInt(data: Data([1]) + Data(repeating: 0, count: 248))
        guard value > margin, value < modulus - margin else { throw TelegraphError.invalid("Invalid DH public value") }
    }
}

struct PublicRSAKey: Decodable, Sendable {
    let modulus: String
    let exponent: String
    let fingerprint: Int64
    static func load(test: Bool) throws -> Self {
        let keys = try JSONDecoder().decode([String: Self].self, from: EmbeddedSchemas.load("public-keys"))
        guard let key = keys[test ? "test" : "production"] else { throw TelegraphError.invalid("Missing Telegram public key") }
        return key
    }
    func paddedEncrypt(_ data: Data) throws -> Data {
        guard data.count <= 144 else { throw TelegraphError.invalid("RSA handshake payload too large") }
        let mod = try Montgomery(BigUInt(data: Data(hex: modulus)))
        let padded = data + (try Crypto.random(192 - data.count))
        for _ in 0..<128 {
            let key = try Crypto.random(32)
            let payload = Data(padded.reversed()) + Crypto.sha256(key + padded)
            let cipher = try Crypto.aesIGE(payload, key: key, iv: Data(repeating: 0, count: 32), encrypt: true)
            let block = Data.xor(key, Crypto.sha256(cipher)) + cipher
            let value = BigUInt(data: block)
            if value < mod.modulus { return try mod.power(value, exponent: Data(hex: exponent)).data(paddedTo: 256) }
        }
        throw TelegraphError.invalid("RSA padding failed")
    }
}

enum SRP {
    static func proof(password: String, parameters: TLObject, privateA: Data? = nil) throws -> TLObject {
        guard let algo = parameters["current_algo"].object,
              algo.name == "passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow" else {
            throw TelegraphError.invalid("Unsupported Telegram password algorithm")
        }
        let p = algo["p"].bytes, g = algo["g"].int
        let field = try Crypto.validateDH(prime: p, generator: g)
        let bData = parameters["srp_B"].bytes, b = BigUInt(data: bData)
        guard b > BigUInt(), b < field.modulus else { throw TelegraphError.invalid("Invalid SRP server value") }
        let salt1 = algo["salt1"].bytes, salt2 = algo["salt2"].bytes
        func sh(_ input: Data, _ salt: Data) -> Data { Crypto.sha256(salt + input + salt) }
        let ph1 = sh(sh(Data(password.utf8), salt1), salt2)
        let x = sh(try Crypto.pbkdf2(ph1, salt: salt1), salt2)
        let a = try privateA ?? Crypto.random(256)
        guard a.count == 256 else { throw TelegraphError.invalid("Invalid SRP private exponent length") }
        let A = try field.power(BigUInt(UInt64(g)), exponent: a)
        try Crypto.validatePublic(A, modulus: field.modulus)
        let aData = A.data(paddedTo: 256), gData = BigUInt(UInt64(g)).data(paddedTo: 256)
        let paddedB = b.data(paddedTo: 256)
        let u = Crypto.sha256(aData + paddedB)
        guard BigUInt(data: u) != BigUInt() else { throw TelegraphError.invalid("Invalid SRP scrambling value") }
        let k = BigUInt(data: Crypto.sha256(p + gData))
        let gx = try field.power(BigUInt(UInt64(g)), exponent: x)
        let base = try field.subtract(b, field.product(k, gx))
        try Crypto.validatePublic(base, modulus: field.modulus)
        let exponent = (BigUInt(data: a) + BigUInt(data: u) * BigUInt(data: x)).data(paddedTo: 260)
        let s = try field.power(base, exponent: exponent).data(paddedTo: 256)
        let K = Crypto.sha256(s)
        let M1 = Crypto.sha256(Data.xor(Crypto.sha256(p), Crypto.sha256(gData)) +
                              Crypto.sha256(salt1) + Crypto.sha256(salt2) + aData + paddedB + K)
        return TLObject("inputCheckPasswordSRP", ["srp_id": parameters["srp_id"], "A": .bytes(aData), "M1": .bytes(M1)])
    }
}
