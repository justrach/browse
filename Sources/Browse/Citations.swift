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

    /// The reply with every citation turned into a numbered marker, and the
    /// sources in the order they were first cited.
    static func mark(_ text: String) -> (text: String, sources: [Source]) {
        var sources: [Source] = []
        var numbers: [String: Int] = [:]
        var inCode = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return line }
            if inCode { return line }
            return rewrite(line, sources: &sources, numbers: &numbers)
        }
        return (lines.joined(separator: "\n"), sources)
    }

    private static func rewrite(_ line: String, sources: inout [Source], numbers: inout [String: Int]) -> String {
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
            let prefix = (out + before).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^([-*•+]|\d+[.)])\s*"#, with: "", options: .regularExpression)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Button { openURL(source.url) } label: {
                        HStack(spacing: 6) {
                            Text("\(source.number)")
                                .font(.system(size: size * 0.7, weight: .semibold))
                                .foregroundStyle(Palette.onAccent)
                                .frame(minWidth: size * 1.15, minHeight: size * 1.15)
                                .background(Palette.accent, in: Circle())
                            Text(source.title)
                                .font(.system(size: size * 0.86))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 10)
                        .padding(.vertical, 4)
                        .background(Palette.wash, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(source.url.absoluteString)
                }
            }
        }
    }
}
