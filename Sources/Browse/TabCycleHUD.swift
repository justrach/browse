import AppKit
import SwiftUI

/// Visual `⌃Tab` / `⌃⇧Tab` most-recently-used tab switcher with live cached
/// page previews (holding Control cycles cards; releasing Control jumps).
struct TabCycleHUD: View {
    let tabs: [Tab]
    let selectedID: Tab.ID?
    let onSelect: (Tab) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let maxVisible = 7
        let selectedIndex = tabs.firstIndex { $0.id == selectedID } ?? 0
        let start = max(0, min(selectedIndex - maxVisible / 2, tabs.count - maxVisible))
        let end = min(tabs.count, start + maxVisible)
        let shown = Array(tabs[start..<end])
        let hiddenBefore = start
        let hiddenAfter = tabs.count - end
        let chosen = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : tabs.first

        let backgroundFill: Color = dark ? Color(white: 0.11).opacity(0.95) : Color.white.opacity(0.96)
        let borderColor: Color = dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)

        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if hiddenBefore > 0 {
                    overflowBadge("‹ \(hiddenBefore)")
                }
                ForEach(shown) { tab in
                    card(for: tab, active: tab.id == chosen?.id, dark: dark)
                }
                if hiddenAfter > 0 {
                    overflowBadge("\(hiddenAfter) ›")
                }
            }

            if let chosen {
                footer(for: chosen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(dark ? 0.50 : 0.18), radius: 28, y: 12)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func overflowBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 4)
    }

    private func card(for tab: Tab, active: Bool, dark: Bool) -> some View {
        let cardFill: Color = active ? Palette.accent.opacity(dark ? 0.16 : 0.10) : .clear

        return Button { onSelect(tab) } label: {
            VStack(alignment: .leading, spacing: 6) {
                TabCycleThumbnail(
                    tab: tab,
                    slot: TabPreviewCache.shared.slot(for: tab),
                    active: active,
                    dark: dark
                )
                titleRow(for: tab, active: active)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(cardFill)
            )
        }
        .buttonStyle(.plain)
    }

    private func titleRow(for tab: Tab, active: Bool) -> some View {
        HStack(spacing: 5) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 12, dim: tab.asleep)
            Text(tab.label)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Palette.ink : Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 132, alignment: .leading)
    }

    private func footer(for chosen: Tab) -> some View {
        HStack(spacing: 6) {
            Mark(icon: chosen.icon, letter: chosen.monogram, size: 13, dim: chosen.asleep)
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
            if chosen.asleep {
                Text("· Asleep")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted.opacity(0.8))
            }
        }
        .padding(.top, 2)
    }
}

private struct TabCycleThumbnail: View {
    @ObservedObject var tab: Tab
    @ObservedObject var slot: TabPreviewCache.Slot
    let active: Bool
    let dark: Bool

    var body: some View {
        let placeholderFill: Color = dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        let idleBorder: Color = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
        let strokeColor: Color = active ? Palette.accent : idleBorder
        let _ = slot.revision
        let preview = TabPreviewCache.shared.displayImage(for: tab, slot: slot)

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(placeholderFill)
            if let pic = preview {
                Image(nsImage: pic)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderContent(for: tab)
            }
        }
        .frame(width: 132, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if tab.asleep {
                sleepBadge(dark: dark)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: active ? 2 : 0.75)
        )
    }

    private func placeholderContent(for tab: Tab) -> some View {
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

    private func sleepBadge(dark: Bool) -> some View {
        let fg: Color = dark ? Color.white.opacity(0.85) : Palette.ink.opacity(0.75)
        let bg: Color = dark ? Color.black.opacity(0.55) : Color.white.opacity(0.85)

        return Image(systemName: "moon.zzz")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(fg)
            .padding(4)
            .background(Circle().fill(bg))
            .padding(5)
    }
}
