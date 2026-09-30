import SwiftUI

/// Progress comes from actions the agent reports: tools, sources, plans and
/// messages. Keep running tools visible even when newer activity arrives.
struct AgentActivity: View {
    let entries: [Agent.Entry]
    let started: Date?
    let ended: Date?
    let live: Bool
    let responding: Bool
    let full: Bool
    let visit: (URL) -> Void
    var waiting: String? = nil

    @State private var expanded = false

    private var activity: [Agent.Entry] { entries.filter { $0.kind != .thought } }
    private var running: [Agent.Entry] {
        activity.filter { $0.kind == .tool && ["pending", "in_progress"].contains($0.status) }
    }

    private var groups: [[Agent.Entry]] { Agent.grouped(activity) }
    private var visible: [[Agent.Entry]] {
        guard !expanded else { return groups }
        guard live else { return [] }
        let recent = Set(groups.suffix(3).compactMap { $0.first?.id })
        return groups.filter { group in
            (group.first.map { recent.contains($0.id) } ?? false) || group.contains {
                $0.kind == .tool && ["pending", "in_progress"].contains($0.status)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            disclosure
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visible, id: \.first?.id) { group in
                        if group.first?.kind == .page {
                            PagesCard(pages: group, open: visit)
                        } else if let entry = group.first {
                            EntryRow(entry: entry, full: full, live: live, visit: visit)
                        }
                    }
                }
            }
            if live {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: running.isEmpty ? "sparkle" : "bolt.horizontal.circle")
                        .font(.system(size: 10))
                        .frame(width: 14, height: 15)
                    Text(currentStatus)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .accessibilityLabel(currentStatus)
                if activity.isEmpty {
                    Text("Tools and sources will appear here as Codegraff uses them.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(Motion.settle, value: expanded)
    }

    private var currentStatus: String {
        if let waiting { return waiting }
        if !running.isEmpty {
            return running.count == 1 ? "1 action running" : "\(running.count) actions running"
        }
        return responding ? "Writing the response…" : "Preparing the next step…"
    }

    private var summary: String {
        let words = Steps.summary(activity)
        return words.isEmpty ? "Activity" : words
    }

    private var disclosure: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                if live && waiting == nil { Ring(size: 9) }
                if live && waiting != nil { Image(systemName: "pause.circle").font(.system(size: 10)) }
                Text(live ? (waiting == nil ? "Activity" : "Waiting for you") : summary)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if live {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.span(from: started, to: context.date))
                            .monospacedDigit()
                    }
                } else if let ended {
                    Text(Self.span(from: started, to: ended)).monospacedDigit()
                }
                if !activity.isEmpty {
                    Text(expanded ? "Less" : "Details")
                        .font(.system(size: 10.5))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.system(size: full ? 12.5 : 12))
            .foregroundStyle(Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activity.isEmpty)
        .help(expanded ? "Show recent activity" : "Show all actions and results")
        .accessibilityLabel(expanded ? "Show less activity" : "Show all activity")
    }

    private static func span(from start: Date?, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start ?? end).rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
