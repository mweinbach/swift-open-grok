import Testing
@testable import OpenGrokMarkdown

@Suite("Rust-compatible Markdown math rendering")
struct MarkdownMathRenderingParityTests {
    @Test("inline dollar and parenthesis math renders Unicode without delimiters")
    func inlineDelimiterRendering() {
        let output = MarkdownRenderer().render(#"Energy is $E = mc^2$, sum \( \alpha + \beta \), and $x_1 + x_2$."#)

        #expect(output.text == "Energy is E = mc², sum α + β, and x₁ + x₂.")
    }

    @Test("raw rendering preserves TeX and canonical upstream dollar delimiters")
    func rawMathRendering() {
        let output = MarkdownRenderer(pretty: false).render(#"A \(x^2\) and \[E = mc^2\]."#)

        #expect(output.text == #"A $x^2$ and $$E = mc^2$$."#)
        #expect(!output.text.contains("²"))
    }

    @Test("scripts match Unicode, wordlike fallback, and unmappable fallback")
    func scripts() {
        #expect(MarkdownMathRenderer.inline(#"E = mc^2 + x^{10} + e^{-x} + a_1 + x_{ij}"#)
                == "E = mc² + x¹⁰ + e⁻ˣ + a₁ + xᵢⱼ")
        #expect(MarkdownMathRenderer.inline(#"p_{\text{torso}} + z_{\mathrm{draft}} + x_{max}"#)
                == "p_(torso) + z_(draft) + x_(max)")
        #expect(MarkdownMathRenderer.inline(#"x^{\alpha\beta} + a_q"#) == "x^(αβ) + a_q")
    }

