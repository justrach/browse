import Foundation

// This store deliberately has no connection to a browser profile.
enum Store { static func file(_ name: String) -> URL { URL(fileURLWithPath: "/unused/" + name) } }
func expect(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

@main struct Checks {
    @MainActor static func main() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("browse-tasks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("tasks.json")
        let tasks = AgentTasks(file: file)
        expect(tasks.all.isEmpty && !FileManager.default.fileExists(atPath: file.path), "Opening a library must not create tasks")
        expect(tasks.save(title: "  Compare sources  ", prompt: "  Keep citations.\nMark uncertainty.  "), "Could not save")
        let saved = tasks.all[0]
        let reloaded = AgentTasks(file: file)
        expect(reloaded.all == [saved] && saved.title == "Compare sources", "Saved task did not survive reopening")
        expect(saved.mentions("CITATIONS") && !saved.mentions("billing"), "Search did not cover instructions")
        expect(reloaded.save(id: saved.id, title: "Revised", prompt: "Different instructions"), "Could not edit")
        expect(AgentTasks(file: file).all.count == 1 && reloaded.all[0].id == saved.id, "Editing duplicated the task")
        let before = try Data(contentsOf: file)
        expect(!reloaded.save(title: " ", prompt: "Words"), "Blank title accepted")
        expect(!reloaded.save(title: "Long", prompt: String(repeating: "x", count: 6001)), "Oversize instructions accepted")
        expect(try Data(contentsOf: file) == before, "Invalid save altered the file")
        expect(reloaded.remove(saved.id) && AgentTasks(file: file).all.isEmpty, "Removal did not persist")
        let damaged = Data("invalid JSON".utf8)
        try damaged.write(to: file)
        let broken = AgentTasks(file: file)
        expect(broken.trouble != nil, "Unreadable file was silently treated as empty")
        expect(!broken.save(title: "", prompt: ""), "Invalid save unexpectedly worked")
        expect(!broken.save(title: "New", prompt: "New instructions"), "Damaged file was overwritten")
        expect(!broken.remove(UUID()), "Removal overwrote damaged file")
        expect(try Data(contentsOf: file) == damaged, "Damaged file was not preserved")
        let blocked = AgentTasks(file: scratch.appendingPathComponent("missing/tasks.json"))
        try Data("not a directory".utf8).write(to: scratch.appendingPathComponent("missing"))
        expect(!blocked.save(title: "Blocked", prompt: "Instructions"), "Write failure was ignored")
        expect(blocked.all.isEmpty && blocked.trouble != nil, "Failed save published an unsaved task")
        print("PASS task persistence, editing, search, removal, validation and write-failure recovery")
    }
}
