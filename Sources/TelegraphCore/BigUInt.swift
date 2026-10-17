import Foundation

/// Unsigned integers used only by the finite-field operations Telegram requires.
struct BigUInt: Equatable, Comparable, Sendable {
    var words: [UInt32] // least significant first
    init(_ value: UInt64 = 0) {
        words = [UInt32(truncatingIfNeeded: value), UInt32(value >> 32)]
        normalize()
    }
    init(data: Data) {
        words = [UInt32](repeating: 0, count: max(1, (data.count + 3) / 4))
        for (i, b) in data.reversed().enumerated() { words[i / 4] |= UInt32(b) << (8 * (i % 4)) }
        normalize()
    }
    init(words: [UInt32]) { self.words = words.isEmpty ? [0] : words; normalize() }
    mutating private func normalize() { while words.count > 1 && words.last == 0 { words.removeLast() } }
    static func < (a: Self, b: Self) -> Bool {
        if a.words.count != b.words.count { return a.words.count < b.words.count }
        for i in a.words.indices.reversed() where a.words[i] != b.words[i] { return a.words[i] < b.words[i] }
        return false
    }
    static func + (a: Self, b: Self) -> Self {
        var out = [UInt32](), carry: UInt64 = 0
        for i in 0..<max(a.words.count, b.words.count) {
            let x = UInt64(i < a.words.count ? a.words[i] : 0) + UInt64(i < b.words.count ? b.words[i] : 0) + carry
            out.append(UInt32(truncatingIfNeeded: x)); carry = x >> 32
        }
        if carry != 0 { out.append(UInt32(carry)) }
        return Self(words: out)
    }
    static func - (a: Self, b: Self) -> Self {
        precondition(a >= b)
        var out = a.words, borrow: UInt64 = 0
        for i in out.indices {
            let x = UInt64(a.words[i]) &- (UInt64(i < b.words.count ? b.words[i] : 0) + borrow)
            out[i] = UInt32(truncatingIfNeeded: x); borrow = x >> 63
        }
        return Self(words: out)
    }
    static func * (a: Self, b: Self) -> Self {
        var out = [UInt32](repeating: 0, count: a.words.count + b.words.count + 1)
        for i in a.words.indices {
            var carry: UInt64 = 0
            for j in b.words.indices {
                let x = UInt64(a.words[i]) * UInt64(b.words[j]) + UInt64(out[i+j]) + carry
                out[i+j] = UInt32(truncatingIfNeeded: x); carry = x >> 32
            }
            out[i + b.words.count] = UInt32(carry)
        }
        return Self(words: out)
    }
    func data(paddedTo size: Int? = nil) -> Data {
        var bytes = Data()
        for word in words.reversed() {
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word))
        }
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if let size, bytes.count < size { return Data(repeating: 0, count: size - bytes.count) + bytes }
        return Data(bytes)
    }
    func remainder(_ divisor: UInt32) -> UInt32 {
        var r: UInt64 = 0
        for word in words.reversed() { r = ((r << 32) | UInt64(word)) % UInt64(divisor) }
        return UInt32(r)
    }
}

/// Montgomery reduction for odd moduli. Secret exponentiation always performs
/// both multiply and square and selects limbs without branching on exponent bits.
struct Montgomery: Sendable {
    let modulus: BigUInt
    let n: Int
    let m: [UInt32]
    let inverse: UInt32
    let r2: [UInt32]

