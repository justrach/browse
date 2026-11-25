import Foundation

@main
struct BrowseSchemeTests {
    static func check(_ cond: Bool, _ msg: String) {
        if !cond {
            fputs("FAIL: \(msg)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let tabID = UUID()
        check(
            BrowseScheme.parse(URL(string: "browse://tab?id=\(tabID.uuidString)")!) == .tab(tabID),
            "browse://tab?id should parse UUID"
        )
        check(
            BrowseScheme.parse(URL(string: "browse://tab?id=not-a-uuid")!) == nil,
            "malformed tab uuid must return nil"
        )

        let spaceID = UUID()
        check(
            BrowseScheme.parse(URL(string: "browse://space?id=\(spaceID.uuidString)")!) == .space(id: spaceID, name: nil),
            "browse://space?id should parse"
        )
        check(
            BrowseScheme.parse(URL(string: "browse://space?name=Work")!) == .space(id: nil, name: "Work"),
            "browse://space?name should parse"
        )

        let targetURL = URL(string: "https://github.com/justrach/browse")!
        check(
            BrowseScheme.parse(URL(string: "browse://open?url=https%3A%2F%2Fgithub.com%2Fjustrach%2Fbrowse")!) == .open(targetURL, newTab: false),
            "browse://open should parse https URL"
        )
        check(
            BrowseScheme.parse(URL(string: "browse://open?url=https%3A%2F%2Fgithub.com%2Fjustrach%2Fbrowse&new_tab=1")!) == .open(targetURL, newTab: true),
            "browse://open new_tab=1 should set newTab true"
        )
        check(
            BrowseScheme.parse(URL(string: "browse://open?url=file%3A%2F%2F%2Fetc%2Fpasswd")!) == nil,
            "file:// must be rejected by browse://open"
        )
        check(
            BrowseScheme.parse(URL(string: "browse://open?url=javascript%3Aalert(1)")!) == nil,
            "javascript: must be rejected by browse://open"
        )

        check(
            BrowseScheme.parse(URL(string: "browse://search?q=!gh%20swift")!) == .search("!gh swift"),
            "browse://search should preserve !bang query"
        )
        check(
            BrowseScheme.parse(URL(string: "browse://search?q=%20%20")!) == nil,
            "blank search query must return nil"
        )

        let longPrompt = String(repeating: "a", count: 5_000)
        if case .ask(let capped) = BrowseScheme.parse(URL(string: "browse://ask?q=\(longPrompt)")!) {
            check(capped.count == 4_000, "ask prompt must be capped at 4000 characters")
        } else {
            check(false, "long ask prompt should parse and cap")
        }

        check(BrowseScheme.parse(URL(string: "browse://new-tab")!) == .newTab, "new-tab failed")
        check(BrowseScheme.parse(URL(string: "browse://private-tab")!) == .newPrivateTab, "private-tab failed")
        check(BrowseScheme.parse(URL(string: "browse://switcher")!) == .switcher, "switcher failed")
        check(BrowseScheme.parse(URL(string: "https://example.com")!) == nil, "non-browse scheme must return nil")

        print("All BrowseScheme unit tests passed.")
    }
}
