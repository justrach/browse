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
    /// True when sitting inside the unified Arc/Dia frosted window canvas
    /// above a floating rounded page card (transparent ground, no bottom seam).
    var framed: Bool = false

    @State private var addressHover = false
    @State private var askHover = false

    private var tint: PageTint? {
        browser.prefs.sideTint ? PageTint(browser.activeHue, over: scheme) : nil
    }

    private var seam: Color {
        if let tint {
            return tint.dark ? Color.white.opacity(0.09) : Color.black.opacity(0.065)
        }
        return scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.065)
    }

    var body: some View {
        let agentOpen = browser.consulting && browser.prefs.usesAgent
        let splitOpen = browser.shownSplit != nil
        let isDark = tint?.dark ?? (scheme == .dark)
        let toggleKey = shortcuts.key(for: .toggleAgent)?.display
        let foldKey = shortcuts.key(for: .toggleFold)?.display
        let passwordsKey = shortcuts.key(for: .passwords)?.display
        let splitKey = shortcuts.key(for: .toggleSplit)?.display

        ZStack(alignment: .leading) {
            // Draggable title-bar surface behind the empty middle of the bar.
            DragStrip(onDoubleClick: browser.newTab)

            HStack(spacing: 6) {
                // When the sidebar is folded, show the Show Sidebar button and
                // available nav controls (Back / Forward / Reload) beside the
                // traffic lights. When open, the sidebar holds them cleanly.
                if !sidebarOpen {
                    Door(
                        icon: "sidebar.left",
                        help: "Show Sidebar" + (foldKey.map { "   \($0)" } ?? "")
                    ) {
                        browser.toggleFold()
                    }
                    .fixedSize()
                    .transition(.opacity)

                    Helm(browser: browser)
                        .fixedSize()
                        .transition(.opacity)
                }

                // Domain | Page Title — shrinks gracefully so right-side controls never clip.
                Group {
                    if let tab = browser.active {
                        AddressSummaryButton(tab: tab, browser: browser, isDark: isDark, hovering: $addressHover)
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
                        icon: "rectangle.split.2x1",
                        on: splitOpen,
                        help: (splitOpen ? "Leave Split View" : "Split View") + (splitKey.map { "   \($0)" } ?? "")
                    ) {
                        browser.toggleSplit()
                    }

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
                                    .foregroundStyle(agentOpen ? Palette.accent : Palette.ink.opacity(0.84))
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
                                        : (isDark
                                            ? Color.white.opacity(askHover ? 0.12 : 0.075)
                                            : Color.white.opacity(askHover ? 0.96 : 0.78)))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        agentOpen
                                            ? Palette.accent.opacity(0.30)
                                            : (isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)),
                                        lineWidth: 0.75
                                    )
                            )
                            .shadow(color: .black.opacity(agentOpen ? 0 : (isDark ? 0.18 : 0.05)), radius: 3, y: 1)
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
            .padding(.leading, sidebarOpen ? (framed ? 0 : 10) : Metrics.lights)
            .padding(.trailing, framed ? Split.gap + 2 : 12)
            .animation(Motion.glide, value: sidebarOpen)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.strip)
        .clipped()
        .background {
            if !framed {
                if let tint {
                    Color(nsColor: tint.color)
                } else {
                    Palette.ground
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !framed {
                Rectangle().fill(seam).frame(height: 1)
            }
        }
        .environment(\.colorScheme, tint.map { $0.dark ? .dark : .light } ?? scheme)
        .animation(Motion.glide, value: tint)
    }
}

private struct AddressSummaryButton: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    let isDark: Bool
    @Binding var hovering: Bool
    @State private var copyHover = false
    @State private var copied = false

    var body: some View {
        let host: String = {
            guard let url = tab.address else { return "" }
            if let h = url.host(), !h.isEmpty {
                return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            }
            return Address.pretty(url)
        }()
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(spacing: 4) {
            Button { browser.edit() } label: {
                HStack(spacing: 7) {
                    if tab.isBlank {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.muted.opacity(0.8))
                        Text("Search or enter website name")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    } else {
                        if tab.loading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                                .frame(width: 13, height: 13)
                        } else {
                            Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                                .opacity(0.92)
                        }
                        Text(host)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !title.isEmpty && title != host {
                            Rectangle()
                                .fill(Palette.ink.opacity(0.16))
                                .frame(width: 1, height: 11)
                            Text(title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, (!tab.isBlank && (hovering || copied)) ? 2 : 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open or edit address   ⌘L")

            if !tab.isBlank && (hovering || copied) {
                Button {
                    browser.copyAddress()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(copied ? Palette.accent : (copyHover ? Palette.ink : Palette.muted))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.ink.opacity(copyHover ? 0.08 : 0))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { copyHover = $0 }
                .padding(.trailing, 3)
                .help("Copy Address   ⇧⌘C")
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(isDark
                    ? Color.white.opacity(hovering ? 0.105 : 0.068)
                    : Color.white.opacity(hovering ? 0.88 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .strokeBorder(
                    isDark
                        ? Color.white.opacity(hovering ? 0.13 : 0.075)
                        : Color.black.opacity(hovering ? 0.095 : 0.055),
                    lineWidth: 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: copied)
        .contextMenu {
            Button("Copy Address") { browser.copyAddress() }
            Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
        }
    }
}
