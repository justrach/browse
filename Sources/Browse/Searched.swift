import Foundation

// What you searched for before, found again from a few of its words. Nothing
// new is kept for it: every search already sits in the history as the page
// of results it opened, and the words are read back out of that address —
// the ones typed into the field here, the ones typed into the engine's own
// box, and the ones another Mac synced over.
//
// Ranked by BM25 over those searches. Every word typed has to be in one; the
// last, while it is still being typed, only has to start one. A rare word
// counts for more than a common one, and a short search that is mostly what
// was typed beats a long one that happens to hold it. Then the history's own
// habit, often and lately, on top.

struct Searched {
    private struct Past {
        let words: String
        let display: String
        let terms: [String]
        let count: Int
        let last: Date
    }

    private let past: [Past]
    /// How many searches each word is in.
    private let spread: [String: Int]
    private let average: Double

    init(_ found: [(words: String, count: Int, last: Date)]) {
        // The same words searched twice — on two engines, or with a
        // different tail of tracking on the address — are one search.
        var merged: [String: (display: String, count: Int, last: Date)] = [:]
        for one in found {
            let display = one.words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let words = Searched.plain(display)
            guard !words.isEmpty else { continue }
            let was = merged[words]
            merged[words] = (
                one.last >= (was?.last ?? .distantPast) ? display : was?.display ?? display,
                (was?.count ?? 0) + one.count,
                max(was?.last ?? one.last, one.last)
            )
        }
        past = merged.map {
            Past(words: $0.key, display: $0.value.display, terms: Searched.terms($0.key),
                 count: $0.value.count, last: $0.value.last)
        }
        var spread: [String: Int] = [:]
        for one in past { for term in Set(one.terms) { spread[term, default: 0] += 1 } }
        self.spread = spread
        average = past.isEmpty ? 1 : max(1, Double(past.reduce(0) { $0 + $1.terms.count }) / Double(past.count))
    }

    /// Most recent searches for a blank field.
    func recent(limit: Int) -> [String] {
        Array(past.sorted {
            if $0.last != $1.last { return $0.last > $1.last }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.words < $1.words
        }.prefix(limit).map(\.display))
    }

    /// Best first, never the very words typed — the field's own search row is that one.
    func matching(_ typed: String, limit: Int, now: Date = Date()) -> [String] {
        let asked = Searched.plain(typed)
        guard !asked.isEmpty, !past.isEmpty else { return [] }
        var whole = Searched.terms(asked)
        guard !whole.isEmpty else { return [] }
        // Still being typed: the last word is whatever it may yet become.
        let partial = typed.last.map({ $0.isLetter || $0.isNumber }) == true ? whole.removeLast() : nil
        let punctuation = typed.last.map({ !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) == true

        let k1 = 1.2, b = 0.75, n = Double(past.count)
        func rarity(_ term: String) -> Double {
            let found = Double(spread[term] ?? 0)
            return log(1 + (n - found + 0.5) / (found + 0.5))
        }

        var scored: [(words: String, score: Double)] = []
        for one in past where one.words != asked {
            // A trailing +, # or other punctuation belongs to the search,
            // not to a half-typed alphabetic word.
            if punctuation && !one.words.contains(asked) { continue }
            let norm = k1 * (1 - b + b * Double(one.terms.count) / average)
            var score = 0.0
            var all = true
            for term in whole {
                let often = Double(one.terms.lazy.filter { $0 == term }.count)
                guard often > 0 else { all = false; break }
                score += rarity(term) * often * (k1 + 1) / (often + norm)
            }
            guard all else { continue }
            if let partial {
                guard let best = one.terms.lazy.filter({ $0.hasPrefix(partial) }).map(rarity).max() else { continue }
                score += best * (k1 + 1) / (1 + norm)
            }
            // Carries straight on from what was typed: the one the grey
            // ending in the field can show.
            if one.words.hasPrefix(asked) { score += 2 }
            let days = max(0, now.timeIntervalSince(one.last) / 86_400)
            score *= 1 + log1p(Double(one.count) * exp(-days / 30))
            scored.append((one.display, score))
        }
        return scored
            .sorted { $0.score == $1.score ? $0.words.count < $1.words.count : $0.score > $1.score }
            .prefix(limit)
            .map(\.words)
    }

    /// Lower case, one space between words.
    static func plain(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func terms(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Where each engine keeps the words: its host, its path and the name
    /// of the part of the address that holds them.
    struct Pages {
        private static let mark = "SEARCHWORDS"

        private enum Slot {
            case query(name: String, pattern: String)
            case path(pattern: String)
            case fragment(pattern: String)
        }

        private let known: [(host: String, path: String, slot: Slot)]

        init(_ templates: [String]) {
            known = templates.compactMap { template in
                guard let parts = URLComponents(string: template.replacingOccurrences(of: "%s", with: Pages.mark)),
                      let host = parts.host?.lowercased()
                else { return nil }
                let path = parts.path.isEmpty ? "/" : parts.path
                if let items = parts.queryItems, let encoded = parts.percentEncodedQueryItems {
                    for (item, raw) in zip(items, encoded) where raw.value?.contains(Pages.mark) == true {
                        return (Pages.bare(host), path, .query(name: item.name, pattern: raw.value ?? ""))
                    }
                }
                if parts.percentEncodedPath.contains(Pages.mark) {
                    return (Pages.bare(host), path, .path(pattern: parts.percentEncodedPath))
                }
                if let fragment = parts.percentEncodedFragment, fragment.contains(Pages.mark) {
                    return (Pages.bare(host), path, .fragment(pattern: fragment))
                }
                return nil
            }
        }

        /// Whether a history key could be a page of results at all: it
        /// starts with an engine's host. Cheap, so the thousands that can't
        /// be are passed over without their addresses being read.
        func might(_ key: String) -> Bool {
            known.contains { key.hasPrefix($0.host) }
        }

        /// The words `url` searched for, if it is a page of results.
        func words(in url: URL) -> String? {
            guard let host = url.host()?.lowercased(),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            let path = url.path.isEmpty ? "/" : url.path
            for engine in known where engine.host == Pages.bare(host) {
                let raw: String?
                let formEncoded: Bool
                switch engine.slot {
                case let .query(name, pattern):
                    guard engine.path == path else { continue }
                    let items = zip(parts.queryItems ?? [], parts.percentEncodedQueryItems ?? [])
                    raw = items.first(where: { $0.0.name == name }).flatMap { Pages.capture(pattern, in: $0.1.value ?? "") }
                    formEncoded = true
                case let .path(pattern):
                    raw = Pages.capture(pattern, in: parts.percentEncodedPath)
                    formEncoded = false
                case let .fragment(pattern):
                    guard engine.path == path else { continue }
                    raw = parts.percentEncodedFragment.flatMap { Pages.capture(pattern, in: $0) }
                    formEncoded = false
                }
                // A query's raw "+" is a space, while %2B is a literal plus.
                guard let raw,
                      let value = (formEncoded ? raw.replacingOccurrences(of: "+", with: " ") : raw)
                        .removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty
                else { continue }
                return value
            }
            return nil
        }

        private static func capture(_ pattern: String, in value: String) -> String? {
            guard let slot = pattern.range(of: mark) else { return nil }
            let before = pattern[..<slot.lowerBound]
            let after = pattern[slot.upperBound...]
            guard value.hasPrefix(before), value.hasSuffix(after), value.count >= before.count + after.count else { return nil }
            return String(value.dropFirst(before.count).dropLast(after.count))
        }

        private static func bare(_ host: String) -> String {
            host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }
}
