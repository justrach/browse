import Foundation

/// A reviewed excerpt is a snapshot, not whatever the tab shows by send time.
struct AgentPassage: Equatable, Codable {
    let text: String
    let title: String
    let url: URL
    let tab: String

    @MainActor init?(text: String, from source: Tab) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let url = source.address else { return nil }
        self.text = String(words.prefix(6000)) + (words.count > 6000 ? "\n…" : "")
        self.title = source.title.isEmpty ? (url.host() ?? "Selected text") : source.title
        self.url = url
        self.tab = String(source.id.uuidString.prefix(8)).lowercased()
    }

    var blocks: [[String: Any]] {
        [
            ["type": "text", "text": "This is the passage I selected from \(title) in browser tab \(tab):"],
            ["type": "resource", "resource": ["uri": url.absoluteString, "mimeType": "text/plain", "text": text]],
        ]
    }
}
