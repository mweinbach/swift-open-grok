// Ed25519Portable.swift
//
// Portable Ed25519 verification for every supported platform.
//
// Strategy (R04):
//   * Prefer CryptoKit `Curve25519.Signing` when available (Apple) — see
//     `Ed25519Verifier` in SignedPolicy.swift.
//   * This module always provides a pure-Swift RFC 8032 verifier so
//     Linux/Windows accept authentic managed-policy sidecars once embedded
//     keys are provisioned — matching Rust's ring Ed25519 path.
//   * Dark builds (empty embedded key set) remain inert on every platform.
//
// Algorithm: SUPERCOP ref10-style field arithmetic over GF(2^255-19),
// pure-Swift SHA-512, variable-time double-scalar mult for verify only.

import Foundation
import OpenGrokShared

/// Pure-Swift Ed25519 verification (works on every platform).
enum Ed25519Portable {
    /// Verify an Ed25519 signature over `message` under `publicKey`.
    /// Returns `false` for structural errors or a bad signature.
    static func isValidSignature(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        guard signature.count == 64, publicKey.count == 32 else { return false }
        return verify(
            publicKey: [UInt8](publicKey),
            signature: [UInt8](signature),
            message: [UInt8](message)
        )
    }

    /// RFC 8032 verify: check `[S]B = R + [H(R‖A‖M)]A`.
    static func verify(publicKey Aenc: [UInt8], signature: [UInt8], message: [UInt8]) -> Bool {
        guard Aenc.count == 32, signature.count == 64 else { return false }
        let s = Array(signature[32..<64])
        if !scValid(s) { return false }
        guard let A = GeP3.fromBytes(Aenc) else { return false }

        var hashIn = [UInt8]()
        hashIn.reserveCapacity(64 + message.count)
        hashIn.append(contentsOf: signature[0..<32])
        hashIn.append(contentsOf: Aenc)
        hashIn.append(contentsOf: message)
        let h = scReduce(SHA512.hash(hashIn))

        // R' = [S]B - [h]A  (using double-scalar: hneg·A + S·B)
        let hneg = scNeg(h)
        let rCheck = Ge.doubleScalarMultVartime(a: hneg, A: A, b: s)
        let rEnc = rCheck.toBytes()
        return ctEqual(rEnc, Array(signature[0..<32]))
    }

    private static func ctEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for i in 0..<a.count { d |= a[i] ^ b[i] }
        return d == 0
    }
}

// MARK: - SHA-512
 
enum SHA512 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        OpenGrokShared.SHA512.hash(message)
    }
}

// MARK: - Field element GF(2^255-19) — 10×25.5-bit limbs

struct Fe {
    /// Limbs t0 + 2^26 t1 + 2^51 t2 + … (ref10).
    var v: (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64)

    init(
        _ v0: Int64 = 0, _ v1: Int64 = 0, _ v2: Int64 = 0, _ v3: Int64 = 0, _ v4: Int64 = 0,
        _ v5: Int64 = 0, _ v6: Int64 = 0, _ v7: Int64 = 0, _ v8: Int64 = 0, _ v9: Int64 = 0
    ) {
        v = (v0, v1, v2, v3, v4, v5, v6, v7, v8, v9)
    }

    static var zero: Fe { Fe() }
    static var one: Fe { Fe(1) }

    subscript(i: Int) -> Int64 {
        get {
            switch i {
            case 0: return v.0; case 1: return v.1; case 2: return v.2; case 3: return v.3
            case 4: return v.4; case 5: return v.5; case 6: return v.6; case 7: return v.7
            case 8: return v.8; default: return v.9
            }
        }
        set {
            switch i {
            case 0: v.0 = newValue; case 1: v.1 = newValue; case 2: v.2 = newValue; case 3: v.3 = newValue
            case 4: v.4 = newValue; case 5: v.5 = newValue; case 6: v.6 = newValue; case 7: v.7 = newValue
            case 8: v.8 = newValue; default: v.9 = newValue
            }
        }
    }

    static func fromBytes(_ s: [UInt8]) -> Fe {
        func load4(_ i: Int) -> Int64 {
            Int64(s[i]) | (Int64(s[i + 1]) << 8) | (Int64(s[i + 2]) << 16) | (Int64(s[i + 3]) << 24)
        }
        var h = Fe.zero
        h[0] = load4(0) & 0x3ffffff
        h[1] = (load4(3) >> 2) & 0x1ffffff
        h[2] = (load4(6) >> 3) & 0x3ffffff
        h[3] = (load4(9) >> 5) & 0x1ffffff
        h[4] = (load4(12) >> 6) & 0x3ffffff
        h[5] = load4(16) & 0x1ffffff
        h[6] = (load4(19) >> 1) & 0x3ffffff
        h[7] = (load4(22) >> 3) & 0x1ffffff
        h[8] = (load4(25) >> 4) & 0x3ffffff
        h[9] = (load4(28) >> 6) & 0x1ffffff
        return h
    }

