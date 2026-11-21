import SwiftUI
import AppKit

// Rich block-level Markdown + native LaTeX renderer for Codegraff replies.
// Supports GFM tables (with alignment and horizontal scroll), fenced code
// blocks (language header + one-click Copy), heading hierarchy, blockquotes,
// nested/task lists, horizontal rules, inline math ($...$, \(...\)), and
// structured display math ($$...$$, \[...\] with stacked fractions, roots,
// big-operator limits, matrices, and cases) — zero external dependencies.

// MARK: - Block Model & Parser

enum MarkdownBlock: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var text: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(text: String, mark: String, depth: Int, checked: Bool?)
    case blockquote([String])
    case code(language: String?, content: String)
    case table(headers: [String], alignments: [Alignment], rows: [[String]])
    case mathBlock(String)
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var i = 0

        func flushPara() {
            guard !para.isEmpty else { return }
            out.append(.paragraph(para.joined(separator: "\n")))
            para.removeAll()
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ```lang ... ```
            if trimmed.hasPrefix("```") {
                flushPara()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var buf: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    buf.append(lines[i])
                    i += 1
                }
                out.append(.code(language: lang.isEmpty ? nil : lang, content: buf.joined(separator: "\n")))
                continue
            }

            // Display math block: $$ ... $$
            if trimmed.hasPrefix("$$") {
                flushPara()
                let after = String(trimmed.dropFirst(2))
                if let endRange = after.range(of: "$$"), !after.isEmpty {
                    let body = String(after[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { out.append(.mathBlock(body)) }
                    i += 1
                    continue
                }
                var buf: [String] = []
                if !after.trimmingCharacters(in: .whitespaces).isEmpty { buf.append(after) }
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t == "$$" {
                        i += 1
                        break
                    }
                    if let endRange = lines[i].range(of: "$$") {
                        let before = String(lines[i][..<endRange.lowerBound])
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { buf.append(before) }
                        i += 1
                        break
                    }
                    buf.append(lines[i])
                    i += 1
                }
                let body = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append(.mathBlock(body)) }
                continue
            }

            // Display math block: \[ ... \]
            if trimmed.hasPrefix("\\[") {
                flushPara()
                let after = String(trimmed.dropFirst(2))
                if let endRange = after.range(of: "\\]") {
                    let body = String(after[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { out.append(.mathBlock(body)) }
                    i += 1
                    continue
                }
                var buf: [String] = []
                if !after.trimmingCharacters(in: .whitespaces).isEmpty { buf.append(after) }
                i += 1
                while i < lines.count {
                    if let endRange = lines[i].range(of: "\\]") {
                        let before = String(lines[i][..<endRange.lowerBound])
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { buf.append(before) }
                        i += 1
                        break
                    }
                    buf.append(lines[i])
                    i += 1
                }
                let body = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append(.mathBlock(body)) }
                continue
            }

            // Empty line ends paragraph.
            if trimmed.isEmpty {
                flushPara()
                i += 1
                continue
            }

            // GFM Table: header row followed by |---|---| separator row.
            if i + 1 < lines.count,
               trimmed.contains("|"),
               let alignments = parseTableSeparator(lines[i + 1]) {
                let headers = splitTableRow(trimmed)
                if !headers.isEmpty {
                    flushPara()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                        guard !rowLine.isEmpty, rowLine.contains("|"), parseTableSeparator(rowLine) == nil else { break }
                        rows.append(splitTableRow(rowLine))
                        i += 1
                    }
                    let colCount = max(headers.count, alignments.count, rows.map(\.count).max() ?? 0)
                    let normHeaders = pad(headers, to: colCount, fill: "")
                    let normAlign = pad(alignments, to: colCount, fill: .leading)
                    let normRows = rows.map { pad($0, to: colCount, fill: "") }
                    out.append(.table(headers: normHeaders, alignments: normAlign, rows: normRows))
                    continue
                }
            }

            // Horizontal rule: ---, ***, ___ (3+ matching chars, optional spaces).
            if isHorizontalRule(trimmed) {
                flushPara()
                out.append(.rule)
                i += 1
                continue
            }

            // Headings: # through ######
            if let heading = parseHeading(trimmed) {
                flushPara()
                out.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Blockquote: consecutive > lines grouped together.
            if trimmed.hasPrefix(">") {
                flushPara()
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var body = String(t.dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quoteLines.append(body)
                    i += 1
                }
                out.append(.blockquote(quoteLines))
                continue
            }

            // List item (unordered, task checkbox, or ordered).
            let leadingSpaces = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let depth = min(4, leadingSpaces / 2)
            if let match = trimmed.range(of: #"^[-*•+]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
                flushPara()
                let prefix = String(trimmed[match])
                let checked = prefix.contains("[x]") || prefix.contains("[X]")
                out.append(.listItem(text: String(trimmed[match.upperBound...]), mark: "•", depth: depth, checked: checked))
                i += 1
                continue
            }
            if let match = trimmed.range(of: #"^[-*•+]\s+"#, options: .regularExpression) {
                flushPara()
                out.append(.listItem(text: String(trimmed[match.upperBound...]), mark: "•", depth: depth, checked: nil))
                i += 1
                continue
            }
            if let match = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushPara()
                let mark = trimmed[..<match.upperBound].trimmingCharacters(in: .whitespaces)
                out.append(.listItem(text: String(trimmed[match.upperBound...]), mark: mark, depth: depth, checked: nil))
                i += 1
                continue
            }

            para.append(trimmed)
            i += 1
        }

        flushPara()
        return out
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return stripped.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let body = rest.trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : (hashes.count, body)
    }

    static func parseTableSeparator(_ line: String) -> [MarkdownBlock.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownBlock.Alignment] = []
        for rawCell in cells {
            let cell = rawCell.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return nil }
            let leftColon = cell.hasPrefix(":")
            let rightColon = cell.hasSuffix(":")
            var inner = cell
            if leftColon { inner.removeFirst() }
            if rightColon && !inner.isEmpty { inner.removeLast() }
            guard !inner.isEmpty, inner.allSatisfy({ $0 == "-" }) else { return nil }
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && !inCode {
                escaped = true
                continue
            }
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
                continue
            }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func pad<T>(_ array: [T], to count: Int, fill: T) -> [T] {
        if array.count >= count { return Array(array.prefix(count)) }
        return array + Array(repeating: fill, count: count - array.count)
    }
}

