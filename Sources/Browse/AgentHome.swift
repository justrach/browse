import SwiftUI

/// Codegraff's page, where the Ask tab opens before anything has been said:
/// a place to start a task and return to a conversation. It uses the same
/// composer as the column, so model choices and multiline drafts stay put.
///
/// The address field on an empty tab and ⌘L are untouched by any of this;
/// this is the agent's own page, a tab of its own.
struct AgentHome: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    @ObservedObject var chats: Chats

    var typing: FocusState<Bool>.Binding

    enum Mode { case search, ask }

    @State private var mode: Mode = .ask
    @State private var typed = ""
    @State private var everything = false
    /// What the chats are being searched for.
    @State private var looking = ""
    @State private var renaming: Chat?
    @State private var shake: CGFloat = 0
    @FocusState private var focused: Bool

    init(browser: Browser, agent: Agent, typing: FocusState<Bool>.Binding) {
        self.browser = browser
        self.agent = agent
        self.chats = agent.chats
        self.typing = typing
    }

    /// As wide as the field and the row of cards under it get.
    private static let measure: CGFloat = 860

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    BrandMark()
                        .frame(width: 44, height: 44)
                        .padding(.bottom, 20)
                    Text("What would you like to explore?")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    Text("Research an idea, compare sources, or pick up where you left off.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    Text("On a page, press . to ask beside it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.bottom, 14)
                    switcher
                        .padding(.bottom, 12)
                    if mode == .ask {
                        AgentComposer(browser: browser, agent: agent, full: true, switchToSearch: { mode = .search; focused = true }, typing: typing)
                            .frame(maxWidth: Metrics.chat)
                        AgentStarters(agent: agent, focus: browser.focusAgent)
                            .frame(maxWidth: Metrics.chat)
                    } else {
                        field
                            .frame(maxWidth: Metrics.chat)
                    }
                    if mode == .ask {
                        AgentNotice(browser: browser, agent: agent)
                            .frame(maxWidth: Self.measure - 120, alignment: .leading)
                            .padding(.top, 14)
                    }
                    Spacer(minLength: 36)
                    recent
                        .frame(maxWidth: Self.measure)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
            .scrollIndicators(.never)
        }
        .background(Palette.ground)
        .modifier(ChatRenamer(chats: chats, chat: $renaming))
        .animation(Motion.settle, value: everything)
        .animation(Motion.quick, value: mode)
    }

    // MARK: - the field

    private var field: some View {
        HStack(spacing: 12) {
            TextField("", text: $typed, prompt: Text(mode == .ask ? "Ask anything, or give Codegraff a task" : "Search or type a URL")
                .foregroundStyle(Palette.muted.opacity(0.8)))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .onSubmit(go)
                .onKeyPress(.tab) {
                    mode = .ask
                    browser.focusAgent()
                    return .handled
                }
            HStack(spacing: 6) {
                Text("Tab")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("to switch")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .fixedSize()
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
        .modifier(Shake(travel: shake))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    /// Search or Ask, the one chosen raised a shade.
    private var switcher: some View {
        HStack(spacing: 2) {
            segment("Search", .search)
            segment("Ask", .ask)
        }
        .padding(3)
        .background(Palette.ground.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .fixedSize()
    }

    private func segment(_ title: String, _ which: Mode) -> some View {
        Button {
            mode = which
            if which == .search { focused = true } else { browser.focusAgent() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: mode == which ? .medium : .regular))
                .foregroundStyle(mode == which ? Palette.ink : Palette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if mode == which {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.wash)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func go() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch mode {
        case .search:
            guard browser.visit(text) else { refuse(); return }
            typed = ""
        case .ask:
            agent.draft = text
            guard agent.canSend else { refuse(); return }
            typed = ""
            // Nothing behind this page to talk about: the words go alone.
            agent.send(page: nil)
        }
    }

    private func refuse() {
        shake = 0
        withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
    }

    // MARK: - the chats so far

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chats")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer(minLength: 0)
                // Past a row of them, a way to find one.
                if !chats.all.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                        TextField("", text: $looking, prompt: Text("Search chats").foregroundStyle(Palette.muted.opacity(0.8)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 220)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                }
                if chats.all.count > 4, looking.isEmpty {
                    Button { everything.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(everything ? "Fewer" : "All Chats")
                            Image(systemName: everything ? "chevron.up" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if chats.all.isEmpty {
                Text("What you ask Codegraff is kept here, a card for each conversation, to pick up again.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.vertical, 20)
            } else {
                let found = chats.ordered.filter { $0.mentions(looking) }
                let shown = everything || !looking.isEmpty ? found : Array(found.prefix(4))
                if shown.isEmpty {
                    Text("No chat mentions “\(looking)”.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.vertical, 20)
                }
                VStack(spacing: 4) {
                    ForEach(shown) { chat in
                        ChatRow(chat: chat) {
                            agent.resume(chat)
                            browser.focusAgent()
                        }
                        .contextMenu { ChatMenu(chat: chat, agent: agent) { renaming = chat } }
                    }
                }
            }
        }
    }
}

/// The same compact conversation row on the Ask page and in its history.
private struct ChatRow: View {
    let chat: Chat
    let open: () -> Void
    @State private var hovering = false

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: chat.isPinned ? "pin.fill" : "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.title.isEmpty ? "Untitled" : chat.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(Agent.rich(chat.failed ?? Self.preview(chat.gist)))
                        .font(.system(size: 12))
                        .foregroundStyle(chat.failed == nil ? Palette.muted : .red.opacity(0.85))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(abs(chat.updated.timeIntervalSinceNow) < 60 ? "Now" : Self.ago.localizedString(for: chat.updated, relativeTo: Date()))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .fixedSize()
            }
            .padding(12)
            .background(hovering ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(chat.title)
    }

    private static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { line in
            var words = line.trimmingCharacters(in: .whitespaces)
            while words.hasPrefix("#") { words.removeFirst() }
            return words.trimmingCharacters(in: .whitespaces)
        }.joined(separator: " ")
    }
}

/// Starting points fill a draft, leaving the question editable before Send.
struct AgentStarters: View {
    @ObservedObject var agent: Agent
    var page: Tab? = nil
    var compact = false
    var focus: () -> Void

    private var hasPage: Bool { page?.isBlank == false }
    private var prompts: [(String, String, String)] {
        hasPage ? [
            ("Summarize this page", "doc.text", "Summarize this page and highlight its key takeaways."),
            ("Check a claim", "checkmark.shield", "Help me check a claim on this page. Ask which claim, then look for independent sources."),
            ("Find related sources", "text.magnifyingglass", "Find useful sources related to this page and explain what each adds.")
        ] : [
            ("Research a topic", "text.magnifyingglass", "Help me research a topic. Ask what I want to explore, then gather and compare sources."),
            ("Compare sources", "doc.on.doc", "Help me compare sources. Ask what I am comparing and which criteria matter."),
            ("Explore an idea", "sparkles", "Help me explore an idea. Ask what I have in mind and what I want to understand.")
        ]
    }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) { buttons }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
    }

    private var buttons: some View {
        ForEach(prompts, id: \.0) { title, icon, prompt in
            Button { agent.draft = prompt; focus() } label: {
                Label(title, systemImage: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Chats stay reachable without leaving the page or widening the column.
struct AgentHistoryButton: View {
    @ObservedObject var agent: Agent
    @ObservedObject private var chats: Chats
    let focus: () -> Void
    @State private var open = false
    @State private var looking = ""
    @State private var renaming: Chat?

    init(agent: Agent, focus: @escaping () -> Void) {
        self.focus = focus
        self.agent = agent
        self.chats = agent.chats
    }

    var body: some View {
        Door(icon: "clock.arrow.circlepath", help: "Recent conversations") { open.toggle() }
            .accessibilityLabel("Recent conversations")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Conversations")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    TextField("Search conversations", text: $looking)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(10)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            let found = chats.ordered.filter { $0.mentions(looking) }
                            if found.isEmpty {
                                Text(chats.all.isEmpty ? "Your conversations will appear here." : "No conversations found.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.vertical, 24)
                            }
                            ForEach(found) { chat in
                                ChatRow(chat: chat) {
                                    agent.resume(chat)
                                    open = false
                                    focus()
                                }
                                .contextMenu { ChatMenu(chat: chat, agent: agent) { renaming = chat } }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: 340, height: 420)
                .background(Palette.ground)
                .modifier(ChatRenamer(chats: chats, chat: $renaming))
            }
    }
}

/// What is in the way of talking to Codegraff, if anything: it isn't on
/// this Mac, nobody is signed in, or it stopped. Nothing when all is well.
struct AgentNotice: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch agent.phase {
            case .missing:
                words("Codegraff isn't on this Mac", "Search runs the `graff` command it installs. Get it, or show Search where yours is in Settings › Agent.")
                HStack(spacing: 6) {
                    Pill("Get Codegraff", filled: true) { browser.open(Agent.download, foreground: true) }
                    Pill("Try again") { agent.restart() }
                }
            case .signedOut:
                words("Sign in to Codegraff", "Approve this Mac on codegraff.com. The page opens here, and sign-in finishes automatically.")
                HStack(spacing: 6) {
                    Pill("Sign in on the web", filled: true) { agent.signIn() }
                    Pill("I've signed in") { agent.restart() }
                }
            case .broken(let why):
                words("Codegraff stopped", why)
                Pill("Reconnect", filled: true) { agent.reconnect() }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func words(_ title: String, _ detail: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
        Text(Agent.rich(detail))
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What can be done to a chat wherever it's listed — on the Ask page and in
/// the sidebar: renamed, pinned to the top, or deleted.
struct ChatMenu: View {
    let chat: Chat
    let agent: Agent
    let rename: () -> Void

    var body: some View {
        Button("Rename…", action: rename)
        Button(chat.isPinned ? "Unpin" : "Pin to Top") { agent.chats.pin(chat.id, !chat.isPinned) }
        Divider()
        Button("Delete Chat", role: .destructive) { agent.forget(chat) }
    }
}

/// Asks what a chat should be called. Left empty, it's named after the
/// first thing asked again.
struct ChatRenamer: ViewModifier {
    let chats: Chats
    @Binding var chat: Chat?

    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Chat", isPresented: Binding(get: { chat != nil }, set: { if !$0 { chat = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") {
                    if let chat { chats.rename(chat.id, to: name) }
                    chat = nil
                }
                Button("Cancel", role: .cancel) { chat = nil }
            } message: {
                Text("Leave it empty to name it after the first thing asked.")
            }
            .onChange(of: chat?.id) { _, _ in name = chat?.title ?? "" }
    }
}
