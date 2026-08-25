import Foundation
import Testing
@testable import OpenGrokMemory

@Suite("Memory chunk hashes match Rust BLAKE3")
struct MemoryChunkHashParityTests {
    @Test("official empty and abc vectors match blake3::hash")
    func officialBlake3Vectors() {
        #expect(
            chunkHash("")
                == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        )
        #expect(
            chunkHash("abc")
                == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
        )
    }

    @Test("Rust fixture hash differs from the former SHA-256 implementation")
    func rustTextFixture() {
        #expect(
            chunkHash("hello")
                == "ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f"
        )
        #expect(
            chunkHash("hello")
                != "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }
}
