import SwiftUI

/// Global popover listing every tab currently playing or muted across all Spaces
/// with one-click play/pause, mute/unmute, and jump-to-tab controls.
struct MediaPopover: View {
    @ObservedObject var browser: Browser
    let close: () -> Void

    var body: some View {
        let entries = browser.mediaEntries()
        let unmutedCount = entries.filter { !$0.tab.muted && $0.tab.noisy }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Playing & Muted Tabs")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if unmutedCount > 1 {
                    Button("Mute All") {
                        for entry in entries where !entry.tab.muted && entry.tab.noisy {
                            entry.tab.toggleMute()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if entries.isEmpty {
                Text("No tabs are playing audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                Divider().opacity(0.4)
                VStack(spacing: 2) {
                    ForEach(entries) { entry in
                        MediaRow(browser: browser, entry: entry, close: close)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
        }
        .frame(width: 288)
        .background(Palette.ground)
    }

    private struct MediaRow: View {
        @ObservedObject var browser: Browser
        let entry: Browser.MediaEntry
        @ObservedObject private var tab: Tab
        let close: () -> Void
        @State private var hovering = false

        init(browser: Browser, entry: Browser.MediaEntry, close: @escaping () -> Void) {
            self.browser = browser
            self.entry = entry
            self._tab = ObservedObject(wrappedValue: entry.tab)
            self.close = close
        }

        var body: some View {
            HStack(spacing: 8) {
                Button {
                    browser.jumpToMedia(entry)
                    close()
                } label: {
                    HStack(spacing: 8) {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.label)
                                .font(.system(size: 12.5, weight: tab.id == browser.activeID ? .semibold : .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let space = entry.space {
                                Text(space.name)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    tab.toggleMediaPlayback()
                } label: {
                    Image(systemName: tab.noisy ? "pause.fill" : "play.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.ink.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(tab.noisy ? "Pause or play media" : "Play media")

                Button {
                    tab.toggleMute()
                } label: {
                    Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tab.muted ? Palette.muted : Palette.accent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.ink.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(tab.muted ? "Unmute Tab" : "Mute Tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