// MARK: - Inline Markdown + LaTeX AttributedString Builder

enum MathTex {
    static let symbols: [String: String] = [
        // Greek lowercase
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Greek uppercase
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators & relations
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "cdots": "⋯",
        "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱", "circ": "∘",
        "bullet": "•", "star": "⋆", "ast": "∗", "oplus": "⊕", "otimes": "⊗",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "propto": "∝", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃",
        "nexists": "∄", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧",
        "lor": "∨", "vee": "∨", "in": "∈", "notin": "∉", "ni": "∋",
        "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "implies": "⟹", "iff": "⟺", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "triangle": "△",
        "degree": "°", "prime": "′", "dagger": "†", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘", "top": "⊤", "bot": "⊥",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "langle": "⟨", "rangle": "⟩", "mid": "∣", "Vert": "‖",
        // Big operators
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁",
        "bigotimes": "⨂",
        // Spacing
        ",": " ", ";": " ", ":": " ", " ": " ", "quad": "  ", "qquad": "    ", "!": "",
        // Escaped punctuation
        "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "|": "‖",
    ]

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "lim", "limsup",
        "liminf", "sup", "inf", "max", "min", "arg", "deg", "det", "dim", "gcd",
        "hom", "ker", "Pr", "mod", "bmod", "pmod", "sgn", "rank", "tr", "Var", "Cov",
    ]

    static let bigOperators: Set<String> = [
        "sum", "prod", "coprod", "int", "iint", "iiint", "oint", "bigcup", "bigcap", "lim", "sup", "inf", "max", "min",
    ]

    static let blackboard: [Character: String] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ",
    ]

    static let spacedOperators: Set<String> = [
        "=", "+", "-", "±", "∓", "×", "÷", "·", "≤", "≥", "≠", "≈", "≡", "∼", "≃",
        "≅", "∝", "∈", "∉", "⊂", "⊆", "⊃", "⊇", "∪", "∩", "→", "←", "↔", "⇒", "⇐",
        "⇔", "⟹", "⟺", "↦", "<", ">", "∧", "∨", "∣",
    ]

    /// Splits a Markdown line into plain-markdown segments and inline-math
    /// segments (`$...$` and `\(...\)`), ignoring code spans `` `...` `` and
    /// currency like `$5` or `$10 to $20`.
    enum Segment: Equatable {
        case markdown(String)
        case math(String)
    }

    static func splitInline(_ text: String) -> [Segment] {
        let chars = Array(text)
        let n = chars.count
        var segments: [Segment] = []
        var buf = ""
        var i = 0
        var inCode = false

        func flushMarkdown() {
            if !buf.isEmpty {
                segments.append(.markdown(buf))
                buf = ""
            }
        }

        while i < n {
            let ch = chars[i]
            if ch == "`" {
                inCode.toggle()
                buf.append(ch)
                i += 1
                continue
            }
            if inCode {
                buf.append(ch)
                i += 1
                continue
            }

            // Inline \( ... \)
            if ch == "\\" && i + 1 < n && chars[i + 1] == "(" {
                if let end = findClosingParenMath(chars, from: i + 2) {
                    let body = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty {
                        flushMarkdown()
                        segments.append(.math(body))
                        i = end + 2
                        continue
                    }
                }
            }

            // Inline $ ... $ (not $$, not escaped \$)
            if ch == "$" && (i == 0 || chars[i - 1] != "\\") && !(i + 1 < n && chars[i + 1] == "$") {
                if let end = findClosingDollarMath(chars, from: i + 1) {
                    let body = String(chars[(i + 1)..<end])
                    if looksLikeMath(body) {
                        flushMarkdown()
                        segments.append(.math(body))
                        i = end + 1
                        continue
                    }
                }
            }

            buf.append(ch)
            i += 1
        }
        flushMarkdown()
        return segments
    }

    private static func findClosingParenMath(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "\\" && chars[i + 1] == ")" { return i }
            i += 1
        }
        return nil
    }

    private static func findClosingDollarMath(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, !chars[start].isWhitespace else { return nil }
        var i = start
        while i < chars.count {
            if chars[i] == "\n" { return nil }
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "$" {
                guard i > start, !chars[i - 1].isWhitespace else { return nil }
                // Don't treat "$5 and $10" as math if followed immediately by digit.
                if i + 1 < chars.count && chars[i + 1].isNumber { return nil }
                return i
            }
            i += 1
        }
        return nil
    }

    private static func looksLikeMath(_ body: String) -> Bool {
        guard !body.isEmpty else { return false }
        // Currency heuristic: "$5 to $10" or "$1,200 per year" starts with a
        // digit and has space-separated prose without math syntax.
        if let first = body.first, first.isNumber, body.contains(" ") {
            let hasMathOp = body.contains("\\") || body.contains("^") || body.contains("_")
                || body.contains("=") || body.contains("+") || body.contains("*")
                || body.contains("<") || body.contains(">")
            if !hasMathOp { return false }
        }
        return true
    }

    /// Renders a Markdown string with inline math (`$...$`, `\(...\)`) and
    /// Citations into a single selectable SwiftUI `AttributedString`.
    @MainActor
    static func inlineRich(_ text: String, size: CGFloat) -> AttributedString {
        let segments = splitInline(text)
        if segments.count == 1, case .markdown(let raw) = segments[0] {
            return Citations.style(Agent.rich(raw), size: size)
        }
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .markdown(let raw):
                result.append(Citations.style(Agent.rich(raw), size: size))
            case .math(let tex):
                result.append(renderInlineMath(tex, size: size))
            }
        }
        return result
    }

    /// Converts an inline TeX expression into a styled serif `AttributedString`
    /// with true superscripts, subscripts, Greek letters, and operators.
    static func renderInlineMath(_ tex: String, size: CGFloat) -> AttributedString {
        let root = MathParser.parse(tex)
        var out = AttributedString()
        appendNode(root, to: &out, size: size, baseline: 0)
        return out
    }

    private static func appendNode(
        _ node: MathNode,
        to out: inout AttributedString,
        size: CGFloat,
        baseline: CGFloat
    ) {
        switch node {
        case .row(let nodes):
            for child in nodes { appendNode(child, to: &out, size: size, baseline: baseline) }
        case .text(let s, let italic, let bold):
            var a = AttributedString(s)
            var font = Font.system(size: size, weight: bold ? .semibold : .regular, design: .serif)
            if italic { font = font.italic() }
            a.font = font
            if baseline != 0 { a.baselineOffset = baseline }
            out.append(a)
        case .symbol(let sym):
            let pad = spacedOperators.contains(sym) ? " \(sym) " : sym
            var a = AttributedString(pad)
            a.font = .system(size: size, design: .serif)
            if baseline != 0 { a.baselineOffset = baseline }
            out.append(a)
        case .frac(let num, let den):
            let simpleNum = num.isSimpleAtom
            let simpleDen = den.isSimpleAtom
            if !simpleNum { appendPlain("(", to: &out, size: size, baseline: baseline) }
            appendNode(num, to: &out, size: size, baseline: baseline)
            if !simpleNum { appendPlain(")", to: &out, size: size, baseline: baseline) }
            appendPlain("/", to: &out, size: size, baseline: baseline)
            if !simpleDen { appendPlain("(", to: &out, size: size, baseline: baseline) }
            appendNode(den, to: &out, size: size, baseline: baseline)
            if !simpleDen { appendPlain(")", to: &out, size: size, baseline: baseline) }
        case .sqrt(let index, let radicand):
            if let index {
                appendNode(index, to: &out, size: size * 0.68, baseline: baseline + size * 0.34)
            }
            appendPlain("√", to: &out, size: size, baseline: baseline)
            let wrap = !radicand.isSimpleAtom
            if wrap { appendPlain("(", to: &out, size: size, baseline: baseline) }
            appendNode(radicand, to: &out, size: size, baseline: baseline)
            if wrap { appendPlain(")", to: &out, size: size, baseline: baseline) }
        case .script(let base, let sup, let sub, _):
            appendNode(base, to: &out, size: size, baseline: baseline)
            let subSize = max(8.5, size * 0.74)
            if let sub {
                appendNode(sub, to: &out, size: subSize, baseline: baseline - size * 0.22)
            }
            if let sup {
                appendNode(sup, to: &out, size: subSize, baseline: baseline + size * 0.34)
            }
        case .delim(let l, let body, let r):
            if !l.isEmpty { appendPlain(l, to: &out, size: size, baseline: baseline) }
            appendNode(body, to: &out, size: size, baseline: baseline)
            if !r.isEmpty { appendPlain(r, to: &out, size: size, baseline: baseline) }
        case .accent(let kind, let body):
            appendNode(body, to: &out, size: size, baseline: baseline)
            let mark: String
            switch kind {
            case "hat", "widehat": mark = "\u{0302}"
            case "bar", "overline": mark = "\u{0304}"
            case "vec": mark = "\u{20D7}"
            case "dot": mark = "\u{0307}"
            case "ddot": mark = "\u{0308}"
            case "tilde", "widetilde": mark = "\u{0303}"
            default: mark = ""
            }
            if !mark.isEmpty { appendPlain(mark, to: &out, size: size, baseline: baseline) }
        case .matrix(let l, let r, let rows):
            if !l.isEmpty { appendPlain(l, to: &out, size: size, baseline: baseline) }
            for (rIdx, row) in rows.enumerated() {
                if rIdx > 0 { appendPlain("; ", to: &out, size: size, baseline: baseline) }
                for (cIdx, cell) in row.enumerated() {
                    if cIdx > 0 { appendPlain(", ", to: &out, size: size, baseline: baseline) }
                    appendNode(cell, to: &out, size: size, baseline: baseline)
                }
            }
            if !r.isEmpty { appendPlain(r, to: &out, size: size, baseline: baseline) }
        }
    }

    private static func appendPlain(_ s: String, to out: inout AttributedString, size: CGFloat, baseline: CGFloat) {
        var a = AttributedString(s)
        a.font = .system(size: size, design: .serif)
        if baseline != 0 { a.baselineOffset = baseline }
        out.append(a)
    }
}

