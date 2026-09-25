import SwiftUI

/// Codegraff's page, where the Ask tab opens before anything has been said:
/// the mark, one field that either asks or goes somewhere — Tab switches
/// which — and the chats so far, a card each, to pick one back up.
///
/// The address field on an empty tab and ⌘L are untouched by any of this;
/// this is the agent's own page, a tab of its own.
struct AgentHome: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    @ObservedObject var chats: Chats

    enum Mode { case search, ask }

    @State private var mode: Mode = .ask
    @State private var typed = ""
    @State private var everything = false
    @State private var shake: CGFloat = 0
    @FocusState private var focused: Bool

    init(browser: Browser, agent: Agent) {
        self.browser = browser
        self.agent = agent
        self.chats = agent.chats
    }

    /// As wide as the field and the row of cards under it get.
    private static let measure: CGFloat = 860

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 56)
                    BrandMark()
                        .frame(width: 64, height: 64)
                        .padding(.bottom, 40)
                    field
                        .frame(maxWidth: Self.measure - 120)
                    if mode == .ask {
                        AgentNotice(browser: browser, agent: agent)
                            .frame(maxWidth: Self.measure - 120, alignment: .leading)
                            .padding(.top, 14)
                    }
                    Spacer(minLength: 56)
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
        .onAppear { DispatchQueue.main.async { focused = true } }
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
                    mode = mode == .ask ? .search : .ask
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
            switcher
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
            focused = true
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
                if chats.all.count > 3 {
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16) {
                    ForEach(everything ? chats.all : Array(chats.all.prefix(3))) { chat in
                        ChatCard(chat: chat) {
                            agent.resume(chat)
                        } forget: {
                            agent.forget(chat)
                        }
                    }
                }
            }
        }
    }
}

/// One conversation: when, what it was about, and how it ended — the reply
/// it got, or what went wrong.
private struct ChatCard: View {
    let chat: Chat
    let open: () -> Void
    let forget: () -> Void

    @State private var hovering = false

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Text(abs(chat.updated.timeIntervalSinceNow) < 60 ? "Just now" : Self.ago.localizedString(for: chat.updated, relativeTo: Date()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Text(chat.title.isEmpty ? "Untitled" : chat.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let failed = chat.failed {
                    trouble(failed)
                        .padding(.top, 6)
                } else {
                    Text(Agent.rich(Self.flat(chat.gist)))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink.opacity(0.62))
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // Links in the gist are for the chat, not the card.
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 200, alignment: .topLeading)
            .clipped()
            .background(hovering ? Palette.wash : Palette.hover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            Button("Delete Chat", role: .destructive, action: forget)
        }
        .help(chat.title)
    }

    private func trouble(_ why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Codegraff couldn't finish this")
                    .font(.system(size: 12.5, weight: .medium))
                Text(why)
                    .font(.system(size: 12))
                    .opacity(0.8)
                    .lineLimit(3)
            }
        }
        .foregroundStyle(Color.red.opacity(0.85))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.red.opacity(0.25), lineWidth: 1))
    }

    /// A reply's lines run together for a card: its bullets become a run of
    /// clauses, its headings plain words.
    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var line = line.trimmingCharacters(in: .whitespaces)
                while line.hasPrefix("#") { line.removeFirst() }
                if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { line = "· " + line.dropFirst(2) }
                return line.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
            .joined(separator: " ")
            // A reply that opens with a list shouldn't open with its dot.
            .replacingOccurrences(of: #"^· "#, with: "", options: .regularExpression)
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
                words("Sign in to Codegraff", "`graff login` opens in Terminal. Come back here once it says you're in.")
                HStack(spacing: 6) {
                    Pill("Sign in…", filled: true) { agent.signIn() }
                    Pill("I've signed in") { agent.restart() }
                }
            case .broken(let why):
                words("Codegraff stopped", why)
                Pill("Start it again", filled: true) { agent.restart() }
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
