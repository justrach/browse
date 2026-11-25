import Foundation

@main
struct SiteSearchTests {
    static func check(_ cond: Bool, _ msg: String) {
        if !cond {
            fputs("FAIL: \(msg)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        // 1. Built-in !bangs resolve cleanly (case-insensitive)
        let gh = SiteSearch.resolve("!gh swift webkit", custom: [], enabled: true)
        check(gh != nil, "!gh should resolve")
        check(gh?.shortcut.name == "GitHub", "expected GitHub name")
        check(gh?.query == "swift webkit", "expected trimmed query")
        check(gh?.url.absoluteString == "https://github.com/search?q=swift%20webkit", "unexpected !gh url: \(gh?.url.absoluteString ?? "")")

        let yt = SiteSearch.resolve("  !YT  lofi beats ", custom: [], enabled: true)
        check(yt?.shortcut.keyword == "yt", "case-insensitive !YT failed")
        check(yt?.url.absoluteString == "https://www.youtube.com/results?search_query=lofi%20beats", "unexpected !YT url")

        let mdn = SiteSearch.resolve("!mdn Array.prototype.map", custom: [], enabled: true)
        check(mdn?.url.absoluteString == "https://developer.mozilla.org/en-US/search?q=Array.prototype.map", "unexpected !mdn url")

        // 2. Empty queries and non-bang multi-word strings do not trigger built-ins
        check(SiteSearch.resolve("!gh", custom: [], enabled: true) == nil, "!gh without query must be nil")
        check(SiteSearch.resolve("!gh   ", custom: [], enabled: true) == nil, "!gh with blank query must be nil")
        check(SiteSearch.resolve("gh swift", custom: [], enabled: true) == nil, "plain 'gh swift' must not trigger built-in without custom shortcut")
        check(SiteSearch.resolve("!unknown test", custom: [], enabled: true) == nil, "unknown bang must be nil")

        // 3. Disabled returns nil
        check(SiteSearch.resolve("!gh swift", custom: [], enabled: false) == nil, "disabled must return nil")

        // 4. Custom shortcuts override built-ins and accept both bare & ! forms
        let customDocs = SiteShortcut(keyword: "docs", name: "Internal Docs", template: "https://docs.example.com/search?q=%s")
        let customGH = SiteShortcut(keyword: "gh", name: "Enterprise Git", template: "https://git.corp.example.com/search?q=%s")
        let customInvalid = SiteShortcut(keyword: "bad", name: "Bad", template: "not-a-valid-template")

        let docsBare = SiteSearch.resolve("docs webkit", custom: [customDocs], enabled: true)
        check(docsBare?.url.absoluteString == "https://docs.example.com/search?q=webkit", "custom bare keyword failed")
        let docsBang = SiteSearch.resolve("!docs webkit", custom: [customDocs], enabled: true)
        check(docsBang?.url.absoluteString == "https://docs.example.com/search?q=webkit", "custom !keyword failed")

        let ghOverride = SiteSearch.resolve("!gh repo", custom: [customGH], enabled: true)
        check(ghOverride?.shortcut.name == "Enterprise Git", "custom shortcut should override built-in")
        check(ghOverride?.url.host() == "git.corp.example.com", "custom override url host mismatch")

        check(SiteSearch.resolve("bad test", custom: [customInvalid], enabled: true) == nil, "invalid custom template must be rejected")

        // 5. Keyword normalization
        check(SiteSearch.normalizeKeyword(" !My_Key-1 ") == "my_key-1", "normalizeKeyword failed")
        check(SiteSearch.normalizeKeyword("!") == nil, "bare ! must fail normalization")
        check(SiteSearch.normalizeKeyword("bad key") == nil, "space in keyword must fail normalization")

        print("All SiteSearch unit tests passed.")
    }
}
