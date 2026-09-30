import Foundation
import Combine

/// Instructions somebody chose to keep, separate from conversations and
/// never scheduled or sent just because they are saved.
struct AgentTask: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var prompt: String

    func mentions(_ text: String) -> Bool {
        text.isEmpty || title.localizedCaseInsensitiveContains(text) || prompt.localizedCaseInsensitiveContains(text)
    }

    static let examples: [AgentTask] = [
        AgentTask(id: UUID(uuidString: "CC001001-0000-4000-8000-000000000001")!, title: "Compare options", prompt: "Help me compare options. Ask what I am choosing between and which criteria matter. Use current primary sources, link to the evidence, and explain trade-offs and anything still uncertain."),
        AgentTask(id: UUID(uuidString: "CC001001-0000-4000-8000-000000000002")!, title: "Check the evidence", prompt: "Help me check a claim. Ask which claim I want to investigate, then find independent primary sources. Separate what the evidence supports from assumptions, and include source links."),
        AgentTask(id: UUID(uuidString: "CC001001-0000-4000-8000-000000000003")!, title: "Turn a page into next steps", prompt: "Read the attached page and suggest practical next steps. Separate required actions from suggestions, preserve relevant source links, and ask about missing context. Prepare a plan for me to review before taking any actions.")
    ]
}

@MainActor
final class AgentTasks: ObservableObject {
    @Published private(set) var all: [AgentTask] = []
    @Published private(set) var trouble: String?
    private let file: URL
    private var unreadable = false

    init(file: URL = Store.file("agent-tasks.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { all = try JSONDecoder().decode([AgentTask].self, from: Data(contentsOf: file)) }
        catch {
            unreadable = true
            trouble = "Saved tasks could not be read. The original file has been kept."
        }
    }

    /// Write before publishing: a failed save leaves both the list and its
    /// editor intact, rather than promising that words have been kept.
    @discardableResult
    func save(id: UUID? = nil, title: String, prompt: String) -> Bool {
        guard !unreadable else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !prompt.isEmpty, title.count <= 80, prompt.count <= 6_000 else {
            trouble = "Give the task a name and instructions: up to 80 and 6,000 characters."
            return false
        }
        var next = all
        let task = AgentTask(id: id ?? UUID(), title: title, prompt: prompt)
        if let at = next.firstIndex(where: { $0.id == task.id }) { next[at] = task }
        else {
            guard next.count < 100 else { trouble = "You can keep up to 100 tasks. Remove one before adding another."; return false }
            next.insert(task, at: 0)
        }
        return write(next)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool { write(all.filter { $0.id != id }) }

    private func write(_ next: [AgentTask]) -> Bool {
        // A damaged file is never overwritten by an apparently empty list.
        guard !unreadable else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            all = next
            trouble = nil
            return true
        } catch {
            trouble = "Could not save tasks on this Mac. Try again after checking disk access."
            return false
        }
    }
}
