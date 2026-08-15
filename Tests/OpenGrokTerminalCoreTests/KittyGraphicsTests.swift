// KittyGraphicsTests.swift
//
// Pin-correct Kitty graphics encoder tests.
// Reference: crates/codegen/xai-grok-pager-render/src/terminal/image.rs
//            and image/tests.rs @ 650c1db7

import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("Kitty graphics encoder", .serialized)
struct KittyGraphicsTests {

    // MARK: - Brand matrix

    @Test("protocolForBrand matches pin matrix and Windows is always none")
    func protocolBrandMatrix() {
        let expected: [(MouseScrollTerminalBrand, KittyGraphicsProtocol)] = [
            (.kitty, .kitty),
            (.ghostty, .kitty),
            (.wezTerm, .kitty),
            (.warpTerminal, .kitty),
            (.iterm2, .none),
            (.unknown, .none),
            (.appleTerminal, .none),
            (.alacritty, .none),
            (.rio, .none),
            (.foot, .none),
            (.vsCode, .none),
            (.cursor, .none),
            (.windsurf, .none),
            (.zed, .none),
            (.grokDesktop, .none),
            (.vte, .none),
            (.terminator, .none),
            (.windowsTerminal, .none),
            (.jetBrains, .none),
            (.otty, .none),
        ]

        for (brand, protocolKind) in expected {
            let unix = KittyGraphics.protocolForBrand(brand: brand, isWindows: false)
            #expect(unix == protocolKind, "unix brand \(brand) → \(protocolKind)")
            let windows = KittyGraphics.protocolForBrand(brand: brand, isWindows: true)
            #expect(windows == .none, "windows brand \(brand) stays none")
        }

        #expect(KittyGraphics.protocolForBrand(brand: .iterm2) == .none)
        #expect(KittyGraphicsProtocol.none.supportsImages == false)
        #expect(KittyGraphicsProtocol.kitty.supportsImages)
    }

