import Foundation

@MainActor
enum Store {
    static var folder: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HISTORY_TEST_DIR"]!, isDirectory: true)
    static func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func quarantine(_ url: URL) { try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bad")) }
}
@MainActor
final class Sync {
    static let shared = Sync()
    nonisolated static let device = "harness"
    func nudge() {}
    func forgotAll() {}
    func forgot(_ keys: [String]) {}
}

@main
struct HistoryChecks {
    @MainActor static func main() async throws {
        try FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        let file = Store.file("history.json")
        try? FileManager.default.removeItem(at: file)
        let engines = Engine.allCases.map { $0.template(custom: "") }
        let url = URL(string: "https://www.google.com/search?q=How%20to%20Use%20SwiftUI")!
        let first = History()
        first.record(url, title: "Google")
        let matching = first.searches(for: "how swift", engines: engines, limit: 4)
        precondition(matching == ["How to Use SwiftUI"], "matching/display: \(matching)")
        // History coalesces writes. Poll for the actual write, with a bound
        // generous enough for a busy CI runner.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(FileManager.default.fileExists(atPath: file.path), "history was not saved")
        let reopened = History()
        let recent = reopened.searches(for: "", engines: engines, limit: 5)
        precondition(recent == ["How to Use SwiftUI"], "persist/reload: \(recent)")
        let host = URL(string: "https://github.com")!
        let rows = [Suggestion(key: "github.com", title: "GitHub", url: host, kind: .visited),
                    Suggestion(key: "github.com", title: "", url: host, kind: .searched)]
        precondition(Set(rows.map(\.id)).count == 2, "suggestion IDs collide")
        reopened.forget()
        let cleared = reopened.searches(for: "", engines: engines, limit: 5)
        precondition(cleared.isEmpty, "clear leaves cached searches: \(cleared)")

        // Single-letter exact host-label ranking & inline completion ("x" -> "x.com").
        let nav = History()
        nav.record(URL(string: "https://xpericheck.com/device/G3116")!, title: "XperiCheck")
        nav.record(URL(string: "https://xpericheck.com/device/G3116")!, title: "XperiCheck")
        nav.record(URL(string: "https://x.com/home")!, title: "Home / X")
        let xOffers = nav.suggestions(for: "x", limit: 5, engines: engines)
        precondition(xOffers.first?.key == "x.com", "expected x.com first for 'x', got \(xOffers.map(\.key))")
        precondition(nav.completion(for: "x", among: xOffers) == ".com", "expected '.com' completion for visited x.com")

        // Unvisited built-in (.known) sites must NOT trigger 1-character inline completion.
        let unvisitedOnly = [Suggestion(key: "youtube.com", title: "YouTube", url: URL(string: "https://youtube.com")!, kind: .known)]
        precondition(nav.completion(for: "y", among: unvisitedOnly) == nil, "1-char completion must ignore unvisited .known sites")

        print("PASS: record/extract, persistence/reload, display casing, ID uniqueness, clear invalidates search cache, 1-char visited domain completion")
    }
}
