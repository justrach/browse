import SwiftUI

/// Progress comes from actions the agent reports: tools, sources, plans and
/// messages. Surfaces real active tools, sources, plan steps, tabular elapsed
/// time, and actionable recovery when the model pauses > 20 s.
struct AgentActivity: View {
    let entries: [Agent.Entry]
    let started: Date?
    let ended: Date?
    let lastUpdate: Date?
    let chatSeed: String
    let live: Bool
    let responding: Bool
    let full: Bool
    let visit: (URL) -> Void
    var waiting: String? = nil
    var onReconnect: (() -> Void)? = nil
    var onReportProblem: (() -> Void)? = nil

    @State private var expanded = false

    private var activity: [Agent.Entry] { entries.filter { $0.kind != .thought } }
    private var running: [Agent.Entry] {
        activity.filter { $0.kind == .tool && ["pending", "in_progress"].contains($0.status) }
    }
    private var activePlanStep: String? {
        guard let plan = activity.last(where: { $0.kind == .plan }), let items = plan.todo else { return nil }
        return items.first(where: { !$0.done })?.text
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
            if !activity.isEmpty || !live {
                disclosure
            }
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visible, id: \.first?.id) { group in
                        if group.first?.kind == .page {
                            PagesCard(pages: group, open: visit)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if let entry = group.first {
                            EntryRow(entry: entry, full: full, live: live, visit: visit)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .animation(Motion.snappy, value: visible.map { $0.first?.id })
            }
            if live {
                workingTrailer
            }
        }
        .animation(Motion.snappy, value: expanded)
        .animation(Motion.snappy, value: running.count)
    }

    /// Live status trailer anchored to real tool/plan activity and quiet recovery.
    private var workingTrailer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(started ?? context.date)))
            let silent = lastUpdate.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
            let quiet = waiting == nil && silent >= 20
            let statusHeadline: String = {
                if let waiting { return waiting }
                if responding { return "Writing…" }
                if let activeTool = running.last {
                    let step = activeTool.step ?? Steps.fallback(activeTool)
                    return "\(step.label)…"
                }
                if activePlanStep != nil { return "Working…" }
                return "Thinking…"
            }()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if waiting != nil {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 12, height: 12)
                    } else {
                        Ring(size: 10)
                            .frame(width: 12, height: 12)
                    }

                    Text(statusHeadline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())

                    Text(Self.elapsedLabel(elapsed))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted.opacity(0.65))
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    if quiet {
                        Text("· Waiting for the model · \(Self.elapsedLabel(silent))")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted.opacity(0.6))
                            .monospacedDigit()
                            .lineLimit(1)
                    } else if waiting == nil, running.isEmpty, let countLabel = activityCountSummary {
                        Text("· \(countLabel)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                if quiet, (onReconnect != nil || onReportProblem != nil) {
                    HStack(spacing: 10) {
                        if let onReconnect {
                            Button("Reconnect", action: onReconnect)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.accent)
                        }
                        if let onReportProblem {
                            Button("Report problem", action: onReportProblem)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.leading, 19)
                }

                if let activeTool = running.last {
                    let step = activeTool.step ?? Steps.fallback(activeTool)
                    trailerDetail("Now", "\(step.label) · \(step.shown)", muted: false)
                }

                if let planStep = activePlanStep {
                    trailerDetail("Plan", planStep, muted: true)
                }
            }
            .padding(.top, 2)
        }
    }

    private var activityCountSummary: String? {
        let count = activity.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 step completed" : "\(count) steps completed"
    }

    private func trailerDetail(_ label: String, _ text: String, muted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.muted.opacity(0.6))
                .frame(width: 28, alignment: .leading)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(muted ? Palette.muted.opacity(0.75) : Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var summary: String {
        let words = Steps.summary(activity)
        return words.isEmpty ? "Activity" : words
    }

    private var disclosure: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                if live && waiting == nil { PulseDot(color: Palette.accent, size: 5, active: true) }
                if live && waiting != nil { Image(systemName: "pause.circle").font(.system(size: 10)) }
                Text(summary)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if !live, let ended {
                    Text(Self.span(from: started, to: ended)).monospacedDigit()
                }
                if !activity.isEmpty {
                    Text(expanded ? "Less" : "Details")
                        .font(.system(size: 10.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(Motion.snappy, value: expanded)
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

    private static func elapsedLabel(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private static func span(from start: Date?, to end: Date) -> String {
        elapsedLabel(max(0, Int(end.timeIntervalSince(start ?? end).rounded())))
    }
}
