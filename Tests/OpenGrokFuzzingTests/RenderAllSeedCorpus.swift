import Foundation

struct RenderAllSeed {
    let filename: String
    let source: String
}

enum RenderAllSeedCorpus {
    static let all: [RenderAllSeed] = [
        RenderAllSeed(filename: "thematic_emoji.txt", source: #"""
        ---

        ## 📐 Heading

        Text after thematic break with emoji.
        """#),
        RenderAllSeed(filename: "bench.md", source: #"""
        # 🚀 Architecture Overview — `xai-grok-pager` Rendering Engine

        The **xai-grok-pager** rendering engine transforms raw markdown into terminal-ready cells. This document covers markdown parsing, syntax highlighting, word wrapping, block layout, viewport clipping, and final buffer composition.

        ---

        ## 📐 The Rendering Pipeline

        Every frame follows the same sequence:

        1. **Markdown parsing** — `StreamingMarkdownRenderer` converts source text into styled lines.
        2. **Word wrapping** — long lines become physical rows while preserving copy fidelity.
        3. **Block output** — per-line metadata carries background color and decorations.

        | Stage | Complexity | Cached? |
        |---|---|---|
        | Markdown parse | `O(n)` | yes |
        | Word wrap | `O(lines × width)` | yes |

        ```python
        def render_markdown(source: str) -> str:
            return source.strip()
        ```

        Wide characters: 👨‍👩‍👧‍👦 漢字 — and links like https://example.com.
        """#),
        RenderAllSeed(filename: "unicode.txt", source: #"""
        漢字テスト ＡＢＣＤＥ 👨‍👩‍👧‍👦 ∀x ∈ ℝ

        ---

        ## 📐 Wide chars

        Ü ö ñ é à ß µ ∞ ≠ ≤ ≥ ÷ × ← → ↑ ↓
        """#),
        RenderAllSeed(filename: "math.md", source: #"""
        # Math seed

        Euler's identity: $e^{i\pi} + 1 = 0$ and a fraction $\frac{a+b}{2}$.

        Paren form \(\alpha_1 + \beta^2 \le \gamma\) inline.

        $$
        \int_0^\infty e^{-x}\,dx = 1
        $$

        | Col | Math |
        |-----|------|
        | a   | $x^2$ |

        - item \(p \to q\)
        - sets $S \subseteq \mathbb{R}^n$

        > quote $$E = mc^2$$

        Escapes: \\(not math\\) and `$code$` and \[unterminated
        """#),
        RenderAllSeed(filename: "code_block.txt", source: #"""
        # Heading

        ```rust
        fn main() {}
        ```
        """#),
        RenderAllSeed(filename: "table.txt", source: #"""
        | a | b |
        |---|---|
        | 1 | 2 |
        """#),
        RenderAllSeed(filename: "mixed.txt", source: #"""
        > **bold** *italic* `code`

        - item 1
          - nested
            - deep
        """#),
        RenderAllSeed(filename: "inline.txt", source: #"""
        [link](https://example.com) ![alt](img.png)

        ***bold italic*** ~~strike~~

        `code` **`bold code`** *`italic code`*
        """#),
        RenderAllSeed(filename: "lists.txt", source: #"""
        # H1
        ## H2
        ### H3

        ---

        1. one
        2. two
        3. three

        - [ ] todo
        - [x] done
        """#)
    ]
}
