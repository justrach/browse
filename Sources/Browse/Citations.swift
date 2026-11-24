import SwiftUI

// Sources in a reply, said once.
//
// Codegraff names its sources as markdown links, and most land at the end of
// a sentence: "…notes of her own. [Computer History Museum](…)". Three
// bullets citing one museum were the museum's name three times over, in
// blue, longer than the points. So a link that comes after the end of a
// sentence and ends its line is a citation: it becomes a small number, the
// same number every time for the same page, and under the reply each source
// is a chip, once. A link inside a sentence — "see [the docs](…)" — is
// words, and stays a link.

enum Citations {
    struct Source: Identifiable, Hashable {
        let number: Int
        let url: URL
        let label: String
        var id: Int { number }

        /// What the chip says: the link's own words, or the site when the
        /// words are only "source" or the address.
        var title: String {
            let plain = label.trimmingCharacters(in: .whitespaces)
            let lower = plain.lowercased()
            if plain.isEmpty || ["source", "link", "here", "this", "page"].contains(lower) || plain.contains("://") {
                return host
            }
            return plain
        }

        var host: String {
            (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        }
    }

    /// Marks a citation's number inside the rewritten markdown, so the reply
    /// can tell it from a link someone typed as a number.
    static let marker: Character = "\u{2063}"

    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#)

    private final class MarkCache: @unchecked Sendable {
        struct Anchor {
            let prefix: String
            let utf8Count: Int
            let rewrittenPrefix: String
            let sources: [Source]
            let numbers: [String: Int]
            let inCode: Bool
            let inMath: Bool
        }

        private let lock = NSLock()
        private let exactLimit = 128
        private var exact: [String: (text: String, sources: [Source])] = [:]
        private var exactRing: [String?] = Array(repeating: nil, count: 128)
        private var exactCursor = 0
        private var lastInput: String?
        private var lastOutput: (text: String, sources: [Source])?
        private var anchors: [Anchor] = []

        func exactHit(_ text: String) -> (text: String, sources: [Source])? {
            lock.lock()
            defer { lock.unlock() }
            if let last = lastInput, last == text, let out = lastOutput {
                storeExactLocked(text, out)
                return out
            }
            return exact[text]
        }

        func matchingAnchor(for text: String) -> Anchor? {
            lock.lock()
            defer { lock.unlock() }
            let count = text.utf8.count
            var best: Anchor?
            for anchor in anchors where count >= anchor.utf8Count && anchor.utf8Count > 0 {
                if let current = best, anchor.utf8Count <= current.utf8Count { continue }
                if text.utf8.prefix(anchor.utf8Count).elementsEqual(anchor.prefix.utf8) {
                    best = anchor
                }
            }
            return best
        }

        func updateAnchor(
            oldUTF8Count: Int?,
            newPrefix: String,
            rewrittenPrefix: String,
            sources: [Source],
            numbers: [String: Int],
            inCode: Bool,
            inMath: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            let updated = Anchor(
                prefix: newPrefix,
                utf8Count: newPrefix.utf8.count,
                rewrittenPrefix: rewrittenPrefix,
                sources: sources,
                numbers: numbers,
                inCode: inCode,
                inMath: inMath
            )
            if let oldUTF8Count, let idx = anchors.firstIndex(where: { $0.utf8Count == oldUTF8Count && newPrefix.utf8.prefix(oldUTF8Count).elementsEqual($0.prefix.utf8) }) {
                anchors[idx] = updated
            } else {
                if anchors.count >= 4 { anchors.removeFirst() }
                anchors.append(updated)
            }
        }

        func recordLast(text: String, result: (text: String, sources: [Source]), cacheExact: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            lastInput = text
            lastOutput = result
            if cacheExact {
                storeExactLocked(text, result)
            }
        }

        private func storeExactLocked(_ text: String, _ result: (text: String, sources: [Source])) {
            if exact[text] != nil {
                exact[text] = result
                return
            }
            if let evicted = exactRing[exactCursor] {
                exact.removeValue(forKey: evicted)
            }
            exactRing[exactCursor] = text
            exactCursor = (exactCursor + 1) % exactLimit
            exact[text] = result
        }
    }

    private static let markCache = MarkCache()