// MARK: - Structured TeX AST & Parser (for Display Math + Inline Math)

indirect enum MathNode: Equatable {
    case row([MathNode])
    case text(String, italic: Bool, bold: Bool)
    case symbol(String)
    case frac(num: MathNode, den: MathNode)
    case sqrt(index: MathNode?, radicand: MathNode)
    case script(base: MathNode, sup: MathNode?, sub: MathNode?, stacked: Bool)
    case delim(left: String, body: MathNode, right: String)
    case accent(kind: String, body: MathNode)
    case matrix(left: String, right: String, rows: [[MathNode]])

    var isSimpleAtom: Bool {
        switch self {
        case .text(let s, _, _): return s.count <= 2
        case .symbol: return true
        case .row(let items): return items.count == 1 && items[0].isSimpleAtom
        default: return false
        }
    }
}

struct MathParser {
    private let chars: [Character]
    private var i = 0

    init(_ tex: String) {
        self.chars = Array(tex)
    }

    static func parse(_ tex: String) -> MathNode {
        var parser = MathParser(tex)
        return parser.parseSequence(stopAt: nil)
    }

    private var atEnd: Bool { i >= chars.count }
    private var current: Character { chars[i] }

    private mutating func skipSpaces() {
        while !atEnd && current.isWhitespace { i += 1 }
    }