    @Test("iTerm2 brand yields none so scrollback never uses OSC 1337")
    func iterm2BrandYieldsNone() {
        let proto = KittyGraphics.protocolForBrand(brand: .iterm2, isWindows: false)
        #expect(proto == .none)
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: proto, brand: .iterm2) == false
        )
    }

    @Test("scrollback overlay excludes Warp even though protocol is kitty")
    func scrollbackOverlayExcludesWarp() {
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: .kitty, brand: .kitty)
        )
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: .kitty, brand: .ghostty)
        )
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: .kitty, brand: .wezTerm)
        )
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: .kitty, brand: .warpTerminal)
                == false
        )
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: .none, brand: .kitty) == false
        )
    }

    // MARK: - Force-off

    @Test("force-off defaults false and overrides capability")
    func forceOffOverridesCapability() {
        let previous = scrollbackInlineOverlayForcedOff()
        defer { setInlineOverlayForceOff(previous) }

        setInlineOverlayForceOff(false)
        #expect(scrollbackInlineOverlayForcedOff() == false)
        #expect(
            KittyGraphics.scrollbackOverlayActive(protocol: .kitty, brand: .kitty)
        )

        setInlineOverlayForceOff(true)
        #expect(scrollbackInlineOverlayForcedOff())
        #expect(
            KittyGraphics.scrollbackOverlayActive(protocol: .kitty, brand: .kitty) == false
        )
        #expect(
            KittyGraphics.scrollbackOverlayActiveForBrand(protocol: .kitty, brand: .kitty)
        )
    }

    // MARK: - Transmit / IDs

    @Test("transmit uses the caller image ID and PNG f=100")
    func transmitUsesCallerImageID() {
        let png = pngSignatureOnly()
        let escape = KittyGraphics.transmit(imageData: png, format: .png, imageId: 42)

        #expect(KittyGraphicsFormat.png.code == 100)
        #expect(escape.contains("a=t"))
        #expect(escape.contains("f=100"))
        #expect(escape.contains("t=d"))
        #expect(escape.contains("q=2"))
        #expect(escape.contains("i=42"))
        #expect(!escape.contains("i=1,"))
        #expect(!escape.contains("i=1;"))
        #expect(!escape.contains(",p="))
        #expect(!escape.contains("a=T"))
        #expect(escape.hasPrefix("\u{1b}_G"))
        #expect(escape.hasSuffix("\u{1b}\\"))
    }

    @Test("transmit of empty payload emits no APC")
    func transmitEmptyIsEmpty() {
        let escape = KittyGraphics.transmit(imageData: Data(), imageId: 7)
        #expect(escape.isEmpty)
    }

    @Test("PNG formatFromBytes accepts magic and rejects JPEG")
    func formatFromBytesPNGOnly() {
        let png = pngSignatureOnly()
        let detected = KittyGraphics.formatFromBytes(png)
        #expect(detected == .png)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(KittyGraphics.formatFromBytes(jpeg) == nil)
        #expect(KittyGraphics.formatFromBytes(Data()) == nil)
    }

    // MARK: - Multi-chunk continuation

    @Test("multi-chunk continuation bytes match pin field names q=2,m=")
    func multiChunkContinuationMatchesPinFields() {
        // 5000 raw bytes → 6668 base64 chars → two 4096-byte chunks (pin test).
        let payload = Data(repeating: 0, count: 5_000)
        let escape = KittyGraphics.transmit(imageData: payload, format: .png, imageId: 99)
        let frames = escape.components(separatedBy: "\u{1b}_G").filter { !$0.isEmpty }

        #expect(frames.count == 2)

        let first = frames[0]
        #expect(first.hasPrefix("a=t,f=100,t=d,q=2,i=99,m=1;"))
        #expect(first.hasSuffix("\u{1b}\\"))

        let second = frames[1]
        #expect(second.hasPrefix("q=2,m=0;"))
        #expect(second.hasSuffix("\u{1b}\\"))
        #expect(!second.hasPrefix("m=0;"))

        // Three chunks: > 8192 base64 chars.
        let large = Data(repeating: 0x41, count: 7_000)
        let largeEscape = KittyGraphics.transmit(imageData: large, format: .png, imageId: 7)
        let largeFrames = largeEscape.components(separatedBy: "\u{1b}_G").filter { !$0.isEmpty }
        #expect(largeFrames.count == 3)
        #expect(largeFrames[0].contains(",m=1;"))
        #expect(largeFrames[1].hasPrefix("q=2,m=1;"))
        #expect(largeFrames[2].hasPrefix("q=2,m=0;"))
    }

    @Test("render a=T chunks preserve cursor and use placement ID 1")
    func renderChunksAndPreservesCursor() {
        let small = KittyGraphics.render(imageData: Data(repeating: 0, count: 10), cols: 40, rows: 20)
        #expect(small.contains("a=T"))
        #expect(small.contains("f=100"))
        #expect(small.contains("q=2"))
        #expect(small.contains("C=1"))
        #expect(small.contains("c=40"))
        #expect(small.contains("r=20"))
        #expect(small.contains("z=1"))
        #expect(small.contains("i=1"))
        #expect(small.contains("p=1"))
        #expect(small.contains("m=0"))

        let large = KittyGraphics.render(
            imageData: Data(repeating: 0, count: 5_000),
            cols: 40,
            rows: 20
        )
        let count = large.components(separatedBy: "\u{1b}_G").filter { !$0.isEmpty }.count
        #expect(count > 1)
        #expect(large.contains("\u{1b}_Gq=2,m="))
    }

    // MARK: - Place / crop / delete

    @Test("place uses caller ID for both i= and p=")
    func placeUsesCallerID() {
        let escape = KittyGraphics.place(imageId: 17, cols: 8, rows: 4, z: -1)
        #expect(escape == "\u{1b}_Ga=p,i=17,p=17,c=8,r=4,z=-1,C=1,q=2\u{1b}\\")
        #expect(!escape.contains(",p=1,"))
    }

    @Test("crop-on-scroll placement carries source crop fields and caller ID")
    func cropOnScrollPlacement() {
        let cropped = KittyGraphics.placeCropped(
            imageId: 5,
            cols: 10,
            rows: 3,
            z: -1,
            srcX: 0,
            srcY: 20,
            srcW: 100,
            srcH: 40
        )
        #expect(
            cropped
                == "\u{1b}_Ga=p,i=5,p=5,c=10,r=3,z=-1,x=0,y=20,w=100,h=40,C=1,q=2\u{1b}\\"
        )

        let full = KittyGraphics.placeForScrollback(
            imageId: 9,
            imgW: 100,
            imgH: 50,
            areaWidth: 40,
            areaHeight: 20,
            fullRows: 20,
            topCropRows: 0
        )
        #expect(full.contains("a=p"))
        #expect(full.contains("i=9"))
        #expect(full.contains("p=9"))
        #expect(full.contains("z=-1"))
        #expect(!full.contains("x="))

        let scrolled = KittyGraphics.placeForScrollback(
            imageId: 9,
            imgW: 100,
            imgH: 50,
            areaWidth: 40,
            areaHeight: 10,
            fullRows: 20,
            topCropRows: 4
        )
        #expect(scrolled.contains("x=0"))
        #expect(scrolled.contains("y="))
        #expect(scrolled.contains("w=100"))
        #expect(scrolled.contains("h="))
        #expect(scrolled.contains("i=9"))
        #expect(scrolled.contains("p=9"))
        #expect(scrolled.contains("z=-1"))
    }

    @Test("delete is ID-specific and omits p=")
    func deleteIsIDSpecific() {
        let first = KittyGraphics.clear(imageId: 3)
        let second = KittyGraphics.clear(imageId: 99)
        #expect(first == "\u{1b}_Ga=d,d=i,i=3,q=2\u{1b}\\")
        #expect(second == "\u{1b}_Ga=d,d=i,i=99,q=2\u{1b}\\")
        #expect(first != second)
        #expect(!first.contains("p="))
        #expect(!second.contains("d=a"))
    }

    @Test("iTerm2 helper exists but is not selected by protocolForBrand")
    func iterm2HelperIsGatedOff() {
        let escape = KittyGraphics.renderITerm2Image(imageData: Data(repeating: 0, count: 10), cols: 30, rows: 15)
        #expect(escape.hasPrefix("\u{1b}]1337;File="))
        #expect(escape.contains("width=30cells"))
        #expect(escape.contains("height=15cells"))
        #expect(escape.contains("preserveAspectRatio=1"))
        #expect(KittyGraphics.protocolForBrand(brand: .iterm2) == .none)
    }
}

private func pngSignatureOnly() -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}
