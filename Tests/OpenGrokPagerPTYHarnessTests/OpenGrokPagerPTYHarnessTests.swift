import Testing

import OpenGrokPagerPTYHarness

@Suite("Virtual screen")
struct VirtualScreenTests {
    @Test("printable text and CRLF land on the grid")
    func plainText() {
        var screen = VirtualScreen(width: 10, height: 3)
        screen.feed("hello\r\nworld")
        #expect(screen.lines == ["hello", "world", ""])
        #expect(screen.text == "hello\nworld")
    }

    /// A bare line feed moves down a row but does **not** return to column
    /// zero — that is `\r`'s job. This is real terminal behaviour and the
    /// reason PTY output arrives as CRLF: the tty driver's ONLCR translates
    /// `\n` to `\r\n` on the way out, so the harness sees both bytes. Treating
    /// a lone `\n` as "next line, column zero" would silently mis-render any
    /// output that relies on the distinction, so it is pinned here.
    @Test("a bare line feed keeps the column")
    func bareLineFeedKeepsColumn() {
        var screen = VirtualScreen(width: 10, height: 2)
        screen.feed("hello\nworld")
        #expect(screen.lines == ["hello", "     world"])
    }

    @Test("carriage return overwrites the current row")
    func carriageReturn() {
        var screen = VirtualScreen(width: 10, height: 2)
        screen.feed("loading...\rdone")
        #expect(screen.lines[0] == "doneing...")
    }

    @Test("cursor positioning and erase-in-display are honoured")
    func cursorAndErase() {
        var screen = VirtualScreen(width: 10, height: 3)
        screen.feed("aaa\nbbb\nccc")
        screen.feed("\u{1B}[2J\u{1B}[1;1H")
        #expect(screen.text.isEmpty)
        screen.feed("top")
        #expect(screen.lines[0] == "top")
    }

    @Test("erase-in-line clears from the cursor to the end of the row")
    func eraseInLine() {
        var screen = VirtualScreen(width: 10, height: 1)
        screen.feed("abcdefgh")
        screen.feed("\u{1B}[4G\u{1B}[0K")
        #expect(screen.lines[0] == "abc")
    }

    /// SGR colour runs and OSC title strings must be consumed whole; leaking
    /// any part of them into the grid would corrupt every assertion made
    /// against a real CLI's output.
    @Test("styling and OSC sequences leave no residue")
    func escapesAreConsumed() {
        var screen = VirtualScreen(width: 20, height: 1)
        screen.feed("\u{1B}[1;31mred\u{1B}[0m")
        #expect(screen.lines[0] == "red")

        var withTitle = VirtualScreen(width: 20, height: 1)
        withTitle.feed("\u{1B}]0;a window title\u{07}text")
        #expect(withTitle.lines[0] == "text")

        var withST = VirtualScreen(width: 20, height: 1)
        withST.feed("\u{1B}]0;title\u{1B}\\text")
        #expect(withST.lines[0] == "text")
    }

    @Test("output longer than the screen scrolls the top away")
    func scrolling() {
        var screen = VirtualScreen(width: 5, height: 2)
        screen.feed("one\r\ntwo\r\nthree")
        #expect(screen.lines == ["two", "three"])
    }

    @Test("writing past the right edge wraps to the next row")
    func wrapping() {
        var screen = VirtualScreen(width: 3, height: 2)
        screen.feed("abcdef")
        #expect(screen.lines == ["abc", "def"])
    }

    @Test("private mode toggles never touch the grid")
    func privateModes() {
        var screen = VirtualScreen(width: 10, height: 2)
        screen.feed("\u{1B}[?25l\u{1B}[?1049hkept\u{1B}[?25h")
        #expect(screen.lines[0] == "kept")
    }
}
