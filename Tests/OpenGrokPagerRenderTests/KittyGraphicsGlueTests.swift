// KittyGraphicsGlueTests.swift
//
// PagerRender public Kitty names must call through TerminalCore.KittyGraphics.
// Reference: crates/codegen/xai-grok-pager-render/src/terminal/image.rs @ 650c1db7

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("PagerRender Kitty graphics glue", .serialized)
struct KittyGraphicsGlueTests {

    @Test("protocolForBrand matches pin matrix; iTerm2 and Windows are none")
    func protocolForBrandPinMatrix() {
        for brand in MouseScrollTerminalBrand.allCases {
            let expected: GraphicsProtocol
            switch brand {
            case .kitty, .ghostty, .wezTerm, .warpTerminal:
                expected = .kitty
            default:
                expected = .none
            }
            #expect(
                protocolForBrand(brand: brand, isWindows: false) == expected,
                "unix brand \(brand) → \(expected)"
            )
            #expect(
                protocolForBrand(brand: brand, isWindows: true) == .none,
                "windows brand \(brand) stays none"
            )
        }

        #expect(protocolForBrand(brand: .iterm2) == .none)
        #expect(KittyGraphics.protocolForBrand(brand: .iterm2) == .none)
        #expect(protocolForBrand(brand: .warpTerminal) == .kitty)
        #expect(GraphicsProtocol.none.supportsImages == false)
        #expect(GraphicsProtocol.kitty.supportsImages)
        #expect(GraphicsProtocol.iterm2.supportsImages)
    }

    @Test("renderKittyImage stays z=-1; renderKittyImageZ keeps the caller z")
    func renderKittyImageZIndexContract() {
        let data = Data(repeating: 0x42, count: 10)
        let scrollback = renderKittyImage(imageData: data, format: .png, cols: 8, rows: 4)
        let coreScrollback = KittyGraphics.renderZ(
            imageData: data,
            format: .png,
            cols: 8,
            rows: 4,
            z: -1
        )
        let overlay = KittyGraphics.render(imageData: data, cols: 8, rows: 4)
        let explicit = renderKittyImageZ(imageData: data, format: .png, cols: 8, rows: 4, z: 1)

        #expect(scrollback == coreScrollback)
        #expect(scrollback.contains("z=-1,"))
        #expect(!scrollback.contains("z=1,"))
        #expect(overlay.contains("z=1,"))
        #expect(scrollback != overlay)

        #expect(explicit == KittyGraphics.renderZ(
            imageData: data,
            format: .png,
            cols: 8,
            rows: 4,
            z: 1
        ))
        #expect(explicit.contains("z=1,"))
        #expect(explicit.contains("a=T"))
        #expect(explicit.contains("i=1"))
        #expect(explicit.contains("p=1"))
    }

    @Test("transmit/place/clear use caller IDs; delete omits p=")
    func callerImageIDsAndDeleteOmitP() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let transmitted = transmitKittyImage(imageData: png, format: .png, imageId: 42)
        #expect(transmitted == KittyGraphics.transmit(imageData: png, format: .png, imageId: 42))
        #expect(transmitted.contains("a=t"))
        #expect(transmitted.contains("i=42"))
        #expect(!transmitted.contains("i=1,"))
        #expect(!transmitted.contains(",p="))

        let placed = placeKittyImage(imageId: 17, cols: 8, rows: 4, z: -1)
        #expect(placed == KittyGraphics.place(imageId: 17, cols: 8, rows: 4, z: -1))
        #expect(placed == "\u{1b}_Ga=p,i=17,p=17,c=8,r=4,z=-1,C=1,q=2\u{1b}\\")
        #expect(!placed.contains(",p=1,"))

        let cropped = placeKittyImageCropped(
            imageId: 5,
            cols: 10,
            rows: 3,
            z: -1,
            srcX: 0,
            srcY: 20,
            srcW: 100,
            srcH: 40
        )
        #expect(cropped == KittyGraphics.placeCropped(
            imageId: 5,
            cols: 10,
            rows: 3,
            z: -1,
            srcX: 0,
            srcY: 20,
            srcW: 100,
            srcH: 40
        ))
        #expect(cropped.contains("p=5"))

        let cleared = clearKittyImage(imageId: 3)
        #expect(cleared == KittyGraphics.clear(imageId: 3))
        #expect(cleared == "\u{1b}_Ga=d,d=i,i=3,q=2\u{1b}\\")
        #expect(!cleared.contains("p="))
        #expect(clearKittyImage(imageId: 99) == "\u{1b}_Ga=d,d=i,i=99,q=2\u{1b}\\")
    }

    @Test("continuation chunks include q=2 and drop the diverged _Gm= form")
    func continuationChunksIncludeQuiet() {
        let payload = Data(repeating: 0, count: 5_000)
        let escape = transmitKittyImage(imageData: payload, format: .png, imageId: 99)
        let frames = escape.components(separatedBy: "\u{1b}_G").filter { !$0.isEmpty }

        #expect(frames.count == 2)
        #expect(frames[0].hasPrefix("a=t,f=100,t=d,q=2,i=99,m=1;"))
        #expect(frames[1].hasPrefix("q=2,m=0;"))
        #expect(!escape.contains("\u{1b}_Gm="))

        let rendered = renderKittyImageZ(
            imageData: payload,
            format: .png,
            cols: 80,
            rows: 24,
            z: 1
        )
        #expect(rendered.contains("\u{1b}_Gq=2,m="))
        #expect(!rendered.contains("\u{1b}_Gm="))
    }

    @Test("iTerm2 helper exists but protocolForBrand stays none")
    func iterm2HelperGatedOff() {
        let escape = renderIterm2Image(imageData: Data(repeating: 0, count: 10), cols: 30, rows: 15)
        #expect(escape == KittyGraphics.renderITerm2Image(
            imageData: Data(repeating: 0, count: 10),
            cols: 30,
            rows: 15
        ))
        #expect(escape.contains("width=30cells"))
        #expect(escape.contains("preserveAspectRatio=1"))
        #expect(protocolForBrand(brand: .iterm2) == .none)
        setTestGraphicsProtocolOverride(nil)
        #expect(detectGraphicsProtocol(
            environment: ["TERM_PROGRAM": "iTerm.app"],
            host: .macos
        ) == .none)
    }

    @Test("force-off symbols re-export through PagerRender and share TerminalCore store")
    func forceOffReexport() {
        let previous = scrollbackInlineOverlayForcedOff()
        defer { setInlineOverlayForceOff(previous) }

        setInlineOverlayForceOff(false)
        #expect(scrollbackInlineOverlayForcedOff() == false)
        setInlineOverlayForceOff(true)
        #expect(scrollbackInlineOverlayForcedOff())
        #expect(
            KittyGraphics.scrollbackOverlayActive(protocol: .kitty, brand: .kitty) == false
        )
    }
}
