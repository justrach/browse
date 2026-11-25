import SwiftUI

/// What you have taken off this site, per-site CSS Boosts / Force Dark Mode,
/// and the way back.
///
/// A list of selectors is not something anyone can read. So resting the pointer
/// on a row puts that one thing back on the page, outlined, and scrolls to it —
/// you decide what to restore by looking at it, not by decoding its name.
struct HiddenPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var curtain: Curtain

    @State private var showCSS = false
    @State private var draftCSS = ""

    init(browser: Browser) {
        self.browser = browser
        self.curtain = browser.curtain
    }

    var body: some View {
        let host = browser.hereHost
        let darkOn = browser.hereDarkMode
        let hasBoost = browser.hereHasBoost

        Plate(host ?? "This page", width: 380, close: { browser.reviewing = false }) {
            VStack(alignment: .leading, spacing: 12) {
                if let host {
                    VStack(alignment: .leading, spacing: 6) {
                        Caption("Site Boost")
                        Card {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Force dark mode")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.ink)
                                    Text("Invert light pages on \(host)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Switch(on: Binding(
                                    get: { darkOn },
                                    set: { _ in browser.toggleSiteDarkMode() }
                                ))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            Rule()

                            Button {
                                withAnimation(Motion.quick) { showCSS.toggle() }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Custom CSS")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Palette.ink)
                                        Text(browser.hereCustomCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                             ? "Style overrides for \(host)"
                                             : "Active on \(host)")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Palette.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: showCSS ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Palette.muted)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showCSS {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .topLeading) {
                                        if draftCSS.isEmpty {
                                            Text("/* CSS for \(host) */")
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundStyle(Palette.muted.opacity(0.6))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 8)
                                        }
                                        TextEditor(text: $draftCSS)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .scrollContentBackground(.hidden)
                                            .foregroundStyle(Palette.ink)
                                            .frame(height: 86)
                                            .padding(4)
                                    }
                                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Palette.hairline, lineWidth: 0.75)
                                    )

                                    HStack(spacing: 6) {
                                        Pill("Apply", filled: true) {
                                            browser.setSiteCustomCSS(draftCSS)
                                        }
                                        if !draftCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasBoost {
                                            Pill("Reset boost") {
                                                draftCSS = ""
                                                browser.clearSiteBoost()
                                            }
                                        }
                                        Spacer()
                                        if browser.prefs.usesAgent {
                                            Pill("Draft with Codegraff") {
                                                browser.restyleSiteWithAgent()
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.bottom, 10)
                            }
                        }
                    }
                }

                if browser.hereVeils.isEmpty {
                    Card { Nothing("Nothing is hidden here.") }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Caption("Hidden on this site — rest on a line to see it")
                        ScrollView(showsIndicators: false) {
                            Card {
                                ForEach(Array(browser.hereVeils.enumerated()), id: \.element.id) { index, veil in
                                    if index > 0 { Rule() }
                                    Row(
                                        veil: veil,
                                        peek: { browser.peek(veil) },
                                        restore: { browser.restore(veil) }
                                    )
                                }
                            }
                            .padding(.bottom, 2)
                        }
                        .frame(maxHeight: 240)
                    }
                }
            }
        } foot: {
            HStack(spacing: 8) {
                Pill("Hide something…", filled: true) { browser.toggleHiding() }
                Pill(browser.tidying ? "Tidying…" : "Tidy") { browser.tidy() }
                if !browser.hereVeils.isEmpty {
                    Pill("Restore all") { browser.restoreAll() }
                }
                Spacer()
            }
        }
        .onAppear {
            draftCSS = browser.hereCustomCSS
            if !draftCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showCSS = true
            }
        }
        .onChange(of: browser.hereHost) { _, _ in
            draftCSS = browser.hereCustomCSS
        }
        // Leaving the panel puts the page back the way it was.
        .onHover { inside in
            if !inside { browser.stopPeeking() }
        }
    }

    private struct Row: View {
        let veil: Veil
        let peek: () -> Void
        let restore: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(veil.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note = veil.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                Quick("Restore", act: restore)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { peek() }
            }
            .animation(Motion.quick, value: hovering)
        }
    }
}
