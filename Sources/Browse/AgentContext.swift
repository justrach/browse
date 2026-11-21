import SwiftUI

struct AgentPageContext: View {
    @ObservedObject var tab: Tab
    @ObservedObject var agent: Agent
    /// True when docked directly into the top of the composer card as a single
    /// slim header strip, avoiding stacked double borders.
    var embedded = false

    @State private var hoverPin = false
    @State private var hoverToggle = false

    private var pinned: Bool { agent.pinned === tab }
    private var included: Bool { pinned || agent.withPage }
    private var title: String { tab.title.isEmpty ? (tab.address?.host() ?? "This page") : tab.title }
    private var host: String { tab.address?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Local page" }

    var body: some View {
        if embedded {
            embeddedStrip
        } else {
            standaloneCard
        }
    }

    private var embeddedStrip: some View {
        HStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 14)
                    .opacity(included ? 1 : 0.4)
                if pinned {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 15, height: 15)

            HStack(spacing: 5) {
                Text(included ? title : "Page excluded")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(included ? Palette.ink.opacity(0.88) : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if pinned {
                    Text("Pinned")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .fixedSize()
                } else if included {
                    Text("·")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted.opacity(0.5))
                    Text(host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if included {
                    actionButton(
                        icon: pinned ? "pin.fill" : "pin",
                        active: pinned,
                        hover: $hoverPin,
                        help: pinned ? "Unpin: follow the page in front" : "Pin this page to the conversation",
                        label: pinned ? "Unpin page context" : "Pin page context"
                    ) {
                        withAnimation(Motion.snappy) {
                            agent.pin(pinned ? nil : tab)
                            if !pinned { agent.withPage = true }
                        }
                    }
                }
                actionButton(
                    icon: included ? "xmark" : "plus",
                    active: false,
                    hover: $hoverToggle,
                    help: included ? "Exclude the page from your next message" : "Include this page with your next message",
                    label: included ? "Exclude page context" : "Include page context"
                ) {
                    withAnimation(Motion.snappy) {
                        if pinned { agent.pin(nil) }
                        agent.withPage = !included
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 33)
        .background(Palette.ink.opacity(included ? 0.025 : 0.01))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 0.75)
        }
        .animation(Motion.snappy, value: included)
        .animation(Motion.snappy, value: pinned)
        .help(title + "\n" + (tab.address?.absoluteString ?? ""))
    }

    private func actionButton(
        icon: String,
        active: Bool,
        hover: Binding<Bool>,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? Palette.accent : (hover.wrappedValue ? Palette.ink : Palette.muted))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.wrappedValue ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(TactilePress())
        .onHover { hover.wrappedValue = $0 }
        .help(help)
        .accessibilityLabel(label)
    }

    private var standaloneCard: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 16)
                    .opacity(included ? 1 : 0.45)
                if pinned {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(included ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(pinned ? "Pinned" : included ? "Included" : "Excluded")
                        .foregroundStyle(pinned ? Palette.accent : Palette.muted)
                    Text("·")
                        .foregroundStyle(Palette.muted.opacity(0.6))
                    Text(host)
                        .foregroundStyle(Palette.muted)
                }
                .font(.system(size: 10.5))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button {
                    withAnimation(Motion.snappy) {
                        agent.pin(pinned ? nil : tab)
                        if !pinned { agent.withPage = true }
                    }
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(pinned ? Palette.accent : (hoverPin ? Palette.ink : Palette.muted))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(hoverPin ? Palette.hover : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(TactilePress())
                .onHover { hoverPin = $0 }
                .help(pinned ? "Unpin: follow the page in front" : "Pin this page to the conversation")
                .accessibilityLabel(pinned ? "Unpin page context" : "Pin page context")

                Button {
                    withAnimation(Motion.snappy) {
                        if pinned { agent.pin(nil) }
                        agent.withPage = !included
                    }
                } label: {
                    Image(systemName: included ? "xmark" : "plus")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(hoverToggle ? Palette.ink : Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(hoverToggle ? Palette.hover : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(TactilePress())
                .onHover { hoverToggle = $0 }
                .help(included ? "Exclude the page from your next message" : "Include this page with your next message")
                .accessibilityLabel(included ? "Exclude page context" : "Include page context")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.ink.opacity(included ? 0.035 : 0.018))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(pinned ? Palette.accent.opacity(0.32) : Palette.hairline.opacity(included ? 0.9 : 0.5), lineWidth: 1)
        )
        .animation(Motion.snappy, value: included)
        .animation(Motion.snappy, value: pinned)
        .help(title + "\n" + (tab.address?.absoluteString ?? ""))
    }
}

/// Both the unsent attachment and its copy in the transcript use the same source.
struct AgentPassageCard: View {
    let passage: AgentPassage
    var remove: (() -> Void)? = nil
    let visit: (URL) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote").font(.system(size: 10))
                Text("Selected text").fontWeight(.medium)
                Spacer(minLength: 4)
                Button(expanded ? "Less" : "Preview") { expanded.toggle() }
                    .accessibilityLabel(expanded ? "Collapse selected text" : "Preview selected text")
                if let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .help("Remove selected text")
                    .accessibilityLabel("Remove selected text")
                }
            }
            .foregroundStyle(Palette.muted)
            if expanded {
                ScrollView {
                    Text(passage.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
            } else {
                Text(passage.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { visit(passage.url) } label: {
                HStack(spacing: 5) {
                    Text(passage.title).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.system(size: 8))
                }
                .foregroundStyle(Palette.muted)
            }
            .help("Open source: \(passage.url.absoluteString)")
            Text(passage.url.host() ?? "Local page")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.ink)
        .buttonStyle(.plain)
        .padding(10)
        .background(Palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
