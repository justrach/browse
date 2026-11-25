import Foundation

/// A user-defined or built-in site search keyword (bang) resolved directly from
/// the Omnibox or Command Switcher (`!gh swift`, `!yt lofi`, or a custom key).
struct SiteShortcut: Codable, Identifiable, Equatable {
    var id: String { keyword }
    var keyword: String
    var name: String
    var template: String
}

/// Resolves `!bang` prefixes and custom site-search keywords into destination URLs
/// without leaving the local process or altering default search-engine behavior.
enum SiteSearch {
    struct Match: Equatable {
        let shortcut: SiteShortcut
        let query: String
        let url: URL
    }

    static let builtIns: [SiteShortcut] = [
        SiteShortcut(keyword: "gh", name: "GitHub", template: "https://github.com/search?q=%s"),
        SiteShortcut(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        SiteShortcut(keyword: "mdn", name: "MDN", template: "https://developer.mozilla.org/en-US/search?q=%s"),
        SiteShortcut(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s"),
        SiteShortcut(keyword: "r", name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
        SiteShortcut(keyword: "hn", name: "Hacker News", template: "https://hn.algolia.com/?q=%s"),
        SiteShortcut(keyword: "npm", name: "npm", template: "https://www.npmjs.com/search?q=%s"),
        SiteShortcut(keyword: "crates", name: "crates.io", template: "https://crates.io/search?q=%s"),
        SiteShortcut(keyword: "so", name: "Stack Overflow", template: "https://stackoverflow.com/search?q=%s"),
        SiteShortcut(keyword: "maps", name: "Google Maps", template: "https://www.google.com/maps/search/%s"),
        SiteShortcut(keyword: "g", name: "Google", template: "https://www.google.com/search?q=%s"),
        SiteShortcut(keyword: "ddg", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
        SiteShortcut(keyword: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%s"),
        SiteShortcut(keyword: "apple", name: "Apple Developer", template: "https://developer.apple.com/search/?q=%s"),
        SiteShortcut(keyword: "x", name: "X", template: "https://x.com/search?q=%s"),
        SiteShortcut(keyword: "pkg", name: "Swift Package Index", template: "https://swiftpackageindex.com/search?query=%s"),
    ]

    private static let builtInByKeyword: [String: SiteShortcut] = Dictionary(
        uniqueKeysWithValues: builtIns.map { ($0.keyword, $0) }
    )

    /// Validates and canonicalizes a shortcut keyword (`1...24` ASCII/Unicode
    /// letters, digits, hyphens, or underscores; optional leading `!` stripped).
    static func normalizeKeyword(_ raw: String) -> String? {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("!") { key.removeFirst() }
        key = key.lowercased()
        guard !key.isEmpty, key.count <= 24 else { return nil }
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return key
    }

    /// Resolves typed Omnibox / switcher input to a matching site shortcut URL.
    /// Custom keywords match with or without a leading `!` and take precedence over
    /// built-ins; built-in bangs require a leading `!` so normal multi-word searches
    /// are never hijacked unintentionally.
    static func resolve(_ input: String, custom: [SiteShortcut], enabled: Bool) -> Match? {
        guard enabled else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.firstIndex(where: \.isWhitespace) else { return nil }

        let token = String(trimmed[..<split])
        let query = trimmed[split...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !query.isEmpty else { return nil }

        let hasBang = token.hasPrefix("!")
        let normalized = (hasBang ? String(token.dropFirst()) : token).lowercased()
        guard !normalized.isEmpty else { return nil }

        if let hit = custom.first(where: { (normalizeKeyword($0.keyword) ?? $0.keyword.lowercased()) == normalized }),
           Engine.accepts(hit.template),
           let url = Engine.url(for: query, template: hit.template) {
            return Match(shortcut: hit, query: query, url: url)
        }

        if hasBang,
           let builtin = builtInByKeyword[normalized],
           let url = Engine.url(for: query, template: builtin.template) {
            return Match(shortcut: builtin, query: query, url: url)
        }

        return nil
    }
}