    func toBytes() -> [UInt8] {
        var h = self
        // Carry pass
        var carry: Int64
        carry = (h[0] + (1 << 25)) >> 26; h[1] &+= carry; h[0] -= carry << 26
        carry = (h[4] + (1 << 25)) >> 26; h[5] &+= carry; h[4] -= carry << 26
        carry = (h[1] + (1 << 24)) >> 25; h[2] &+= carry; h[1] -= carry << 25
        carry = (h[5] + (1 << 24)) >> 25; h[6] &+= carry; h[5] -= carry << 25
        carry = (h[2] + (1 << 25)) >> 26; h[3] &+= carry; h[2] -= carry << 26
        carry = (h[6] + (1 << 25)) >> 26; h[7] &+= carry; h[6] -= carry << 26
        carry = (h[3] + (1 << 24)) >> 25; h[4] &+= carry; h[3] -= carry << 25
        carry = (h[7] + (1 << 24)) >> 25; h[8] &+= carry; h[7] -= carry << 25
        carry = (h[4] + (1 << 25)) >> 26; h[5] &+= carry; h[4] -= carry << 26
        carry = (h[8] + (1 << 25)) >> 26; h[9] &+= carry; h[8] -= carry << 26
        carry = (h[9] + (1 << 24)) >> 25; h[0] &+= carry * 19; h[9] -= carry << 25
        carry = (h[0] + (1 << 25)) >> 26; h[1] &+= carry; h[0] -= carry << 26

        // q = floor(h / p)
        var q = (19 &* h[9] &+ (1 << 24)) >> 25
        q = (h[0] &+ q) >> 26
        q = (h[1] &+ q) >> 25
        q = (h[2] &+ q) >> 26
        q = (h[3] &+ q) >> 25
        q = (h[4] &+ q) >> 26
        q = (h[5] &+ q) >> 25
        q = (h[6] &+ q) >> 26
        q = (h[7] &+ q) >> 25
        q = (h[8] &+ q) >> 26
        q = (h[9] &+ q) >> 25

        h[0] &+= 19 &* q
        carry = h[0] >> 26; h[1] &+= carry; h[0] -= carry << 26
        carry = h[1] >> 25; h[2] &+= carry; h[1] -= carry << 25
        carry = h[2] >> 26; h[3] &+= carry; h[2] -= carry << 26
        carry = h[3] >> 25; h[4] &+= carry; h[3] -= carry << 25
        carry = h[4] >> 26; h[5] &+= carry; h[4] -= carry << 26
        carry = h[5] >> 25; h[6] &+= carry; h[5] -= carry << 25
        carry = h[6] >> 26; h[7] &+= carry; h[6] -= carry << 26
        carry = h[7] >> 25; h[8] &+= carry; h[7] -= carry << 25
        carry = h[8] >> 26; h[9] &+= carry; h[8] -= carry << 26
        carry = h[9] >> 25; h[9] -= carry << 25

        var s = [UInt8](repeating: 0, count: 32)
        s[0] = UInt8(truncatingIfNeeded: h[0])
        s[1] = UInt8(truncatingIfNeeded: h[0] >> 8)
        s[2] = UInt8(truncatingIfNeeded: h[0] >> 16)
        s[3] = UInt8(truncatingIfNeeded: (h[0] >> 24) | (h[1] << 2))
        s[4] = UInt8(truncatingIfNeeded: h[1] >> 6)
        s[5] = UInt8(truncatingIfNeeded: h[1] >> 14)
        s[6] = UInt8(truncatingIfNeeded: (h[1] >> 22) | (h[2] << 3))
        s[7] = UInt8(truncatingIfNeeded: h[2] >> 5)
        s[8] = UInt8(truncatingIfNeeded: h[2] >> 13)
        s[9] = UInt8(truncatingIfNeeded: (h[2] >> 21) | (h[3] << 5))
        s[10] = UInt8(truncatingIfNeeded: h[3] >> 3)
        s[11] = UInt8(truncatingIfNeeded: h[3] >> 11)
        s[12] = UInt8(truncatingIfNeeded: (h[3] >> 19) | (h[4] << 6))
        s[13] = UInt8(truncatingIfNeeded: h[4] >> 2)
        s[14] = UInt8(truncatingIfNeeded: h[4] >> 10)
        s[15] = UInt8(truncatingIfNeeded: h[4] >> 18)
        s[16] = UInt8(truncatingIfNeeded: h[5])
        s[17] = UInt8(truncatingIfNeeded: h[5] >> 8)
        s[18] = UInt8(truncatingIfNeeded: h[5] >> 16)
        s[19] = UInt8(truncatingIfNeeded: (h[5] >> 24) | (h[6] << 1))
        s[20] = UInt8(truncatingIfNeeded: h[6] >> 7)
        s[21] = UInt8(truncatingIfNeeded: h[6] >> 15)
        s[22] = UInt8(truncatingIfNeeded: (h[6] >> 23) | (h[7] << 3))
        s[23] = UInt8(truncatingIfNeeded: h[7] >> 5)
        s[24] = UInt8(truncatingIfNeeded: h[7] >> 13)
        s[25] = UInt8(truncatingIfNeeded: (h[7] >> 21) | (h[8] << 4))
        s[26] = UInt8(truncatingIfNeeded: h[8] >> 4)
        s[27] = UInt8(truncatingIfNeeded: h[8] >> 12)
        s[28] = UInt8(truncatingIfNeeded: (h[8] >> 20) | (h[9] << 6))
        s[29] = UInt8(truncatingIfNeeded: h[9] >> 2)
        s[30] = UInt8(truncatingIfNeeded: h[9] >> 10)
        s[31] = UInt8(truncatingIfNeeded: h[9] >> 18)
        return s
    }

