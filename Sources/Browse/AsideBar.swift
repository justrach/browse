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
    /// True in macOS Full Screen mode (no window traffic lights on the left).
    var fullScreen: Bool = false
    /// True when floating down over the page on top-edge hover in Full Screen.
    var floating: Bool = false

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
        let isDark = fullScreen || (tint?.dark ?? (scheme == .dark))
        let toggleKey = shortcuts.key(for: .toggleAgent)?.display
        let foldKey = shortcuts.key(for: .toggleFold)?.display
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

                // Right-side utility doors + top-right graff pill (always visible, never clipped).
                HStack(spacing: 4) {
                    if !sidebarOpen {
                        UpdateChip(browser: browser)
                        if browser.activeDownloadCount > 0 || !browser.loot.active.isEmpty {
                            AsideDownloadsButton(browser: browser, loot: browser.loot)
                        }
                        AsideBackgroundAudioButton(browser: browser)
                    }
                    let overviewKey = shortcuts.key(for: .tabOverview)?.display
                    Door(
                        icon: "square.grid.2x2",
                        on: browser.tabSwitcher == .grid,
                        help: "Tab Overview" + (overviewKey.map { "   \($0)" } ?? "")
                    ) {
                        browser.toggleTabOverview()
                    }

                    Door(
                        icon: "rectangle.split.2x1",
                        on: splitOpen,
                        help: (splitOpen ? "Leave Split View" : "Split View") + (splitKey.map { "   \($0)" } ?? "")
                    ) {
                        browser.toggleSplit()
                    }

                    ExtensionSlot()

                    if browser.prefs.usesAgent {
                        let keyHint = toggleKey ?? "."
                        Button { browser.toggleAgent() } label: {
                            HStack(spacing: 5.5) {
                                GraffMark(
                                    size: 14,
                                    color: agentOpen ? Palette.accent : Palette.ink.opacity(0.86)
                                )
                                Text("graff")
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(agentOpen ? Palette.accent : Palette.ink)
                                if !agentOpen {
                                    ShortcutBadge(keys: keyHint)
                                }
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, !agentOpen ? 6 : 10)
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
                        .help((agentOpen ? "Hide graff" : "Open graff") + "   \(keyHint)  ·  Press . while reading")
                        .padding(.leading, 4)
                    }
                }
                .fixedSize()
            }
            .padding(.leading, sidebarOpen ? (framed ? 0 : 10) : (fullScreen ? 10 : Metrics.lights))
            .padding(.trailing, framed ? Split.gap + 2 : 12)
            .animation(Motion.glide, value: sidebarOpen)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.strip)
        .clipped()
        .background {
            if floating {
                if fullScreen {
                    Color.black.opacity(0.95)
                } else {
                    ZStack {
                        SideGlass(dark: tint?.dark)
                        if let tint {
                            tint.wash
                        } else {
                            Palette.ground.opacity(scheme == .dark ? 0.86 : 0.90)
                        }
                    }
                }
            } else if !framed {
                if let tint {
                    Color(nsColor: tint.color)
                } else {
                    Palette.ground
                }
            }
        }
        .overlay(alignment: .bottom) {
            if floating || !framed {
                Rectangle().fill(fullScreen ? Color.white.opacity(0.10) : seam).frame(height: 1)
            }
        }
        .shadow(
            color: floating ? .black.opacity(isDark ? 0.42 : 0.14) : .clear,
            radius: floating ? 18 : 0,
            y: floating ? 4 : 0
        )
        .environment(\.colorScheme, fullScreen ? .dark : (tint.map { $0.dark ? .dark : .light } ?? scheme))
        .animation(Motion.glide, value: tint)
    }
}

