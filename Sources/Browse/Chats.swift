import Foundation

/// Every conversation had with Codegraff, newest first, kept so the page
/// the Ask tab opens on can offer them again (see AgentHome.swift). Each
/// keeps what was said and the name graff gave its session, so opening one
/// picks the conversation up with graff where it was left, not only on
/// screen.
struct Chat: Codable, Identifiable, Equatable {
    let id: UUID
    /// graff's name for the session, for `session/load`.
    var session: String?
    var title: String
    let started: Date
    var updated: Date
    var entries: [Agent.Entry]
    /// Why the last turn didn't finish, when it didn't.
    var failed: String?

    /// The words its card shows under the title: the last reply, or what
    /// was asked when nothing has come back.
    var gist: String {
        if let reply = entries.last(where: { $0.kind == .reply }) { return reply.text }
        return entries.first(where: { $0.kind == .you })?.text ?? ""
    }

    /// The first thing asked, on one line, short enough to be a title.
    static func title(for entries: [Agent.Entry]) -> String {
        let first = entries.first { $0.kind == .you }?.text ?? ""
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }
}

@MainActor
final class Chats: ObservableObject {
    @Published private(set) var all: [Chat] = []

    /// Kept to this many; the oldest go first.
    private static let most = 200
    /// A tool's output kept with a chat. The whole of it was for the turn it
    /// was used in; a reminder is enough after.
    private static let kept = 2_000

    private var saving = false

    init() { load() }

    func keep(_ chat: Chat) {
        var chat = chat
        chat.entries = chat.entries.map { entry in
            var entry = entry
            if entry.output.count > Chats.kept { entry.output = String(entry.output.prefix(Chats.kept)) + "\n…" }
            return entry
        }
        all.removeAll { $0.id == chat.id }
        all.insert(chat, at: 0)
        if all.count > Chats.most { all.removeLast(all.count - Chats.most) }
        save()
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    // MARK: - the file

    private static var file: URL { Store.file("chats.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Chats.file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([Chat].self, from: data) else {
            Store.quarantine(Chats.file)
            return
        }
        all = list.sorted { $0.updated > $1.updated }
    }

    /// Coalesced, and off the main thread, as history is.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.saving = false
            self.write(self.all)
        }
    }

    /// The app is quitting: now, on this thread.
    func flush() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        try? data.write(to: Chats.file, options: .atomic)
    }

    private func write(_ list: [Chat]) {
        let file = Chats.file
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(list) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
