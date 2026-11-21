import SwiftUI

/// Compact single-row top bar inspired by Aside, shown when tabs are in the
/// sidebar or folded away (`⌘S`):
///
///   [Sidebar ⌘S]  [< > ↻]  mail.google.com | Inbox — Gmail         [🔑] [🧩]  [✦ Ask ⌘;]
///
/// Adapts to the active page's tint just like SideBar so the chrome reads as
/// one unified surface. Clicking the domain/title opens the address bar (`⌘L`),
/// dragging empty space moves the window, and the top-right `Ask` pill stays
/// pinned right above where the Agent Sidebar slides out.
struct AsideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @Environment(\.colorScheme) private var scheme
    /// True when the left tab sidebar is visible beside this bar.
    let sidebarOpen: Bool

    @State private var addressHover = false
    @State private var askHover = false

    private var tint: PageTint? {
        browser.prefs.sideTint ? PageTint(browser.activeHue, over: scheme) : nil
    }

    private var seam: Color {
        tint.map { $0.dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) } ?? Palette.hairline
    }

    var body: some View {
        let agentOpen = browser.consulting && browser.prefs.usesAgent
        let toggleKey = shortcuts.key(for: .toggleAgent)?.display
        let foldKey = shortcuts.key(for: .toggleFold)?.display
        let passwordsKey = shortcuts.key(for: .passwords)?.display

        ZStack(alignment: .leading) {
            // Draggable title-bar surface behind the empty middle of the bar.
            DragStrip(onDoubleClick: browser.newTab)

            HStack(spacing: 6) {
                // Toggle left tab sidebar (⌘S).
                Door(
                    icon: "sidebar.left",
                    help: (sidebarOpen ? "Hide Sidebar" : "Show Sidebar")
                        + (foldKey.map { "   \($0)" } ?? "")
                ) {
                    browser.toggleFold()
                }
                .fixedSize()

                // When the sidebar is folded, show Back / Forward / Reload here.
                if !sidebarOpen {
                    Helm(browser: browser)
                        .fixedSize()
                        .transition(.opacity)
                }

                // Domain | Page Title — shrinks gracefully so right-side controls never clip.
                Group {
                    if let tab = browser.active {
                        AddressSummaryButton(tab: tab, browser: browser, hovering: $addressHover)
                    } else {
                        Button { browser.edit() } label: {
                            Text("Search or enter website name")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)

                // Right-side utility doors + top-right Ask pill (always visible, never clipped).
                HStack(spacing: 4) {
                    Door(
                        icon: "key",
                        help: "Passwords" + (passwordsKey.map { "   \($0)" } ?? "")
                    ) {
                        browser.managing = true
                    }

                    ExtensionSlot()

                    if browser.prefs.usesAgent {
                        Button { browser.toggleAgent() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(agentOpen ? Palette.accent : Palette.ink.opacity(0.82))
                                Text("Ask")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(agentOpen ? Palette.accent : Palette.ink)
                                if !agentOpen, let toggleKey {
                                    ShortcutBadge(keys: toggleKey)
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, (!agentOpen && toggleKey != nil) ? 6 : 10)
                            .frame(height: 28)
                            .background(
                                Capsule()
                                    .fill(agentOpen
                                        ? Palette.accent.opacity(askHover ? 0.16 : 0.11)
                                        : (askHover ? Palette.hover : Palette.ink.opacity(0.055)))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        agentOpen ? Palette.accent.opacity(0.28) : Palette.ink.opacity(0.11),
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
                .fixedSize()
            }
            .padding(.leading, sidebarOpen ? 12 : Metrics.lights)
            .padding(.trailing, 12)
            .animation(Motion.glide, value: sidebarOpen)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.strip)
        .clipped()
        .background {
            if let tint {
                Color(nsColor: tint.color)
            } else {
                Palette.ground
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(seam).frame(height: 1)
        }
        .environment(\.colorScheme, tint.map { $0.dark ? .dark : .light } ?? scheme)
        .animation(Motion.glide, value: tint)
    }
}

private struct AddressSummaryButton: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    @Binding var hovering: Bool

    var body: some View {
        let host: String = {
            guard let url = tab.address else { return "" }
            if let h = url.host(), !h.isEmpty {
                return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            }
            return Address.pretty(url)
        }()
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
                        .truncationMode(.tail)
                    if !title.isEmpty && title != host {
                        Rectangle()
                            .fill(Palette.ink.opacity(0.16))
                            .frame(width: 1, height: 12)
                        Text(title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.ink.opacity(0.06) : .clear)
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
