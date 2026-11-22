import SwiftUI

/// The same input on the Ask page and beside a site. Backed by a dedicated
/// native AppKit `NanoComposerField` + isolated `ComposerBuffer` so typing
/// stays buttery 120 FPS without re-rendering the transcript, while bringing
/// NanoHarness ergonomics: rounded accent caret, `/` slash-command completion,
/// `↑`/`↓` prompt recall, `⌘↩` interrupt/send-queued, context ring, and `⌘⇧E`
/// full-page Write mode.
struct AgentComposer: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    @ObservedObject private var composer: ComposerBuffer
    var full = false
    var switchToSearch: (() -> Void)? = nil
    var onShowGuide: (() -> Void)? = nil
    var onReconnect: (() -> Void)? = nil

    var typing: FocusState<Bool>.Binding

    @Environment(\.colorScheme) private var scheme
    @State private var measuredHeight: CGFloat = 34
    @State private var editorFocused = false
    @State private var localFocusToken = 0
    @State private var recall = PromptRecallState()
    @State private var slashSelection = 0
    @State private var slashDismissed = false
    @State private var modelOpenRequest = 0
    @State private var writeHover = false

    init(
        browser: Browser,
        agent: Agent,
        full: Bool = false,
        switchToSearch: (() -> Void)? = nil,
        onShowGuide: (() -> Void)? = nil,
        onReconnect: (() -> Void)? = nil,
        typing: FocusState<Bool>.Binding
    ) {
        self.browser = browser
        self.agent = agent
        self._composer = ObservedObject(wrappedValue: agent.composer)
        self.full = full
        self.switchToSearch = switchToSearch
        self.onShowGuide = onShowGuide
        self.onReconnect = onReconnect
        self.typing = typing
    }

    var body: some View {
        foot
            .onChange(of: browser.agentFocusRequest) { _, _ in
                localFocusToken &+= 1
            }
            .onChange(of: typing.wrappedValue) { _, focused in
                if focused { localFocusToken &+= 1 }
            }
            .onChange(of: agent.chatID) { _, _ in
                recall.reset()
                slashDismissed = false
            }
    }

    // MARK: - slash completion

    /// Active `/` command token when the draft begins with `/` on a single word.
    private var slashQuery: String? {
        guard composer.editingQueueID == nil,
              agent.asking?.isQuestion != true,
              !slashDismissed,
              composer.text.hasPrefix("/")
        else { return nil }
        let rest = String(composer.text.dropFirst())
        if rest.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return rest
    }

    private var slashMatches: [NanoSlashCommand] {
        guard let query = slashQuery else { return [] }
        let all = NanoSlashCommand.catalog(
            agentCommands: agent.commands,
            working: agent.phase == .working,
            full: full
        )
        let needle = query.lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().hasPrefix(needle) || $0.name.lowercased().contains(needle)
        }
    }

    private var slashMenuOpen: Bool { !slashMatches.isEmpty }

    private func acceptSlashCommand(_ command: NanoSlashCommand? = nil) {
        let matches = slashMatches
        guard let chosen = command ?? (matches.indices.contains(slashSelection) ? matches[slashSelection] : matches.first) else { return }
        slashDismissed = false
        slashSelection = 0
        switch chosen.action {
        case .newChat:
            agent.draft = ""
            agent.startOver()
            browser.focusAgent()
        case .model:
            agent.draft = ""
            modelOpenRequest &+= 1
        case .stop:
            agent.draft = ""
            agent.stop()
        case .expand:
            agent.draft = ""
            withAnimation(Motion.gentle) {
                if full { browser.talkToColumn() } else { browser.takeStage() }
            }
        case .writeMode:
            agent.draft = ""
            openWriteMode()
        case .feedback:
            agent.draft = ""
            browser.reportAgentProblem()
        case .reconnect:
            agent.draft = ""
            if let onReconnect { onReconnect() } else { agent.reconnect() }
        case .guide:
            agent.draft = ""
            onShowGuide?()
        case .insert(let prefix):
            agent.draft = prefix
            localFocusToken &+= 1
        }
    }

    private func openWriteMode() {
        guard agent.asking?.isQuestion != true, composer.editingQueueID == nil else { return }
        withAnimation(Motion.quick) { agent.writeMode = true }
    }

    // MARK: - model & context footer

    @ViewBuilder
    private var choices: some View {
        HStack(spacing: 6) {
            if let current = agent.model {
                ModelPicker(agent: agent, current: current, openRequest: modelOpenRequest)
                    .help("Switch model or adjust reasoning effort   /model")
            } else if agent.phase == .starting {
                Text("Loading models…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
            }
        }
        .disabled(agent.phase == .working)
    }

    private var canSubmit: Bool {
        if composer.editingQueueID != nil { return true }
        return AgentFeedbackDraft.command(composer.text) != nil || agent.canSend
    }

    private var contextTab: Tab? {
        guard agent.asking?.isQuestion != true else { return nil }
        if let pinned = agent.pinned { return pinned }
        if !full, let tab = browser.active, !tab.isBlank { return tab }
        return nil
    }

    // MARK: - the foot

    private var foot: some View {
        let radius: CGFloat = full ? 18 : 16
        let minH: CGFloat = full ? 48 : 30
        let maxH: CGFloat = full ? 210 : 156
        let dark = scheme == .dark

        return VStack(alignment: .leading, spacing: 8) {
            if full, agent.pinned == nil, let tab = browser.active, !tab.isBlank, agent.asking == nil {
                Button { agent.pin(tab) } label: {
                    Label("Attach current page", systemImage: "plus")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Attach \(tab.label) to this conversation")
            }
            if let passage = agent.passage {
                AgentPassageCard(passage: passage, remove: { agent.passage = nil }, visit: { browser.open($0, foreground: true) })
                if agent.asking?.isQuestion == true {
                    Text("Your words answer the question. Selected text stays for your next message.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // NanoHarness slash-command completion popover anchored cleanly above the composer.
            if slashMenuOpen {
                slashMenu
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // What was typed while it worked, in the order it will go.
            if !agent.queue.isEmpty {
                QueuePanel(agent: agent, full: full)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // One unified composer card: optional slim page-context header strip
            // docked cleanly above the native 120 FPS text editor, model picker,
            // context ring, write-mode toggle, and send button.
            VStack(alignment: .leading, spacing: 0) {
                if let tab = contextTab {
                    AgentPageContext(tab: tab, agent: agent, embedded: true)
                }

                VStack(alignment: .leading, spacing: full ? 8 : 6) {
                    ZStack(alignment: .topLeading) {
                        if composer.text.isEmpty {
                            Text(prompt)
                                .font(.system(size: full ? 14.5 : 13.5))
                                .foregroundStyle(Palette.muted.opacity(0.7))
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                        NanoComposerField(
                            text: composer.text,
                            revision: composer.revision,
                            fontSize: full ? 14.5 : 13.5,
                            minHeight: minH,
                            maxHeight: maxH,
                            newlinesOnReturn: false,
                            slashMenuOpen: slashMenuOpen,
                            recallingUnchanged: recall.isShowingUnchanged(composer.text),
                            focusRequest: localFocusToken,
                            measuredHeight: $measuredHeight,
                            isFocused: $editorFocused,
                            onTextChange: { newText in
                                slashDismissed = false
                                slashSelection = 0
                                agent.syncDraftFromEditor(newText)
                            },
                            onSubmit: send,
                            onCommandReturn: commandReturn,
                            onSlashMove: { delta in
                                let count = slashMatches.count
                                guard count > 0 else { return }
                                slashSelection = (slashSelection + delta + count) % count
                            },
                            onSlashAccept: { acceptSlashCommand() },
                            onSlashDismiss: { slashDismissed = true },
                            onRecall: stepRecall,
                            onEscape: handleEscape,
                            onToggleWriteMode: openWriteMode,
                            onTab: switchToSearch
                        )
                        .frame(height: max(minH, min(maxH, measuredHeight)))
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { localFocusToken &+= 1 }

                    HStack(spacing: 6) {
                        choices
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let ctx = agent.context, ctx.window > 0 {
                            ContextUsageRing(used: ctx.used, window: ctx.window)
                        }
                        if agent.asking?.isQuestion != true, composer.editingQueueID == nil {
                            Button(action: openWriteMode) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(writeHover ? Palette.ink : Palette.muted.opacity(0.8))
                                    .frame(width: 24, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(writeHover ? Palette.hover : .clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(TactilePress())
                            .onHover { writeHover = $0 }
                            .animation(Motion.quick, value: writeHover)
                            .help("Expand editor   ⌘⇧E")
                            .accessibilityLabel("Expand editor")
                        }
                        actions
                    }
                }
                .padding(.leading, full ? 14 : 11)
                .padding(.trailing, full ? 10 : 8)
                .padding(.top, full ? 12 : 10)
                .padding(.bottom, 8)
            }
            .background(dark ? Color.white.opacity(0.05) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        editorFocused
                            ? Palette.accent.opacity(dark ? 0.55 : 0.45)
                            : (dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(dark ? 0.22 : 0.045), radius: 3, y: 1)
            .shadow(color: .black.opacity(dark ? 0.20 : 0.055), radius: 14, y: 5)
            .animation(Motion.quick, value: editorFocused)
        }
        .animation(Motion.quick, value: slashMenuOpen)
        .animation(Motion.settle, value: agent.queue.map(\.id))
        .padding(.horizontal, full ? 12 : 14)
        .padding(.top, full ? 4 : 6)
        .padding(.bottom, full ? 12 : 14)
    }

    private var slashMenu: some View {
        let matches = slashMatches
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(matches.prefix(7).enumerated()), id: \.element.id) { index, cmd in
                let lit = index == min(slashSelection, max(0, matches.count - 1))
                Button { acceptSlashCommand(cmd) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cmd.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(lit ? Palette.accent : Palette.muted)
                            .frame(width: 16)
                        Text("/\(cmd.name)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                        Text(cmd.description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(lit ? Palette.hover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { over in if over { slashSelection = index } }
            }
        }
        .padding(5)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
    }

    private var actions: some View {
        HStack(spacing: 5) {
            if composer.editingQueueID != nil {
                round(icon: "checkmark", help: "Save to queue   ↩", live: true, act: send)
            } else if AgentFeedbackDraft.command(composer.text) != nil {
                round(icon: "arrow.up", help: "Review feedback", live: true, act: send)
            } else if agent.phase == .working, agent.asking?.isQuestion != true {
                round(icon: "stop.fill", help: "Stop", live: composer.text.isEmpty) { agent.stop() }
                if !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    round(icon: "arrow.up", help: "Queue   ↩  ·  Interrupt & send now   ⌘↩", live: true, act: send)
                }
            } else {
                round(icon: "arrow.up", help: "Send   ↩", live: canSubmit, act: send)
                    .disabled(!canSubmit)
            }
        }
    }

    private var prompt: String {
        if composer.editingQueueID != nil { return "Edit queued message…" }
        if agent.asking?.isQuestion == true { return "Answer Codegraff" }
        if agent.phase == .working { return full ? "Queue a follow-up (⌘↩ to interrupt)…" : "Queue a follow-up…" }
        return !full && agent.withPage && browser.active?.isBlank == false ? "Ask about this page…" : "Do anything…"
    }

    private func round(icon: String, help: String, live: Bool, act: @escaping () -> Void) -> some View {
        let size: CGFloat = full ? 30 : 27
        return Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: full ? 11.5 : 10.5, weight: .bold))
                .foregroundStyle(live ? Palette.onAccent : Palette.muted)
                .frame(width: size, height: size)
                .background(live ? Palette.accent : Palette.wash, in: Circle())
        }
        .buttonStyle(TactilePress())
        .accessibilityLabel(help)
        .animation(Motion.snappy, value: live)
        .help(help)
    }

    private func stepRecall(_ delta: Int) {
        guard composer.editingQueueID == nil, agent.asking?.isQuestion != true else { return }
        if let replacement = recall.step(delta: delta, currentText: composer.text, history: agent.sessionPrompts) {
            agent.draft = replacement
        }
    }

    private func handleEscape() {
        if composer.editingQueueID != nil {
            agent.cancelQueueEdit()
            localFocusToken &+= 1
        }
    }

    private func send() {
        guard canSubmit else { return }
        recall.reset()
        slashDismissed = false
        agent.send(page: agent.withPage && !full ? browser.active : nil)
        if browser.agentFeedback == nil { localFocusToken &+= 1 }
    }

    private func commandReturn() {
        recall.reset()
        slashDismissed = false
        agent.sendInterrupt(page: agent.withPage && !full ? browser.active : nil)
        if browser.agentFeedback == nil { localFocusToken &+= 1 }
    }
}

/// NanoHarness compact context ring + tabular percentage (`DESIGN.md` / `view_session_footer.zig`):
/// muted below 80%, warm warning at 80%+, danger at 95%+.
struct ContextUsageRing: View {
    let used: Int
    let window: Int

    private var ratio: Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(window)))
    }

    private var percent: Int { Int((ratio * 100).rounded()) }

    private var ringColor: Color {
        if ratio >= 0.95 { return Color(red: 0.88, green: 0.30, blue: 0.30) }
        if ratio >= 0.80 { return Color(red: 0.92, green: 0.62, blue: 0.18) }
        return Palette.muted
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Palette.ink.opacity(0.12), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: max(0.03, ratio))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)

            Text("\(percent)%")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(ratio >= 0.80 ? ringColor : Palette.muted.opacity(0.85))
                .monospacedDigit()
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .help("Context window: \(Self.formatTokens(used)) / \(Self.formatTokens(window)) tokens (\(percent)%)")
        .accessibilityLabel("Context window \(percent) percent used")
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// NanoHarness full-page Write editor (`⌘⇧E`, matching `view_write.zig`):
/// edits the exact same `ComposerBuffer` draft on a distraction-free canvas.
/// Enter inserts a newline; ⌘↩ sends; Esc or ⌘⇧E returns to the chat.
struct NanoWritePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    @ObservedObject private var composer: ComposerBuffer
    let full: Bool
    let close: () -> Void

    @State private var measuredHeight: CGFloat = 240
    @State private var editorFocused = true
    @State private var focusToken = 1

    init(browser: Browser, agent: Agent, full: Bool, close: @escaping () -> Void) {
        self.browser = browser
        self.agent = agent
        self._composer = ObservedObject(wrappedValue: agent.composer)
        self.full = full
        self.close = close
    }

    private var words: Int { NanoSlashCommand.wordCount(composer.text) }
    private var canSend: Bool { !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ZStack {
                if !full { DragStrip() }
                HStack(spacing: 8) {
                    Button(action: close) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(TactilePress())
                    .help("Return to composer   Esc")

                    Spacer(minLength: 4)

                    Text(words == 1 ? "1 word" : "\(words) words")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Button(action: sendFromWrite) {
                        HStack(spacing: 5) {
                            Text("Send")
                                .font(.system(size: 12, weight: .medium))
                            Text("⌘↩")
                                .font(.system(size: 10.5, weight: .medium))
                                .opacity(0.8)
                        }
                        .foregroundStyle(canSend ? Palette.onAccent : Palette.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(canSend ? Palette.accent : Palette.wash, in: Capsule())
                    }
                    .buttonStyle(TactilePress())
                    .disabled(!canSend)
                    .help("Send draft   ⌘↩")
                }
                .padding(.horizontal, full ? 20 : 14)
            }
            .frame(height: full ? 48 : Metrics.strip)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }

            // Full-height writing canvas
            GeometryReader { geo in
                let maxW: CGFloat = full ? 720 : .infinity
                ZStack(alignment: .topLeading) {
                    if composer.text.isEmpty {
                        Text("Do anything…")
                            .font(.system(size: full ? 17 : 15))
                            .foregroundStyle(Palette.muted.opacity(0.6))
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                    NanoComposerField(
                        text: composer.text,
                        revision: composer.revision,
                        fontSize: full ? 17 : 15,
                        minHeight: max(180, geo.size.height - 32),
                        maxHeight: max(180, geo.size.height - 32),
                        newlinesOnReturn: true,
                        slashMenuOpen: false,
                        recallingUnchanged: false,
                        focusRequest: focusToken,
                        measuredHeight: $measuredHeight,
                        isFocused: $editorFocused,
                        onTextChange: { agent.syncDraftFromEditor($0) },
                        onSubmit: {},
                        onCommandReturn: sendFromWrite,
                        onSlashMove: { _ in },
                        onSlashAccept: {},
                        onSlashDismiss: {},
                        onRecall: { _ in },
                        onEscape: close,
                        onToggleWriteMode: close
                    )
                    .frame(maxWidth: maxW, maxHeight: .infinity)
                }
                .padding(.horizontal, full ? 32 : 16)
                .padding(.vertical, 16)
                .frame(maxWidth: maxW, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.ground)
        .onAppear { focusToken &+= 1 }
    }

    private func sendFromWrite() {
        guard canSend else { return }
        agent.send(page: agent.withPage && !full ? browser.active : nil)
        if agent.draft.isEmpty { close() }
    }
}
