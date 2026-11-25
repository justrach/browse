import Foundation

/// Deep-link actions accepted over the `browse://` custom URL scheme so local
/// companions such as Nanolight can switch tabs, switch Spaces, open web URLs,
/// run searches/bangs, or prefill a Codegraff prompt safely.
enum BrowseCommand: Equatable {
    case tab(UUID)
    case space(id: UUID?, name: String?)
    case open(URL, newTab: Bool)
    case search(String)
    case ask(String)
    case newTab
    case newPrivateTab
    case switcher
}

enum BrowseScheme {
    static func parse(_ url: URL) -> BrowseCommand? {
        guard url.scheme?.lowercased() == "browse",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let action = (parts.host ?? parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !action.isEmpty else { return nil }

        let items = parts.queryItems ?? []
        func value(_ names: String...) -> String? {
            for name in names {
                if let val = items.first(where: { $0.name.lowercased() == name })?.value {
                    return val
                }
            }
            return nil
        }

        switch action {
        case "tab":
            guard let raw = value("id"), let id = UUID(uuidString: raw) else { return nil }
            return .tab(id)

        case "space":
            let id = value("id").flatMap(UUID.init(uuidString:))
            let name = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = (name?.isEmpty == false) ? name : nil
            guard id != nil || cleanName != nil else { return nil }
            return .space(id: id, name: cleanName)

        case "open":
            guard let raw = value("url"),
                  let target = URL(string: raw),
                  let scheme = target.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = target.host(), !host.isEmpty
            else { return nil }
            let rawNewTab = value("new_tab", "newtab")?.lowercased() ?? ""
            let newTab = rawNewTab == "1" || rawNewTab == "true" || rawNewTab == "yes"
            return .open(target, newTab: newTab)

        case "search":
            guard let raw = value("q", "query")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            return .search(String(raw.prefix(2_000)))

        case "ask":
            guard let raw = value("q", "prompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            // Prefill-only: never executes automatically.
            return .ask(String(raw.prefix(4_000)))

        case "new-tab", "newtab":
            return .newTab

        case "private-tab", "new-private-tab", "incognito":
            return .newPrivateTab

        case "switcher", "tabs":
            return .switcher

        default:
            return nil
        }
    }
}