    /// The reply with every citation turned into a numbered marker, and the
    /// sources in the order they were first cited.
    static func mark(_ text: String) -> (text: String, sources: [Source]) {
        if let hit = markCache.exactHit(text) {
            return hit
        }

        if let anchor = markCache.matchingAnchor(for: text) {
            let suffixStart = text.utf8.index(text.startIndex, offsetBy: anchor.utf8Count)
            let tail = text[suffixStart...]
            var sources = anchor.sources
            var numbers = anchor.numbers
            var inCode = anchor.inCode
            var inMath = anchor.inMath

            if let lastNL = tail.lastIndex(of: "\n") {
                var stableOut = anchor.rewrittenPrefix
                stableOut.reserveCapacity(anchor.rewrittenPrefix.count + tail.count)
                let completedSlice = tail[..<lastNL]
                for lineSub in completedSlice.split(separator: "\n", omittingEmptySubsequences: false) {
                    stableOut += processLine(String(lineSub), sources: &sources, numbers: &numbers, inCode: &inCode, inMath: &inMath)
                    stableOut.append("\n")
                }
                let afterNL = tail.index(after: lastNL)
                markCache.updateAnchor(
                    oldUTF8Count: anchor.utf8Count,
                    newPrefix: String(text[..<afterNL]),
                    rewrittenPrefix: stableOut,
                    sources: sources,
                    numbers: numbers,
                    inCode: inCode,
                    inMath: inMath
                )
                let rewrittenTail = processLine(String(text[afterNL...]), sources: &sources, numbers: &numbers, inCode: &inCode, inMath: &inMath)
                let result = (stableOut + rewrittenTail, sources)
                markCache.recordLast(text: text, result: result)
                return result
            } else {
                let rewrittenTail = processLine(String(tail), sources: &sources, numbers: &numbers, inCode: &inCode, inMath: &inMath)
                let result = (anchor.rewrittenPrefix + rewrittenTail, sources)
                markCache.recordLast(text: text, result: result)
                return result
            }
        }

        var sources: [Source] = []
        var numbers: [String: Int] = [:]
        var inCode = false
        var inMath = false

        if let lastNL = text.lastIndex(of: "\n") {
            var stableOut = ""
            stableOut.reserveCapacity(text.count)
            for lineSub in text[..<lastNL].split(separator: "\n", omittingEmptySubsequences: false) {
                stableOut += processLine(String(lineSub), sources: &sources, numbers: &numbers, inCode: &inCode, inMath: &inMath)
                stableOut.append("\n")
            }
            let afterNL = text.index(after: lastNL)
            markCache.updateAnchor(
                oldUTF8Count: nil,
                newPrefix: String(text[..<afterNL]),
                rewrittenPrefix: stableOut,
                sources: sources,
                numbers: numbers,
                inCode: inCode,
                inMath: inMath
            )
            let rewrittenTail = processLine(String(text[afterNL...]), sources: &sources, numbers: &numbers, inCode: &inCode, inMath: &inMath)
            let result = (stableOut + rewrittenTail, sources)
            markCache.recordLast(text: text, result: result, cacheExact: true)
            return result
        }

        let rewritten = processLine(text, sources: &sources, numbers: &numbers, inCode: &inCode, inMath: &inMath)
        let result = (rewritten, sources)
        markCache.recordLast(text: text, result: result, cacheExact: true)
        return result
    }

