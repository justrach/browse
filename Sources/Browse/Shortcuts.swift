import SwiftUI

/// The keys this browser itself takes, shared by setup and Help.
struct Shortcut: Identifiable {
    let keys: String
    let what: String
    var id: String { keys }
}

enum Shortcuts {
    static let first: [Shortcut] = [
        Shortcut(keys: "⌘T", what: "New tab"),
        Shortcut(keys: "⌘L", what: "Open address"),
        Shortcut(keys: "⌘K", what: "Search open tabs"),
        Shortcut(keys: "⇧⌘T", what: "Reopen closed tab"),
        Shortcut(keys: "⇧⌘N", what: "New private tab"),
        Shortcut(keys: "⌃Tab", what: "Next tab"),
        Shortcut(keys: "⌃⇧Tab", what: "Previous tab"),
        Shortcut(keys: "⌘,", what: "Settings"),
    ]

    static let pages: [Shortcut] = [
        Shortcut(keys: "⌘[", what: "Back"),
        Shortcut(keys: "⌘]", what: "Forward"),
        Shortcut(keys: "⌘R", what: "Reload page"),
        Shortcut(keys: "⌘F", what: "Find on page"),
        Shortcut(keys: "⌘G", what: "Find next"),
        Shortcut(keys: "⇧⌘G", what: "Find previous"),
    ]

    static let tabs: [Shortcut] = [
        Shortcut(keys: "⌘1–⌘9", what: "Jump to a tab"),
        Shortcut(keys: "⇧⌘[", what: "Previous tab"),
        Shortcut(keys: "⇧⌘]", what: "Next tab"),
        Shortcut(keys: "⌘S", what: "Hide or show tabs, if the page lets it"),
        Shortcut(keys: "⇧⌘S", what: "Move tabs to side or top"),
        Shortcut(keys: "⇧⌘B", what: "Bookmark this page"),
    ]
}

struct ShortcutLine: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 9) {
            Text(shortcut.keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(minWidth: 60)
            Text(shortcut.what)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
    }
}

struct ShortcutGuide: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Plate("Keyboard Shortcuts", close: { browser.showingShortcuts = false }) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    group("Start here", Shortcuts.first)
                    group("On a page", Shortcuts.pages)
                    group("Tabs and layout", Shortcuts.tabs)
                    Text("Some pages use shortcuts of their own. Their editor gets those keys first.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.faint)
                }
                .padding(.bottom, 2)
            }
            .frame(height: 310)
        }
    }

    private func group(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .textCase(.uppercase)
                .tracking(0.6)
            ForEach(shortcuts) { ShortcutLine(shortcut: $0) }
        }
    }
}

struct ShortcutReminder: View {
    let show: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("A few keys make browsing quicker.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button("See shortcuts", action: show)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.accent)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Dismiss shortcut reminder")
            .accessibilityLabel("Dismiss shortcut reminder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }
}