    private mutating func parseSequence(stopAt: Character?) -> MathNode {
        var items: [MathNode] = []
        while !atEnd {
            skipSpaces()
            if atEnd { break }
            if let stopAt, current == stopAt {
                i += 1
                break
            }
            // Stop at \right, \end, &, \\ when inside delimiters/environments.
            if stopAt == nil && (peek("\\right") || peek("\\end{")) { break }
            guard let atom = parseAtom() else { break }
            items.append(parseScripts(attachedTo: atom))
        }
        return items.count == 1 ? items[0] : .row(items)
    }

    private mutating func parseScripts(attachedTo base: MathNode) -> MathNode {
        var sup: MathNode?
        var sub: MathNode?
        while true {
            skipSpaces()
            guard !atEnd else { break }
            if current == "^" {
                i += 1
                sup = parseGroupOrAtom()
            } else if current == "_" {
                i += 1
                sub = parseGroupOrAtom()
            } else {
                break
            }
        }
        guard sup != nil || sub != nil else { return base }
        let stacked: Bool
        if case .symbol(let s) = base, ["∑", "∏", "∐", "⋃", "⋂", "lim", "sup", "inf", "max", "min"].contains(s) {
            stacked = true
        } else if case .text(let t, false, _) = base, ["lim", "sup", "inf", "max", "min"].contains(t) {
            stacked = true
        } else {
            stacked = false
        }
        return .script(base: base, sup: sup, sub: sub, stacked: stacked)
    }

