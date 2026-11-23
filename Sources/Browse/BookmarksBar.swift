import SwiftUI

// The bookmarks bar: the top of the bookmarks, in a thin row above the page,
// as Chrome and Safari have one. A folder opens as a menu. More than the row
// holds scrolls sideways.
//
// Off unless asked for — Settings › Tabs, or Bookmarks › Show Bookmarks Bar
// — since the page gives up a strip of its height to it. It goes with the
// tabs when they fold away (⌘S) and when a video takes the screen.

struct BookmarksBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    var framed: Bool = false
    var darkCanvas: Bool = false
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 30
    static let gap: CGFloat = 2
    static let air: CGFloat = 10
    static let moreWidth: CGFloat = 24

    @State private var widths: [Bookmark.ID: CGFloat] = [:]
    @State private var room: CGFloat = 0

    static func fit(_ widths: [CGFloat], room: CGFloat) -> Int {
        let available = max(0, room - 2 * air)
        let total = widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0))
        if total <= available { return widths.count }
        var used: CGFloat = 0
        var count = 0
        let budget = max(0, available - moreWidth - gap)
        for (i, w) in widths.enumerated() {
            let step = w + (i > 0 ? gap : 0)
            if used + step > budget { break }
            used += step
            count += 1
        }
        return count
    }

    private var shownCount: Int {
        guard room > 0 else { return bookmarks.roots.count }
        let measured = bookmarks.roots.map { widths[$0.id] ?? 120 }
        return Self.fit(measured, room: room)
    }

    var body: some View {
        let count = shownCount
        let visible = Array(bookmarks.roots.prefix(count))
        let overflow = Array(bookmarks.roots.dropFirst(count))

        HStack(spacing: Self.gap) {
            ForEach(visible) { node in
                Item(node: node) {
                    if node.isFolder {
                        BookmarkMenu.shared.popUp(node)
                    } else if let text = node.url, let url = URL(string: text) {
                        browser.pickBookmark(url)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    if abs((widths[node.id] ?? -1) - newWidth) > 0.5 {
                        widths[node.id] = newWidth
                    }
                }
                .overlay {
                    if let url = node.url.flatMap(URL.init(string:)) {
                        MiddleClick { browser.pickBookmark(url, inNewTab: true) }
                    } else if node.isFolder {
                        MiddleClick { browser.openAll(node) }
                    }
                }
                .contextMenu {
                    if node.isFolder {
                        let urls = Bookmarks.urls(node.children ?? [])
                        Button("Open All in New Tabs") { browser.openAll(node) }
                            .disabled(urls.isEmpty)
                    } else if let url = node.url.flatMap(URL.init(string:)) {
                        Button("Open in New Tab") { browser.pickBookmark(url, inNewTab: true) }
                    }
                    Divider()
                    Button("Rename…") {
                        Ask.name(node.isFolder ? "Rename Folder" : "Rename Bookmark", placeholder: node.title, initial: node.title, confirm: "Rename") {
                            bookmarks.update(node.id, title: $0, url: nil)
                        }
                    }
                    Button("Remove", role: .destructive) { bookmarks.askRemove(node) }
                }
            }

            if !overflow.isEmpty {
                OverflowButton(count: overflow.count) {
                    BookmarkMenu.shared.popUp(overflow, title: "More Bookmarks")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.air)
        .frame(height: BookmarksBar.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newRoom in
            if abs(room - newRoom) > 0.5 { room = newRoom }
        }
        .background {
            if !framed { Palette.ground }
        }
        .overlay(alignment: .bottom) {
            if !framed {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
        }
        .environment(\.colorScheme, framed ? (darkCanvas ? .dark : .light) : scheme)
    }

    private struct OverflowButton: View {
        let count: Int
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .frame(width: BookmarksBar.moreWidth, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("More bookmarks (\(count))")
        }
    }

    private struct Item: View {
        let node: Bookmark
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                if node.isFolder {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                } else {
                    Mark(icon: Favicons.shared.cached(node.host ?? ""), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 13)
                }
                Text(node.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if node.isFolder {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .help(node.url ?? node.title)
        }
    }
}