private struct AddressSummaryButton: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    let isDark: Bool
    @Binding var hovering: Bool
    @ObservedObject private var shield = Shield.shared
    @State private var copyHover = false
    @State private var copied = false
    @State private var siteHover = false
    @State private var siteCardOpen = false
    @State private var zoomHover = false
    @State private var readerHover = false
    @State private var readerMenuOpen = false
    @State private var audioHover = false

    var body: some View {
        let host: String = {
            guard let url = tab.address else { return "" }
            if let h = url.host(), !h.isEmpty {
                return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            }
            return Address.pretty(url)
        }()
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shieldPaused = !tab.isBlank && !host.isEmpty && browser.prefs.shielded && shield.isPaused(on: host)
        let zoomed = !tab.isBlank && abs(tab.zoom - browser.prefs.pageZoom) > 0.005
        let showCopy = !tab.isBlank && (hovering || copied)
        let hasTrailingChip = !tab.isBlank

        HStack(spacing: 2) {
            if !tab.isBlank {
                Button { siteCardOpen.toggle() } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if tab.loading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                                .frame(width: 14, height: 14)
                        } else {
                            Mark(icon: tab.icon, letter: tab.monogram, size: 13.5)
                                .opacity(0.94)
                        }
                        if shieldPaused {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 5.5, height: 5.5)
                                .offset(x: 2, y: 2)
                        }
                    }
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.ink.opacity(siteHover || siteCardOpen ? 0.08 : 0))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { siteHover = $0 }
                .padding(.leading, 4)
                .help(shieldPaused ? "Site info (ad blocker paused on \(host))" : "Site information & shield")
                .popover(isPresented: $siteCardOpen, arrowEdge: .bottom) {
                    SiteCard(browser: browser, tab: tab) { siteCardOpen = false }
                }
            }

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
                .padding(.leading, tab.isBlank ? 10 : 3)
                .padding(.trailing, hasTrailingChip ? 2 : 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open or edit address   ⌘L")

            if !tab.isBlank && (tab.noisy || tab.muted) {
                Button { tab.toggleMute() } label: {
                    Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tab.muted ? Palette.muted : Palette.ink.opacity(0.86))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.ink.opacity(audioHover ? 0.08 : 0))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { audioHover = $0 }
                .padding(.trailing, 1)
                .help(tab.muted ? "Unmute Tab" : "Mute Tab")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if tab.reader {
                Button { readerMenuOpen.toggle() } label: {
                    Image(systemName: "doc.plaintext.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.accent.opacity(readerHover || readerMenuOpen ? 0.18 : 0.12))
                        )
                }
                .buttonStyle(.plain)
                .onHover { readerHover = $0 }
                .padding(.trailing, 1)
                .help("Reading Mode appearance   ⇧⌘R to exit")
                .popover(isPresented: $readerMenuOpen, arrowEdge: .bottom) {
                    ReaderPopover(browser: browser, prefs: browser.prefs) {
                        readerMenuOpen = false
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if zoomed {
                Button { browser.resetZoom() } label: {
                    Text("\(Int((tab.zoom * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(zoomHover ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(
                            Capsule().fill(Palette.ink.opacity(zoomHover ? 0.11 : 0.065))
                        )
                }
                .buttonStyle(.plain)
                .onHover { zoomHover = $0 }
                .padding(.trailing, 1)
                .help("Reset zoom to default   ⌘0")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if !tab.isBlank {
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
                .opacity(showCopy ? 1 : 0)
                .allowsHitTesting(showCopy)
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
        .animation(Motion.quick, value: zoomed)
        .animation(Motion.quick, value: zoomHover)
        .animation(Motion.quick, value: tab.reader)
        .animation(Motion.quick, value: tab.noisy)
        .animation(Motion.quick, value: tab.muted)
        .contextMenu {
            Button("Site Information…") { siteCardOpen = true }
                .disabled(tab.isBlank)
            Button("Reload") { browser.reload() }
                .disabled(tab.isBlank)
            Divider()
            Button("Copy Address") { browser.copyAddress() }
                .disabled(tab.isBlank)
            Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
                .disabled(tab.isBlank)
            Button("Paste and Go") { browser.pasteAndGo() }
        }
    }
}

/// Compact Reading Mode typography & surface popover anchored to the reader badge.
private struct ReaderPopover: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                HStack(spacing: 8) {
                    ForEach(Preferences.ReaderTheme.allCases) { theme in
                        let selected = prefs.readerTheme == theme
                        Button {
                            prefs.readerTheme = theme
                            browser.applyReaderStyle()
                        } label: {
                            VStack(spacing: 4) {
                                swatch(for: theme, selected: selected)
                                Text(theme.title)
                                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Font")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                HStack(spacing: 4) {
                    ForEach(Preferences.ReaderFont.allCases) { font in
                        let selected = prefs.readerFont == font
                        Button {
                            prefs.readerFont = font
                            browser.applyReaderStyle()
                        } label: {
                            Text(font.title)
                                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Palette.ink : Palette.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selected ? Palette.wash : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(selected ? Palette.hairline : Color.clear, lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 8) {
                Text("Text size")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        prefs.readerSize = max(14, prefs.readerSize - 1)
                        browser.applyReaderStyle()
                    } label: {
                        Text("A−")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: 24)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(prefs.readerSize <= 14)

                    Text("\(prefs.readerSize)")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .frame(width: 24)

                    Button {
                        prefs.readerSize = min(26, prefs.readerSize + 1)
                        browser.applyReaderStyle()
                    } label: {
                        Text("A+")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 24)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(prefs.readerSize >= 26)
                }
            }

            Divider().overlay(Palette.hairline)

            Button {
                close()
                browser.toggleReader()
            } label: {
                HStack {
                    Text("Exit Reading Mode")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⇧⌘R")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 232)
        .background(Palette.ground)
    }

    @ViewBuilder
    private func swatch(for theme: Preferences.ReaderTheme, selected: Bool) -> some View {
        let size: CGFloat = 24
        Group {
            switch theme {
            case .auto:
                ZStack {
                    Circle().fill(Color.white)
                    Circle().fill(Color(white: 0.12)).mask(
                        Rectangle().frame(width: size / 2, height: size).offset(x: size / 4)
                    )
                }
            case .light:
                Circle().fill(Color.white)
            case .sepia:
                Circle().fill(Color(red: 0.97, green: 0.94, blue: 0.88))
            case .dark:
                Circle().fill(Color(white: 0.11))
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(selected ? Palette.accent : Palette.hairline, lineWidth: selected ? 2 : 0.75)
        )
    }
}

/// Active download progress button shown in AsideBar only while a download runs and the sidebar is folded.
private struct AsideDownloadsButton: View {
    @ObservedObject var browser: Browser
    @ObservedObject var loot: Loot
    @State private var hovering = false

    var body: some View {
        let fraction = loot.overallProgress
        Button { browser.hoarding = true } label: {
            ZStack {
                if let fraction {
                    Circle()
                        .stroke(Palette.ink.opacity(0.14), lineWidth: 2)
                        .frame(width: 20, height: 20)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.05, fraction)))
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .animation(.easeOut(duration: 0.2), value: fraction)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: fraction == nil ? 11.5 : 9.5, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(0.88))
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .overlay(alignment: .topTrailing) {
                if fraction == nil && !loot.active.isEmpty {
                    PulseDot(color: Palette.accent, size: 4.5, active: true)
                        .offset(x: -1, y: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Downloading (\(max(browser.activeDownloadCount, loot.active.count)))   ⇧⌘J")
        .animation(Motion.quick, value: hovering)
    }
}

/// Folded-sidebar indicator for background tabs actively playing audio.
private struct AsideBackgroundAudioButton: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    var body: some View {
        let noisy = browser.tabs.filter { $0.id != browser.activeID && $0.noisy && !$0.muted }
        if !noisy.isEmpty {
            Button { browser.select(noisy[0]) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10.5, weight: .medium))
                    if noisy.count > 1 {
                        Text("\(noisy.count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, noisy.count > 1 ? 6 : 0)
                .frame(minWidth: 28, minHeight: 28, maxHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(Palette.accent.opacity(hovering ? 0.16 : 0.10))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Jump to audio tab: \(noisy[0].label) (right-click for options)")
            .contextMenu {
                ForEach(noisy) { tab in
                    Button("Go to “\(tab.label)”") { browser.select(tab) }
                    Button("Mute “\(tab.label)”") { tab.toggleMute() }
                    Divider()
                }
                Button("Mute All Background Audio") {
                    for tab in noisy { tab.toggleMute() }
                }
            }
            .animation(Motion.quick, value: hovering)
        }
    }
}