    private mutating func parseGroupOrAtom() -> MathNode {
        skipSpaces()
        guard !atEnd else { return .row([]) }
        if current == "{" {
            i += 1
            return parseSequence(stopAt: "}")
        }
        return parseAtom() ?? .row([])
    }

    private mutating func parseOptionalBracket() -> MathNode? {
        skipSpaces()
        guard !atEnd, current == "[" else { return nil }
        i += 1
        return parseSequence(stopAt: "]")
    }

    private mutating func parseAtom() -> MathNode? {
        skipSpaces()
        guard !atEnd else { return nil }

        let ch = current
        if ch == "{" {
            i += 1
            return parseSequence(stopAt: "}")
        }
        if ch == "}" {
            i += 1
            return nil
        }
        if ch == "\\" {
            return parseCommand()
        }
        if ch.isNumber {
            var num = ""
            while !atEnd && (current.isNumber || current == ".") {
                num.append(current)
                i += 1
            }
            return .text(num, italic: false, bold: false)
        }
        if ch.isLetter {
            i += 1
            return .text(String(ch), italic: true, bold: false)
        }
        i += 1
        if ch == "-" { return .symbol("−") }
        return .symbol(String(ch))
    }

    private mutating func parseCommand() -> MathNode {
        i += 1 // skip '\'
        guard !atEnd else { return .text("\\", italic: false, bold: false) }

        // Single-character command (\{, \}, \, \; \\ etc.)
        if !current.isLetter {
            let ch = current
            i += 1
            if ch == "\\" { return .text("\n", italic: false, bold: false) }
            let key = String(ch)
            if let sym = MathTex.symbols[key] { return .text(sym, italic: false, bold: false) }
            return .text(key, italic: false, bold: false)
        }

        var name = ""
        while !atEnd && current.isLetter {
            name.append(current)
            i += 1
        }

        switch name {
        case "frac", "dfrac", "tfrac":
            let num = parseGroupOrAtom()
            let den = parseGroupOrAtom()
            return .frac(num: num, den: den)
        case "binom", "dbinom", "tbinom":
            let top = parseGroupOrAtom()
            let bot = parseGroupOrAtom()
            return .matrix(left: "(", right: ")", rows: [[top], [bot]])
        case "sqrt":
            let idx = parseOptionalBracket()
            let rad = parseGroupOrAtom()
            return .sqrt(index: idx, radicand: rad)
        case "left":
            let leftDelim = parseDelimiterToken()
            var bodyItems: [MathNode] = []
            while !atEnd {
                skipSpaces()
                if peek("\\right") {
                    i += 6
                    break
                }
                guard let atom = parseAtom() else { break }
                bodyItems.append(parseScripts(attachedTo: atom))
            }
            let rightDelim = parseDelimiterToken()
            let body: MathNode = bodyItems.count == 1 ? bodyItems[0] : .row(bodyItems)
            return .delim(left: leftDelim, body: body, right: rightDelim)
        case "begin":
            let env = parseBraceString()
            return parseEnvironment(env)
        case "text", "textrm", "mathrm", "operatorname", "mbox":
            return .text(parseBraceString(), italic: false, bold: false)
        case "mathbf", "textbf", "boldsymbol", "bm":
            return .text(parseBraceString(), italic: false, bold: true)
        case "mathit", "textit":
            return .text(parseBraceString(), italic: true, bold: false)
        case "mathbb":
            let raw = parseBraceString()
            let mapped = raw.map { MathTex.blackboard[$0] ?? String($0) }.joined()
            return .text(mapped, italic: false, bold: false)
        case "mathcal", "mathscr", "mathfrak":
            return .text(parseBraceString(), italic: true, bold: false)
        case "hat", "widehat", "bar", "overline", "vec", "dot", "ddot", "tilde", "widetilde", "underline":
            return .accent(kind: name, body: parseGroupOrAtom())
        case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "big", "Big", "bigg", "Bigg":
            return parseAtom() ?? .row([])
        default:
            if let sym = MathTex.symbols[name] {
                return .symbol(sym)
            }
            if MathTex.functions.contains(name) {
                return .text(name, italic: false, bold: false)
            }
            return .text(name, italic: false, bold: false)
        }
    }

