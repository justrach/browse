import AppKit
import SwiftUI

/// Visual `⌃Tab` / `⌃⇧Tab` most-recently-used tab switcher with live cached
/// page previews (holding Control cycles cards; releasing Control jumps).
struct TabCycleHUD: View {
    let tabs: [Tab]
    let selectedID: Tab.ID?
    let onSelect: (Tab) -> Void

    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var previews = TabPreviewCache.shared

    var body: some View {
        let dark = scheme == .dark
        let _ = previews.revision
        let shown = Array(tabs.prefix(7))
        let chosen = shown.first { $0.id == selectedID } ?? shown.first

        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(shown) { tab in
                    let active = tab.id == chosen?.id
                    let preview = previews.image(for: tab)
                    Button { onSelect(tab) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                                if let pic = preview {
                                    Image(nsImage: pic)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    VStack(spacing: 6) {
                                        Mark(icon: tab.icon, letter: tab.monogram, size: 22)
                                        if let host = tab.address?.host()?.replacingOccurrences(of: "www.", with: "") {
                                            Text(host)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(Palette.muted)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(8)
                                }
                            }
                            .frame(width: 132, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        active ? Palette.accent : (dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)),
                                        lineWidth: active ? 2 : 0.75
                                    )
                            )

                            HStack(spacing: 5) {
                                Mark(icon: tab.icon, letter: tab.monogram, size: 12)
                                Text(tab.label)
                                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                                    .foregroundStyle(active ? Palette.ink : Palette.muted)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(active ? Palette.accent.opacity(dark ? 0.16 : 0.10) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let chosen {
                HStack(spacing: 6) {
                    Mark(icon: chosen.icon, letter: chosen.monogram, size: 13)
                    Text(chosen.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let host = chosen.address?.host()?.replacingOccurrences(of: "www.", with: "") {
                        Text("· \(host)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(dark ? Color(white: 0.11).opacity(0.95) : Color.white.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(dark ? 0.50 : 0.18), radius: 28, y: 12)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
