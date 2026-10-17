import Foundation
import Testing
@testable import TelegraphCore

@Test func independentArithmeticFixtures() throws {
    struct Vector: Decodable {
        let modulus: String, a: String, b: String, exponent: String, product: String, power: String
    }
    let url = try #require(Bundle.module.url(forResource: "arithmetic", withExtension: "json"))
    for v in try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url)) {
        let field = try Montgomery(BigUInt(data: Data(hex: v.modulus)))
        let a = try BigUInt(data: Data(hex: v.a)), b = try BigUInt(data: Data(hex: v.b))
        #expect(try field.product(a, b) == BigUInt(data: Data(hex: v.product)))
        #expect(try field.power(a, exponent: Data(hex: v.exponent)) == BigUInt(data: Data(hex: v.power)))
    }
}

@Test func srpMatchesIndependentServerProof() throws {
    let url = try #require(Bundle.module.url(forResource: "srp", withExtension: "json"))
    let v = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    func data(_ key: String) throws -> Data { try Data(hex: #require(v[key])) }
    let params = TLObject("account.password", [
        "current_algo": .object(TLObject("passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow", [
            "salt1": .bytes(try data("salt1")), "salt2": .bytes(try data("salt2")), "g": .int(3), "p": .bytes(try data("prime"))
        ])),
        "srp_B": .bytes(try data("B")), "srp_id": .long(42)
    ])
    let proof = try SRP.proof(password: #require(v["password"]), parameters: params, privateA: data("a"))
    #expect(proof["A"].bytes == (try data("A")))
    #expect(proof["M1"].bytes == (try data("M1")))
    #expect(proof["srp_id"].long == 42)
}