    func isNegative() -> Bool { (toBytes()[0] & 1) == 1 }

    func isNonZero() -> Bool {
        var d: UInt8 = 0
        for b in toBytes() { d |= b }
        return d != 0
    }

    static func + (a: Fe, b: Fe) -> Fe {
        Fe(
            a[0] &+ b[0], a[1] &+ b[1], a[2] &+ b[2], a[3] &+ b[3], a[4] &+ b[4],
            a[5] &+ b[5], a[6] &+ b[6], a[7] &+ b[7], a[8] &+ b[8], a[9] &+ b[9]
        )
    }

    static func - (a: Fe, b: Fe) -> Fe {
        Fe(
            a[0] &- b[0], a[1] &- b[1], a[2] &- b[2], a[3] &- b[3], a[4] &- b[4],
            a[5] &- b[5], a[6] &- b[6], a[7] &- b[7], a[8] &- b[8], a[9] &- b[9]
        )
    }

    prefix static func - (a: Fe) -> Fe {
        Fe(-a[0], -a[1], -a[2], -a[3], -a[4], -a[5], -a[6], -a[7], -a[8], -a[9])
    }

    static func * (lhs: Fe, rhs: Fe) -> Fe {
        let f = lhs, g = rhs
        let f0 = f[0], f1 = f[1], f2 = f[2], f3 = f[3], f4 = f[4]
        let f5 = f[5], f6 = f[6], f7 = f[7], f8 = f[8], f9 = f[9]
        let g0 = g[0], g1 = g[1], g2 = g[2], g3 = g[3], g4 = g[4]
        let g5 = g[5], g6 = g[6], g7 = g[7], g8 = g[8], g9 = g[9]
        let g1_19 = 19 &* g1, g2_19 = 19 &* g2, g3_19 = 19 &* g3, g4_19 = 19 &* g4
        let g5_19 = 19 &* g5, g6_19 = 19 &* g6, g7_19 = 19 &* g7, g8_19 = 19 &* g8, g9_19 = 19 &* g9
        let f1_2 = 2 &* f1, f3_2 = 2 &* f3, f5_2 = 2 &* f5, f7_2 = 2 &* f7, f9_2 = 2 &* f9

        var h0 = f0*g0 &+ f1_2*g9_19 &+ f2*g8_19 &+ f3_2*g7_19 &+ f4*g6_19
            &+ f5_2*g5_19 &+ f6*g4_19 &+ f7_2*g3_19 &+ f8*g2_19 &+ f9_2*g1_19
        var h1 = f0*g1 &+ f1*g0 &+ f2*g9_19 &+ f3*g8_19 &+ f4*g7_19
            &+ f5*g6_19 &+ f6*g5_19 &+ f7*g4_19 &+ f8*g3_19 &+ f9*g2_19
        var h2 = f0*g2 &+ f1_2*g1 &+ f2*g0 &+ f3_2*g9_19 &+ f4*g8_19
            &+ f5_2*g7_19 &+ f6*g6_19 &+ f7_2*g5_19 &+ f8*g4_19 &+ f9_2*g3_19
        var h3 = f0*g3 &+ f1*g2 &+ f2*g1 &+ f3*g0 &+ f4*g9_19
            &+ f5*g8_19 &+ f6*g7_19 &+ f7*g6_19 &+ f8*g5_19 &+ f9*g4_19
        var h4 = f0*g4 &+ f1_2*g3 &+ f2*g2 &+ f3_2*g1 &+ f4*g0
            &+ f5_2*g9_19 &+ f6*g8_19 &+ f7_2*g7_19 &+ f8*g6_19 &+ f9_2*g5_19
        var h5 = f0*g5 &+ f1*g4 &+ f2*g3 &+ f3*g2 &+ f4*g1
            &+ f5*g0 &+ f6*g9_19 &+ f7*g8_19 &+ f8*g7_19 &+ f9*g6_19
        var h6 = f0*g6 &+ f1_2*g5 &+ f2*g4 &+ f3_2*g3 &+ f4*g2
            &+ f5_2*g1 &+ f6*g0 &+ f7_2*g9_19 &+ f8*g8_19 &+ f9_2*g7_19
        var h7 = f0*g7 &+ f1*g6 &+ f2*g5 &+ f3*g4 &+ f4*g3
            &+ f5*g2 &+ f6*g1 &+ f7*g0 &+ f8*g9_19 &+ f9*g8_19
        var h8 = f0*g8 &+ f1_2*g7 &+ f2*g6 &+ f3_2*g5 &+ f4*g4
            &+ f5_2*g3 &+ f6*g2 &+ f7_2*g1 &+ f8*g0 &+ f9_2*g9_19
        var h9 = f0*g9 &+ f1*g8 &+ f2*g7 &+ f3*g6 &+ f4*g5
            &+ f5*g4 &+ f6*g3 &+ f7*g2 &+ f8*g1 &+ f9*g0

        var carry: Int64
        carry = (h0 + (1 << 25)) >> 26; h1 &+= carry; h0 -= carry << 26
        carry = (h4 + (1 << 25)) >> 26; h5 &+= carry; h4 -= carry << 26
        carry = (h1 + (1 << 24)) >> 25; h2 &+= carry; h1 -= carry << 25
        carry = (h5 + (1 << 24)) >> 25; h6 &+= carry; h5 -= carry << 25
        carry = (h2 + (1 << 25)) >> 26; h3 &+= carry; h2 -= carry << 26
        carry = (h6 + (1 << 25)) >> 26; h7 &+= carry; h6 -= carry << 26
        carry = (h3 + (1 << 24)) >> 25; h4 &+= carry; h3 -= carry << 25
        carry = (h7 + (1 << 24)) >> 25; h8 &+= carry; h7 -= carry << 25
        carry = (h4 + (1 << 25)) >> 26; h5 &+= carry; h4 -= carry << 26
        carry = (h8 + (1 << 25)) >> 26; h9 &+= carry; h8 -= carry << 26
        carry = (h9 + (1 << 24)) >> 25; h0 &+= carry * 19; h9 -= carry << 25
        carry = (h0 + (1 << 25)) >> 26; h1 &+= carry; h0 -= carry << 26
        return Fe(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    func squared() -> Fe { self * self }

    func pow22523() -> Fe {
        // z^((q-5)/8) via the standard addition chain.
        var t0 = squared()
        var t1 = t0.squared().squared()
        t1 = self * t1
        t0 = t0 * t1
        var t2 = t0.squared()
        t1 = t1 * t2
        t2 = t1.squared()
        for _ in 1..<5 { t2 = t2.squared() }
        t1 = t2 * t1
        t2 = t1.squared()
        for _ in 1..<10 { t2 = t2.squared() }
        t2 = t2 * t1
        var t3 = t2.squared()
        for _ in 1..<20 { t3 = t3.squared() }
        t2 = t3 * t2
        t2 = t2.squared()
        for _ in 1..<10 { t2 = t2.squared() }
        t1 = t2 * t1
        t2 = t1.squared()
        for _ in 1..<50 { t2 = t2.squared() }
        t2 = t2 * t1
        t3 = t2.squared()
        for _ in 1..<100 { t3 = t3.squared() }
        t2 = t3 * t2
        t2 = t2.squared()
        for _ in 1..<50 { t2 = t2.squared() }
        t1 = t2 * t1
        t1 = t1.squared()
        t1 = t1.squared()
        return t1 * self
    }

    func inverted() -> Fe {
        var t0 = squared()
        var t1 = t0.squared().squared()
        t1 = self * t1
        t0 = t0 * t1
        var t2 = t0.squared()
        t1 = t1 * t2
        t2 = t1.squared()
        for _ in 1..<5 { t2 = t2.squared() }
        t1 = t2 * t1
        t2 = t1.squared()
        for _ in 1..<10 { t2 = t2.squared() }
        t2 = t2 * t1
        var t3 = t2.squared()
        for _ in 1..<20 { t3 = t3.squared() }
        t2 = t3 * t2
        t2 = t2.squared()
        for _ in 1..<10 { t2 = t2.squared() }
        t1 = t2 * t1
        t2 = t1.squared()
        for _ in 1..<50 { t2 = t2.squared() }
        t2 = t2 * t1
        t3 = t2.squared()
        for _ in 1..<100 { t3 = t3.squared() }
        t2 = t3 * t2
        t2 = t2.squared()
        for _ in 1..<50 { t2 = t2.squared() }
        t1 = t2 * t1
        t1 = t1.squared()
        for _ in 1..<5 { t1 = t1.squared() }
        return t1 * t0
    }
}

// Curve constants (little-endian field encodings).
private let FE_D: Fe = Fe.fromBytes([
    0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75,
    0xab, 0xd8, 0x41, 0x41, 0x4d, 0x0a, 0x70, 0x00,
    0x98, 0xe8, 0x79, 0x77, 0x79, 0x40, 0xc7, 0x8c,
    0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c, 0x03, 0x52,
])
private let FE_D2: Fe = FE_D + FE_D
private let FE_SQRT_M1: Fe = Fe.fromBytes([
    0xb0, 0xa0, 0x0e, 0x4a, 0x27, 0x1b, 0xee, 0xc4,
    0x78, 0xe4, 0x2f, 0xad, 0x06, 0x18, 0x43, 0x2f,
    0xa7, 0xd7, 0xfb, 0x3d, 0x99, 0x00, 0x4d, 0x2b,
    0x0b, 0xdf, 0xc1, 0x4f, 0x80, 0x24, 0x83, 0x2b,
])

// MARK: - Group elements

struct GeP3 {
    var X, Y, Z, T: Fe
    static var zero: GeP3 { GeP3(X: .zero, Y: .one, Z: .one, T: .zero) }

    /// Decode a compressed point; nil if not on the curve.
    static func fromBytes(_ s: [UInt8]) -> GeP3? {
        guard s.count == 32 else { return nil }
        var yb = s
        let sign = Int(yb[31] >> 7)
        yb[31] &= 0x7f
        let y = Fe.fromBytes(yb)
        let z = Fe.one
        let y2 = y.squared()
        let u = y2 - z                 // y^2 - 1
        let v = FE_D * y2 + z          // d y^2 + 1
        // ref10 ge_frombytes: x = uv^3 (uv^7)^((q-5)/8)
        let v3 = v.squared() * v       // v^3
        var x = u * v3 * v.squared().squared() // uv^7 = u · v^3 · v^4
        x = x.pow22523()
        x = x * v3 * u

        var check = x.squared() * v - u
        if check.isNonZero() {
            check = x.squared() * v + u
            if check.isNonZero() { return nil }
            x = x * FE_SQRT_M1
        }
        if x.isNegative() != (sign == 1) {
            x = -x
        }
        // Non-canonical: x=0 with sign bit set.
        if !x.isNonZero() && sign == 1 { return nil }
        return GeP3(X: x, Y: y, Z: z, T: x * y)
    }

    func toBytes() -> [UInt8] {
        let recip = Z.inverted()
        let x = X * recip
        let y = Y * recip
        var s = y.toBytes()
        if x.isNegative() { s[31] |= 0x80 }
        return s
    }

    func toCached() -> GeCached {
        GeCached(
            YplusX: Y + X,
            YminusX: Y - X,
            Z: Z,
            T2d: T * FE_D2
        )
    }

    func toP2() -> GeP2 { GeP2(X: X, Y: Y, Z: Z) }
}

struct GeP2 {
    var X, Y, Z: Fe
    static var zero: GeP2 { GeP2(X: .zero, Y: .one, Z: .one) }

    func dbl() -> GeP1P1 {
        let XX = X.squared()
        let YY = Y.squared()
        let B = Z.squared() + Z.squared()
        let A = X + Y
        let AA = A.squared()
        let YnX = YY + XX
        let YmX = YY - XX
        let E = AA - YnX
        let G = YnX
        let F = YmX
        let H = B - F
        return GeP1P1(X: E, Y: G, Z: F, T: H)
    }

    func toBytes() -> [UInt8] {
        let recip = Z.inverted()
        let x = X * recip
        let y = Y * recip
        var s = y.toBytes()
        if x.isNegative() { s[31] |= 0x80 }
        return s
    }
}

struct GeP1P1 {
    var X, Y, Z, T: Fe
    func toP2() -> GeP2 { GeP2(X: X * T, Y: Y * Z, Z: Z * T) }
    func toP3() -> GeP3 { GeP3(X: X * T, Y: Y * Z, Z: Z * T, T: X * Y) }
}

struct GeCached {
    var YplusX, YminusX, Z, T2d: Fe
}

struct GePrecomp {
    var yplusx, yminusx, xy2d: Fe
}

enum Ge {
    static func add(_ p: GeP3, _ q: GeCached) -> GeP1P1 {
        let YplusX = p.Y + p.X
        let YminusX = p.Y - p.X
        let A = YplusX * q.YplusX
        let B = YminusX * q.YminusX
        let C = q.T2d * p.T
        let ZZ = p.Z * q.Z
        let D = ZZ + ZZ
        let E = A - B
        let F = D - C
        let G = D + C
        let H = A + B
        return GeP1P1(X: E, Y: H, Z: G, T: F)
    }

    static func sub(_ p: GeP3, _ q: GeCached) -> GeP1P1 {
        let YplusX = p.Y + p.X
        let YminusX = p.Y - p.X
        let A = YplusX * q.YminusX
        let B = YminusX * q.YplusX
        let C = q.T2d * p.T
        let ZZ = p.Z * q.Z
        let D = ZZ + ZZ
        let E = A - B
        let F = D + C
        let G = D - C
        let H = A + B
        return GeP1P1(X: E, Y: H, Z: G, T: F)
    }

    static func madd(_ p: GeP3, _ q: GePrecomp) -> GeP1P1 {
        let YplusX = p.Y + p.X
        let YminusX = p.Y - p.X
        let A = YplusX * q.yplusx
        let B = YminusX * q.yminusx
        let C = q.xy2d * p.T
        let D = p.Z + p.Z
        let E = A - B
        let F = D - C
        let G = D + C
        let H = A + B
        return GeP1P1(X: E * F, Y: G * H, Z: F * G, T: E * H)
    }

    static func msub(_ p: GeP3, _ q: GePrecomp) -> GeP1P1 {
        let YplusX = p.Y + p.X
        let YminusX = p.Y - p.X
        let A = YplusX * q.yminusx
        let B = YminusX * q.yplusx
        let C = q.xy2d * p.T
        let D = p.Z + p.Z
        let E = A - B
        let F = D + C
        let G = D - C
        let H = A + B
        return GeP1P1(X: E * F, Y: G * H, Z: F * G, T: E * H)
    }

    /// a·A + b·B (B = basepoint), variable-time.
    static func doubleScalarMultVartime(a: [UInt8], A: GeP3, b: [UInt8]) -> GeP2 {
        let aslide = slide(a)
        let bslide = slide(b)
        let Ai = precomputeOddMultiples(A)
        let Bi = baseOddMultiples()

        var r = GeP2.zero
        var i = 255
        while i >= 0 && aslide[i] == 0 && bslide[i] == 0 { i -= 1 }
        while i >= 0 {
            var t = r.dbl()
            if aslide[i] > 0 {
                t = add(t.toP3(), Ai[Int(aslide[i] / 2)])
            } else if aslide[i] < 0 {
                t = sub(t.toP3(), Ai[Int((-aslide[i]) / 2)])
            }
            if bslide[i] > 0 {
                t = add(t.toP3(), Bi[Int(bslide[i] / 2)])
            } else if bslide[i] < 0 {
                t = sub(t.toP3(), Bi[Int((-bslide[i]) / 2)])
            }
            r = t.toP2()
            i -= 1
        }
        return r
    }
}

private func precomputeOddMultiples(_ A: GeP3) -> [GeCached] {
    var Ai = [GeCached](repeating: GeCached(YplusX: .zero, YminusX: .zero, Z: .zero, T2d: .zero), count: 8)
    Ai[0] = A.toCached()
    let A2 = A.toP2().dbl().toP3()
    for i in 1..<8 {
        Ai[i] = Ge.add(A2, Ai[i - 1]).toP3().toCached()
    }
    return Ai
}

private func baseOddMultiples() -> [GeCached] {
    // Basepoint compressed y = 4/5.
    let by: [UInt8] = [
        0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
        0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
        0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
        0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    ]
    guard let B = GeP3.fromBytes(by) else {
        return Array(
            repeating: GeCached(YplusX: .one, YminusX: .one, Z: .one, T2d: .zero),
            count: 8
        )
    }
    return precomputeOddMultiples(B)
}

private func slide(_ a: [UInt8]) -> [Int8] {
    var r = [Int8](repeating: 0, count: 256)
    for i in 0..<256 {
        r[i] = Int8(1 & (a[i >> 3] >> (i & 7)))
    }
    for i in 0..<256 where r[i] != 0 {
        var b = 1
        while b <= 6 && i + b < 256 {
            if r[i + b] != 0 {
                if r[i] + (r[i + b] << b) <= 15 {
                    r[i] += r[i + b] << b
                    r[i + b] = 0
                } else if r[i] - (r[i + b] << b) >= -15 {
                    r[i] -= r[i + b] << b
                    var k = i + b
                    while k < 256 {
                        if r[k] == 0 {
                            r[k] = 1
                            break
                        }
                        r[k] = 0
                        k += 1
                    }
                } else {
                    break
                }
            }
            b += 1
        }
    }
    return r
}

// MARK: - Scalars mod L

private let L_BYTES: [UInt8] = [
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
    0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
]

private func scValid(_ s: [UInt8]) -> Bool {
    guard s.count == 32 else { return false }
    for i in stride(from: 31, through: 0, by: -1) {
        if s[i] < L_BYTES[i] { return true }
        if s[i] > L_BYTES[i] { return false }
    }
    return false
}

private func scNeg(_ s: [UInt8]) -> [UInt8] {
    var nz: UInt8 = 0
    for b in s { nz |= b }
    if nz == 0 { return [UInt8](repeating: 0, count: 32) }
    var out = [UInt8](repeating: 0, count: 32)
    var borrow = 0
    for i in 0..<32 {
        let d = Int(L_BYTES[i]) - Int(s[i]) - borrow
        if d < 0 {
            out[i] = UInt8(d + 256)
            borrow = 1
        } else {
            out[i] = UInt8(d)
            borrow = 0
        }
    }
    return out
}

/// Reduce a 64-byte little-endian integer mod L (ref10 `sc_reduce`).
private func scReduce(_ s: [UInt8]) -> [UInt8] {
    precondition(s.count == 64)
    func load3(_ i: Int) -> Int64 {
        Int64(s[i]) | (Int64(s[i + 1]) << 8) | (Int64(s[i + 2]) << 16)
    }
    func load4(_ i: Int) -> Int64 {
        Int64(s[i]) | (Int64(s[i + 1]) << 8) | (Int64(s[i + 2]) << 16) | (Int64(s[i + 3]) << 24)
    }

    var s0 = 2097151 & load3(0)
    var s1 = 2097151 & (load4(2) >> 5)
    var s2 = 2097151 & (load3(5) >> 2)
    var s3 = 2097151 & (load4(7) >> 7)
    var s4 = 2097151 & (load4(10) >> 4)
    var s5 = 2097151 & (load3(13) >> 1)
    var s6 = 2097151 & (load4(15) >> 6)
    var s7 = 2097151 & (load3(18) >> 3)
    var s8 = 2097151 & load3(21)
    var s9 = 2097151 & (load4(23) >> 5)
    var s10 = 2097151 & (load3(26) >> 2)
    var s11 = 2097151 & (load4(28) >> 7)
    var s12 = 2097151 & (load4(31) >> 4)
    var s13 = 2097151 & (load3(34) >> 1)
    var s14 = 2097151 & (load4(36) >> 6)
    var s15 = 2097151 & (load3(39) >> 3)
    var s16 = 2097151 & load3(42)
    var s17 = 2097151 & (load4(44) >> 5)
    let s18 = 2097151 & (load3(47) >> 2)
    let s19 = 2097151 & (load4(49) >> 7)
    let s20 = 2097151 & (load4(52) >> 4)
    let s21 = 2097151 & (load3(55) >> 1)
    let s22 = 2097151 & (load4(57) >> 6)
    let s23 = (load4(60) >> 3)

    s11 &+= s23 * 666643
    s12 &+= s23 * 470296
    s13 &+= s23 * 654183
    s14 &-= s23 * 997805
    s15 &+= s23 * 136657
    s16 &-= s23 * 683901

    s10 &+= s22 * 666643
    s11 &+= s22 * 470296
    s12 &+= s22 * 654183
    s13 &-= s22 * 997805
    s14 &+= s22 * 136657
    s15 &-= s22 * 683901

    s9 &+= s21 * 666643
    s10 &+= s21 * 470296
    s11 &+= s21 * 654183
    s12 &-= s21 * 997805
    s13 &+= s21 * 136657
    s14 &-= s21 * 683901

    s8 &+= s20 * 666643
    s9 &+= s20 * 470296
    s10 &+= s20 * 654183
    s11 &-= s20 * 997805
    s12 &+= s20 * 136657
    s13 &-= s20 * 683901

    s7 &+= s19 * 666643
    s8 &+= s19 * 470296
    s9 &+= s19 * 654183
    s10 &-= s19 * 997805
    s11 &+= s19 * 136657
    s12 &-= s19 * 683901

    s6 &+= s18 * 666643
    s7 &+= s18 * 470296
    s8 &+= s18 * 654183
    s9 &-= s18 * 997805
    s10 &+= s18 * 136657
    s11 &-= s18 * 683901

    var carry: Int64
    carry = (s6 + (1 << 20)) >> 21; s7 &+= carry; s6 -= carry << 21
    carry = (s8 + (1 << 20)) >> 21; s9 &+= carry; s8 -= carry << 21
    carry = (s10 + (1 << 20)) >> 21; s11 &+= carry; s10 -= carry << 21
    carry = (s12 + (1 << 20)) >> 21; s13 &+= carry; s12 -= carry << 21
    carry = (s14 + (1 << 20)) >> 21; s15 &+= carry; s14 -= carry << 21
    carry = (s16 + (1 << 20)) >> 21; s17 &+= carry; s16 -= carry << 21

    carry = (s7 + (1 << 20)) >> 21; s8 &+= carry; s7 -= carry << 21
    carry = (s9 + (1 << 20)) >> 21; s10 &+= carry; s9 -= carry << 21
    carry = (s11 + (1 << 20)) >> 21; s12 &+= carry; s11 -= carry << 21
    carry = (s13 + (1 << 20)) >> 21; s14 &+= carry; s13 -= carry << 21
    carry = (s15 + (1 << 20)) >> 21; s16 &+= carry; s15 -= carry << 21

    s5 &+= s17 * 666643
    s6 &+= s17 * 470296
    s7 &+= s17 * 654183
    s8 &-= s17 * 997805
    s9 &+= s17 * 136657
    s10 &-= s17 * 683901

    s4 &+= s16 * 666643
    s5 &+= s16 * 470296
    s6 &+= s16 * 654183
    s7 &-= s16 * 997805
    s8 &+= s16 * 136657
    s9 &-= s16 * 683901

    s3 &+= s15 * 666643
    s4 &+= s15 * 470296
    s5 &+= s15 * 654183
    s6 &-= s15 * 997805
    s7 &+= s15 * 136657
    s8 &-= s15 * 683901

    s2 &+= s14 * 666643
    s3 &+= s14 * 470296
    s4 &+= s14 * 654183
    s5 &-= s14 * 997805
    s6 &+= s14 * 136657
    s7 &-= s14 * 683901

    s1 &+= s13 * 666643
    s2 &+= s13 * 470296
    s3 &+= s13 * 654183
    s4 &-= s13 * 997805
    s5 &+= s13 * 136657
    s6 &-= s13 * 683901

    s0 &+= s12 * 666643
    s1 &+= s12 * 470296
    s2 &+= s12 * 654183
    s3 &-= s12 * 997805
    s4 &+= s12 * 136657
    s5 &-= s12 * 683901
    s12 = 0

    carry = (s0 + (1 << 20)) >> 21; s1 &+= carry; s0 -= carry << 21
    carry = (s2 + (1 << 20)) >> 21; s3 &+= carry; s2 -= carry << 21
    carry = (s4 + (1 << 20)) >> 21; s5 &+= carry; s4 -= carry << 21
    carry = (s6 + (1 << 20)) >> 21; s7 &+= carry; s6 -= carry << 21
    carry = (s8 + (1 << 20)) >> 21; s9 &+= carry; s8 -= carry << 21
    carry = (s10 + (1 << 20)) >> 21; s11 &+= carry; s10 -= carry << 21

    carry = (s1 + (1 << 20)) >> 21; s2 &+= carry; s1 -= carry << 21
    carry = (s3 + (1 << 20)) >> 21; s4 &+= carry; s3 -= carry << 21
    carry = (s5 + (1 << 20)) >> 21; s6 &+= carry; s5 -= carry << 21
    carry = (s7 + (1 << 20)) >> 21; s8 &+= carry; s7 -= carry << 21
    carry = (s9 + (1 << 20)) >> 21; s10 &+= carry; s9 -= carry << 21
    carry = (s11 + (1 << 20)) >> 21; s12 &+= carry; s11 -= carry << 21

    s0 &+= s12 * 666643
    s1 &+= s12 * 470296
    s2 &+= s12 * 654183
    s3 &-= s12 * 997805
    s4 &+= s12 * 136657
    s5 &-= s12 * 683901
    s12 = 0

    carry = (s0 + (1 << 20)) >> 21; s1 &+= carry; s0 -= carry << 21
    carry = (s1 + (1 << 20)) >> 21; s2 &+= carry; s1 -= carry << 21
    carry = (s2 + (1 << 20)) >> 21; s3 &+= carry; s2 -= carry << 21
    carry = (s3 + (1 << 20)) >> 21; s4 &+= carry; s3 -= carry << 21
    carry = (s4 + (1 << 20)) >> 21; s5 &+= carry; s4 -= carry << 21
    carry = (s5 + (1 << 20)) >> 21; s6 &+= carry; s5 -= carry << 21
    carry = (s6 + (1 << 20)) >> 21; s7 &+= carry; s6 -= carry << 21
    carry = (s7 + (1 << 20)) >> 21; s8 &+= carry; s7 -= carry << 21
    carry = (s8 + (1 << 20)) >> 21; s9 &+= carry; s8 -= carry << 21
    carry = (s9 + (1 << 20)) >> 21; s10 &+= carry; s9 -= carry << 21
    carry = (s10 + (1 << 20)) >> 21; s11 &+= carry; s10 -= carry << 21
    carry = (s11 + (1 << 20)) >> 21; s12 &+= carry; s11 -= carry << 21

    s0 &+= s12 * 666643
    s1 &+= s12 * 470296
    s2 &+= s12 * 654183
    s3 &-= s12 * 997805
    s4 &+= s12 * 136657
    s5 &-= s12 * 683901

    carry = s0 >> 21; s1 &+= carry; s0 -= carry << 21
    carry = s1 >> 21; s2 &+= carry; s1 -= carry << 21
    carry = s2 >> 21; s3 &+= carry; s2 -= carry << 21
    carry = s3 >> 21; s4 &+= carry; s3 -= carry << 21
    carry = s4 >> 21; s5 &+= carry; s4 -= carry << 21
    carry = s5 >> 21; s6 &+= carry; s5 -= carry << 21
    carry = s6 >> 21; s7 &+= carry; s6 -= carry << 21
    carry = s7 >> 21; s8 &+= carry; s7 -= carry << 21
    carry = s8 >> 21; s9 &+= carry; s8 -= carry << 21
    carry = s9 >> 21; s10 &+= carry; s9 -= carry << 21
    carry = s10 >> 21; s11 &+= carry; s10 -= carry << 21

    var out = [UInt8](repeating: 0, count: 32)
    out[0] = UInt8(truncatingIfNeeded: s0)
    out[1] = UInt8(truncatingIfNeeded: s0 >> 8)
    out[2] = UInt8(truncatingIfNeeded: (s0 >> 16) | (s1 << 5))
    out[3] = UInt8(truncatingIfNeeded: s1 >> 3)
    out[4] = UInt8(truncatingIfNeeded: s1 >> 11)
    out[5] = UInt8(truncatingIfNeeded: (s1 >> 19) | (s2 << 2))
    out[6] = UInt8(truncatingIfNeeded: s2 >> 6)
    out[7] = UInt8(truncatingIfNeeded: (s2 >> 14) | (s3 << 7))
    out[8] = UInt8(truncatingIfNeeded: s3 >> 1)
    out[9] = UInt8(truncatingIfNeeded: s3 >> 9)
    out[10] = UInt8(truncatingIfNeeded: (s3 >> 17) | (s4 << 4))
    out[11] = UInt8(truncatingIfNeeded: s4 >> 4)
    out[12] = UInt8(truncatingIfNeeded: s4 >> 12)
    out[13] = UInt8(truncatingIfNeeded: (s4 >> 20) | (s5 << 1))
    out[14] = UInt8(truncatingIfNeeded: s5 >> 7)
    out[15] = UInt8(truncatingIfNeeded: (s5 >> 15) | (s6 << 6))
    out[16] = UInt8(truncatingIfNeeded: s6 >> 2)
    out[17] = UInt8(truncatingIfNeeded: s6 >> 10)
    out[18] = UInt8(truncatingIfNeeded: (s6 >> 18) | (s7 << 3))
    out[19] = UInt8(truncatingIfNeeded: s7 >> 5)
    out[20] = UInt8(truncatingIfNeeded: s7 >> 13)
    out[21] = UInt8(truncatingIfNeeded: s8)
    out[22] = UInt8(truncatingIfNeeded: s8 >> 8)
    out[23] = UInt8(truncatingIfNeeded: (s8 >> 16) | (s9 << 5))
    out[24] = UInt8(truncatingIfNeeded: s9 >> 3)
    out[25] = UInt8(truncatingIfNeeded: s9 >> 11)
    out[26] = UInt8(truncatingIfNeeded: (s9 >> 19) | (s10 << 2))
    out[27] = UInt8(truncatingIfNeeded: s10 >> 6)
    out[28] = UInt8(truncatingIfNeeded: (s10 >> 14) | (s11 << 7))
    out[29] = UInt8(truncatingIfNeeded: s11 >> 1)
    out[30] = UInt8(truncatingIfNeeded: s11 >> 9)
    out[31] = UInt8(truncatingIfNeeded: s11 >> 17)
    return out
}
