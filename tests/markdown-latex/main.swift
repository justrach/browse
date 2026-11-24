import SwiftUI

enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let wash = Color.gray.opacity(0.1)
    static let hairline = Color.gray.opacity(0.2)
    static let ground = Color.white
    static let accent = Color.blue
    static let safe = Color.green
}

enum Agent {
    @MainActor static func rich(_ text: String) -> AttributedString { AttributedString(text) }
}

enum YouTubeHelper {
    static func linkTimestamps(in text: String) -> String { text }
}

enum Citations {
    struct Source: Identifiable { let id = 0 }
    static func mark(_ text: String) -> (text: String, sources: [Source]) { (text, []) }
    static func style(_ string: AttributedString, size: CGFloat) -> AttributedString { string }
}

struct SourcesRow: View {
    let sources: [Citations.Source]
    var size: CGFloat = 13
    var body: some View { EmptyView() }
}

func check(_ cond: @autoclosure () -> Bool, _ msg: String) {
    if !cond() {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
}

@main
struct MarkdownLatexTests {
    static func main() {
        // 1. GFM Table parsing with alignment & escaped pipes
        let mdTable = """
        Here are examples:

        | Example | What to look at | Score |
        |---|:---:|---:|
        | [Ian Silber](https://iansilber.com) | Opens with a 15s game | 10 |
        | `a|b` pipe | Escaped \\| works | 9 |
        """
        let blocks = MarkdownParser.parse(mdTable)
        check(blocks.count == 2, "expected paragraph + table, got \(blocks.count)")
        if case .table(let headers, let aligns, let rows) = blocks[1] {
            check(headers == ["Example", "What to look at", "Score"], "headers mismatch: \(headers)")
            check(aligns == [.leading, .center, .trailing], "aligns mismatch: \(aligns)")
            check(rows.count == 2, "expected 2 rows")
            check(rows[0][0] == "[Ian Silber](https://iansilber.com)", "row 0 col 0 mismatch")
            check(rows[1][0] == "`a|b` pipe", "backtick pipe should not split cell: \(rows[1][0])")
            check(rows[1][1] == "Escaped | works", "escaped pipe should stay in cell: \(rows[1][1])")
        } else {
            check(false, "second block was not .table")
        }

        // 2. Display math blocks ($$...$$ single/multi-line and \[...\])
        let mdMath = """
        Inline $E = mc^2$ and \\(O(n \\log n)\\) costs $5 to $10.

        $$
        \\sum_{i=1}^{n} \\frac{1}{i^2} = \\frac{\\pi^2}{6}
        $$

        \\[ \\sqrt[3]{x^2 + 1} \\]
        """
        let mathBlocks = MarkdownParser.parse(mdMath)
        check(mathBlocks.count == 3, "expected 3 blocks, got \(mathBlocks.count)")
        if case .mathBlock(let tex1) = mathBlocks[1] {
            check(tex1.contains("\\frac{\\pi^2}{6}"), "missing frac in mathBlock 1")
            let ast = MathParser.parse(tex1)
            if case .row(let items) = ast {
                check(items.count >= 4, "expected parsed math row nodes")
            } else {
                check(false, "expected .row AST")
            }
        } else {
            check(false, "block 1 not mathBlock")
        }
        if case .mathBlock(let tex2) = mathBlocks[2] {
            check(tex2 == "\\sqrt[3]{x^2 + 1}", "block 2 tex mismatch: \(tex2)")
            let ast = MathParser.parse(tex2)
            if case .sqrt(let idx, _) = ast {
                check(idx != nil, "expected cube root index")
            } else {
                check(false, "expected .sqrt AST, got \(ast)")
            }
        } else {
            check(false, "block 2 not mathBlock")
        }

        // 3. Inline math splitting & currency guard
        let segs = MathTex.splitInline("Inline $E = mc^2$ and \\(x_i + \\alpha\\) costs $5 to $10 and `$not_math$`.")
        let mathSegs = segs.compactMap { seg -> String? in
            if case .math(let s) = seg { return s }
            return nil
        }
        check(mathSegs == ["E = mc^2", "x_i + \\alpha"], "unexpected inline math segments: \(mathSegs)")

        // 4. Fenced code with language, blockquote, task list, horizontal rule
        let rich = """
        ## Title

        > Quoted line 1
        > Quoted line 2

        - [x] Done item
        - [ ] Todo item

        ---

        ```swift
        let x = 1
        ```
        """
        let richBlocks = MarkdownParser.parse(rich)
        check(richBlocks.count == 6, "expected 6 blocks, got \(richBlocks.count)")
        if case .heading(2, "Title") = richBlocks[0] {} else { check(false, "heading mismatch") }
        if case .blockquote(let q) = richBlocks[1] { check(q.count == 2, "blockquote lines") } else { check(false, "blockquote mismatch") }
        if case .listItem("Done item", _, 0, true) = richBlocks[2] {} else { check(false, "checked item mismatch") }
        if case .listItem("Todo item", _, 0, false) = richBlocks[3] {} else { check(false, "unchecked item mismatch") }
        if case .rule = richBlocks[4] {} else { check(false, "rule mismatch") }
        if case .code("swift", "let x = 1") = richBlocks[5] {} else { check(false, "code block mismatch") }

        print("PASS markdown tables, code blocks, blockquotes, task lists, and inline/display LaTeX")
    }
}
