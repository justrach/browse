import SwiftUI

// A peek at a link, Arc's way: shift-click it and its page opens in a panel
// over the one you are reading, which stays where it was underneath. Escape,
// a click beside the panel or its cross puts it away; its other button keeps
// it, as a tab beside this one, loaded as it is.
//
// Off unless asked for, in Settings › General: shift-click means other
// things to some pages, and nobody who doesn't want this should meet it.
//
// The page is a tab of its own, only not in the row: keeping it is moving
// it there, with nothing loaded twice.

extension Browser {
    /// Shift-click on a link, from a tab in the row.
    func peek(_ url: URL, from tab: Tab) {
        let page = Tab(shy: tab.shy)
        prepare(page)
        page.go(to: url)
        withAnimation(Motion.settle) { peekTab = page }
    }

    /// Put away: the page goes with the panel.
    func closePeek() {
        guard let page = peekTab else { return }
        withAnimation(Motion.quick) { peekTab = nil }
        page.close()
    }

    /// Kept: a tab beside the one it was opened from, and in front.
    func keepPeek() {
        guard let page = peekTab else { return }
        let place = placeForNew()
        withAnimation(Motion.quick) { peekTab = nil }
        insert(page, at: place)
        select(page)
    }

    /// Promoted straight into Split View beside the active page.
    func splitPeek() {
        guard let page = peekTab else { return }
        let place = placeForNew()
        withAnimation(Motion.quick) { peekTab = nil }
        insert(page, at: place)
        open(page, on: .right)
    }
}

/// The peek over the page: the page dimmed around it, and the panel.
struct PeekLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            // The dimming only fades. Grown and shrunk with the panel, its
            // edges travelled across the window as it came (Drice, 24 Sep 2026).
            if browser.peekTab != nil {
                Color.black.opacity(0.24)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.closePeek() }
                    .transition(.opacity)
            }
            if let tab = browser.peekTab {
                PeekPanel(browser: browser, tab: tab)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

/// The Little-Arc-style peek panel with a slim glass header bar (Back/Forward,
/// Reload, favicon + domain/title, Copy Link, Open in Split, Expand to Tab, Close).
struct PeekPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let host = tab.address.map { Address.pretty($0) } ?? ""

        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    // Slim Little-Arc header bar.
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            BarIcon("chevron.left", help: "Back", disabled: !tab.canGoBack) { tab.back() }
                            BarIcon("chevron.right", help: "Forward", disabled: !tab.canGoForward) { tab.forward() }
                            BarIcon(tab.loading ? "xmark" : "arrow.clockwise", help: tab.loading ? "Stop" : "Reload") {
                                if tab.loading { tab.stop() } else { tab.reload() }
                            }
                        }

                        Spacer(minLength: 8)

                        // Centered site identity — click to copy URL.
                        Button {
                            guard let url = tab.address else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
                        } label: {
                            HStack(spacing: 6) {
                                if tab.loading {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.65)
                                        .frame(width: 13, height: 13)
                                } else {
                                    Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                                }
                                Text(tab.title.isEmpty ? host : tab.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if !host.isEmpty && !tab.title.isEmpty && tab.title != host {
                                    Text(host)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy URL")

                        Spacer(minLength: 8)

                        HStack(spacing: 2) {
                            BarIcon(copied ? "checkmark" : "link", accent: copied, help: "Copy Link") {
                                guard let url = tab.address else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
                            }
                            BarIcon("rectangle.split.2x1", help: "Open in Split View") { browser.splitPeek() }
                            BarIcon("arrow.up.left.and.arrow.down.right", help: "Open as a Tab") { browser.keepPeek() }
                            BarIcon("xmark", help: "Close (esc)") { browser.closePeek() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(Palette.ground)

                    Rectangle()
                        .fill(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.065))
                        .frame(height: 1)

                    Page(tab: tab)
                }
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: .black.opacity(dark ? 0.45 : 0.22), radius: 32, y: 12)
                .frame(width: geo.size.width * 0.84, height: geo.size.height * 0.88)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(Motion.quick, value: copied)
    }

    private struct BarIcon: View {
        let symbol: String
        var accent = false
        let help: String
        var disabled = false
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, accent: Bool = false, help: String, disabled: Bool = false, act: @escaping () -> Void) {
            self.symbol = symbol
            self.accent = accent
            self.help = help
            self.disabled = disabled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent ? Palette.accent : (hovering ? Palette.ink : Palette.muted))
                    .opacity(disabled ? 0.35 : 1)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(hovering && !disabled ? Palette.hover : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(help)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
