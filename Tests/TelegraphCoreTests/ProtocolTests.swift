import Foundation
import Testing
@testable import TelegraphCore

@Test func unsignedArithmetic() throws {
    for m: UInt64 in [3, 17, 65537, 4_294_967_291, 18_446_744_073_709_551_557] {
        let field = try Montgomery(BigUInt(m))
        for a: UInt64 in [0, 1, 2, 12345, 4_294_967_290] where a < m {
            for b: UInt64 in [0, 1, 3, 12346, 4_294_967_289] where b < m {
                let expected = m.dividingFullWidth(a.multipliedFullWidth(by: b)).remainder
                #expect(try field.product(BigUInt(a), BigUInt(b)) == BigUInt(expected))
                #expect(try field.subtract(BigUInt(a), BigUInt(b)) == BigUInt(a >= b ? a-b : m-(b-a)))
            }
        }
    }
    #expect(BigUInt(UInt64.max) + BigUInt(1) == BigUInt(data: try Data(hex: "010000000000000000")))
    #expect((BigUInt(UInt64.max) * BigUInt(UInt64.max)).data().hex == "fffffffffffffffe0000000000000001")
    #expect(try Montgomery(BigUInt(497)).power(BigUInt(4), exponent: Data([13])) == BigUInt(445))
    let factors = try factorPQ(1_000_000_007 * 1_000_000_009)
    #expect(factors.0 == 1_000_000_007 && factors.1 == 1_000_000_009)
}

@Test func aesKnownAnswerAndIntegrity() throws {
    let key = try Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    let plain = try Data(hex: "00112233445566778899aabbccddeeff")
    let expected = try Data(hex: "8ea2b7ca516745bfeafc49904b496089")
    let zeroIV = Data(repeating: 0, count: 32)
    #expect(try Crypto.aesIGE(plain, key: key, iv: zeroIV, encrypt: true) == expected)
    #expect(try Crypto.aesIGE(expected, key: key, iv: zeroIV, encrypt: false) == plain)
    let authKey = Data((0..<256).map(UInt8.init))
    let body = Data(repeating: 42, count: 132)
    let packet = try Crypto.encryptMessage(body, authKey: authKey, incoming: true)
    #expect(try Crypto.decryptMessage(packet, authKey: authKey).prefix(body.count) == body)
    var corrupt = packet; corrupt[30] ^= 1
    #expect(throws: (any Error).self) { try Crypto.decryptMessage(corrupt, authKey: authKey) }
    #expect(throws: (any Error).self) { try Crypto.decryptMessage(packet.prefix(30), authKey: authKey) }
    let prime = try Data(hex: Crypto.dhPrimeHex)
    #expect(prime.count == 256)
    _ = try Crypto.validateDH(prime: prime, generator: 3)
    #expect(throws: (any Error).self) { try Crypto.validateDH(prime: Data(repeating: 0, count: 256), generator: 3) }
}

@Test func tlRoundTripAndBounds() throws {
    let codec = try TLCodec()
    let obj = TLObject("message", [
        "out": .bool(true), "id": .int(42), "date": .int(100),
        "peer_id": .object(TLObject("peerUser", ["user_id": .long(123)])),
        "message": .string("Hello 🌍\nWorld"), "offline": .bool(true)
    ])
    let encoded = try codec.encode(obj)
    let decoded = try #require(try codec.decode(encoded).object)
    #expect(decoded["message"].string == "Hello 🌍\nWorld")
    #expect(decoded["out"].bool && decoded["offline"].bool)
    #expect(throws: (any Error).self) { try codec.decode(encoded.dropLast()) }
    #expect(throws: (any Error).self) { try codec.decode(encoded + Data([0])) }
    for length in [0, 1, 253, 254, 255, 1024] {
        let input = Data(repeating: 17, count: length)
        var reader = BinaryReader(data: try tlBytes(input))
        #expect(try reader.bytes() == input)
        #expect(reader.remaining == 0)
    }
    #expect(codec.byName["messages.sendMessage"] != nil)
    #expect(codec.byName["auth.sendCode"] != nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TELEGRAPH_LIVE_TEST"] == "1"))
func liveTestServerHandshake() async throws {
    let tcp = TCPTransport(endpoint: .bootstrap(test: true))
    do {
        try await tcp.connect()
        let auth = try await KeyExchange.run(transport: tcp, dc: 2, test: true, codec: TLCodec())
        #expect(auth.key.count == 256)
        #expect(abs(auth.timeOffset) < 300)
        await tcp.close()
        // An intentionally invalid application ID verifies encrypted RPC routing
        // without using anyone's application credentials or signing in.
        let session = MTSession(endpoint: .bootstrap(test: true), test: true, apiID: 0, auth: auth,
                                codec: try TLCodec(), onAuth: { _ in })
        do {
            let result = try await session.request(TLObject("help.getConfig"))
            #expect(result.object?.name == "config")
        } catch let error as TelegraphError {
            #expect(["API_ID_INVALID", "CONNECTION_API_ID_INVALID"].contains(error.rpcMessage ?? ""))
        } catch { await session.close(); throw error }
        await session.close()
    } catch { await tcp.close(); throw error }
}