    private static func processLine(
        _ line: String,
        sources: inout [Source],
        numbers: inout [String: Int],
        inCode: inout Bool,
        inMath: inout Bool
    ) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inCode.toggle(); return line }
        if inCode { return line }
        if trimmed == "$$" || trimmed == "\\[" || trimmed == "\\]" { inMath.toggle(); return line }
        if inMath || trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") { return line }
        // Keep pipe table rows untouched so links inside table cells stay
        // clean clickable links instead of losing their closing parenthesis.
        if trimmed.hasPrefix("|") { return line }
        return rewrite(line, sources: &sources, numbers: &numbers)
    }

    private static func stripListMark(_ s: String) -> Substring {
        guard let first = s.first else { return s[...] }
        var idx = s.startIndex
        if first == "-" || first == "*" || first == "•" || first == "+" {
            idx = s.index(after: idx)
        } else if first.isNumber {
            var digitsEnd = idx
            while digitsEnd < s.endIndex, s[digitsEnd].isNumber {
                digitsEnd = s.index(after: digitsEnd)
            }
            guard digitsEnd < s.endIndex, s[digitsEnd] == "." || s[digitsEnd] == ")" else {
                return s[...]
            }
            idx = s.index(after: digitsEnd)
        } else {
            return s[...]
        }
        while idx < s.endIndex, s[idx].isWhitespace {
            idx = s.index(after: idx)
        }
        return s[idx...]
    }

    private static func rewrite(_ line: String, sources: inout [Source], numbers: inout [String: Int]) -> String {
        guard line.contains("](") else { return line }
        let whole = line as NSString
        let matches = link.matches(in: line, range: NSRange(location: 0, length: whole.length))
        guard !matches.isEmpty else { return line }
        var out = ""
        var at = 0
        for (index, match) in matches.enumerated() {
            let before = whole.substring(with: NSRange(location: at, length: match.range.location - at))
            let nextStart = index + 1 < matches.count ? matches[index + 1].range.location : whole.length
            let after = whole.substring(with: NSRange(location: match.range.upperBound, length: nextStart - match.range.upperBound))
            let label = whole.substring(with: match.range(at: 1))
            let address = whole.substring(with: match.range(at: 2))
            // What the line says before the link, less a list's own mark: a
            // line that is only a bulleted link is a link, not a citation.
            let trimmedPrefix = (out + before).trimmingCharacters(in: .whitespaces)
            let prefix = stripListMark(trimmedPrefix)
            let endsSentence = prefix.last.map { ".!?;:)(—–".contains($0) } ?? false
            let restIsBare = after.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)).isEmpty
            guard endsSentence, restIsBare, let url = URL(string: address) else {
                out += before + whole.substring(with: match.range)
                at = match.range.upperBound
                continue
            }
            let key = address.components(separatedBy: "#").first ?? address
            let number: Int
            if let known = numbers[key] {
                number = known
            } else {
                number = sources.count + 1
                numbers[key] = number
                sources.append(Source(number: number, url: url, label: label))
            }
            // Snug against the sentence, as a footnote sits; an opening
            // bracket left alone by the citation goes with it.
            var lead = (out + before)
            while lead.last == " " { lead.removeLast() }
            if lead.last == "(" { lead.removeLast(); while lead.last == " " { lead.removeLast() } }
            out = lead + "[\(marker)\(number)](\(address))"
            at = match.range.upperBound
        }
        var tail = whole.substring(from: at)
        // The closing bracket of "([Source](…))".
        if tail.hasPrefix(")"), out.hasSuffix(")"), line.contains("([") { tail.removeFirst() }
        return out + tail
    }

    /// A reply's markdown line, its citation numbers set small and raised in
    /// the accent.
    static func style(_ string: AttributedString, size: CGFloat) -> AttributedString {
        var styled = string
        for run in string.runs where run.link != nil {
            let words = String(string[run.range].characters)
            guard words.first == marker else { continue }
            styled[run.range].font = .system(size: size * 0.68, weight: .semibold)
            styled[run.range].baselineOffset = size * 0.38
            styled[run.range].foregroundColor = Palette.accent
            styled[run.range].underlineStyle = nil
        }
        // The marker itself draws nothing, but it isn't needed on screen.
        while let hidden = styled.characters.firstIndex(of: marker) {
            styled.characters.remove(at: hidden)
        }
        return styled
    }
}

/// Under a reply: each source once, numbered as the reply cites it.
struct SourcesRow: View {
    let sources: [Citations.Source]
    var size: CGFloat = 13
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Palette.hairline.opacity(0.5)).frame(height: 1)
            Text("Sources · \(sources.count)")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundStyle(Palette.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(sources) { source in
                    Button { openURL(source.url) } label: {
                        HStack(spacing: 6) {
                            Text("\(source.number)")
                                .font(.system(size: size * 0.7, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .frame(minWidth: size * 1.15, minHeight: size * 1.15)
                                .background(Palette.wash, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .font(.system(size: size * 0.86))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                if source.title != source.host {
                                    Text(source.host)
                                        .font(.system(size: size * 0.75))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8))
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                        .background(Palette.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(source.url.absoluteString)
                    .accessibilityLabel("Source \(source.number): \(source.title), \(source.host)")
                }
            }
        }
    }
}