    private mutating func parseDelimiterToken() -> String {
        skipSpaces()
        guard !atEnd else { return "" }
        if current == "." { i += 1; return "" }
        if current == "\\" {
            i += 1
            if atEnd { return "" }
            if !current.isLetter {
                let c = current
                i += 1
                return String(c)
            }
            var cmd = ""
            while !atEnd && current.isLetter { cmd.append(current); i += 1 }
            return MathTex.symbols[cmd] ?? cmd
        }
        let c = current
        i += 1
        return String(c)
    }

    private mutating func parseBraceString() -> String {
        skipSpaces()
        guard !atEnd else { return "" }
        if current != "{" {
            let c = current
            i += 1
            return String(c)
        }
        i += 1
        var depth = 1
        var out = ""
        while !atEnd && depth > 0 {
            let ch = current
            i += 1
            if ch == "{" { depth += 1; out.append(ch) }
            else if ch == "}" {
                depth -= 1
                if depth > 0 { out.append(ch) }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private mutating func parseEnvironment(_ env: String) -> MathNode {
        let endToken = "\\end{\(env)}"
        var body = ""
        while !atEnd {
            if peek(endToken) {
                i += endToken.count
                break
            }
            body.append(current)
            i += 1
        }
        let rawRows = body.components(separatedBy: "\\\\")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rows: [[MathNode]] = rawRows.map { rowStr in
            rowStr.components(separatedBy: "&").map { MathParser.parse($0) }
        }
        let (left, right): (String, String) = {
            switch env {
            case "pmatrix": return ("(", ")")
            case "bmatrix": return ("[", "]")
            case "Bmatrix": return ("{", "}")
            case "vmatrix": return ("|", "|")
            case "Vmatrix": return ("‖", "‖")
            case "cases": return ("{", "")
            default: return ("", "")
            }
        }()
        return .matrix(left: left, right: right, rows: rows)
    }

    private func peek(_ prefix: String) -> Bool {
        let p = Array(prefix)
        guard i + p.count <= chars.count else { return false }
        for k in 0..<p.count where chars[i + k] != p[k] { return false }
        return true
    }
}

// MARK: - SwiftUI Display Math Renderer

struct DisplayMathView: View {
    let tex: String
    var size: CGFloat = 14

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        let root = MathParser.parse(tex)
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                MathNodeView(node: root, size: size + 2)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minWidth: 180)
            }
            .frame(maxWidth: .infinity)
            .background(Palette.wash.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.75))

