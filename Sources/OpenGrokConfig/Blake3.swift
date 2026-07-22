// Blake3.swift
//
// Pure-Swift BLAKE3 one-shot hasher for session-directory encoding parity
// with Rust `blake3::hash`. No CryptoKit / external dependency: this must
// compile and produce identical digests on macOS, Linux, and Windows.
//
// Implements the BLAKE3 hash mode (no keyed hash, no derive_key, no tree
// reduce beyond the single-chunk and multi-chunk parent-node paths required
// for arbitrary-length inputs). Spec: https://github.com/BLAKE3-team/BLAKE3

import Foundation

/// Pure-Swift BLAKE3. Public so tests can pin official vectors without going
/// through the path helpers.
public enum Blake3 {
    /// 32-byte BLAKE3 digest of `data`.
    public static func hash(_ data: Data) -> Data {
        hash(Array(data))
    }

    /// 32-byte BLAKE3 digest of `bytes`.
    public static func hash(_ bytes: [UInt8]) -> Data {
        Data(Hasher.hash(bytes))
    }

    /// Lowercase hex of the full 32-byte digest.
    public static func hexDigest(_ bytes: [UInt8]) -> String {
        Hasher.hash(bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// First `n` lowercase hex characters of the digest (used by
    /// `encodeCwdDirname`, which takes 16).
    public static func hexPrefix(_ string: String, length: Int = 16) -> String {
        let full = hexDigest(Array(string.utf8))
        return String(full.prefix(length))
    }
}

// MARK: - Implementation

private enum Hasher {
    // BLAKE2s / BLAKE3 IV.
    static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    static let chunkLen = 1024
    static let blockLen = 64
    static let outLen = 32

    // Flag bits.
    static let chunkStart: UInt32 = 1 << 0
    static let chunkEnd: UInt32 = 1 << 1
    static let parent: UInt32 = 1 << 2
    static let root: UInt32 = 1 << 3

    static let msgPermutation: [Int] = [
        2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8,
    ]

    static func hash(_ input: [UInt8]) -> [UInt8] {
        if input.count <= chunkLen {
            return hashSingleChunk(input)
        }
        return hashMultiChunk(input)
    }

    /// Messages that fit in one chunk: compress blocks, then finalize as root.
    static func hashSingleChunk(_ input: [UInt8]) -> [UInt8] {
        var chaining = iv
        var blockFlags: UInt32 = chunkStart
        var offset = 0
        if input.isEmpty {
            // Empty message: one empty block with CHUNK_START|CHUNK_END|ROOT.
            return compress(
                chainingValue: chaining,
                block: [UInt8](repeating: 0, count: blockLen),
                blockLen: 0,
                counter: 0,
                flags: chunkStart | chunkEnd | root
            )
        }
        while offset < input.count {
            let remaining = input.count - offset
            let take = min(blockLen, remaining)
            var block = [UInt8](repeating: 0, count: blockLen)
            block.replaceSubrange(0..<take, with: input[offset..<(offset + take)])
            offset += take
            let isLast = offset >= input.count
            var flags = blockFlags
            if isLast {
                flags |= chunkEnd | root
                return compress(
                    chainingValue: chaining,
                    block: block,
                    blockLen: UInt32(take),
                    counter: 0,
                    flags: flags
                )
            }
            chaining = compressCV(
                chainingValue: chaining,
                block: block,
                blockLen: UInt32(take),
                counter: 0,
                flags: flags
            )
            blockFlags = 0 // only first block of the chunk has CHUNK_START
        }
        // Unreachable: loop always returns on last block.
        return [UInt8](repeating: 0, count: outLen)
    }

    /// Multi-chunk: hash each full chunk to a CV, then build a binary parent
    /// tree (left-to-right) and finalize the root.
    static func hashMultiChunk(_ input: [UInt8]) -> [UInt8] {
        var cvs: [[UInt32]] = []
        var chunkIndex: UInt64 = 0
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunkLen, input.count)
            let chunk = Array(input[offset..<end])
            cvs.append(chunkCV(chunk, counter: chunkIndex))
            chunkIndex += 1
            offset = end
        }
        // Parent tree: while more than one CV, pair them left-to-right.
        // An odd leftover is carried up unchanged (BLAKE3 subtree rule).
        while cvs.count > 1 {
            var next: [[UInt32]] = []
            var i = 0
            while i < cvs.count {
                if i + 1 < cvs.count {
                    next.append(parentCV(left: cvs[i], right: cvs[i + 1], isRoot: false))
                    i += 2
                } else {
                    next.append(cvs[i])
                    i += 1
                }
            }
            // The above left-fold is wrong for BLAKE3's tree. BLAKE3 uses a
            // stack-based subtree combiner. Use the correct stack method.
            break
        }
        return hashMultiChunkStack(input)
    }

