import SwiftUI

/// The same input on the Ask page and beside a site. The draft belongs to
/// Agent, so expanding the column never leaves what was typed behind.
struct AgentComposer: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    var full = false
    var switchToSearch: (() -> Void)? = nil

    var typing: FocusState<Bool>.Binding

    var body: some View {
        foot
    }

    /// Under the field: unified model + reasoning chip. Always visible (never
    /// hidden when the text field loses focus, so the popover stays anchored
    /// while searching or picking models).
    @ViewBuilder
    private var choices: some View {
        HStack(spacing: 6) {
            if let current = agent.model {
                ModelPicker(agent: agent, current: current)
                    .help("Switch model or adjust reasoning effort")
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
        AgentFeedbackDraft.command(agent.draft) != nil || agent.canSend
    }

    private var contextTab: Tab? {
        guard agent.asking?.isQuestion != true else { return nil }
        if let pinned = agent.pinned { return pinned }
        if !full, let tab = browser.active, !tab.isBlank { return tab }
        return nil
    }

    // MARK: - the foot

    private var foot: some View {
        let radius: CGFloat = full ? 18 : 14
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
            // What was typed while it worked, in the order it will go.
            if !agent.queue.isEmpty {
                QueuePanel(agent: agent, full: full)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // One unified composer card: optional slim page-context header strip
            // docked cleanly above the text field, model picker, and send button.
            VStack(alignment: .leading, spacing: 0) {
                if let tab = contextTab {
                    AgentPageContext(tab: tab, agent: agent, embedded: true)
                }

                VStack(alignment: .leading, spacing: full ? 10 : 8) {
                    ZStack(alignment: .topLeading) {
                        if agent.draft.isEmpty {
                            Text(prompt)
                                .foregroundStyle(Palette.muted.opacity(0.7))
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $agent.draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1...8)
                            .focused(typing)
                            .onSubmit(send)
                            .onKeyPress(.tab) {
                                guard let switchToSearch else { return .ignored }
                                switchToSearch()
                                return .handled
                            }
                            .accessibilityLabel("Message Codegraff")
                    }
                    .font(.system(size: full ? 14.5 : 13.5))
                    .frame(maxWidth: .infinity, minHeight: full ? 52 : 34, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { typing.wrappedValue = true }

                    HStack(spacing: 8) {
                        choices
                            .frame(maxWidth: .infinity, alignment: .leading)
                        actions
                    }
                }
                .padding(.leading, full ? 14 : 11)
                .padding(.trailing, full ? 10 : 8)
                .padding(.top, full ? 12 : 10)
                .padding(.bottom, 8)
            }
            .background(full ? Palette.ground : Palette.ink.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        typing.wrappedValue ? Palette.accent.opacity(full ? 0.45 : 0.4) : Palette.ink.opacity(0.11),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(full ? 0.04 : 0), radius: 8, y: 2)
            .animation(Motion.quick, value: typing.wrappedValue)
        }
        .animation(Motion.settle, value: agent.queue.map(\.id))
        .padding(.horizontal, full ? 12 : 14)
        .padding(.top, full ? 4 : 6)
        .padding(.bottom, full ? 12 : 14)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if AgentFeedbackDraft.command(agent.draft) != nil {
                round(icon: "arrow.up", help: "Review feedback", live: true, act: send)
            } else if agent.phase == .working, agent.asking?.isQuestion != true {
                round(icon: "stop.fill", help: "Stop", live: agent.draft.isEmpty) { agent.stop() }
                if !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    round(icon: "arrow.up", help: "Queue message   ↩", live: true, act: send)
                }
            } else {
                round(icon: "arrow.up", help: "Send   ↩", live: canSubmit, act: send)
                    .disabled(!canSubmit)
            }
        }
    }

    private var prompt: String {
        if agent.asking?.isQuestion == true { return "Answer Codegraff" }
        if agent.phase == .working { return full ? "Type a follow-up to queue…" : "Queue a follow-up…" }
        return !full && agent.withPage && browser.active?.isBlank == false ? "Ask about this page…" : "Ask Codegraff…"
    }

    /// The send (or stop) button: the accent once there's something to
    /// send, a quiet grey until then.
    private func round(icon: String, help: String, live: Bool, act: @escaping () -> Void) -> some View {
        let size: CGFloat = full ? 32 : 28
        return Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: full ? 11.5 : 11, weight: .bold))
                .foregroundStyle(live ? Palette.onAccent : Palette.muted)
                .frame(width: size, height: size)
                .background(live ? Palette.accent : Palette.wash, in: Circle())
        }
        .buttonStyle(TactilePress())
        .accessibilityLabel(help)
        .animation(Motion.snappy, value: live)
        .help(help)
    }

    private func send() {
        guard canSubmit else { return }
        agent.send(page: agent.withPage && !full ? browser.active : nil)
        if browser.agentFeedback == nil { browser.focusAgent() }
    }

}
