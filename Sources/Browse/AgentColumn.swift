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

    /// The whole stage rather than a column beside it (see Browser.agentFull).
    var full = false

    @FocusState private var typing: Bool
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    var body: some View {
        VStack(spacing: 0) {
            if full && agent.entries.isEmpty {
                // Nothing said yet, and the whole page to say it on:
                // Codegraff's own page, with the chats so far.
                AgentHome(browser: browser, agent: agent)
            } else if full {
                conversation
            } else {
                insetConversation
            }
        }
        .frame(width: full ? nil : prefs.agentWidth)
        .frame(maxWidth: full ? .infinity : nil, maxHeight: .infinity)
        .background(full ? Palette.ground : Palette.wash)
        .overlay(alignment: .leading) {
            if !full {
                Rectangle().fill(Palette.hairline).frame(width: 1)
            }
        }
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
            DispatchQueue.main.async { typing = true }
        }
        // From Codegraff's page into the talk: the field at the foot takes
        // the keyboard for what comes next.
        .onChange(of: agent.entries.isEmpty) { _, empty in
            if !empty { DispatchQueue.main.async { typing = true } }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            head
            if !full {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            said
            if let ask = agent.asking {
                measure(
                    AskCard(ask: ask) { agent.answer(ask, with: $0) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            measure(foot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Leave the resize edge at the true column boundary while the talk sits
    /// inside the column as one surface.
    private var insetConversation: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return conversation
            .background(Palette.ground, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            .padding(6)
    }

    // MARK: - the head

    private var head: some View {
        HStack(spacing: 8) {
            if full {
                // The talk as a page: a new one first, then what this one is
                // about, as a chat's own page has it.
                Door(icon: "square.and.pencil", help: "New chat") { agent.startOver() }
                Text(Chat.title(for: agent.entries))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Circle()
                    .fill(light)
                    .frame(width: 6, height: 6)
                Text("Codegraff")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            // Working says how long under the question; the head says only
            // what is in the way.
            if !agent.phase.words.isEmpty, agent.phase != .working {
                Text(agent.phase.words)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !full {
                Door(icon: "square.and.pencil", help: "New conversation") { agent.startOver() }
                    .disabled(agent.entries.isEmpty)
            }
            Door(
                icon: full ? "sidebar.right" : "arrow.up.left.and.arrow.down.right",
                help: full ? "Beside the page" : "Fill the window"
            ) {
                if full { browser.talkToColumn() } else { browser.takeStage() }
            }
            Door(icon: "xmark", help: "Close   ⇧⌘A") { browser.toggleAgent() }
        }
        .padding(.leading, full ? 10 : 14)
        .padding(.trailing, 8)
        .frame(height: 44)
    }

    /// Under the field: the model it is on and how hard it thinks, each a
    /// menu of what graff offers — the models its keys reach, the levels
    /// that model takes (as Harness asks graff for them).
    @ViewBuilder
    private var choices: some View {
        HStack(spacing: 12) {
            if let current = agent.model {
                ModelPicker(agent: agent, current: current)
                    .help("The model Codegraff uses — changing it carries the conversation over")
            }
            if let effort = agent.effort {
                Menu {
                    ForEach(effort.levels, id: \.value) { level in
                        Button {
                            agent.choose(effort: level.value)
                        } label: {
                            if level.value == effort.current {
                                Label(level.name, systemImage: "checkmark")
                            } else {
                                Text(level.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.system(size: 9.5))
                        Text(effort.currentName)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .semibold))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
                }
                // Drawn as given, the same as the model's menu beside it —
                // a borderless menu sets its own size and ink.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("How hard it thinks before it answers")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.muted)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(agent.phase == .working)
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
                            full: full
                        ) { url in browser.open(url, foreground: true) }
                    }
                }
                .padding(.horizontal, full ? 20 : 14)
                .padding(.vertical, 12)
            )
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: .infinity)
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
                Text("Ask about the page you're on, have it fill in a form, or give Codegraff something to do on your Mac. It runs commands and edits files without stopping to ask.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - the foot

    private var foot: some View {
        VStack(alignment: .leading, spacing: 8) {
            // On the stage the page is out of sight, so it doesn't go along.
            if !full, let tab = browser.active, !tab.isBlank, agent.asking?.isQuestion != true {
                pageChip(tab)
            }
            // One box: the words, and under them in the same box what
            // they go to — the model, how hard it thinks — and the button.
            VStack(alignment: .leading, spacing: full ? 10 : 8) {
                ZStack(alignment: .topLeading) {
                    if agent.draft.isEmpty {
                        Text(prompt)
                            .foregroundStyle(Palette.muted.opacity(0.75))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $agent.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1...8)
                        .focused($typing)
                        .onSubmit(send)
                }
                .font(.system(size: full ? 14.5 : 13.5))
                .frame(minHeight: full ? nil : 38, alignment: .topLeading)
                HStack(alignment: .center, spacing: 8) {
                    choices
                    Spacer(minLength: 0)
                    if agent.phase == .working, agent.asking?.isQuestion != true {
                        round(icon: "stop.fill", help: "Stop", live: true) { agent.stop() }
                    } else {
                        round(icon: "arrow.up", help: "Send   ↩", live: agent.canSend) { send() }
                            .disabled(!agent.canSend)
                    }
                }
            }
            .padding(.leading, full ? 16 : 12)
            .padding(.trailing, full ? 10 : 8)
            .padding(.top, full ? 13 : 12)
            .padding(.bottom, 9)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: full ? 20 : 19, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: full ? 20 : 19, style: .continuous)
                    .strokeBorder(typing ? Palette.accent.opacity(0.45) : Palette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            .animation(Motion.quick, value: typing)
            .onTapGesture { typing = true }
        }
        .padding(.horizontal, full ? 12 : 8)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var prompt: String {
        if agent.asking?.isQuestion == true { return "Answer Codegraff" }
        return agent.phase == .working ? "Codegraff is working…" : "Ask Codegraff"
    }

    /// The page that goes with the next message; a click leaves it behind.
    private func pageChip(_ tab: Tab) -> some View {
        Button { agent.withPage.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: agent.withPage ? "doc.text" : "doc")
                    .font(.system(size: 10, weight: .medium))
                Text(tab.title.isEmpty ? (tab.address?.host() ?? "This page") : tab.title)
                    .lineLimit(1)
                    .strikethrough(!agent.withPage)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(agent.withPage ? Palette.ink : Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(agent.withPage ? "This page goes with your message. Click to leave it out" : "Click to send this page with your message")
    }

    /// The send (or stop) button: the accent once there's something to
    /// send, a quiet grey until then.
    private func round(icon: String, help: String, live: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(live ? Palette.onAccent : Palette.muted)
                .frame(width: 28, height: 28)
                .background(live ? Palette.accent : Palette.wash, in: Circle())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: live)
        .help(help)
    }

    private func send() {
        guard agent.canSend else { return }
        agent.send(page: agent.withPage && !full ? browser.active : nil)
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
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
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

/// The model graff works on, and a way to change it that holds up with five
/// hundred of them: a popover with a field that narrows the list as you type
/// — arrows walk it, Return takes one — the few used last at the top, then
/// one section per provider, the one you are on first and the long routers
/// last. Nested menus built from the first word of each name were a heap
/// once OpenRouter's "anthropic/…" names came in.
private struct ModelPicker: View {
    @ObservedObject var agent: Agent
    let current: Agent.Model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Text(current.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelList(agent: agent, current: current) { open = false }
        }
    }
}

private struct ModelList: View {
    @ObservedObject var agent: Agent
    let current: Agent.Model
    let done: () -> Void

    @State private var query = ""
    /// Where the arrow keys have walked to, in the order rows are drawn.
    @State private var picked = 0
    /// Long sections opened with "Show all".
    @State private var opened: Set<String> = []
    @FocusState private var typing: Bool

    /// A section: its rows, each with its place among all the rows drawn,
    /// and how many there are before any are held back.
    struct Section: Identifiable {
        let id: String
        let title: String
        var rows: [(index: Int, model: Agent.Model)]
        let total: Int
    }

    /// A long provider shows this many until opened or searched.
    private static let glimpse = 6

    private var sections: [Section] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ model: Agent.Model) -> Bool {
            guard !words.isEmpty else { return true }
            let hay = "\(model.label) \(model.name) \(Agent.Model.said(model.provider)) \(model.maker ?? "")".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        var out: [Section] = []
        var index = 0
        func add(_ id: String, _ title: String, _ models: [Agent.Model], total: Int) {
            guard !models.isEmpty else { return }
            let rows = models.map { model -> (Int, Agent.Model) in
                defer { index += 1 }
                return (index, model)
            }
            out.append(Section(id: id, title: title, rows: rows, total: total))
        }
        if words.isEmpty {
            let recent = [current] + agent.recentModels.filter { $0 != current }
            add("recent", "Recent", Array(recent.prefix(5)), total: min(5, recent.count))
        }
        let byProvider = Dictionary(grouping: agent.models.filter(matches), by: \.provider)
        for provider in byProvider.keys.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
            let all = byProvider[provider] ?? []
            let held = words.isEmpty && all.count > Self.glimpse + 2 && !opened.contains(provider)
            add(provider, Agent.Model.said(provider), held ? Array(all.prefix(Self.glimpse)) : all, total: all.count)
        }
        return out
    }

    /// The provider you are on first, the ones people pick by name next,
    /// and the routers that carry hundreds last.
    private func rank(_ provider: String) -> Int {
        if provider == current.provider { return 0 }
        let first = ["codegraff", "codex", "anthropic", "openai", "xai", "kimi", "deepseek"]
        if let at = first.firstIndex(of: provider) { return at + 1 }
        return provider == "openrouter" ? 99 : 50
    }

    var body: some View {
        let sections = sections
        let rows = sections.flatMap { $0.rows.map(\.model) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("Search \(agent.models.count) models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($typing)
                    .onSubmit { if rows.indices.contains(picked) { choose(rows[picked]) } }
                    .onKeyPress(.downArrow) {
                        picked = min(picked + 1, max(0, rows.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        picked = max(picked - 1, 0)
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                                ForEach(section.rows, id: \.index) { row in
                                    line(row.model, lit: row.index == picked)
                                        .id(row.index)
                                        .onTapGesture { choose(row.model) }
                                        .onHover { if $0 { picked = row.index } }
                                }
                                if section.rows.count < section.total {
                                    Button {
                                        opened.insert(section.id)
                                    } label: {
                                        Text("Show all \(section.total)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Palette.muted)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .background(.regularMaterial)
                            }
                        }
                        if rows.isEmpty {
                            Text("No model matches “\(query)”")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .padding(16)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: picked) { _, now in reader.scrollTo(now) }
            }
            .frame(height: 400)
        }
        .frame(width: 360)
        .onAppear { DispatchQueue.main.async { typing = true } }
        .onChange(of: query) { _, _ in picked = 0 }
    }

    private func line(_ model: Agent.Model, lit: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Palette.ink)
                .opacity(model == current ? 1 : 0)
                .frame(width: 12)
            Text(model.label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let tag = model.tag {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Palette.wash, in: Capsule())
            }
            Spacer(minLength: 8)
            if let maker = model.maker {
                Text(maker)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            if let window = model.window {
                Text(window)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted.opacity(0.8))
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Palette.hover : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func choose(_ model: Agent.Model) {
        done()
        agent.choose(model)
    }
}

/// The pages graff read in a row, on one card: each its icon, title and
/// site, and a click away from being a tab of yours.
private struct PagesCard: View {
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

/// A turn drawn: the question, the work as one line — "Working for 7s" over
/// the step it is on while it works, "Worked for 58s" once it is done, that
/// opens to show every step — and the answer with its copy and time.
private struct TurnView: View {
    let turn: Turn
    let live: Bool
    let full: Bool
    let visit: (URL) -> Void

    /// Opened by hand. Closed otherwise: while it works, only the step it
    /// is on shows, and each gives way to the next.
    @State private var unfolded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: full ? 12 : 10) {
            if let you = turn.you {
                EntryRow(entry: you, full: full, visit: visit)
            }
            if !turn.work.isEmpty || (live && turn.answer.isEmpty) {
                VStack(alignment: .leading, spacing: 6) {
                    fold
                    if unfolded, !turn.work.isEmpty {
                        steps
                    } else if live, turn.answer.isEmpty {
                        now
                    }
                }
            }
            ForEach(turn.answer) { entry in
                EntryRow(entry: entry, full: full, visit: visit)
            }
            if !live, let reply = turn.answer.last(where: { $0.kind == .reply }) {
                foot(reply)
            }
        }
        .animation(Motion.settle, value: unfolded)
        .animation(Motion.settle, value: live)
    }

    /// Every step, in order, down a hairline.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Agent.grouped(turn.work), id: \.first?.id) { run in
                if run.first?.kind == .page {
                    PagesCard(pages: run, open: visit)
                } else if let entry = run.first {
                    EntryRow(entry: entry, full: full, visit: visit)
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1).padding(.leading, 4)
        }
        .transition(.opacity)
    }

    /// The one step it is on, under the line that says how long.
    private var now: some View {
        let last = Agent.grouped(turn.work).last
        let icon: String
        let words: String
        if let run = last, run.first?.kind == .page {
            let hosts = run.compactMap { URL(string: $0.key)?.host()?.replacingOccurrences(of: "www.", with: "") }
            icon = "globe"
            words = (run.count == 1 ? "Read a page" : "Read \(run.count) pages") + (hosts.isEmpty ? "" : " · " + Array(Set(hosts)).sorted().prefix(3).joined(separator: ", "))
        } else if let entry = last?.first, entry.kind == .tool {
            icon = EntryRow.icon(entry)
            words = EntryRow.said(entry)
        } else {
            icon = "sparkle"
            words = "Thinking"
        }
        return HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 14)
            Text(words)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: full ? 12.5 : 12))
        .foregroundStyle(Palette.muted)
        .padding(.leading, 2)
        .id(words)
        .transition(.opacity)
        .animation(Motion.quick, value: words)
    }

    private var fold: some View {
        Button { if !turn.work.isEmpty { unfolded.toggle() } } label: {
            HStack(spacing: 6) {
                if live {
                    Ring(size: 9)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Working for " + Self.span(from: turn.started, to: context.date))
                            .monospacedDigit()
                    }
                } else {
                    Text(turn.started.flatMap { start in turn.ended.map { "Worked for " + Self.span(from: start, to: $0) } } ?? "Worked")
                }
                if !turn.work.isEmpty {
                    Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                }
            }
            .font(.system(size: full ? 13 : 12))
            .foregroundStyle(Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(unfolded ? "Hide the steps" : "Show each step")
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
            Text(reply.until.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5))
        }
        .foregroundStyle(Palette.muted)
    }

    /// "58s", "2m 5s".
    private static func span(from start: Date?, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start ?? end).rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// One thing said, by you or by it, or one thing it did.
private struct EntryRow: View {
    let entry: Agent.Entry
    /// On the stage, where the words are set larger.
    var full = false
    let visit: (URL) -> Void
    @State private var open = false

    init(entry: Agent.Entry, full: Bool = false, visit: @escaping (URL) -> Void) {
        self.entry = entry
        self.full = full
        self.visit = visit
    }

    private var said: String { EntryRow.said(entry) }
    private var icon: String { EntryRow.icon(entry) }

    /// A tool's name as graff gives it, said the way a person would.
    static func said(_ entry: Agent.Entry) -> String {
        // mcp__search__ in chats from before the app was browse.
        guard let prefix = ["mcp__browse__", "mcp__search__"].first(where: entry.text.hasPrefix) else { return entry.text }
        let tool = String(entry.text.dropFirst(prefix.count))
        return [
            "search": "Searching the web", "read_pages": "Reading pages", "open": "Opening a page",
            "read": "Reading the page", "links": "Looking at the links", "go": "Going to a page",
            "back": "Going back", "forward": "Going forward", "reload": "Reloading",
            "click": "Clicking", "type": "Typing", "submit": "Submitting a form",
            "form_fields": "Reading the form", "fill": "Filling in the form",
            "run_js": "Running a script on the page", "screenshot": "Looking at the page",
            "tabs": "Looking at your tabs", "show": "Showing you a page", "close": "Closing a page",
        ][tool] ?? tool
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
                Text(entry.text)
                    .font(.system(size: full ? 14.5 : 13))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, full ? 15 : 11)
                    .padding(.vertical, full ? 9 : 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: full ? 18 : 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, full ? 80 : 28)
        case .reply:
            ReplyText(text: entry.text, size: full ? 14.5 : 13)
        case .thought:
            Button { open.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 14)
                    Text(open ? entry.text : "Thinking")
                        .font(.system(size: 12))
                        .italic(open)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Button { open.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 14)
                        Text(said)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(open ? nil : 1)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let url = URL(string: entry.text), url.scheme?.hasPrefix("http") == true {
                            Button { visit(url) } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                            .help("Open in a tab")
                        }
                        mark
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open, !entry.output.isEmpty {
                    ScrollView {
                        Text(entry.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            // A step among steps, down the fold's hairline: no box of its own.
            .padding(.vertical, 3)
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

    /// What it did, at a glance: searched, fetched, read, changed, ran — or
    /// worked in the browser, through Search's own tools.
    static func icon(_ entry: Agent.Entry) -> String {
        let title = entry.text.lowercased()
        if title.contains("browse__") || title.contains("search__") || title.hasPrefix("browse.") || title.hasPrefix("search.") || title.hasPrefix("search:") { return "safari" }
        switch entry.act {
        case "search": return "magnifyingglass"
        case "fetch": return "globe"
        case "read": return "doc.text"
        case "edit", "delete", "move": return "pencil"
        case "execute": return "terminal"
        case "think": return "brain"
        default: return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch entry.status {
        case "completed":
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
        case "failed":
            Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red.opacity(0.8))
        default:
            Ring(size: 9)
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
        AccountCard(browser: browser)
        Card {
            Line(
                "Codegraff",
                "The Ask tab at the head of the row, with your chats, and a column beside the page. Codegraff reads the page you're on, fills in forms, and works on your Mac with all its tools — commands, file edits, codedb — without stopping to ask. ⇧⌘A shows and hides the column; ⌘↩ in the address field asks it"
            ) {
                Switch(on: Binding(
                    get: { prefs.usesAgent },
                    set: { on in
                        prefs.usesAgent = on
                        if !on {
                            browser.consulting = false
                            agent.shutDown()
                        }
                    }
                ))
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
            Line("graff", location) {
                HStack(spacing: 6) {
                    if !prefs.agentPath.isEmpty {
                        Pill("Look for it") { use("") }
                    }
                    Pill("Choose…") { choose() }
                }
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