    /// Correct multi-chunk path using BLAKE3's CV stack.
    static func hashMultiChunkStack(_ input: [UInt8]) -> [UInt8] {
        var cvStack: [[UInt32]] = []
        var totalChunks: UInt64 = 0
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunkLen, input.count)
            let chunk = Array(input[offset..<end])
            let isLastChunk = end >= input.count
            if isLastChunk {
                // Finalize root from remaining stack + this final chunk.
                return finalizeRoot(
                    stack: cvStack,
                    finalChunk: chunk,
                    chunkCounter: totalChunks
                )
            }
            let cv = chunkCV(chunk, counter: totalChunks)
            totalChunks += 1
            cvStack.append(cv)
            // Merge complete subtrees (pop pairs while trailing zeros in count).
            var count = totalChunks
            while count & 1 == 0 {
                let right = cvStack.removeLast()
                let left = cvStack.removeLast()
                cvStack.append(parentCV(left: left, right: right, isRoot: false))
                count >>= 1
            }
            offset = end
        }
        // Empty already handled; single-chunk handled above.
        return [UInt8](repeating: 0, count: outLen)
    }

    static func finalizeRoot(
        stack: [[UInt32]],
        finalChunk: [UInt8],
        chunkCounter: UInt64
    ) -> [UInt8] {
        // Compress final chunk blocks; last block sets CHUNK_END. If the stack
        // is empty this is also ROOT; otherwise we produce a CV and merge.
        var chaining = iv
        var blockFlags: UInt32 = chunkStart
        var offset = 0
        var lastCV: [UInt32] = chaining
        var lastBlock = [UInt8](repeating: 0, count: blockLen)
        var lastBlockLen: UInt32 = 0
        var lastFlags: UInt32 = 0

        if finalChunk.isEmpty {
            lastBlockLen = 0
            lastFlags = chunkStart | chunkEnd
            lastCV = chaining
        } else {
            while offset < finalChunk.count {
                let remaining = finalChunk.count - offset
                let take = min(blockLen, remaining)
                var block = [UInt8](repeating: 0, count: blockLen)
                block.replaceSubrange(0..<take, with: finalChunk[offset..<(offset + take)])
                offset += take
                let isLast = offset >= finalChunk.count
                var flags = blockFlags
                if isLast {
                    flags |= chunkEnd
                    lastCV = chaining
                    lastBlock = block
                    lastBlockLen = UInt32(take)
                    lastFlags = flags
                    break
                }
                chaining = compressCV(
                    chainingValue: chaining,
                    block: block,
                    blockLen: UInt32(take),
                    counter: chunkCounter,
                    flags: flags
                )
                blockFlags = 0
            }
        }

        // If no parents, finalize as root on the last block.
        if stack.isEmpty {
            return compress(
                chainingValue: lastCV,
                block: lastBlock,
                blockLen: lastBlockLen,
                counter: chunkCounter,
                flags: lastFlags | root
            )
        }

        // Non-root final chunk CV.
        var cv = compressCV(
            chainingValue: lastCV,
            block: lastBlock,
            blockLen: lastBlockLen,
            counter: chunkCounter,
            flags: lastFlags
        )

        // Merge up the stack right-to-left; the final parent is ROOT.
        var s = stack
        while !s.isEmpty {
            let left = s.removeLast()
            let isRoot = s.isEmpty
            if isRoot {
                return parentRootOutput(left: left, right: cv)
            }
            cv = parentCV(left: left, right: cv, isRoot: false)
        }
        return wordsToBytes(cv)
    }

    static func chunkCV(_ chunk: [UInt8], counter: UInt64) -> [UInt32] {
        var chaining = iv
        var blockFlags: UInt32 = chunkStart
        var offset = 0
        if chunk.isEmpty {
            return compressCV(
                chainingValue: chaining,
                block: [UInt8](repeating: 0, count: blockLen),
                blockLen: 0,
                counter: counter,
                flags: chunkStart | chunkEnd
            )
        }
        while offset < chunk.count {
            let remaining = chunk.count - offset
            let take = min(blockLen, remaining)
            var block = [UInt8](repeating: 0, count: blockLen)
            block.replaceSubrange(0..<take, with: chunk[offset..<(offset + take)])
            offset += take
            var flags = blockFlags
            let isLast = offset >= chunk.count
            if isLast { flags |= chunkEnd }
            chaining = compressCV(
                chainingValue: chaining,
                block: block,
                blockLen: UInt32(take),
                counter: counter,
                flags: flags
            )
            if isLast { return chaining }
            blockFlags = 0
        }
        return chaining
    }

    static func parentCV(left: [UInt32], right: [UInt32], isRoot: Bool) -> [UInt32] {
        var block = [UInt8](repeating: 0, count: blockLen)
        let leftBytes = wordsToBytes(left)
        let rightBytes = wordsToBytes(right)
        for i in 0..<32 { block[i] = leftBytes[i] }
        for i in 0..<32 { block[32 + i] = rightBytes[i] }
        var flags = parent
        if isRoot { flags |= root }
        return compressCV(
            chainingValue: iv,
            block: block,
            blockLen: UInt32(blockLen),
            counter: 0,
            flags: flags
        )
    }

    static func parentRootOutput(left: [UInt32], right: [UInt32]) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: blockLen)
        let leftBytes = wordsToBytes(left)
        let rightBytes = wordsToBytes(right)
        for i in 0..<32 { block[i] = leftBytes[i] }
        for i in 0..<32 { block[32 + i] = rightBytes[i] }
        return compress(
            chainingValue: iv,
            block: block,
            blockLen: UInt32(blockLen),
            counter: 0,
            flags: parent | root
        )
    }

    /// Compress and return the first 8 words as a chaining value.
    static func compressCV(
        chainingValue: [UInt32],
        block: [UInt8],
        blockLen: UInt32,
        counter: UInt64,
        flags: UInt32
    ) -> [UInt32] {
        let state = compressState(
            chainingValue: chainingValue,
            block: block,
            blockLen: blockLen,
            counter: counter,
            flags: flags
        )
        return Array(state.prefix(8))
    }

    /// Compress and return the 32-byte output (first 8 little-endian words).
    static func compress(
        chainingValue: [UInt32],
        block: [UInt8],
        blockLen: UInt32,
        counter: UInt64,
        flags: UInt32
    ) -> [UInt8] {
        wordsToBytes(compressCV(
            chainingValue: chainingValue,
            block: block,
            blockLen: blockLen,
            counter: counter,
            flags: flags
        ))
    }

    static func compressState(
        chainingValue: [UInt32],
        block: [UInt8],
        blockLen: UInt32,
        counter: UInt64,
        flags: UInt32
    ) -> [UInt32] {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let j = i * 4
            m[i] = UInt32(block[j])
                | (UInt32(block[j + 1]) << 8)
                | (UInt32(block[j + 2]) << 16)
                | (UInt32(block[j + 3]) << 24)
        }
        var v = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 { v[i] = chainingValue[i] }
        v[8] = iv[0]
        v[9] = iv[1]
        v[10] = iv[2]
        v[11] = iv[3]
        v[12] = UInt32(truncatingIfNeeded: counter)
        v[13] = UInt32(truncatingIfNeeded: counter >> 32)
        v[14] = blockLen
        v[15] = flags

        // 7 rounds; message is permuted between rounds (not after the last).
        var msg = m
        round(state: &v, m: msg)
        for _ in 0..<6 {
            msg = permute(msg)
            round(state: &v, m: msg)
        }

        // BLAKE3 / BLAKE2s finalize with XOR (not addition).
        var out = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 {
            out[i] = v[i] ^ v[i + 8]
            out[i + 8] = chainingValue[i] ^ v[i + 8]
        }
        return out
    }

    static func round(state: inout [UInt32], m: [UInt32]) {
        // Columns.
        g(&state, 0, 4, 8, 12, m[0], m[1])
        g(&state, 1, 5, 9, 13, m[2], m[3])
        g(&state, 2, 6, 10, 14, m[4], m[5])
        g(&state, 3, 7, 11, 15, m[6], m[7])
        // Diagonals (BLAKE3 reference_impl order).
        g(&state, 0, 5, 10, 15, m[8], m[9])
        g(&state, 1, 6, 11, 12, m[10], m[11])
        g(&state, 2, 7, 8, 13, m[12], m[13])
        g(&state, 3, 4, 9, 14, m[14], m[15])
    }

    static func g(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ mx: UInt32, _ my: UInt32) {
        s[a] = s[a] &+ s[b] &+ mx
        s[d] = rotr32(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]
        s[b] = rotr32(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b] &+ my
        s[d] = rotr32(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]
        s[b] = rotr32(s[b] ^ s[c], 7)
    }

    static func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    static func permute(_ m: [UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 { out[i] = m[msgPermutation[i]] }
        return out
    }

    static func wordsToBytes(_ words: [UInt32]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(words.count * 4)
        for w in words.prefix(8) {
            out.append(UInt8(truncatingIfNeeded: w))
            out.append(UInt8(truncatingIfNeeded: w >> 8))
            out.append(UInt8(truncatingIfNeeded: w >> 16))
            out.append(UInt8(truncatingIfNeeded: w >> 24))
        }
        return out
    }
}
