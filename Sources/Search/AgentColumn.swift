import SwiftUI

/// Codegraff, down the right of the window (see Agent.swift for what it is
/// talking to). The same ground, hairline and pills as the rest of the app:
/// what was said, in order, a question when graff has one, and a field at
/// the foot. The page you are on goes with what you type unless you take it
/// off.
struct AgentColumn: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    @ObservedObject var prefs: Preferences

    @FocusState private var typing: Bool
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    var body: some View {
        VStack(spacing: 0) {
            head
            Rectangle().fill(Palette.hairline).frame(height: 1)
            said
            if let ask = agent.asking {
                AskCard(ask: ask) { agent.answer(ask, with: $0) }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            foot
        }
        .frame(width: prefs.agentWidth)
        .frame(maxHeight: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .overlay(alignment: .leading) { edge }
        .animation(Motion.settle, value: agent.asking?.id)
        .onAppear {
            agent.wake()
            DispatchQueue.main.async { typing = true }
        }
    }

    // MARK: - the head

    private var head: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(light)
                .frame(width: 6, height: 6)
            Text("Codegraff")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if !agent.phase.words.isEmpty {
                Text(agent.phase.words)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Door(icon: "square.and.pencil", help: "New conversation") { agent.startOver() }
                .disabled(agent.entries.isEmpty)
            Door(icon: "xmark", help: "Close   ⇧⌘A") { browser.toggleAgent() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
    }

    /// Under the field: the model it is on and how hard it thinks, each a
    /// menu of what graff offers — the models its keys reach, the levels
    /// that model takes (as Harness asks graff for them).
    @ViewBuilder
    private var choices: some View {
        HStack(spacing: 10) {
            if let current = agent.model {
                Menu {
                    ForEach(agent.models) { model in
                        Button {
                            agent.choose(model)
                        } label: {
                            let words = model.context > 0 ? "\(model.label) · \(model.provider) · \(model.context / 1000)k" : "\(model.label) · \(model.provider)"
                            if model == current {
                                Label(words, systemImage: "checkmark")
                            } else {
                                Text(words)
                            }
                        }
                    }
                } label: {
                    Text(current.label)
                }
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
                    Text("Reasoning: \(effort.currentName)")
                }
                .help("How hard it thinks before it answers")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.muted)
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(agent.phase == .working)
        .padding(.horizontal, 4)
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

    /// Everything said, in order, with the pages graff read in a row kept
    /// together on one card. A plain stack, not a lazy one: a lazy stack
    /// guesses the height of what it hasn't drawn, and with a reply growing
    /// at the bottom every guess moved the whole column.
    private var said: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if agent.entries.isEmpty { empty }
                ForEach(Agent.grouped(agent.entries), id: \.first?.id) { run in
                    if run.first?.kind == .page {
                        PagesCard(pages: run) { url in browser.open(url, foreground: true) }
                    } else if let entry = run.first {
                        EntryRow(entry: entry) { url in browser.open(url, foreground: true) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: .infinity)
    }

    /// What there is before anything has been said: how to start, or what
    /// is in the way of starting.
    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch agent.phase {
            case .missing:
                Text("Codegraff isn't on this Mac")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("Search runs the `graff` command it installs. Get it, or show Search where yours is in Settings › Agent.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Pill("Get Codegraff", filled: true) {
                        browser.open(Agent.download, foreground: true)
                    }
                    Pill("Try again") { agent.restart() }
                }
            case .signedOut:
                Text("Sign in to Codegraff")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("`graff login` opens in Terminal. Come back here once it says you're in.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Pill("Sign in…", filled: true) { agent.signIn() }
                    Pill("I've signed in") { agent.restart() }
                }
            case .broken(let why):
                Text("Codegraff stopped")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Pill("Start it again", filled: true) { agent.restart() }
            default:
                Text("Ask about the page you're on, or give Codegraff something to do on your Mac. It runs commands and edits files without stopping to ask.")
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
            if let tab = browser.active, !tab.isBlank, agent.asking?.isQuestion != true {
                pageChip(tab)
            }
            HStack(alignment: .bottom, spacing: 8) {
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
                .font(.system(size: 13))
                if agent.phase == .working, agent.asking?.isQuestion != true {
                    round(icon: "stop.fill", help: "Stop") { agent.stop() }
                } else {
                    round(icon: "arrow.up", help: "Send   ↩") { send() }
                        .disabled(!agent.canSend)
                        .opacity(agent.canSend ? 1 : 0.35)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            choices
        }
        .padding(.horizontal, 12)
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

    private func round(icon: String, help: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ground)
                .frame(width: 24, height: 24)
                .background(Palette.ink, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func send() {
        guard agent.canSend else { return }
        agent.send(page: agent.withPage ? browser.active : nil)
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

/// One thing said, by you or by it, or one thing it did.
private struct EntryRow: View {
    let entry: Agent.Entry
    let visit: (URL) -> Void
    @State private var open = false

    init(entry: Agent.Entry, visit: @escaping (URL) -> Void) {
        self.entry = entry
        self.visit = visit
    }

    /// A tool's name as graff gives it, said the way a person would.
    private var said: String {
        let prefix = "mcp__search__"
        guard entry.text.hasPrefix(prefix) else { return entry.text }
        let tool = String(entry.text.dropFirst(prefix.count))
        return [
            "search": "Searching the web", "read_pages": "Reading pages", "open": "Opening a page",
            "read": "Reading the page", "links": "Looking at the links", "go": "Going to a page",
            "back": "Going back", "forward": "Going forward", "reload": "Reloading",
            "click": "Clicking", "type": "Typing", "submit": "Submitting a form",
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
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 28)
        case .reply:
            Text(Agent.rich(entry.text))
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .thought:
            Button { open.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
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
    private var icon: String {
        let title = entry.text.lowercased()
        if title.contains("search__") || title.hasPrefix("search.") || title.hasPrefix("search:") { return "safari" }
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
                "Codegraff beside the page",
                "A column on the right where Codegraff reads the page you're on and works on your Mac with all its tools — commands, file edits, codedb — without stopping to ask. ⇧⌘A shows and hides it; ⌘↩ in the address field asks it"
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
            Line("graff", location) {
                HStack(spacing: 6) {
                    if !prefs.agentPath.isEmpty {
                        Pill("Look for it") { use("") }
                    }
                    Pill("Choose…") { choose() }
                }
            }
            Rule()
            Line("Sign in", "graff login, in Terminal — a Codegraff account, or Codex, Kimi and the others it knows") {
                Pill("Sign in…") { agent.signIn() }
            }
        }
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
