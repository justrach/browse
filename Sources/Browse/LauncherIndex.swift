import Foundation

/// Zero-secret snapshot exported to `~/Library/Application Support/browse/launcher.json`
/// so local companion launchers like Nanolight can search open tabs, bookmarks,
/// Spaces, and custom site-search shortcuts without polling processes or reading cookies.
struct LauncherSnapshot: Codable, Equatable {
    struct TabItem: Codable, Equatable {
        let id: String
        let title: String
        let url: String
        let host: String
        let spaceId: String
        let spaceName: String
        let group: String
        let pinned: Bool
        let active: Bool
    }

    struct BookmarkItem: Codable, Equatable {
        let title: String
        let url: String
        let host: String
        let folder: String
    }

    struct SpaceItem: Codable, Equatable {
        let id: String
        let name: String
    }

    let version: Int
    let updatedAt: Int64
    let tabs: [TabItem]
    let bookmarks: [BookmarkItem]
    let spaces: [SpaceItem]
    let shortcuts: [SiteShortcut]
}

@MainActor
enum LauncherIndex {
    private static var pendingWork: DispatchWorkItem?

    static func snapshot(
        tabs: [Tab],
        parked: [UUID: Parked],
        spaces: [Space],
        activeSpaceID: UUID,
        activeTabID: Tab.ID?,
        groups: [TabGroup],
        bookmarks: [Bookmark],
        customShortcuts: [SiteShortcut],
        siteShortcutsEnabled: Bool
    ) -> LauncherSnapshot {
        let spaceByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        let activeGroupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })

        var tabItems: [LauncherSnapshot.TabItem] = []
        tabItems.reserveCapacity(min(200, tabs.count + 16))

        func appendTabs(_ list: [Tab], spaceID: UUID, groupByID: [UUID: String], isCurrentSpace: Bool) {
            let spaceName = spaceByID[spaceID]?.name ?? "Personal"
            for tab in list {
                guard tabItems.count < 200 else { return }
                guard !tab.shy, !tab.bench, !tab.isBlank,
                      let url = tab.pending ?? tab.address,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      let host = url.host(), !host.isEmpty
                else { continue }
                let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let groupName = tab.userGroupID.flatMap { groupByID[$0] } ?? (tab.agentGroup ?? "")
                let rawTitle = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
                tabItems.append(LauncherSnapshot.TabItem(
                    id: tab.id.uuidString,
                    title: rawTitle.isEmpty ? bareHost : rawTitle,
                    url: url.absoluteString,
                    host: bareHost,
                    spaceId: spaceID.uuidString,
                    spaceName: spaceName,
                    group: groupName,
                    pinned: tab.pin != nil,
                    active: isCurrentSpace && tab.id == activeTabID
                ))
            }
        }

        appendTabs(tabs, spaceID: activeSpaceID, groupByID: activeGroupByID, isCurrentSpace: true)
        for space in spaces where space.id != activeSpaceID {
            guard tabItems.count < 200 else { break }
            if let row = parked[space.id] {
                let rowGroups = Dictionary(uniqueKeysWithValues: row.groups.map { ($0.id, $0.name) })
                appendTabs(row.tabs, spaceID: space.id, groupByID: rowGroups, isCurrentSpace: false)
            }
        }

        var bookmarkItems: [LauncherSnapshot.BookmarkItem] = []
        bookmarkItems.reserveCapacity(64)
        var seenBookmarkURLs = Set<String>()
        func walkBookmarks(_ nodes: [Bookmark], folder: String) {
            for node in nodes {
                guard bookmarkItems.count < 400 else { return }
                if node.isFolder {
                    walkBookmarks(node.children ?? [], folder: node.title)
                    continue
                }
                guard let raw = node.url,
                      seenBookmarkURLs.insert(raw).inserted,
                      let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      let host = url.host(), !host.isEmpty
                else { continue }
                let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let cleanTitle = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                bookmarkItems.append(LauncherSnapshot.BookmarkItem(
                    title: cleanTitle.isEmpty ? bareHost : cleanTitle,
                    url: raw,
                    host: bareHost,
                    folder: folder
                ))
            }
        }
        walkBookmarks(bookmarks, folder: "")

        let spaceItems = spaces.map { LauncherSnapshot.SpaceItem(id: $0.id.uuidString, name: $0.name) }

        var shortcuts: [SiteShortcut] = []
        if siteShortcutsEnabled {
            var seenKeys = Set<String>()
            for item in customShortcuts {
                guard let norm = SiteSearch.normalizeKeyword(item.keyword),
                      Engine.accepts(item.template),
                      seenKeys.insert(norm).inserted
                else { continue }
                shortcuts.append(SiteShortcut(keyword: norm, name: item.name, template: item.template))
            }
            for item in SiteSearch.builtIns {
                guard seenKeys.insert(item.keyword).inserted else { continue }
                shortcuts.append(item)
            }
        }

        return LauncherSnapshot(
            version: 1,
            updatedAt: Int64(Date().timeIntervalSince1970),
            tabs: tabItems,
            bookmarks: bookmarkItems,
            spaces: spaceItems,
            shortcuts: shortcuts
        )
    }

    static func scheduleWrite(
        _ snapshot: LauncherSnapshot,
        to file: URL = Store.file("launcher.json"),
        immediate: Bool = false
    ) {
        pendingWork?.cancel()
        pendingWork = nil

        let writeBlock: @Sendable () -> Void = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        if immediate {
            writeBlock()
            return
        }

        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async(execute: writeBlock)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
