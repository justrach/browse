import SwiftUI

/// Codegraff, down the right of the window (see Agent.swift for what it is
/// talking to) — or the whole stage, the talk as a page of its own, when
/// the door in its head or the Ask tab is pressed. The same ground, hairline
/// and pills as the rest of the app: what was said, in order, a question
/// when graff has one, and a field at the foot. The page you are on goes
/// with what you type unless you take it off.
///
/// On the stage, before anything has been said, it is Codegraff's page
/// instead (see AgentHome.swift); after, each turn is what you asked, the
/// work folded into one line, and the answer.
struct AgentColumn: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    @ObservedObject var prefs: Preferences
    @ObservedObject private var shortcuts = ShortcutStore.shared

    /// The whole stage rather than a column beside it (see Browser.agentFull).
    var full = false

    @FocusState private var typing: Bool
    @State private var confirmingReconnect = false
    @State private var showingGuide = false
    @State private var showingTasks = false
    @State private var showingBrowserChat = false

    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    var body: some View {
        VStack(spacing: 0) {
            if full && agent.entries.isEmpty {
                head
                AgentHome(browser: browser, agent: agent, typing: $typing)
            } else if full {
                head
                conversation
            } else {
                conversation
            }
        }
        .frame(width: full ? nil : prefs.agentWidth)
        .frame(maxWidth: full ? .infinity : nil, maxHeight: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .leading) { if !full { edge } }
        .animation(Motion.settle, value: agent.asking?.id)
        // A link in what graff said opens here, as a tab, not in whichever
        // browser the Mac would hand it to.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.hasPrefix("http") == true else { return .systemAction }
            browser.open(url, foreground: true)
            return .handled
        })
        .onAppear {
            agent.wake()
            focusInput()
        }
        .onChange(of: browser.agentFocusRequest) { _, _ in focusInput() }
        .sheet(item: $browser.agentFeedback) { draft in
            AgentFeedbackView(draft: draft)
        }
        .sheet(isPresented: $showingTasks) {
            AgentTaskLibrary(agent: agent, tasks: agent.tasks, focus: browser.focusAgent)
        }
        .sheet(isPresented: $showingBrowserChat) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Continue in browser").font(.headline)
                    Spacer()
                    Button("Done") { showingBrowserChat = false }.keyboardShortcut(.cancelAction)
                }
                AgentBrowserChatCard(chat: agent.browserChat)
            }
            .padding(24)
            .frame(width: 540)
            .background(Palette.ground)
        }
        .alert("Reconnect Codegraff?", isPresented: $confirmingReconnect) {
            Button("Reconnect") { agent.reconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the current run and restores this conversation. Queued messages wait until you send another message. Browser actions already taken stay in place.")
        }
    }

    private func focusInput() {
        guard browser.takeAgentFocus() else { return }
        let request = browser.agentFocusRequest
        DispatchQueue.main.async {
            guard browser.consulting, !browser.editing, browser.agentFocusRequest == request else { return }
            typing = true
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if !full {
                head
            }
            measure(
                VStack(spacing: 0) {
                    AgentTaskStateView(agent: agent, focus: browser.focusAgent)
                    AgentPagesView()
                }
                .padding(.horizontal, full ? 20 : 18)
            )
            said
            if let ask = agent.asking {
                measure(
                    AskCard(ask: ask) { agent.answer(ask, with: $0) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            measure(AgentComposer(browser: browser, agent: agent, full: full, typing: $typing))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - the head

    private var head: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Codegraff")
                        .font(.system(size: 12.5, weight: full ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if !full {
                        PulseDot(color: light, size: 5, active: agent.phase == .starting || agent.phase == .working)
                            .accessibilityLabel(status)
                    }
                }
                if full || agent.asking != nil || !agent.phase.words.isEmpty {
                    HStack(spacing: 4) {
                        if full {
                            PulseDot(color: light, size: 5, active: agent.phase == .starting || agent.phase == .working)
                        }
                        Text(status)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                }
            }
            .help(agent.entries.isEmpty ? status : "\(agent.title) — \(status)")
            Spacer(minLength: 0)
            if prefs.agentTasks {
                Door(icon: "square.stack", help: "Task library — saved instructions") { showingTasks = true }
                    .accessibilityLabel("Task library")
            }
            AgentHistoryButton(agent: agent, focus: browser.focusAgent)
            Door(icon: "square.and.pencil", help: "New conversation") { agent.startOver(); browser.focusAgent() }
                .disabled(agent.entries.isEmpty && agent.draft.isEmpty)
            Menu {
                Button("Continue in browser…") { showingBrowserChat = true }
                Divider()
                Button("How to use Codegraff…") { showingGuide = true }
                Button("Report an agent problem…") { browser.reportAgentProblem() }
                Divider()
                Button("Reconnect…") { confirmingReconnect = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Conversation options")
            .accessibilityLabel("Conversation options")
            Door(icon: "questionmark.circle", help: "How to use Codegraff") { showingGuide = true }
                .accessibilityLabel("How to use Codegraff")
                .popover(isPresented: $showingGuide, arrowEdge: .bottom) { AgentGuide() }
            Door(
                icon: full ? "sidebar.right" : "arrow.up.left.and.arrow.down.right",
                help: (full ? "Beside the page" : "Expand conversation")
                    + (ShortcutStore.shared.key(for: .expandAgent).map { "   \($0.display)" } ?? "")
            ) {
                withAnimation(Motion.gentle) {
                    if full { browser.talkToColumn() } else { browser.takeStage() }
                }
            }
            Door(
                icon: "xmark",
                help: "Close" + (ShortcutStore.shared.key(for: .toggleAgent).map { "   \($0.display)" } ?? "")
            ) { browser.toggleAgent() }
        }
        .padding(.horizontal, full ? 20 : 18)
        .frame(height: full ? 56 : 44)
    }

    private var status: String {
        if agent.taskState != .idle { return agent.taskState.words }
        if !agent.phase.words.isEmpty { return agent.phase.words }
        if !full { return "Ready to help" }
        return agent.entries.isEmpty ? "Research and tasks" : agent.title
    }

    private var light: Color {
        switch agent.phase {
        case .ready: return .green.opacity(0.8)
        case .starting, .working: return .orange.opacity(0.85)
        case .asleep: return Palette.faint
        case .missing, .signedOut, .broken: return .red.opacity(0.75)
        }
    }

    // MARK: - what was said

    /// Everything said, a turn at a time: what you asked, the work graff did
    /// on it folded into one line, and its answer. A plain stack, not a lazy
    /// one: a lazy stack guesses the height of what it hasn't drawn, and
    /// with a reply growing at the bottom every guess moved the whole column.
    private var said: some View {
        ScrollView {
            measure(
                VStack(alignment: .leading, spacing: full ? 20 : 12) {
                    if agent.entries.isEmpty { empty }
                    if full, let first = agent.entries.first {
                        Text(Self.day(first.at))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                    let turns = Turn.split(agent.entries)
                    ForEach(turns) { turn in
                        TurnView(
                            turn: turn,
                            // Working on it — or asked before graff was up,
                            // and waiting for it to be.
                            live: turn.id == turns.last?.id && (agent.phase == .working
                                || (agent.phase == .starting && turn.you != nil && turn.answer.isEmpty)),
                            full: full,
                            waiting: agent.asking.map { $0.isQuestion ? "Waiting for your answer…" : "Waiting for your approval…" },
                            visit: { url in browser.open(url, foreground: true) },
                            feedback: { browser.reportAgentProblem(kind: .answer) }
                        )
                    }
                }
                .padding(.horizontal, full ? 20 : 18)
                .padding(.vertical, 18)
            )
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: .infinity)
        .mask {
            VStack(spacing: 0) {
                if !full {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 12)
                }
                Rectangle()
            }
        }
    }

    /// "Today 7:44 PM", or the day it was, over a conversation on the stage.
    private static func day(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }

    /// What there is before anything has been said: how to start, or what
    /// is in the way of starting.
    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch agent.phase {
            case .missing, .signedOut, .broken:
                AgentNotice(browser: browser, agent: agent)
            default:
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .padding(.bottom, 6)
                Text(browser.active?.isBlank == false ? "Explore this page" : "Start a conversation")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("Ask a question, check a claim, or follow an idea. Choose what goes with your message below.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                AgentStarters(agent: agent, page: browser.active, compact: true, focus: browser.focusAgent)
                    .padding(.top, 8)
                agentShortcutHints
                    .padding(.top, 10)
            }
        }
        .padding(.top, 28)
    }

    private var agentShortcutHints: some View {
        let toggle = shortcuts.key(for: .toggleAgent)?.display
        let expand = shortcuts.key(for: .expandAgent)?.display
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let toggle {
                    HStack(spacing: 5) {
                        ShortcutBadge(keys: toggle)
                        Text("Sidebar")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                if let expand {
                    HStack(spacing: 5) {
                        ShortcutBadge(keys: expand)
                        Text("Full view")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                HStack(spacing: 5) {
                    ShortcutBadge(keys: ".")
                    Text("Quick ask")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    /// Everything the talk draws is held to one measure and centred on the
    /// stage it fills; in the column it fills the column and nothing more.
    private func measure<Content: View>(_ content: Content) -> some View {
        content
            .frame(maxWidth: full ? Metrics.chat : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    /// The column's edge: pulled left to widen it, double-clicked to put it
    /// back, as the sidebar's is.
    private var edge: some View {
        Capsule()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: 2, height: 32)
            .frame(maxHeight: .infinity)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.agentWidth }
                        let wanted = (grabbed ?? prefs.agentWidth) - value.translation.width
                        prefs.agentWidth = min(Metrics.agentMax, max(Metrics.agentMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.agentWidth = Metrics.agent }
            })
            .animation(Motion.quick, value: onEdge)
    }
}

/// Unified NanoHarness-style Model + Reasoning chip and two-step popover
/// (`model_picker.zig` + `view_picker.zig`):
/// - Trigger chip shows maker mark + model label + current effort level in one
///   compact pill that never collides with the send button.
/// - Clicking opens the compact reasoning card (brand-colored capsule slider
///   for instant effort changes) with a header button expanding into the full
///   searchable catalog (subscription routes first with Plan pills, favorites,
///   exact search ranking, stable model IDs, and two-step reasoning stage).
struct ModelPicker: View {
    @ObservedObject var agent: Agent
    let current: Agent.Model

    @State private var open = false
    @State private var hovering = false

    private var effortLabel: String? {
        guard let effort = agent.effort, !effort.current.isEmpty else { return nil }
        return Agent.Model.reasoningLabel(effort.current, binary: current.binaryEffort)
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                ProviderMark(provider: current.makerKey, size: 14)
                Text(current.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering || open ? Palette.ink : Palette.ink.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
                if let effortLabel {
                    Text(effortLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted.opacity(0.8))
                        .fixedSize()
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || open ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(
            "Model: \(current.label)"
                + (effortLabel.map { ", reasoning \($0)" } ?? "")
                + ", via \(Agent.Model.said(current.provider))"
        )
        .popover(isPresented: $open, arrowEdge: .top) {
            NanoModelPopover(agent: agent, current: current) { open = false }
        }
    }
}

private struct NanoModelPopover: View {
    @ObservedObject var agent: Agent
    let current: Agent.Model
    let done: () -> Void

    enum Step: Equatable {
        case compact
        case list
        case stage(Agent.Model)
    }

    @Environment(\.colorScheme) private var scheme
    @State private var step: Step = .list
    @State private var canReturnCompact = false
    @State private var query = ""
    @State private var starredOnly = false
    @State private var highlightedID: String?
    @State private var stagedEffort: String = ""
    @FocusState private var searchFocused: Bool

    private var dark: Bool { scheme == .dark }

    private var currentLevels: [String] {
        if !current.effortLevels.isEmpty { return current.effortLevels }
        return agent.effort?.levels.map(\.value) ?? []
    }

    var body: some View {
        Group {
            switch step {
            case .compact:
                compactCard
            case .list:
                catalogList
            case .stage(let model):
                stagePage(for: model)
            }
        }
        .animation(Motion.snappy, value: step)
        .onAppear {
            if currentLevels.count > 1 {
                step = .compact
                canReturnCompact = true
            } else {
                step = .list
                canReturnCompact = false
                highlightedID = current.id
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    // MARK: - Step 0: Compact thinking tier card (276pt)

    private var compactCard: some View {
        let levels = currentLevels
        let binary = current.binaryEffort
        let accent = ProviderMark.brandAccent(for: current.makerKey, dark: dark)
        let activeValue = agent.effort?.current ?? levels.first ?? ""
        let activeIndex = levels.firstIndex(of: activeValue) ?? 0
        let levelText = Agent.Model.reasoningLabel(activeValue, binary: binary)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                canReturnCompact = true
                highlightedID = current.id
                step = .list
                DispatchQueue.main.async { searchFocused = true }
            } label: {
                HStack(spacing: 8) {
                    ProviderMark(provider: current.makerKey, size: 15)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("via \(Agent.Model.said(current.provider))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.hover.opacity(0.55)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)

            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(binary ? "THINKING" : "REASONING")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.muted.opacity(0.75))
                        Text(levelText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    if let ctx = current.window {
                        Text(ctx)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }

                EffortCapsuleSlider(
                    count: levels.count,
                    index: activeIndex,
                    accent: accent,
                    compact: true
                ) { next in
                    guard levels.indices.contains(next) else { return }
                    agent.choose(effort: levels[next])
                }

                HStack {
                    Text(binary ? "Off" : "Faster")
                    Spacer()
                    Text(binary ? "On" : "Deeper")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(width: 276)
    }

    // MARK: - Step 1: Full searchable model catalog (356pt)

    private struct SectionGroup: Identifiable {
        let id: String
        let provider: String
        let title: String
        let isPlan: Bool
        let models: [Agent.Model]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var catalogRows: (flat: [Agent.Model], sections: [SectionGroup]) {
        let favs = agent.favoriteModelIDs
        let base = starredOnly ? agent.models.filter { favs.contains($0.id) } : agent.models

        if !trimmedQuery.isEmpty || starredOnly {
            let matched: [(model: Agent.Model, rank: Int)] = base.compactMap { m in
                guard let rank = m.searchRank(for: trimmedQuery) else { return nil }
                return (m, rank)
            }
            let sorted = matched.sorted { a, b in
                if a.model.billingRank != b.model.billingRank { return a.model.billingRank < b.model.billingRank }
                if a.rank != b.rank { return a.rank < b.rank }
                return false
            }.map(\.model)
            return (sorted, [])
        }

        // Preserve first-appearance route order, place `claude-agent` ahead of
        // `anthropic`, then order routes by best billing rank (plan → local →
        // credits → api), 1:1 with NanoHarness `model_picker.zig:rows`.
        var routeOrder: [String] = []
        var byRoute: [String: [Agent.Model]] = [:]
        for model in base {
            if byRoute[model.provider] == nil { routeOrder.append(model.provider) }
            byRoute[model.provider, default: []].append(model)
        }
        if let agentIdx = routeOrder.firstIndex(of: "claude-agent"),
           let anthIdx = routeOrder.firstIndex(of: "anthropic"),
           agentIdx > anthIdx {
            let moved = routeOrder.remove(at: agentIdx)
            routeOrder.insert(moved, at: anthIdx)
        }
        let sortedRoutes = routeOrder.enumerated().sorted { a, b in
            let ra = byRoute[a.element]?.map(\.billingRank).min() ?? 2
            let rb = byRoute[b.element]?.map(\.billingRank).min() ?? 2
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)

        var sections: [SectionGroup] = []
        var flat: [Agent.Model] = []
        for route in sortedRoutes {
            let items = (byRoute[route] ?? []).sorted { a, b in
                if a.billingRank != b.billingRank { return a.billingRank < b.billingRank }
                return false
            }
            guard !items.isEmpty else { continue }
            let isPlan = items.contains { $0.billingRank == 0 }
            sections.append(SectionGroup(
                id: route,
                provider: route,
                title: Agent.Model.said(route),
                isPlan: isPlan,
                models: items
            ))
            flat.append(contentsOf: items)
        }
        return (flat, sections)
    }

    private var catalogList: some View {
        let data = catalogRows
        let flat = data.flat
        let highlighted = flat.first { $0.id == highlightedID } ?? flat.first

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if canReturnCompact {
                    Button { step = .compact } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 22, height: 22)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Back to reasoning slider")
                }
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("Search \(agent.models.count) models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit {
                        if let pick = highlighted { openStageOrCommit(pick) }
                    }
                    .onKeyPress(.downArrow) {
                        moveHighlight(in: flat, delta: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(in: flat, delta: -1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if !query.isEmpty {
                            query = ""
                        } else if canReturnCompact {
                            step = .compact
                        } else {
                            done()
                        }
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    starredOnly.toggle()
                    highlightedID = nil
                } label: {
                    Image(systemName: starredOnly ? "star.fill" : "star")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(starredOnly ? Palette.accent : Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(starredOnly ? Palette.accent.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(starredOnly ? "Show all models" : "Show starred models")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle().fill(Palette.hairline).frame(height: 1)

            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if data.sections.isEmpty {
                            ForEach(flat, id: \.id) { model in
                                modelRow(model, lit: model.id == highlighted?.id, showRoute: true)
                                    .id(model.id)
                            }
                        } else {
                            ForEach(data.sections) { section in
                                SwiftUI.Section {
                                    ForEach(section.models, id: \.id) { model in
                                        modelRow(model, lit: model.id == highlighted?.id, showRoute: false)
                                            .id(model.id)
                                    }
                                } header: {
                                    HStack(spacing: 7) {
                                        ProviderMark(provider: section.provider, size: 13)
                                        Text(section.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Palette.muted)
                                        Spacer(minLength: 4)
                                        if section.isPlan {
                                            Text("Plan")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Palette.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 9)
                                    .padding(.bottom, 4)
                                    .background(.regularMaterial)
                                }
                            }
                        }
                        if flat.isEmpty {
                            Text(starredOnly && trimmedQuery.isEmpty
                                 ? "No starred models yet — click ★ on any model."
                                 : "No model matches “\(query)”")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .padding(16)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlightedID) { _, now in
                    if let now { reader.scrollTo(now) }
                }
            }
            .frame(height: 380)

            if let info = highlighted {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                detailFooter(for: info)
            }
        }
        .frame(width: 356)
        .onChange(of: query) { _, _ in
            highlightedID = catalogRows.flat.first?.id
        }
    }

    private func modelRow(_ model: Agent.Model, lit: Bool, showRoute: Bool) -> some View {
        let selected = model == current
        let starred = agent.favoriteModelIDs.contains(model.id)

        return HStack(spacing: 8) {
            ProviderMark(provider: model.makerKey, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(lit || selected ? Palette.ink : Palette.ink.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let tag = model.tag {
                        Text(tag)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.wash, in: Capsule())
                    }
                }
                if showRoute {
                    Text("via \(Agent.Model.said(model.provider))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if showRoute && model.billingRank == 0 {
                Text("Plan")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if let window = model.window {
                Text(window)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accent)
            }
            Button {
                agent.toggleFavorite(model)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 10.5))
                    .foregroundStyle(starred ? Palette.accent : Palette.muted.opacity(lit ? 0.7 : 0.35))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(starred ? "Remove from starred" : "Star model")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, showRoute ? 5 : 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(lit || selected ? Palette.hover : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { openStageOrCommit(model) }
        .onHover { over in if over { highlightedID = model.id } }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Agent.Model.said(model.provider))
    }

    /// Catalog-only facts strip under the list (matching NanoHarness detail card).
    private func detailFooter(for model: Agent.Model) -> some View {
        HStack(spacing: 8) {
            Text("via \(Agent.Model.said(model.provider))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let range = model.reasoningRange {
                factChip(range)
            }
            if let billing = model.billingLabel {
                factChip(billing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.ground.opacity(0.6))
    }

    private func factChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
    }

    private func moveHighlight(in flat: [Agent.Model], delta: Int) {
        guard !flat.isEmpty else { return }
        let idx = flat.firstIndex { $0.id == highlightedID } ?? 0
        let next = min(max(0, idx + delta), flat.count - 1)
        highlightedID = flat[next].id
    }

    private func openStageOrCommit(_ model: Agent.Model) {
        let levels = model.effortLevels
        if levels.count > 1 {
            let preferred = agent.preferredEffort
            if levels.contains(preferred) {
                stagedEffort = preferred
            } else if levels.contains("medium") {
                stagedEffort = "medium"
            } else {
                stagedEffort = levels.last ?? ""
            }
            step = .stage(model)
        } else {
            done()
            agent.choose(model)
        }
    }

    // MARK: - Step 2: Model reasoning stage (356pt, 1:1 with NanoHarness `page`)

    private func stagePage(for model: Agent.Model) -> some View {
        let levels = model.effortLevels
        let binary = model.binaryEffort
        let accent = ProviderMark.brandAccent(for: model.makerKey, dark: dark)
        let idx = levels.firstIndex(of: stagedEffort) ?? max(0, levels.count - 1)
        let currentName = levels.indices.contains(idx)
            ? Agent.Model.reasoningLabel(levels[idx], binary: binary)
            : "Default"

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    step = .list
                    DispatchQueue.main.async { searchFocused = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Models")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            HStack(spacing: 12) {
                ProviderMark(provider: model.makerKey, size: 20)
                    .frame(width: 38, height: 38)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text("via \(Agent.Model.said(model.provider))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }

            if model.window != nil || model.billingLabel != nil || model.fastSupported {
                HStack(spacing: 6) {
                    if let ctx = model.window { factChip("\(ctx) context") }
                    if let billing = model.billingLabel { factChip(billing) }
                    if model.fastSupported { factChip("Fast supported") }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(binary ? "Thinking" : "Reasoning")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text(currentName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(accent.opacity(0.32), lineWidth: 1))
                        .contentTransition(.numericText())
                }

                if levels.count > 1 {
                    EffortCapsuleSlider(
                        count: levels.count,
                        index: idx,
                        accent: accent,
                        compact: false
                    ) { next in
                        guard levels.indices.contains(next) else { return }
                        stagedEffort = levels[next]
                    }
                    HStack {
                        Text(binary ? "Off" : "Faster")
                        Spacer()
                        Text(binary ? "On" : "Deeper")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                }
            }

            Button {
                done()
                agent.choose(model, effort: levels.indices.contains(idx) ? levels[idx] : nil)
            } label: {
                Text("Use model")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(TactilePress())
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
        .frame(width: 356)
        .onKeyPress(.escape) {
            step = .list
            DispatchQueue.main.async { searchFocused = true }
            return .handled
        }
    }
}

/// Capsule reasoning slider 1:1 with NanoHarness `view_picker.zig:slider`:
/// brand-colored capsule fill, illuminated stop dots, continuous pointer drag
/// with alignment haptics, and smooth settle onto stops on release.
private struct EffortCapsuleSlider: View {
    let count: Int
    let index: Int
    let accent: Color
    let compact: Bool
    let onSelect: (Int) -> Void

    @State private var dragFraction: CGFloat?

    private var last: CGFloat { CGFloat(max(1, count - 1)) }
    private var fraction: CGFloat { dragFraction ?? (CGFloat(index) / last) }

    var body: some View {
        let railH: CGFloat = compact ? 28 : 26
        let thumbW: CGFloat = compact ? 40 : 28
        let thumbH: CGFloat = compact ? 30 : 28

        GeometryReader { geo in
            let w = max(thumbW, geo.size.width)
            let travel = max(1, w - thumbW)
            let fillW = max(railH, thumbW + fraction * travel)
            let thumbX = fraction * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.ink.opacity(0.07))
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    .frame(height: railH)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.85), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillW, height: railH)

                // Stop dots along the rail.
                if count > 1 {
                    ForEach(0..<count, id: \.self) { stop in
                        let stopFrac = CGFloat(stop) / last
                        let x = thumbW / 2 + stopFrac * travel
                        let reached = stopFrac <= fraction + 0.01
                        Circle()
                            .fill(reached ? Color.white.opacity(0.65) : Palette.muted.opacity(0.35))
                            .frame(width: 4.5, height: 4.5)
                            .position(x: x, y: geo.size.height / 2)
                    }
                }

                // Tactile neutral thumb.
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.75))
                    .shadow(color: .black.opacity(dragFraction != nil ? 0.22 : 0.14), radius: dragFraction != nil ? 6 : 3, y: 1)
                    .frame(width: thumbW, height: thumbH)
                    .offset(x: thumbX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = min(1, max(0, (value.location.x - thumbW / 2) / travel))
                        dragFraction = raw
                        let snapped = Int((raw * last).rounded())
                        if snapped != index {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            onSelect(snapped)
                        }
                    }
                    .onEnded { value in
                        let raw = min(1, max(0, (value.location.x - thumbW / 2) / travel))
                        let snapped = Int((raw * last).rounded())
                        if snapped != index {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            onSelect(snapped)
                        }
                        withAnimation(Motion.snappy) { dragFraction = nil }
                    }
            )
            .animation(dragFraction == nil ? Motion.snappy : nil, value: index)
        }
        .frame(height: compact ? 34 : 32)
    }
}

/// The pages graff read in a row, on one card: each its icon, title and
/// site, and a click away from being a tab of yours.
struct PagesCard: View {
    let pages: [Agent.Entry]
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(pages) { page in
                PageLine(page: page, open: open)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct PageLine: View {
        let page: Agent.Entry
        let open: (URL) -> Void
        @State private var hovering = false

        var body: some View {
            let url = URL(string: page.key)
            let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
            Button { if let url { open(url) } } label: {
                HStack(spacing: 8) {
                    if let icon = url?.host().flatMap({ Favicons.shared.cached($0.lowercased()) }) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: page.text.hasPrefix("Search: ") ? "magnifyingglass" : "globe")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 14, height: 14)
                    }
                    Text(page.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open \(page.key) in a tab")
        }
    }
}

/// One exchange: what was asked, the work graff did on it — thinking, tools,
/// pages read — and the answer it ended on. What came before anything was
/// asked is a turn with no question.
private struct Turn: Identifiable {
    let id: UUID
    var you: Agent.Entry?
    var work: [Agent.Entry] = []
    var answer: [Agent.Entry] = []

    /// The answer is what it said last, after the last thing it did; all
    /// that came before is work. While a reply is still coming it is the
    /// answer, and moves into the work if graff goes on to do something.
    static func split(_ entries: [Agent.Entry]) -> [Turn] {
        var turns: [Turn] = []
        var said: [Agent.Entry] = []
        var asked: Agent.Entry?
        func close() {
            guard asked != nil || !said.isEmpty else { return }
            let tail = said.reversed().prefix { $0.kind == .reply || $0.kind == .note }.count
            turns.append(Turn(
                id: asked?.id ?? said.first?.id ?? UUID(),
                you: asked,
                work: Array(said.dropLast(tail)),
                answer: Array(said.suffix(tail))
            ))
        }
        for entry in entries {
            if entry.kind == .you {
                close()
                asked = entry
                said = []
            } else {
                said.append(entry)
            }
        }
        close()
        return turns
    }

    var started: Date? { you?.at ?? work.first?.at }
    var ended: Date? { (work + answer).map(\.until).max() }
}

/// A turn's question, reported activity and answer. Live work remains
/// visible; completed work folds away so the answer has room to be read.
private struct TurnView: View {
    let turn: Turn
    let live: Bool
    let full: Bool
    let waiting: String?
    let visit: (URL) -> Void

    @State private var copied = false
    let feedback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: full ? 12 : 10) {
            if let you = turn.you {
                EntryRow(entry: you, full: full, visit: visit)
            }
            if turn.work.contains(where: { $0.kind != .thought }) || live {
                AgentActivity(entries: turn.work, started: turn.started, ended: turn.ended,
                              live: live, responding: !turn.answer.isEmpty, full: full, visit: visit, waiting: live ? waiting : nil)
            }
            ForEach(turn.answer) { entry in
                EntryRow(entry: entry, full: full, visit: visit)
            }
            if !live, let reply = turn.answer.last(where: { $0.kind == .reply }) {
                foot(reply)
            }
        }
        .animation(Motion.settle, value: live)
    }

    /// Copy, and when it was said.
    private func foot(_ reply: Agent.Entry) -> some View {
        HStack(spacing: 12) {
            Button {
                let all = turn.answer.filter { $0.kind == .reply }.map(\.text).joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            Button(action: feedback) {
                Image(systemName: "flag")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Report a problem with this answer")
            .accessibilityLabel("Report a problem with this answer")
            Spacer(minLength: 0)
            // A short stamp leaves the answer's actions easy to find.
            Text(reply.until.formatted(date: Calendar.current.isDateInToday(reply.until) ? .omitted : .abbreviated, time: .shortened))
                .font(.system(size: 10.5))
        }
        .foregroundStyle(Palette.muted)
        .padding(.top, 3)
    }


}

/// One thing said, by you or by it, or one thing it did.
struct EntryRow: View {
    let entry: Agent.Entry
    /// On the stage, where the words are set larger.
    var full = false
    var live = false
    let visit: (URL) -> Void

    init(entry: Agent.Entry, full: Bool = false, live: Bool = false, visit: @escaping (URL) -> Void) {
        self.entry = entry
        self.full = full
        self.live = live
        self.visit = visit
    }

    var body: some View {
        switch entry.kind {
        case .you:
            VStack(alignment: .trailing, spacing: 4) {
                if let page = entry.page {
                    Label(page, systemImage: "doc.text")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                if let passage = entry.passage {
                    AgentPassageCard(passage: passage, visit: visit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(entry.text)
                    .font(.system(size: full ? 14.5 : 13))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, full ? 15 : 11)
                    .padding(.vertical, full ? 9 : 7)
                    .background(full ? Palette.wash : Palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: full ? 18 : 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, full ? 80 : 28)
        case .reply:
            ReplyText(text: entry.text, size: full ? 14.5 : 13)
        case .thought:
            EmptyView()
        case .tool:
            // A card of its own, as Harness draws a step (AgentCards.swift).
            StepCard(entry: entry, visit: visit)
        case .plan:
            TodoCard(items: entry.todo ?? [], expanded: live)
        case .note:
            Text(entry.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        case .page:
            // Drawn with the others on a card (see PagesCard).
            EmptyView()
        }
    }
}

/// A reply's markdown a block at a time — paragraphs, lists, headings, code —
/// with bold, code and links inside each line (Agent.rich). SwiftUI's own
/// reading of markdown is inline only, and a list read that way is a run of
/// dashes.
private struct ReplyText: View {
    let text: String
    var size: CGFloat = 13

    enum Block {
        case words(String)
        case item(String, mark: String, depth: Int)
        case heading(String)
        case code(String)
    }

    var body: some View {
        // Citations as small numbers, their sources under the reply once
        // (Citations.swift).
        let marked = Citations.mark(text)
        VStack(alignment: .leading, spacing: size * 0.7) {
            ForEach(Array(Self.blocks(marked.text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .words(let words):
                    Text(Citations.style(Agent.rich(words), size: size))
                        .lineSpacing(size * 0.2)
                case .item(let words, let mark, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(mark)
                            .foregroundStyle(Palette.muted)
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(Citations.style(Agent.rich(words), size: size))
                            .lineSpacing(size * 0.2)
                    }
                    .padding(.leading, 4 + CGFloat(depth) * 16)
                case .heading(let words):
                    Text(Citations.style(Agent.rich(words), size: size))
                        .font(.system(size: size + 1, weight: .semibold))
                case .code(let code):
                    Text(code)
                        .font(.system(size: size - 1.5, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            if !marked.sources.isEmpty {
                SourcesRow(sources: marked.sources, size: size)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var words: [String] = []
        var code: [String]?
        func flush() {
            if !words.isEmpty { out.append(.words(words.joined(separator: "\n"))) }
            words = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") {
                    out.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty || line == "---" || line == "***" { flush(); continue }
            let depth = raw.prefix { $0 == " " }.count / 2
            if let mark = line.range(of: #"^[-*•+]\s+"#, options: .regularExpression) {
                flush()
                out.append(.item(String(line[mark.upperBound...]), mark: "•", depth: depth))
            } else if let mark = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                out.append(.item(String(line[mark.upperBound...]), mark: line[..<mark.upperBound].trimmingCharacters(in: .whitespaces), depth: depth))
            } else if let mark = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                out.append(.heading(String(line[mark.upperBound...])))
            } else {
                words.append(line.hasPrefix("> ") ? String(line.dropFirst(2)) : line)
            }
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }
}

/// graff waiting on you: a question it asked mid-turn, or leave to do
/// something.
private struct AskCard: View {
    let ask: Agent.Ask
    let choose: (Agent.Ask.Option?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = ask.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if ask.isQuestion {
                // Its choices, if it offered any, one to a line; the field
                // below takes an answer in your own words either way.
                ForEach(ask.options) { option in
                    Pill(option.name) { choose(option) }
                }
                HStack(spacing: 6) {
                    Text("Or type an answer below")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    Pill("Skip") { choose(nil) }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(ask.options) { option in
                        Pill(option.name, filled: option == ask.options.first(where: \.allows)) {
                            choose(option)
                        }
                    }
                    if !ask.options.contains(where: \.refuses) {
                        Pill("Don't") { choose(nil) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// Settings › Agent: on or off, where graff is, and signing in to it.
struct AgentPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var agent: Agent

    /// Where Search found graff, looked up again when the path changes.
    @State private var found: String?
    @State private var looked = false

    var body: some View {
        Card {
            Line(
                "Codegraff",
                "Toggle the agent sidebar with ⌘;, expand full screen with ⇧⌘;, or press . while reading. ⌘↩ asks from the address field."
            ) {
                Switch(on: $prefs.usesAgent)
            }
            if prefs.usesAgent {
                Text("Codegraff can read pages, fill forms, run commands and edit files on your Mac without asking before each action. Send only the work you want it to do.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                Rule()
                Line("Start a conversation", "Review the included page, write a question, then press Return to send.") {
                    Pill("Open beside page", filled: true) {
                        browser.tuning = false
                        browser.talkToColumn()
                    }
                }
            }
        }
        AccountCard(browser: browser)
        if prefs.usesAgent { AgentBrowserChatCard(chat: agent.browserChat) }
        Card {
            Line("graff", location) {
                HStack(spacing: 6) {
                    if looked, found == nil {
                        Pill("Get Codegraff", filled: true) {
                            browser.tuning = false
                            browser.open(Agent.download, foreground: true)
                        }
                    }
                    if !prefs.agentPath.isEmpty {
                        Pill("Look for it") { use("") }
                    }
                    Pill("Choose…") { choose() }
                }
            }
            Rule()
            Line("Ask about selected text", "Right-click a passage and choose Ask Codegraff about Selection. Review the excerpt and its source before sending") {
                Switch(on: $prefs.agentSelection)
            }
            Rule()
            Line("Task library", "Keep reusable instructions on this Mac. The library button in chat adds them to an editable draft; nothing runs until you send") {
                Switch(on: $prefs.agentTasks)
            }
            Rule()
            Line("Keep a draft per tab", "Switch tabs and return to your unsent question and selected excerpt. Pinned conversations keep their draft. Drafts last until you close the tab or quit Browse") {
                Switch(on: $prefs.agentDrafts)
            }
            Rule()
            Line(
                "Your other MCP servers",
                "The tools your Codegraff, Claude, Cursor and Codex configs name, as well as the browser's. Each is a process of its own for every chat, so they are left out unless you want them. Takes effect with the next chat"
            ) {
                Switch(on: Binding(
                    get: { prefs.agentAllTools },
                    set: { prefs.agentAllTools = $0 }
                ))
            }
            Rule()
            Line(
                "Quick steps with Jev",
                "On a form or a search's filters, Jev picks each click and field in one quick call, through your Codegraff sign-in, and Codegraff says what gets typed. The page's words and controls go to Jev as they do to Codegraff's model"
            ) {
                Switch(on: Binding(
                    get: { prefs.agentJev },
                    set: { prefs.agentJev = $0 }
                ))
            }
            Rule()
            Line("Other accounts", "graff login, in Terminal — Codex, Kimi and the other providers graff knows") {
                Pill("Open…") { agent.loginInTerminal() }
            }
        }
        ConnectCard()
        .task(id: prefs.agentPath) {
            looked = false
            found = await Agent.locate(custom: prefs.agentPath)?.program.path
            looked = true
        }
    }

    private var location: String {
        guard looked else { return "Looking…" }
        guard let found else {
            return prefs.agentPath.isEmpty
                ? "Not found — install Codegraff, or show Search where graff is"
                : "Nothing to run at \(prefs.agentPath)"
        }
        return found.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use this graff"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url.path)
    }

    /// A different graff: the one running goes, the new one starts the next
    /// time it's wanted.
    private func use(_ path: String) {
        prefs.agentPath = path
        if agent.phase != .asleep { agent.shutDown() }
    }
}