    init(_ modulus: BigUInt) throws {
        guard modulus > BigUInt(1), modulus.words[0] & 1 == 1 else { throw TelegraphError.invalid("Invalid modular arithmetic modulus") }
        self.modulus = modulus; n = modulus.words.count; m = modulus.words
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- (m[0] &* inv)) }
        inverse = 0 &- inv
        var r = [UInt32](repeating: 0, count: n); r[0] = 1
        for _ in 0..<(n * 64) { r = Self.doubleMod(r, m: m) }
        r2 = r
    }
    private static func doubleMod(_ a: [UInt32], m: [UInt32]) -> [UInt32] {
        var out = a, carry: UInt64 = 0
        for i in out.indices {
            let x = UInt64(a[i]) * 2 + carry
            out[i] = UInt32(truncatingIfNeeded: x); carry = x >> 32
        }
        return reduceOnce(out, high: UInt32(carry), m: m)
    }
    private static func reduceOnce(_ a: [UInt32], high: UInt32, m: [UInt32]) -> [UInt32] {
        var diff = a, borrow: UInt64 = 0
        for i in a.indices {
            let x = UInt64(a[i]) &- (UInt64(m[i]) + borrow)
            diff[i] = UInt32(truncatingIfNeeded: x); borrow = x >> 63
        }
        let last = UInt64(high) &- borrow
        let mask = UInt32(0) &- UInt32(1 ^ (last >> 63))
        return a.indices.map { (diff[$0] & mask) | (a[$0] & ~mask) }
    }
    private func fixed(_ a: BigUInt) throws -> [UInt32] {
        guard a < modulus else { throw TelegraphError.invalid("Integer outside Telegram field") }
        return a.words + repeatElement(0, count: n - a.words.count)
    }
    private func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: 2 * n + 2)
        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<n {
                let v = UInt64(a[i]) * UInt64(b[j]) + UInt64(t[i+j]) + carry
                t[i+j] = UInt32(truncatingIfNeeded: v); carry = v >> 32
            }
            t[i+n] = UInt32(truncatingIfNeeded: carry)
        }
        for i in 0..<n {
            let u = t[i] &* inverse
            var carry: UInt64 = 0
            for j in 0..<n {
                let v = UInt64(u) * UInt64(m[j]) + UInt64(t[i+j]) + carry
                t[i+j] = UInt32(truncatingIfNeeded: v); carry = v >> 32
            }
            for k in (i+n)..<t.count {
                let v = UInt64(t[k]) + carry
                t[k] = UInt32(truncatingIfNeeded: v); carry = v >> 32
            }
        }
        return Self.reduceOnce(Array(t[n..<(2*n)]), high: t[2*n], m: m)
    }
    func power(_ base: BigUInt, exponent: Data) throws -> BigUInt {
        let one = [UInt32(1)] + repeatElement(UInt32(0), count: n - 1)
        let b = multiply(try fixed(base), r2)
        var result = multiply(one, r2)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                let square = multiply(result, result)
                let product = multiply(square, b)
                let mask = UInt32(0) &- UInt32((byte >> bit) & 1)
                result = (0..<n).map { (product[$0] & mask) | (square[$0] & ~mask) }
            }
        }
        return BigUInt(words: multiply(result, one))
    }
    func product(_ a: BigUInt, _ b: BigUInt) throws -> BigUInt {
        let am = multiply(try fixed(a), r2)
        return BigUInt(words: multiply(am, try fixed(b)))
    }
    func subtract(_ a: BigUInt, _ b: BigUInt) throws -> BigUInt {
        let aw = try fixed(a), bw = try fixed(b)
        var result = aw, borrow: UInt64 = 0
        for i in 0..<n {
            let v = UInt64(aw[i]) &- (UInt64(bw[i]) + borrow)
            result[i] = UInt32(truncatingIfNeeded: v); borrow = v >> 63
        }
        let mask = UInt32(0) &- UInt32(borrow)
        var carry: UInt64 = 0
        for i in 0..<n {
            let v = UInt64(result[i]) + UInt64(m[i] & mask) + carry
            result[i] = UInt32(truncatingIfNeeded: v); carry = v >> 32
        }
        return BigUInt(words: result)
    }
}

func factorPQ(_ value: UInt64) throws -> (UInt64, UInt64) {
    guard value > 3, value <= UInt64(Int64.max), value & 1 == 1 else { throw TelegraphError.invalid("Invalid Telegram pq") }
    func gcd(_ x: UInt64, _ y: UInt64) -> UInt64 {
        var a = x, b = y
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
    func step(_ x: UInt64, _ c: UInt64) -> UInt64 {
        let r = value.dividingFullWidth(x.multipliedFullWidth(by: x)).remainder
        return (r + c) % value
    }
    for c in 1...32 {
        var x: UInt64 = 2, y: UInt64 = 2
        for _ in 0..<200_000 {
            x = step(x, UInt64(c)); y = step(step(y, UInt64(c)), UInt64(c))
            let d = gcd(x > y ? x-y : y-x, value)
            if d == value { break }
            if d > 1 {
                let q = value / d
                guard d <= UInt64(UInt32.max), q <= UInt64(UInt32.max) else { break }
                return (min(d, q), max(d, q))
            }
        }
    }
    throw TelegraphError.invalid("Could not factor Telegram pq")
}
