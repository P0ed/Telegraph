import Foundation

struct DCAuth: Codable, Sendable {
    let dc: Int32
    let key: Data
    var salt: Int64
    var timeOffset: Double
}

enum KeyExchange {
    static func run(transport: any PacketTransport, dc: Int32, test: Bool, codec: TLCodec) async throws -> DCAuth {
        let nonce = try Crypto.random(16)
        var lastID: Int64 = 0
        func query(_ obj: TLObject) async throws -> TLObject {
            let body = try codec.encode(obj)
            var packet = Data()
            let timeID = Int64(Date().timeIntervalSince1970 * 4_294_967_296) & ~3
            lastID = max(timeID, lastID + 4)
            packet.appendLE(Int64(0)); packet.appendLE(lastID)
            packet.appendLE(Int32(body.count)); packet.append(body)
            try await transport.send(packet)
            var reader = BinaryReader(data: try await transport.receive())
            guard try reader.integer(Int64.self) == 0 else { throw TelegraphError.invalid("Encrypted packet during key exchange") }
            _ = try reader.integer(Int64.self)
            let length = try reader.integer(Int32.self)
            guard length >= 4, length <= 64 * 1024, Int(length) == reader.remaining else { throw TelegraphError.invalid("Invalid key exchange length") }
            guard let result = try codec.decode(reader.read(Int(length))).object else { throw TelegraphError.invalid("Invalid key exchange response") }
            guard result["nonce"].bytes.constantEquals(nonce) else { throw TelegraphError.invalid("Key exchange nonce mismatch") }
            return result
        }
        let pqReply = try await query(TLObject("req_pq_multi", ["nonce": .bytes(nonce)]))
        guard pqReply.name == "resPQ", pqReply["server_nonce"].bytes.count == 16,
              (1...8).contains(pqReply["pq"].bytes.count) else { throw TelegraphError.invalid("Invalid Telegram pq response") }
        let serverNonce = pqReply["server_nonce"].bytes, pqData = pqReply["pq"].bytes
        let pq = pqData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let (p, q) = try factorPQ(pq)
        let publicKey = try PublicRSAKey.load(test: test)
        guard pqReply["server_public_key_fingerprints"].array.contains(.long(publicKey.fingerprint)) else {
            throw TelegraphError.invalid("Unknown Telegram RSA key; update Telegraph")
        }
        let newNonce = try Crypto.random(32)
        let inner = TLObject("p_q_inner_data_dc", [
            "pq": .bytes(pqData), "p": .bytes(BigUInt(p).data()), "q": .bytes(BigUInt(q).data()),
            "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce), "new_nonce": .bytes(newNonce),
            "dc": .int(test ? dc + 10_000 : dc)
        ])
        let encrypted = try publicKey.paddedEncrypt(codec.encode(inner))
        let dhReply = try await query(TLObject("req_DH_params", [
            "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce),
            "p": .bytes(BigUInt(p).data()), "q": .bytes(BigUInt(q).data()),
            "public_key_fingerprint": .long(publicKey.fingerprint), "encrypted_data": .bytes(encrypted)
        ]))
        guard dhReply.name == "server_DH_params_ok", dhReply["server_nonce"].bytes.constantEquals(serverNonce) else {
            throw TelegraphError.invalid("Invalid Telegram DH response")
        }
        let h1 = Crypto.sha1(newNonce + serverNonce), h2 = Crypto.sha1(serverNonce + newNonce)
        let aesKey = h1 + h2.slice(0..<12)
        let aesIV = h2.slice(12..<20) + Crypto.sha1(newNonce + newNonce) + newNonce.slice(0..<4)
        let answer = try Crypto.aesIGE(dhReply["encrypted_answer"].bytes, key: aesKey, iv: aesIV, encrypt: false)
        var reader = BinaryReader(data: answer)
        let hash = try reader.read(20)
        let start = reader.offset
        guard let dh = try codec.decode(&reader).object, dh.name == "server_DH_inner_data",
              reader.remaining <= 15, hash.constantEquals(Crypto.sha1(answer.slice(start..<reader.offset))),
              dh["nonce"].bytes.constantEquals(nonce), dh["server_nonce"].bytes.constantEquals(serverNonce) else {
            throw TelegraphError.invalid("Invalid DH answer integrity or nonces")
        }
        let field = try Crypto.validateDH(prime: dh["dh_prime"].bytes, generator: dh["g"].int)
        let ga = BigUInt(data: dh["g_a"].bytes)
        try Crypto.validatePublic(ga, modulus: field.modulus)
        let offset = Double(dh["server_time"].int) - Date().timeIntervalSince1970
        var retryID: Int64 = 0
        for _ in 0..<5 {
            let b = try Crypto.random(256)
            let gb = try field.power(BigUInt(UInt64(dh["g"].int)), exponent: b)
            try Crypto.validatePublic(gb, modulus: field.modulus)
            let authKey = try field.power(ga, exponent: b).data(paddedTo: 256)
            let clientData = try codec.encode(TLObject("client_DH_inner_data", [
                "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce),
                "retry_id": .long(retryID), "g_b": .bytes(gb.data())
            ]))
            var clientPlain = Crypto.sha1(clientData) + clientData
            clientPlain.append(try Crypto.random((16 - clientPlain.count % 16) % 16))
            let encryptedClient = try Crypto.aesIGE(clientPlain, key: aesKey, iv: aesIV, encrypt: true)
            let result = try await query(TLObject("set_client_DH_params", [
                "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce), "encrypted_data": .bytes(encryptedClient)
            ]))
            guard result["server_nonce"].bytes.constantEquals(serverNonce) else { throw TelegraphError.invalid("DH server nonce mismatch") }
            let code: UInt8
            switch result.name { case "dh_gen_ok": code = 1; case "dh_gen_retry": code = 2; case "dh_gen_fail": code = 3
            default: throw TelegraphError.invalid("Unknown DH completion response") }
            let auxHash = Crypto.sha1(authKey).slice(0..<8)
            let expected = Crypto.sha1(newNonce + Data([code]) + auxHash).suffix(16)
            guard result["new_nonce_hash\(code)"].bytes.constantEquals(Data(expected)) else {
                throw TelegraphError.invalid("DH completion hash mismatch")
            }
            if code == 1 {
                var saltReader = BinaryReader(data: Data.xor(newNonce.slice(0..<8), serverNonce.slice(0..<8)))
                return DCAuth(dc: dc, key: authKey, salt: try saltReader.integer(), timeOffset: offset)
            }
            guard code == 2 else { throw TelegraphError.invalid("Telegram rejected the DH exchange") }
            var auxReader = BinaryReader(data: auxHash); retryID = try auxReader.integer()
        }
        throw TelegraphError.invalid("Too many DH exchange retries")
    }
}
