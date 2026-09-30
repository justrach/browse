import SwiftUI

struct AgentPageContext: View {
    @ObservedObject var tab: Tab
    @ObservedObject var agent: Agent

    private var pinned: Bool { agent.pinned === tab }
    private var included: Bool { pinned || agent.withPage }
    private var title: String { tab.title.isEmpty ? (tab.address?.host() ?? "This page") : tab.title }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pinned ? "pin.fill" : "doc.text")
                .font(.system(size: 11))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).lineLimit(1)
                Text("\(pinned ? "Pinned" : included ? "Included" : "Excluded") · \(tab.address?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Local page")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                agent.pin(pinned ? nil : tab)
                if !pinned { agent.withPage = true }
            } label: {
                Image(systemName: pinned ? "pin.slash" : "pin")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .help(pinned ? "Unpin: follow the page in front" : "Pin this page to the conversation")
            .accessibilityLabel(pinned ? "Unpin page context" : "Pin page context")
            Button {
                if pinned { agent.pin(nil) }
                agent.withPage = !included
            } label: {
                Image(systemName: included ? "xmark" : "plus")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .help(included ? "Exclude the page from your next message" : "Include this page with your next message")
            .accessibilityLabel(included ? "Exclude page context" : "Include page context")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(included ? Palette.ink : Palette.muted)
        .padding(.vertical, 4)
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
