import SwiftUI

/// Compact single-row top bar inspired by Aside, shown when tabs are in the
/// sidebar or folded away (`⌘S`):
///
///   [Sidebar ⌘S]  [< > ↻]  mail.google.com | Inbox — Gmail         [🔑] [🧩]  [✦ Ask ⌘;]
///
/// Clicking the domain/title opens the address bar (`⌘L`), dragging empty space
/// moves the window, and the top-right `Ask` pill stays pinned right above
/// where the Agent Sidebar slides out — even when tabs are folded.
struct AsideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// True when the left tab sidebar is visible beside this bar.
    let sidebarOpen: Bool

    @State private var addressHover = false
    @State private var askHover = false

    var body: some View {
        let agentOpen = browser.consulting && browser.prefs.usesAgent
        let toggleKey = shortcuts.key(for: .toggleAgent)?.display
        let foldKey = shortcuts.key(for: .toggleFold)?.display
        let passwordsKey = shortcuts.key(for: .passwords)?.display

        ZStack(alignment: .leading) {
            // Draggable title-bar surface behind the empty middle of the bar.
            DragStrip(onDoubleClick: browser.newTab)

            HStack(spacing: 6) {
                if !sidebarOpen {
                    Color.clear.frame(width: Metrics.lights - 12)
                }

                // Toggle left tab sidebar (⌘S).
                Door(
                    icon: "sidebar.left",
                    help: (sidebarOpen ? "Hide Sidebar" : "Show Sidebar")
                        + (foldKey.map { "   \($0)" } ?? "")
                ) {
                    browser.toggleFold()
                }

                // When the sidebar is folded, show Back / Forward / Reload here
                // so navigation stays one click away.
                if !sidebarOpen {
                    Helm(browser: browser)
                }

                // Domain | Page Title — click anywhere to edit address (⌘L).
                if let tab = browser.active {
                    AddressSummaryButton(tab: tab, browser: browser, hovering: $addressHover)
                } else {
                    Button { browser.edit() } label: {
                        Text("Search or enter website name")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                // Right-side utility doors + top-right Ask pill.
                HStack(spacing: 4) {
                    Door(
                        icon: "key",
                        help: "Passwords" + (passwordsKey.map { "   \($0)" } ?? "")
                    ) {
                        browser.managing = true
                    }

                    ExtensionSlot()

                    Door(icon: "puzzlepiece.extension", help: "Extensions") {
                        Store.settings.set(SettingsPanel.Page.extensions.rawValue, forKey: "settings.page")
                        browser.tuning = true
                    }

                    if browser.prefs.usesAgent {
                        Button { browser.toggleAgent() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(agentOpen ? Palette.accent : Palette.ink.opacity(0.8))
                                Text("Ask")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                if let toggleKey {
                                    ShortcutBadge(keys: toggleKey, active: agentOpen)
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, toggleKey == nil ? 10 : 6)
                            .frame(height: 28)
                            .background(
                                Capsule()
                                    .fill(agentOpen ? Palette.wash : (askHover ? Palette.hover : Palette.ink.opacity(0.055)))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        agentOpen ? Palette.accent.opacity(0.35) : Palette.hairline,
                                        lineWidth: 0.75
                                    )
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(TactilePress())
                        .onHover { askHover = $0 }
                        .help((agentOpen ? "Hide Agent Sidebar" : "Ask Codegraff") + (toggleKey.map { "   \($0)" } ?? ""))
                        .padding(.leading, 4)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
        }
        .frame(height: Metrics.strip)
        .background(Palette.ground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}

private struct AddressSummaryButton: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    @Binding var hovering: Bool

    var body: some View {
        let host = tab.address.map(Address.pretty) ?? ""
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)

        Button { browser.edit() } label: {
            HStack(spacing: 8) {
                if tab.isBlank {
                    Text("Search or enter website name")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                } else {
                    if tab.loading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                    }
                    Text(host)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !title.isEmpty && title != host {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(width: 1, height: 12)
                        Text(title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Open or edit address   ⌘L")
        .contextMenu {
            Button("Copy Address") { browser.copyAddress() }
            Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
        }
    }
}
