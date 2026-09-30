import SwiftUI

// A turn's steps drawn as Harness draws them (crates/ui/src/transcript.rs,
// DESIGN.md): one card per step on a small radius and a hairline, the
// label muted and what it acted on in ink — "Run  cargo test", "Edit
// src/resolve.rs" — with a disclosure that opens the card to what the step
// printed, or to its diff with line numbers. graff's plan is a card of its
// own: "Todo  1/2 done", opening to the list.

/// One step: a tool call, typed (see AgentSteps.swift).
struct StepCard: View {
    let entry: Agent.Entry
    /// Opens a page the step went to, in a tab.
    let visit: (URL) -> Void

    @State private var open = false
    @State private var hovering = false

    private var step: Step { entry.step ?? Steps.fallback(entry) }
    private var opens: Bool { !entry.output.isEmpty || entry.diff != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if opens { open.toggle() } } label: { head }
                .buttonStyle(.plain)
                .help(opens ? (open ? "Hide result" : "Show result") : "\(step.label) \(step.shown) · \(entry.status)")
            if open {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Group {
                    if let diff = entry.diff {
                        DiffView(diff: diff)
                    } else {
                        ScrollView {
                            Text(entry.output)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Palette.ink.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(Palette.ink.opacity(hovering ? 0.05 : 0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: open)
    }

    private var head: some View {
        HStack(spacing: 8) {
            Image(systemName: step.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 18, height: 18)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(step.label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Text(step.shown)
                .font(.system(size: 12, design: step.kind == .exec ? .monospaced : .default))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let url = URL(string: step.shown), url.scheme?.hasPrefix("http") == true {
                Button { visit(url) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Open in a tab")
            }
            mark
            if opens {
                Text(open ? "Hide" : "Result")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var mark: some View {
        switch entry.status {
        case "completed":
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.muted)
                .help("Completed")
        case "": EmptyView()
        case "failed":
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.red.opacity(0.75))
                .help("Failed")
        default:
            Ring(size: 9)
        }
    }
}

/// graff's plan: "Todo  1/2 done", opening to its lines.
struct TodoCard: View {
    let items: [TodoItem]

    @State private var open = false

    init(items: [TodoItem], expanded: Bool = false) {
        self.items = items
        self._open = State(initialValue: expanded)
    }

    var body: some View {
        let done = items.filter(\.done).count
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18)
                        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("Todo")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Text("\(done)/\(items.count) done")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18)
                        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .padding(.horizontal, 7)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10.5))
                                .foregroundStyle(item.done ? Palette.accent : Palette.muted)
                            Text(item.text)
                                .font(.system(size: 12))
                                .foregroundStyle(item.done ? Palette.muted : Palette.ink)
                                .strikethrough(item.done, color: Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .transition(.opacity)
            }
        }
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .animation(Motion.settle, value: open)
    }
}

/// An edit's diff, Harness's way: a hunk header, then each line with its
/// old and new numbers — removed in red, added in green, the rest plain —
/// with three lines of context round each change.
struct DiffView: View {
    let diff: StepDiff

    private struct Line: Identifiable {
        let id: Int
        let old: Int?
        let new: Int?
        let text: String
        /// "-", "+" or " ".
        let sign: Character
    }

    private var lines: [Line] {
        let before = diff.old.map { $0.components(separatedBy: "\n") } ?? []
        let after = diff.new.components(separatedBy: "\n")
        let change = after.difference(from: before)
        var removed = Set<Int>(), added = Set<Int>()
        for step in change {
            switch step {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        // Walk both texts together: what stayed moves both numbers on.
        var all: [Line] = []
        var o = 0, n = 0
        while o < before.count || n < after.count {
            if o < before.count, removed.contains(o) {
                all.append(Line(id: all.count, old: o + 1, new: nil, text: before[o], sign: "-"))
                o += 1
            } else if n < after.count, added.contains(n) {
                all.append(Line(id: all.count, old: nil, new: n + 1, text: after[n], sign: "+"))
                n += 1
            } else {
                all.append(Line(id: all.count, old: o < before.count ? o + 1 : nil, new: n < after.count ? n + 1 : nil,
                                text: n < after.count ? after[n] : before[o], sign: " "))
                o += 1
                n += 1
            }
        }
        // Only what changed and three lines round it.
        let changed = all.indices.filter { all[$0].sign != " " }
        guard !changed.isEmpty else { return Array(all.prefix(40)) }
        let keep = Set(changed.flatMap { max(0, $0 - 3)...min(all.count - 1, $0 + 3) })
        return all.indices.filter(keep.contains).map { all[$0] }
    }

    var body: some View {
        let shown = lines
        VStack(alignment: .leading, spacing: 0) {
            Text(diff.old == nil ? "New file  \(diff.path)" : diff.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in
                        HStack(spacing: 0) {
                            Text(line.old.map(String.init) ?? "")
                                .frame(width: 34, alignment: .trailing)
                            Text(line.new.map(String.init) ?? "")
                                .frame(width: 34, alignment: .trailing)
                            Text(String(line.sign))
                                .frame(width: 22)
                            Text(line.text)
                                .foregroundStyle(Palette.ink.opacity(0.9))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tint(line.sign).opacity(line.sign == " " ? 1 : 0.9))
                        .padding(.vertical, 1.5)
                        .background(fill(line.sign))
                        .overlay(alignment: .leading) {
                            if line.sign != " " {
                                Rectangle().fill(tint(line.sign)).frame(width: 2)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func tint(_ sign: Character) -> Color {
        switch sign {
        case "-": return Color(red: 0.86, green: 0.30, blue: 0.30)
        case "+": return Color(red: 0.25, green: 0.66, blue: 0.40)
        default: return Palette.muted
        }
    }

    private func fill(_ sign: Character) -> Color {
        sign == " " ? .clear : tint(sign).opacity(0.1)
    }
}

/// Harness's queue, docked above the composer: what was typed while
/// Codegraff worked, a row each in the order it will go. A row can go now —
/// the turn under way stops for it — go back into the composer to be
/// changed, or go.
struct QueuePanel: View {
    @ObservedObject var agent: Agent
    var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(agent.queue.count == 1 ? "Queued" : "Queued · \(agent.queue.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(Array(agent.queue.enumerated()), id: \.element.id) { index, item in
                Row(item: item, first: index == 0, agent: agent)
            }
        }
        .padding(.bottom, 4)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private struct Row: View {
        let item: Agent.Queued
        let first: Bool
        let agent: Agent

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: first ? "arrow.turn.down.right" : "line.3.horizontal")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 14)
                    .help(first ? "Goes next" : "Waits its turn")
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let passage = item.passage {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .help("Selected text from \(passage.title)\n\(passage.text)")
                        .accessibilityLabel("Selected text from \(passage.title)")
                }
                Spacer(minLength: 6)
                HStack(spacing: 2) {
                    action("arrow.up", "Send now: stop the turn under way and send this") { agent.sendNow(item.id) }
                    action("pencil", "Edit") { agent.edit(item.id) }
                    action("xmark", "Remove") { agent.unqueue(item.id) }
                }
                .opacity(hovering ? 1 : 0.55)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ink.opacity(hovering ? 0.045 : 0)))
            .padding(.horizontal, 4)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }

        private func action(_ icon: String, _ help: String, _ act: @escaping () -> Void) -> some View {
            Button(action: act) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

/// On a page with a form, low in its corner: Codegraff offered to fill it
/// in, on this tab alone. It asks the page once it has loaded and settled,
/// and keeps out of the way — gone while Codegraff is already on this tab,
/// for good on this site once dismissed, and never where Codegraff is off.
struct FormPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var agent: Agent
    @ObservedObject private var prefs: Preferences

    /// Sites told no, for as long as the app runs.
    @MainActor private static var dismissed: Set<String> = []

    @State private var fields = 0
    @State private var hovering = false
    @State private var gone = false
    /// The first time the pill shows on a page: a line over it saying what
    /// it does, once, for good.
    @AppStorage("hint.formPill", store: Store.settings) private var hinted = false

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        self.agent = browser.agent
        self.prefs = browser.prefs
    }

    private var host: String { tab.address?.host() ?? "" }

    private var shown: Bool {
        fields >= 3 && !gone && prefs.usesAgent && !tab.loading
            && agent.pinned !== tab && !FormPill.dismissed.contains(host)
    }

    var body: some View {
        Group {
            if shown {
                HStack(spacing: 0) {
                    Button {
                        hinted = true
                        browser.talk(about: tab, task: Browser.fillTask)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Fill in with Codegraff")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.leading, 13)
                        .padding(.trailing, 8)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Codegraff fills in this form on this tab alone, asks for what it doesn't know, and doesn't submit it  ⌥⌘F")
                    Button {
                        FormPill.dismissed.insert(host)
                        gone = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .frame(width: 26, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0.5)
                    .help("Not on this site")
                }
                .foregroundStyle(Palette.onAccent)
                .background(Capsule().fill(Palette.accent))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .onHover { hovering = $0 }
                .overlay(alignment: .topTrailing) {
                    if !hinted {
                        Text("New: Codegraff fills this form in on this tab, asks for what it doesn't know, and leaves submitting to you.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 250, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .offset(y: -78)
                            .transition(.opacity)
                            .onTapGesture { hinted = true }
                            // Read once, then it's known.
                            .task {
                                try? await Task.sleep(nanoseconds: 9_000_000_000)
                                hinted = true
                            }
                    }
                }
                .padding(18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: shown)
        // Asked once the page has loaded, and again a moment later for a
        // form that draws itself after.
        .task(id: "\(tab.id)|\(tab.address?.absoluteString ?? "")|\(tab.loading)") {
            fields = 0
            gone = false
            guard !tab.loading else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            fields = await browser.fillable(in: tab)
            if fields < 3 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                fields = await browser.fillable(in: tab)
            }
        }
    }
}