            if hovering || copied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tex, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(copied ? "Copied" : "TeX")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(copied ? Palette.safe : Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Palette.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Copy LaTeX source")
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct MathNodeView: View {
    let node: MathNode
    let size: CGFloat

    var body: some View {
        switch node {
        case .row(let items):
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MathNodeView(node: item, size: size)
                }
            }
        case .text(let s, let italic, let bold):
            Text(s)
                .font(italic
                      ? Font.system(size: size, weight: bold ? .semibold : .regular, design: .serif).italic()
                      : Font.system(size: size, weight: bold ? .semibold : .regular, design: .serif))
        case .symbol(let sym):
            let big = ["∑", "∏", "∐", "∫", "∬", "∭", "∮", "⋃", "⋂"].contains(sym)
            let pad: CGFloat = MathTex.spacedOperators.contains(sym) ? 4 : (big ? 2 : 0.5)
            Text(sym)
                .font(.system(size: big ? size * 1.45 : size, weight: .regular, design: .serif))
                .padding(.horizontal, pad)
        case .frac(let num, let den):
            VStack(spacing: 2) {
                MathNodeView(node: num, size: max(10, size * 0.86))
                Rectangle()
                    .fill(Palette.ink.opacity(0.78))
                    .frame(height: 1)
                    .padding(.horizontal, 1)
                MathNodeView(node: den, size: max(10, size * 0.86))
            }
            .fixedSize()
            .padding(.horizontal, 3)
        case .sqrt(let index, let radicand):
            HStack(alignment: .center, spacing: 0) {
                if let index {
                    MathNodeView(node: index, size: max(9, size * 0.6))
                        .offset(x: 3, y: -size * 0.32)
                }
                Text("√")
                    .font(.system(size: size * 1.15, design: .serif))
                VStack(spacing: 1) {
                    Rectangle().fill(Palette.ink.opacity(0.8)).frame(height: 1)
                    MathNodeView(node: radicand, size: size)
                        .padding(.horizontal, 2)
                }
                .fixedSize()
            }
        case .script(let base, let sup, let sub, let stacked):
            let subSize = max(9.5, size * 0.68)
            if stacked {
                VStack(spacing: 1) {
                    if let sup { MathNodeView(node: sup, size: subSize) }
                    MathNodeView(node: base, size: size)
                    if let sub { MathNodeView(node: sub, size: subSize) }
                }
                .fixedSize()
                .padding(.horizontal, 2)
            } else {
                HStack(alignment: .center, spacing: 0.5) {
                    MathNodeView(node: base, size: size)
                    VStack(alignment: .leading, spacing: 1) {
                        if let sup {
                            MathNodeView(node: sup, size: subSize)
                                .offset(y: sub == nil ? -size * 0.28 : -size * 0.08)
                        }
                        if let sub {
                            MathNodeView(node: sub, size: subSize)
                                .offset(y: sup == nil ? size * 0.28 : size * 0.08)
                        }
                    }
                }
            }
        case .delim(let left, let body, let right):
            HStack(alignment: .center, spacing: 2) {
                if !left.isEmpty {
                    Text(left).font(.system(size: size * 1.2, weight: .light, design: .serif))
                }
                MathNodeView(node: body, size: size)
                if !right.isEmpty {
                    Text(right).font(.system(size: size * 1.2, weight: .light, design: .serif))
                }
            }
        case .accent(let kind, let body):
            VStack(spacing: 0) {
                if kind == "bar" || kind == "overline" {
                    Rectangle().fill(Palette.ink.opacity(0.8)).frame(height: 1)
                    MathNodeView(node: body, size: size)
                } else if kind == "underline" {
                    MathNodeView(node: body, size: size)
                    Rectangle().fill(Palette.ink.opacity(0.8)).frame(height: 1)
                } else {
                    let top: String = {
                        switch kind {
                        case "hat", "widehat": return "ˆ"
                        case "vec": return "→"
                        case "dot": return "˙"
                        case "ddot": return "¨"
                        case "tilde", "widetilde": return "˜"
                        default: return ""
                        }
                    }()
                    if !top.isEmpty {
                        Text(top)
                            .font(.system(size: size * 0.72, design: .serif))
                            .offset(y: size * 0.22)
                    }
                    MathNodeView(node: body, size: size)
                }
            }
            .fixedSize()
        case .matrix(let left, let right, let rows):
            let scale = max(1.3, min(2.6, 1.0 + CGFloat(max(0, rows.count - 1)) * 0.65))
            HStack(alignment: .center, spacing: 4) {
                if !left.isEmpty {
                    Text(left).font(.system(size: size * scale, weight: .ultraLight, design: .serif))
                }
                Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                MathNodeView(node: cell, size: max(11, size * 0.92))
                            }
                        }
                    }
                }
                if !right.isEmpty {
                    Text(right).font(.system(size: size * scale, weight: .ultraLight, design: .serif))
                }
            }
        }
    }
}