    @Test("Greek symbols, relations, arrows, and operators match upstream")
    func symbols() {
        #expect(MarkdownMathRenderer.inline(#"\alpha + \beta = \Gamma"#) == "α + β = Γ")
        #expect(MarkdownMathRenderer.inline(#"a \le b \ne c \times d"#) == "a ≤ b ≠ c × d")
        #expect(MarkdownMathRenderer.inline(#"x \in A \cup B \implies f: A \to B"#)
                == "x ∈ A ∪ B ⟹ f: A → B")
    }

    @Test("fractions use vulgar glyphs and parenthesize compound operands")
    func fractions() {
        #expect(MarkdownMathRenderer.inline(#"\frac{1}{2} + \frac{3}{4}"#) == "½ + ¾")
        #expect(MarkdownMathRenderer.inline(#"\frac{dy}{dx}"#) == "dy/dx")
        #expect(MarkdownMathRenderer.inline(#"\frac{a+b}{c}"#) == "(a+b)/c")
        #expect(MarkdownMathRenderer.inline(#"\frac{x}{y - z}"#) == "x/(y − z)")
    }

    @Test("square, cubic, quartic, and arbitrary roots remain readable")
    func roots() {
        #expect(MarkdownMathRenderer.inline(#"\sqrt{x}"#) == "√x")
        #expect(MarkdownMathRenderer.inline(#"\sqrt{a + b}"#) == "√(a + b)")
        #expect(MarkdownMathRenderer.inline(#"\sqrt[3]{x} + \sqrt[4]{x} + \sqrt[n]{x}"#)
                == "∛x + ∜x + ⁿ√x")
    }

    @Test("mathematical alphabets, accents, typography, and text modes match")
    func alphabetsAccentsAndText() {
        #expect(MarkdownMathRenderer.inline(#"\mathbb{R}^n + \mathcal{L} + \mathbf{v}"#)
                == "ℝⁿ + ℒ + 𝐯")
        #expect(MarkdownMathRenderer.inline(#"\hat{x} + \vec{v}"#) == "x\u{0302} + v\u{20D7}")
        #expect(MarkdownMathRenderer.inline(#"\text{x-ray}, f'(x), a - b"#) == "x-ray, f′(x), a − b")
    }

    @Test("integrals, sums, spacing, and modular operators preserve semantics")
    func structuredOperators() {
        #expect(MarkdownMathRenderer.inline(#"\sum_{i=0}^{2} \gamma^{i}"#) == "∑ᵢ₌₀² γⁱ")
        #expect(MarkdownMathRenderer.inline(#"\int_0^1 x \, dx = \frac{1}{2}"#)
                == "∫₀¹ x dx = ½")
        #expect(MarkdownMathRenderer.inline(#"a \equiv b \pmod{m}"#) == "a ≡ b (mod m)")
        #expect(MarkdownMathRenderer.inline(#"a \not= b; x \not\in S"#) == "a ≠ b; x ∉ S")
    }

    @Test("upstream's real-world MTP loss equation has no surviving TeX commands")
    func realWorldLossEquation() {
        let equation = #"""
        \boxed{
        \mathcal{L}_{\text{MTP}}
        =
        \sum_{i=0}^{2}
        \gamma^{i}\,
        \mathbb{E}_{\text{positions, mask}}
        \Big[
        \mathrm{KL}\big(
          \mathrm{softmax}(z_{\text{torso}}^{(s_i)})
          \;\big\|\;
          \mathrm{softmax}(z_{\text{draft}}^{(i)})
        \big)
        \Big]
        }
        """#

        let rendered = MarkdownMathRenderer.inline(equation) ?? ""
        #expect(rendered.contains("ℒ_(MTP)"))
        #expect(rendered.contains("∑ᵢ₌₀²"))
        #expect(rendered.contains("𝔼_(positions, mask)"))
        #expect(rendered.contains("softmax(z_(torso)"))
        #expect(rendered.contains("‖"))
        #expect(!rendered.contains("boxed"))
        #expect(!rendered.contains("\\"))
    }

    @Test("display dollar and bracket equations are indented standalone blocks")
    func multilineDisplayBlocks() {
        let source = #"""
        Before.

        $$
        \int_0^1 x \, dx = \frac{1}{2}
        $$

        \[
        \frac{a+b}{2} \ge \sqrt{ab}
        \]

        After.
        """#
        let output = MarkdownRenderer().render(source)

        #expect(output.lines.contains { $0.text == "  ∫₀¹ x dx = ½" })
        #expect(output.lines.contains { $0.text == "  (a+b)/2 ≥ √(ab)" })
        #expect(!output.text.contains("$$"))
        #expect(!output.text.contains(#"\["#))
    }

    @Test("display equations split preceding and following prose")
    func inlineDisplayBlock() {
        let lines = MarkdownRenderer().render(#"text $$x^2 + y^2 = z^2$$ more"#).lines.map(\.text)

        #expect(lines.count == 3)
        #expect(lines[0].contains("text"))
        #expect(lines[1] == "  x² + y² = z²")
        #expect(lines[2].contains("more"))
    }

    @Test("equation environments render through the real Markdown renderer")
    func equationEnvironment() {
        let output = MarkdownRenderer().render(#"\begin{equation}E = mc^2\end{equation}"#)

        #expect(output.text == "  E = mc²")
        #expect(!output.text.contains("begin"))
    }

    @Test("aligned environments and cases retain independent visual rows")
    func multilineEnvironments() {
        #expect(MarkdownMathRenderer.display(#"\begin{aligned} f(x) &= x^2 \\ g(x) &= 2x \end{aligned}"#)
                == ["f(x) = x²", "g(x) = 2x"])

        let cases = MarkdownMathRenderer.display(#"f(x) = \begin{cases} x & x > 0 \\ 0 & \text{otherwise} \end{cases}"#)
        #expect(cases?.count == 2)
        #expect(cases?.first?.contains("⎧") == true)
        #expect(cases?.last?.contains("⎩") == true)
    }

    @Test("matrix environments preserve columns and terminal delimiters")
    func matrixEnvironments() {
        #expect(MarkdownMathRenderer.display(#"\begin{pmatrix} 1 & 22 \\ 333 & 4 \end{pmatrix}"#)
                == ["⎛1    22⎞", "⎝333  4⎠"])
        #expect(MarkdownMathRenderer.display(#"\begin{bmatrix} a & b \end{bmatrix}"#)
                == ["[a  b]"])
    }

    @Test("headings, lists, quotes, and table cells reach converted math")
    func containerRendering() {
        let source = #"""
        ## About \(\pi^2\)

        - implies \(p \to q\)

        > energy \(E = mc^2\)

        | Mode | Metric |
        | --- | --- |
        | Rate | \(\alpha + \beta\) |
        | Set | \[x^2\] |
        """#
        let output = MarkdownRenderer().render(source)

        #expect(output.text.contains("About π²"))
        #expect(output.text.contains("implies p → q"))
        #expect(output.text.contains("energy E = mc²"))
        #expect(output.text.contains("α + β"))
        #expect(output.text.contains("x²"))
        #expect(!output.text.contains(#"\("#))
        #expect(!output.text.contains(#"\["#))
    }

    @Test("link labels with math retain valid hyperlink display-column ranges")
    func hyperlinkRanges() {
        let output = MarkdownRenderer().render(#"See [$\alpha^2$](https://example.com)."#)

        #expect(output.text.contains("α²"))
        #expect(output.hyperlinks.contains { $0.url == "https://example.com" && $0.columnRange == 4..<6 })
    }

    @Test("currency, escaped delimiters, inline code, and fenced code stay verbatim")
    func nonMathPreservation() {
        let source = #"""
        Prices are $5 and $10; escaped \\(x^2\\).

        `$y^2$` and `\(z_1\)`.

        ```latex
        \[q^3\]
        ```
        """#
        let output = MarkdownRenderer().render(source)

        #expect(output.text.contains("$5 and $10"))
        #expect(output.text.contains("$y^2$"))
        #expect(output.text.contains(#"\(z_1\)"#))
        #expect(output.text.contains(#"\[q^3\]"#))
    }

    @Test("oversized math uses upstream's raw-source fallback without delimiters")
    func sourceLimit() {
        let body = String(repeating: "x", count: MarkdownMathRenderer.maximumSourceBytes + 1)

        #expect(MarkdownMathRenderer.inline(body) == nil)
        #expect(MarkdownMathRenderer.display(body) == nil)
        #expect(MarkdownRenderer().render("$\(body)$").text == body)
    }

    @Test("malformed LaTeX remains total without hiding neighboring prose")
    func malformedMath() {
        for source in [#"$\frac{a}$"#, #"$\sqrt[$"#, #"$\unknown{x}$"#,
                       #"open \[x"#, #"open $x"#] {
            let output = MarkdownRenderer().render("before \(source) after")
            #expect(output.text.contains("before"))
            #expect(output.text.contains("after"))
        }
    }

    @Test("every split delimiter and UTF-8 math boundary converges to a full render")
    func streamingChunkBoundaries() {
        let source = "Stable.\n\n" + #"A \(\alpha^2\), $x_1$, and $$\frac{1}{2}$$ end."#
        let full = MarkdownRenderer().render(source)
        let characters = Array(source)

        for split in 0...characters.count {
            var renderer = StreamingMarkdownRenderer()
            renderer.pushAndRender(String(characters[..<split]))
            let streamed = renderer.pushAndRender(String(characters[split...]))
            #expect(streamed == full, "Incremental mismatch at split \(split)")
            #expect(renderer.finish() == full, "Mismatch at split \(split)")
        }
    }
}
