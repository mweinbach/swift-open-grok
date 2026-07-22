// OutputEncoder.swift
//
// ANSI output helpers: cursor movement, clears, OSC 8 hyperlinks, synchronized
// output markers.

import Foundation

public enum ANSIOutput {
    /// CSI CUP — move cursor to 1-based (row, col). Inputs are 0-based.
    public static func moveTo(column: Int, row: Int) -> String {
        "\u{1B}[\(row + 1);\(column + 1)H"
    }

    /// Erase from cursor to end of display (CSI J default / 0).
    public static let clearFromCursorDown = "\u{1B}[J"

    /// Clear screen + scrollback + home (used by resize purge path).
    public static let clearScreenAndScrollbackHome = "\u{1B}[2J\u{1B}[3J\u{1B}[H"

    /// Begin synchronized update (DCS mode 2026).
    public static let beginSynchronizedUpdate = "\u{1B}[?2026h"

    /// End synchronized update.
    public static let endSynchronizedUpdate = "\u{1B}[?2026l"

    /// OSC 8 hyperlink open. Control characters are stripped from `url`.
    public static func osc8Open(url: String, id: UInt32?) -> String {
        let u = String(url.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v >= 0x20 && v != 0x7F
        }.map { Character($0) })
        if let id {
            return "\u{1B}]8;id=\(id);\(u)\u{07}"
        }
        return "\u{1B}]8;;\(u)\u{07}"
    }

    /// OSC 8 hyperlink close.
    public static let osc8Close = "\u{1B}]8;;\u{07}"
}

/// Encode a run of cell updates as a byte stream with optional OSC 8 wrapping.
public enum CellStreamEncoder {
    public static func encode(
        updates: [CellUpdate],
        linkIds: [UInt32] = [],
        linkTable: [LinkRef] = [],
        area: TerminalRect
    ) -> Data {
        var out = Data()
        guard !updates.isEmpty else { return out }
        let width = max(area.width, 1)

        func resolve(_ x: Int, _ y: Int) -> LinkRef? {
            let idx = (y - area.y) * width + (x - area.x)
            return resolveLink(ids: linkIds, table: linkTable, index: idx)
        }

        var i = 0
        while i < updates.count {
            let u = updates[i]
            let link = resolve(u.x, u.y)
            var j = i + 1
            while j < updates.count {
                let n = updates[j]
                if resolve(n.x, n.y) != link { break }
                j += 1
            }
            if let link {
                out.append(contentsOf: ANSIOutput.osc8Open(url: link.url, id: link.id).utf8)
            }
            for k in i..<j {
                let cell = updates[k].cell
                if cell.skip { continue }
                // Move cursor then write symbol (minimal encoder).
                out.append(contentsOf: ANSIOutput.moveTo(column: updates[k].x, row: updates[k].y).utf8)
                out.append(contentsOf: cell.grapheme.utf8)
            }
            if link != nil {
                out.append(contentsOf: ANSIOutput.osc8Close.utf8)
            }
            i = j
        }
        return out
    }
}
