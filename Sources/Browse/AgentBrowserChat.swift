import AppKit
import Combine
import Foundation
import SwiftUI

/// The existing Codegraff account relay, with Browse as the host. It forwards
/// messages into this Agent rather than launching a second graff. Nothing
/// listens on the Mac, and the account key stays out of the browser link.
@MainActor
final class AgentBrowserChat: ObservableObject {
    @Published private(set) var on = false
    @Published private(set) var status = "Off"
    @Published private(set) var connected = false

    private weak var agent: Agent?
    private let prefs: Preferences
    private var work: Task<Void, Never>?
    private var changes = Set<AnyCancellable>()
    private var conversation: UUID?
    private var device = ""
    private var session = ""
    private var generation = UUID()
    private var sent: [UUID: Agent.Entry] = [:]
    private var seq = 0
    private var state = Data()
    private var sessionURL: URL?
    private var key: String?
    private var acceptedMessages: [String] = []

    private static var base: URL {
        if Store.testing, let value = ProcessInfo.processInfo.environment["SEARCH_REMOTE_URL"], let url = URL(string: value) { return url }
        return CodegraffAccount.base
    }

    init(agent: Agent, prefs: Preferences) {
        self.agent = agent
        self.prefs = prefs
        agent.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.checkConversation() }
        }.store(in: &changes)
        prefs.$usesAgent.sink { [weak self] enabled in
            if !enabled { self?.switchOn(false) }
        }.store(in: &changes)
    }

    var url: URL? { connected ? sessionURL : nil }

    func switchOn(_ wanted: Bool) {
        if !wanted { disconnect(); return }
        guard !on, prefs.usesAgent, let agent else { return }
        guard let key = CodegraffAccount.key() else {
            status = "Sign in to Codegraff first"
            return
        }
        self.key = key
        conversation = agent.identifyConversation()
        // A fresh identity prevents commands from an earlier enable reaching
        // a later one, even if a gateway request was still in flight.
        device = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        session = "browse-" + String(device.prefix(12))
        var parts = URLComponents(string: "https://codegraff.com/browse/chat")
        parts?.queryItems = [URLQueryItem(name: "session", value: session)]
        sessionURL = parts?.url
        generation = UUID()
        let run = generation
        on = true
        status = "Connecting…"
        seq = 0; sent = [:]; state = Data()
        acceptedMessages = []
        agent.wake()
        work = Task { await self.run(run) }
    }

    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyLink() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func checkConversation() {
        guard on else { return }
        if !prefs.usesAgent || agent?.chatID != conversation { disconnect() }
    }

    private func disconnect() {
        let oldDevice = device, oldKey = key
        generation = UUID()
        work?.cancel(); work = nil
        on = false; connected = false; status = "Off"
        conversation = nil; sessionURL = nil; key = nil
        sent = [:]; state = Data()
        guard !oldDevice.isEmpty, let oldKey else { return }
        device = ""
        Task { _ = try? await Self.request("DELETE", "/v1/remote/agents/\(oldDevice)", nil, key: oldKey) }
    }

    private func active(_ run: UUID) -> Bool {
        on && generation == run && prefs.usesAgent && agent?.chatID == conversation && !Task.isCancelled
    }

    private func run(_ run: UUID) async {
        var registered = false
        var delay: UInt64 = 1
        while active(run) {
            do {
                if !registered {
                    _ = try await call("register", [
                        "hostname": Host.current().localizedName ?? "Mac",
                        "name": "Browse on \(Host.current().localizedName ?? "Mac")",
                        "cwd": "", "version": "browse-chat-v1",
                    ])
                    guard active(run) else { return }
                    registered = true
                    state = Data(); sent = [:]
                }
                // Short bounded polls leave room for publishing native turns.
                // Only changed entries cross the relay, at most once a second.
                let reply = try await call("poll", ["wait_ms": 1_000, "sessions": [[
                    "id": session, "state": agent?.phase == .working ? "busy" : "idle", "last_seq": seq,
                ]]])
                guard active(run) else { return }
                connected = true; status = "Available in your browser"
                delay = 1
                for command in reply["commands"] as? [[String: Any]] ?? [] {
                    guard active(run) else { return }
                    try await handle(command, run: run)
                }
                guard active(run) else { return }
                let batch = updates()
                if !batch.isEmpty {
                    try await publish(batch)
                }
            } catch let error as RelayError {
                guard active(run) else { return }
                connected = false
                if error.code == 401 || error.code == 403 {
                    disconnect()
                    status = "Sign in again — browser access was refused"
                    return
                }
                // Re-register after a relay restart; fresh upserts rebuild
                // the transcript after an uncertain upload.
                if error.code == 404 { registered = false }
                state = Data(); sent = [:]
                status = "Reconnecting…"
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            } catch {
                guard active(run) else { return }
                connected = false; status = "Reconnecting…"
                registered = false
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    private func updates() -> [[String: Any]] {
        guard let agent else { return [] }
        var batch: [[String: Any]] = []
        for (order, entry) in agent.entries.enumerated() where sent[entry.id] != entry {
            var value: [String: Any] = [
                "id": entry.id.uuidString, "kind": entry.kind.rawValue,
                "order": order,
                "text": Self.excerpt(entry.text), "output": Self.excerpt(entry.output),
                "status": entry.status, "act": entry.act,
                "at": entry.at.timeIntervalSince1970 * 1_000,
                "until": entry.until.timeIntervalSince1970 * 1_000,
                "truncated": entry.text.utf8.count > 32_000 || entry.output.utf8.count > 32_000,
            ]
            if let page = entry.page { value["page"] = page }
            if let todo = entry.todo { value["todo"] = todo.map { ["text": $0.text, "done": $0.done] } }
            batch.append(stamp(["type": "browse_entry", "entry": value]))
            sent[entry.id] = entry
        }
        var value: [String: Any] = [
            "title": agent.title, "phase": agent.phase.words,
            "busy": agent.phase == .working, "queued": agent.queue.count,
            "model": agent.model?.label ?? "Codegraff",
        ]
        if let ask = agent.asking {
            value["ask"] = ["id": ask.id.uuidString, "title": ask.title,
                            "detail": ask.detail ?? "", "question": ask.isQuestion,
                            "options": ask.options.map { ["id": $0.id, "name": $0.name] }]
        }
        switch agent.outcome {
        case .stopped: value["stopped"] = true
        case .interrupted(let message): value["error"] = Self.excerpt(message)
        default: break
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? Data()
        if state != encoded {
            batch.append(stamp(["type": "browse_state", "state": value]))
            state = encoded
        }
        return batch
    }

    private func stamp(_ event: [String: Any]) -> [String: Any] {
        seq += 1
        let event = event.merging(["seq": seq]) { _, new in new }
        return event
    }

    /// Bound bytes rather than characters: emoji and combined glyphs can be
    /// large, and control characters grow sixfold when encoded as JSON.
    private static func excerpt(_ text: String) -> String {
        String(decoding: text.utf8.prefix(32_000), as: UTF8.self)
    }

    private func handle(_ command: [String: Any], run: UUID) async throws {
        guard let id = command["id"] as? String, active(run), let agent else { return }
        let body = command["body"] as? [String: Any] ?? [:]
        var code = 200
        var result: [String: Any] = ["ok": true]
        var events: [[String: Any]] = []
        if command["session_id"] as? String != session {
            code = 403; result = ["error": "Enable a conversation from Browse on this Mac"]
        } else if command["kind"] as? String == "close" {
            // Close browser access, never the native conversation.
            _ = try await call("events", ["command_id": id, "result": ["status": 200, "body": result]])
            guard active(run) else { return }
            disconnect()
            return
        } else if command["kind"] as? String == "request" {
            switch body["type"] as? String {
            case "user":
                let messageID = (body["client_message_id"] as? String).flatMap { $0.count <= 64 ? $0 : nil }
                if let messageID, acceptedMessages.contains(messageID) {} else if let text = body["text"] as? String, agent.sendFromBrowser(text) {
                    if let messageID {
                        acceptedMessages.append(messageID)
                        if acceptedMessages.count > 256 { acceptedMessages.removeFirst() }
                    }
                } else {
                    code = 409; result = ["error": "Codegraff cannot accept a message yet — check Browse"]
                    events = [stamp(["type": "error", "message": result["error"] ?? "Message refused"])]
                }
            case "answer":
                guard let ask = agent.asking, body["ask_id"] as? String == ask.id.uuidString else {
                    code = 409; result = ["error": "That question has already changed"]
                    break
                }
                if body["cancelled"] as? Bool == true { agent.answer(ask, with: nil, preserveDraft: true) }
                else if let option = body["option_id"] as? String,
                        let choice = ask.options.first(where: { $0.id == option }) { agent.answer(ask, with: choice, preserveDraft: true) }
                else if ask.isQuestion, let text = body["text"] as? String, agent.sendFromBrowser(text) {} else {
                    code = 400; result = ["error": "Choose an answer to this question"]
                }
            case "cancel":
                if agent.phase == .working { agent.stop() }
                else { code = 409; result = ["error": "No turn is running"] }
            case "reattach":
                // Upserts rebuild the same transcript, without duplicating
                // turns or starting another agent. New seq values are fine.
                sent = [:]; state = Data()
                events = updates()
            default:
                code = 400; result = ["error": "Use Browse to change models or start a conversation"]
                events = [stamp(["type": "error", "message": result["error"] ?? "Unsupported request"])]
            }
        } else {
            code = 403; result = ["error": "Start conversations from Browse"]
        }
        events += updates()
        events.append(stamp(["type": "browse_ack", "command_id": id, "ok": code < 300, "error": result["error"] ?? ""]))
        try await publish(events, command: id, result: ["status": code, "body": result])
    }

    /// The gateway caps one upload. Long histories are sent in small batches,
    /// and a command's result follows its last batch, never ahead of it.
    private func publish(_ events: [[String: Any]], command: String? = nil, result: [String: Any]? = nil) async throws {
        let run = generation
        var batch: [[String: Any]] = []
        var bytes = 0
        for event in events {
            let size = try JSONSerialization.data(withJSONObject: event).count
            if bytes + size > 500_000 && !batch.isEmpty {
                _ = try await call("events", ["session_id": session, "events": batch])
                guard active(run) else { throw CancellationError() }
                batch = []; bytes = 0
            }
            batch.append(event); bytes += size
        }
        var payload: [String: Any] = ["session_id": session, "events": batch]
        if let command { payload["command_id"] = command }
        if let result { payload["result"] = result }
        _ = try await call("events", payload)
    }

    private func call(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let key else { throw RelayError(code: 401) }
        return try await Self.request("POST", "/v1/remote/agents/\(device)/\(action)", body, key: key)
    }

    private struct RelayError: Error { let code: Int }

    private static func request(_ method: String, _ path: String, _ body: [String: Any]?, key: String) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = 35
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw RelayError(code: code) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var probe: [String: Any] { ["on": on, "connected": connected, "status": status, "session": session, "url": url?.absoluteString ?? ""] }
}

struct AgentBrowserChatCard: View {
    @ObservedObject var chat: AgentBrowserChat
    var body: some View {
        Card {
            Line("Continue in browser", "This conversation, from Chrome or your phone. Sign in to the same Codegraff account; keep Browse open and your Mac awake.") {
                Switch(on: Binding(get: { chat.on }, set: { chat.switchOn($0) }))
            }
            Text("Enabling access sends this conversation’s messages, activity and tool results through Codegraff’s relay. Browser messages run here with the same agent permissions. Unsent drafts stay on this Mac. Access ends when you turn it off, disable Codegraff or switch conversations.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 12)
            if chat.on || chat.status != "Off" {
                Rule()
                Line(chat.status, chat.on ? "Your link requires your Codegraff sign-in. It grants no access by itself." : "Use the account controls above, then try again.") {
                    HStack(spacing: 6) {
                        Pill("Copy link") { chat.copyLink() }.disabled(!chat.connected)
                        Pill("Open in browser", filled: true) { chat.open() }.disabled(!chat.connected)
                    }
                }
            }
        }
    }
}
