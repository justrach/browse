import SwiftUI

extension Agent {
    enum TaskState: Equatable {
        case idle, starting, working, answer, approval, finished, stopped, interrupted(String), signedOut, missing

        var words: String {
            switch self {
            case .idle: return "Ready to help"
            case .starting: return "Connecting…"
            case .working: return "Working"
            case .answer: return "Needs your answer"
            case .approval: return "Needs your approval"
            case .finished: return "Finished"
            case .stopped: return "Ready to continue"
            case .interrupted: return "Interrupted"
            case .signedOut: return "Sign in to continue"
            case .missing: return "Codegraff isn't installed"
            }
        }
    }

    var taskState: TaskState {
        if let asking { return asking.isQuestion ? .answer : .approval }
        switch phase {
        case .starting: return .starting
        case .working: return .working
        case .broken(let why): return .interrupted(why)
        case .signedOut: return .signedOut
        case .missing: return .missing
        case .ready, .asleep:
            switch outcome {
            case .finished: return .finished
            case .stopped: return .stopped
            case .interrupted(let why): return .interrupted(why)
            case nil: return .idle
            }
        }
    }

    var currentAction: String {
        if let running = entries.last(where: { $0.kind == .tool && ["pending", "in_progress"].contains($0.status) }) {
            return running.text
        }
        return entries.last?.kind == .reply ? "Writing the response…" : "Preparing the next step…"
    }
}

/// A persistent place to see why work paused and what can happen next.
struct AgentTaskStateView: View {
    @ObservedObject var agent: Agent
    let focus: () -> Void

    private var state: Agent.TaskState { agent.taskState }

    var body: some View {
        if state != .idle && !agent.entries.isEmpty {
            HStack(alignment: .center, spacing: 9) {
                if state == .working || state == .starting {
                    Ring(size: 10)
                } else {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.words).fontWeight(.medium)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .lineLimit(2).help(detail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                action
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
            .padding(10)
            .background(Palette.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    private var detail: String? {
        switch state {
        case .working: return agent.currentAction
        case .answer, .approval: return agent.asking?.title
        case .interrupted(let why): return why
        case .stopped: return agent.queue.isEmpty ? "Send a follow-up when you're ready." : "Queued follow-ups wait for your next send."
        default: return nil
        }
    }

    private var icon: String {
        switch state {
        case .answer: return "bubble.left"
        case .approval: return "hand.raised"
        case .finished: return "checkmark.circle"
        case .stopped: return "pause.circle"
        case .interrupted: return "exclamationmark.circle"
        default: return "person.crop.circle"
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .working: control("Stop") { agent.stop() }
        case .answer: control("Answer") { focus() }
        case .approval: Text("Review below").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
        case .interrupted: control("Reconnect") { agent.reconnect() }
        case .signedOut: control("Sign in") { agent.signIn() }
        case .finished: control("Follow up") { focus() }
        case .stopped:
            control("Continue") {
                if agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    agent.draft = "Continue from where you stopped."
                }
                focus()
            }
        default: EmptyView()
        }
    }

    private func control(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.accent)
            .fixedSize()
            .padding(.vertical, 5)
    }
}
