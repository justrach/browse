import SwiftUI

struct AgentPagesView: View {
    @ObservedObject private var tools = AgentTools.shared
    @State private var expanded = false

    var body: some View {
        if !tools.openPages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.system(size: 11))
                        Text("Agent pages").fontWeight(.medium)
                        Text("\(tools.openPages.count)").monospacedDigit()
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(expanded ? "Hide" : "Show") agent pages, \(tools.openPages.count) open")
                if expanded {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(tools.openPages) { page in
                                Button { tools.inspectPage(page.id) } label: {
                                    HStack(spacing: 8) {
                                        if page.loading { Ring(size: 9) }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(page.title).foregroundStyle(Palette.ink).lineLimit(1)
                                            Text(page.url.host() ?? "Local page").font(.system(size: 10.5)).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .help("Open in a tab: \(page.url.absoluteString)")
                            }
                        }
                    }
                    .frame(height: min(150, CGFloat(tools.openPages.count) * 44))
                    Text("Open a page to inspect it in your tabs.")
                        .font(.system(size: 10.5))
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .buttonStyle(.plain)
            .animation(Motion.quick, value: expanded)
            .padding(.vertical, 7)
        }
    }
}
