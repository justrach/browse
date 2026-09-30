import Foundation

/// A report starts with the person's description. No conversation or page
/// is collected; the GitHub draft is reviewed before it is submitted.
struct AgentFeedbackDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case stalled = "Stopped responding"
        case answer = "Incorrect answer"
        case action = "Browser action failed"
        case suggestion = "Suggestion"
        var id: String { rawValue }
    }

    let id = UUID()
    var kind: Kind = .stalled
    var details = ""
    var expected = ""

    var ready: Bool { !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var title: String { "Agent: " + kind.rawValue.lowercased() }
    var report: String {
        var text = "## What happened\n\n" + details.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty { text += "\n\n## What I expected\n\n" + wanted }
        return text
    }

    /// A local command, available even when graff is busy or disconnected.
    /// Similar names and mentions inside a message remain ordinary prompts.
    static func command(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/feedback") else { return nil }
        let tail = text.dropFirst("/feedback".count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