// MARK: - Rich Markdown Reply View

struct MarkdownReplyView: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        let marked = Citations.mark(text)
        let blocks = MarkdownParser.parse(marked.text)

        VStack(alignment: .leading, spacing: size * 0.72) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let words):
                    Text(MathTex.inlineRich(words, size: size))
                        .lineSpacing(size * 0.22)

                case .heading(let level, let words):
                    let hSize: CGFloat = level == 1 ? size + 4.5 : (level == 2 ? size + 2.5 : (level == 3 ? size + 1 : size))
                    Text(MathTex.inlineRich(words, size: hSize))
                        .font(.system(size: hSize, weight: level <= 2 ? .semibold : .medium))
                        .padding(.top, level <= 2 ? 4 : 2)

                case .listItem(let words, let mark, let depth, let checked):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: size - 1))
                                .foregroundStyle(checked ? Palette.accent : Palette.muted)
                                .frame(minWidth: 14, alignment: .trailing)
                        } else {
                            Text(mark)
                                .foregroundStyle(Palette.muted)
                                .frame(minWidth: 12, alignment: .trailing)
                        }
                        Text(MathTex.inlineRich(words, size: size))
                            .lineSpacing(size * 0.22)
                    }
                    .padding(.leading, 2 + CGFloat(depth) * 14)

                case .blockquote(let lines):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Palette.accent.opacity(0.45))
                            .frame(width: 2.5)
                        Text(MathTex.inlineRich(lines.joined(separator: "\n"), size: size))
                            .foregroundStyle(Palette.ink.opacity(0.86))
                            .lineSpacing(size * 0.22)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.wash.opacity(0.45), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                case .code(let language, let code):
                    CodeBlockCard(language: language, code: code, size: size)

                case .table(let headers, let alignments, let rows):
                    MarkdownTableCard(headers: headers, alignments: alignments, rows: rows, size: size)

                case .mathBlock(let tex):
                    DisplayMathView(tex: tex, size: size)

                case .rule:
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 2)
                }
            }
            if !marked.sources.isEmpty {
                SourcesRow(sources: marked.sources, size: size)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodeBlockCard: View {
    let language: String?
    let code: String
    let size: CGFloat

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(copied ? Palette.safe : Palette.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.ink.opacity(0.04))

            Rectangle().fill(Palette.hairline).frame(height: 0.75)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: max(11, size - 1.5), design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.wash.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.75))
    }
}

private struct MarkdownTableCard: View {
    let headers: [String]
    let alignments: [MarkdownBlock.Alignment]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        let cellSize = max(11.5, size - 0.5)
        let colCount = headers.count

        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        let align = col < alignments.count ? alignments[col] : .leading
                        Text(MathTex.inlineRich(headers[col], size: cellSize))
                            .font(.system(size: cellSize, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(align.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(minWidth: 96, maxWidth: 260, alignment: Alignment(horizontal: align.horizontal, vertical: .top))
                    }
                }
                .background(Palette.wash.opacity(0.85))

                ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<colCount, id: \.self) { col in
                            let align = col < alignments.count ? alignments[col] : .leading
                            let cell = col < row.count ? row[col] : ""
                            Text(MathTex.inlineRich(cell, size: cellSize))
                                .font(.system(size: cellSize))
                                .foregroundStyle(Palette.ink.opacity(0.92))
                                .lineSpacing(2.5)
                                .multilineTextAlignment(align.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(minWidth: 96, maxWidth: 260, alignment: Alignment(horizontal: align.horizontal, vertical: .top))
                        }
                    }
                    .background(rIdx.isMultiple(of: 2) ? Color.clear : Palette.ink.opacity(0.02))
                }
            }
        }
        .background(Palette.ground.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.75))
    }
}
