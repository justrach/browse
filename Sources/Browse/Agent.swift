import AppKit
import Foundation

// Codegraff, working beside the page.
//
// Search doesn't carry an agent of its own; it runs the one already on the
// Mac — `graff`, Codegraff's command — and talks to it the way Zed and
// Harness do, over the Agent Client Protocol: JSON-RPC, one message a line,
// on the program's stdin and stdout. Search is the client. It opens a
// session, sends what you type (with the page you're on, unless you leave it
// out), and shows what comes back as it comes: the reply, the thinking, each
// command and edit.
//
// graff runs as `graff acp --yolo`, the way the Codegraff app runs it: every
// tool it has — the shell, reading and editing files, codedb, its MCP
// servers — and no stopping to ask before each one. Search passes words and
// a page in and shows what comes out; graff does its own talking to its
// model, with its own sign-in.
//
// What Harness learned driving graff, kept here: graff finds itself by the
// newest copy on the Mac, not the first; it reads each line into 64 KiB and
// stops listening at a longer one, so nothing sent may be longer; it owns one
// session per process, so a new conversation is a new graff; and a question
// it asks mid-turn holds the turn until it hears `session/answer`.

@MainActor
final class Agent: ObservableObject {
    enum Phase: Equatable {
        /// Not started: the column hasn't been opened since launch.
        case asleep
        case starting
        case ready
        case working
        /// graff is there but has nobody signed in.
        case signedOut
        /// No graff anywhere Search looked.
        case missing
        case broken(String)

        var words: String {
            switch self {
            case .asleep, .ready: return ""
            case .starting: return "Starting…"
            case .working: return "Working…"
            case .signedOut: return "Signed out"
            case .missing: return "Not installed"
            case .broken: return "Stopped"
            }
        }
    }

    /// One thing said or done.
    struct Entry: Identifiable, Equatable, Codable {
        /// `page`: one graff read through the browser's tools, with its
        /// address in `key`, for the user to open.
        enum Kind: String, Codable { case you, reply, thought, tool, note, page }
        var id = UUID()
        let kind: Kind
        var text: String
        /// A tool's own id, which its updates arrive under.
        var key = ""
        /// A tool's progress: pending, in_progress, completed, failed.
        var status = ""
        /// What a tool printed or changed.
        var output = ""
        /// What sort of thing a tool does, as ACP names it: read, edit,
        /// execute, fetch, search, think, other.
        var act = ""
        /// The page that went with something you said.
        var page: String?
        /// When it began, and when it last changed: a reply grows, a tool
        /// finishes. How long a turn worked is read from these.
        var at = Date()
        var until = Date()
    }

    /// graff waiting on you: an answer to a question it asked in the middle
    /// of its work, or — from a graff that wasn't told to go ahead — leave to
    /// do something on the Mac.
    struct Ask: Identifiable, Equatable {
        enum Wants: Equatable {
            /// `session/request_permission`, answered by the request's own
            /// id — graff's are strings, `graff-permission-1`.
            case permission(request: String)
            /// graff's `gui_ask_user`, answered with `session/answer`.
            case question
        }
        struct Option: Identifiable, Equatable {
            let id: String
            let name: String
            let kind: String
            var allows: Bool { kind.hasPrefix("allow") }
            var refuses: Bool { kind.hasPrefix("reject") }
        }
        let id = UUID()
        let wants: Wants
        let title: String
        let detail: String?
        let options: [Option]

        var isQuestion: Bool { wants == .question }
    }

    /// A model graff can reach from here, as `graff/models` lists it.
    struct Model: Identifiable, Equatable {
        let provider: String
        let name: String
        var context = 0
        var id: String { "\(provider)/\(name)" }

        static func == (a: Model, b: Model) -> Bool { a.id == b.id }

        /// The model's own part of its name: after any "vendor/", without a
        /// ":free" or ":beta" on the end.
        private var bare: String {
            var bare = name
            if let slash = bare.lastIndex(of: "/") { bare = String(bare[bare.index(after: slash)...]) }
            if let colon = bare.firstIndex(of: ":") { bare = String(bare[..<colon]) }
            return bare
        }

        /// What follows a colon — OpenRouter's "free", "beta", "extended".
        var tag: String? {
            name.split(separator: ":").dropFirst().first.map(String.init)
        }

        /// Whose model it is, when a router carries it: "anthropic/…" is
        /// Anthropic's.
        var maker: String? {
            guard let slash = name.firstIndex(of: "/") else { return nil }
            return Model.said(String(name[..<slash]))
        }

        /// "gpt-6-sol" as people say it: "GPT-6 Sol"; "claude-opus-4-8" is
        /// "Claude Opus 4.8", and a date on the end is left off.
        var label: String {
            var words: [String] = []
            var dated = false
            for part in bare.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init) {
                let lower = part.lowercased()
                // 20251101, or 2024-05-13: a snapshot's date, not part of
                // what it's called.
                if part.count == 8, part.allSatisfy(\.isNumber) { continue }
                if part.count == 4, part.hasPrefix("20"), part.allSatisfy(\.isNumber) { dated = true; continue }
                if dated, part.count <= 2, part.allSatisfy(\.isNumber) { continue }
                dated = false
                if let cased = Model.cased[lower] {
                    words.append(cased)
                    continue
                }
                if let last = words.last {
                    // 4-8 → 4.8; GPT 6 → GPT-6.
                    if part.allSatisfy(\.isNumber), part.count <= 2, last.last?.isNumber == true, !last.hasSuffix("B") {
                        words[words.count - 1] = last + "." + part
                        continue
                    }
                    if last == "GPT", part.first?.isNumber == true {
                        words[words.count - 1] = "GPT-" + part
                        continue
                    }
                }
                if ["gpt", "glm", "ui", "ai", "oss", "vl", "moe", "r1", "v3", "v4", "k2", "k3", "4o"].contains(lower) {
                    words.append(part.uppercased())
                } else if lower.range(of: #"^a?\d+(\.\d+)?[bkm]$"#, options: .regularExpression) != nil {
                    // 72b → 72B, the size of the thing; a10b → A10B.
                    words.append(part.uppercased())
                } else if lower.range(of: #"^o\d$"#, options: .regularExpression) != nil {
                    // OpenAI's o1, o3, o4 are written small.
                    words.append(lower)
                } else {
                    words.append(part.prefix(1).uppercased() + part.dropFirst())
                }
            }
            return words.isEmpty ? name : words.joined(separator: " ")
        }

        /// Words their makers write their own way.
        private static let cased = [
            "deepseek": "DeepSeek", "minimax": "MiniMax", "lmstudio": "LM Studio", "hy4": "HY4",
            "openai": "OpenAI", "chatgpt": "ChatGPT", "gemma": "Gemma", "phi": "Phi",
        ]

        /// Its window in words a person reads at a glance: "1M", "262K".
        var window: String? {
            guard context > 0 else { return nil }
            if context >= 1_000_000 { return context % 1_000_000 < 100_000 ? "\(context / 1_000_000)M" : String(format: "%.1fM", Double(context) / 1_000_000) }
            if context >= 1_000 { return "\(context / 1_000)K" }
            return "\(context)"
        }

        /// Only for making pictures and sounds, or for batch jobs: nothing to
        /// talk to.
        var talks: Bool {
            let lower = name.lowercased()
            return !["imagine", "-image", "image-", "video", "lyria", "embedding", "embed-", "tts", "whisper", "transcribe", ":batch"]
                .contains { lower.contains($0) }
        }

        /// A provider or maker by the name it goes by.
        static func said(_ key: String) -> String {
            let known = [
                "codegraff": "Codegraff", "codex": "Codex", "openai": "OpenAI", "anthropic": "Anthropic",
                "xai": "xAI", "x-ai": "xAI", "kimi": "Kimi", "moonshotai": "Moonshot", "deepseek": "DeepSeek",
                "openrouter": "OpenRouter", "google": "Google", "meta-llama": "Meta", "mistralai": "Mistral",
                "qwen": "Qwen", "z-ai": "Z.ai", "cerebras": "Cerebras", "mlx": "MLX", "lmstudio": "LM Studio",
                "fugu": "Fugu", "nvidia": "NVIDIA", "microsoft": "Microsoft", "amazon": "Amazon", "cohere": "Cohere",
                "minimax": "MiniMax", "baidu": "Baidu", "bytedance": "ByteDance", "ibm-granite": "IBM", "perplexity": "Perplexity",
            ]
            if let name = known[key.lowercased()] { return name }
            return key.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// How hard it thinks: graff's `thought_level`, a session config option
    /// with the levels the model on offer takes.
    struct Effort: Equatable {
        let id: String
        var current: String
        var levels: [(value: String, name: String)]

        static func == (a: Effort, b: Effort) -> Bool {
            a.id == b.id && a.current == b.current && a.levels.map(\.value) == b.levels.map(\.value)
        }

        var currentName: String {
            levels.first { $0.value == current }?.name ?? current.capitalized
        }
    }

    @Published private(set) var phase: Phase = .asleep
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var asking: Ask?
    @Published private(set) var models: [Model] = []
    /// The model graff says it is running.
    @Published private(set) var model: Model?
    @Published private(set) var effort: Effort?
    @Published var draft = ""
    /// Whether the page you are on goes with the next message.
    @Published var withPage = true

    /// Where to get graff, for a Mac without it.
    static let download = URL(string: "https://github.com/justrach/codegraff/releases/latest")!

    /// graff takes a line at a time into 64 KiB; anything longer and it stops
    /// listening. Kept well under, for the envelope around what is sent.
    private static let longestLine = 60_000

    private let prefs: Preferences
    private var pipe: AcpPipe?
    private var program: URL?
    private var session: String?
    /// A session to pick up again when graff comes back — after a change
    /// of model, the conversation carries on rather than starting over.
    private var resuming: String?
    /// True while `session/load` replays what was said, which the column
    /// already shows.
    private var replaying = false
    private var next = 1
    private var waiting: [Int: (Result<Any, Failure>) -> Void] = [:]
    /// Requests from graff that are still to be answered, by id, with the
    /// id as it came so the answer carries it back the same.
    private var owed: [String: Any] = [:]
    /// What was typed while graff was still starting, sent once it is up.
    private var held: [[String: Any]]?
    /// True from a prompt going out until its answer comes back.
    private var prompting = false
    /// Whether this session has been told where it is. Once is enough.
    private var introduced = false

    /// Every conversation so far, for the Ask tab's page (see Chats.swift).
    let chats = Chats()
    /// The one on screen, once something has been said in it.
    @Published private(set) var chatID: UUID?
    /// Why the last turn went wrong, for its card; nothing once one works.
    private var stumble: String?
    /// What was said before, for a graff that couldn't pick the session
    /// back up: it goes ahead of the next message instead.
    private var lost: String?
    /// When graff last did something or was asked something.
    private var lastActive = Date()
    private var idleWatch: Task<Void, Never>?
    /// graff and its pages hold ~40 MB and more for as long as it runs. With
    /// nothing to do for this long it goes, and the next message brings the
    /// same conversation back with `session/load`.
    private static let idleLimit: TimeInterval = 10 * 60

    init(prefs: Preferences) {
        self.prefs = prefs
        // graff saves its session when its input ends, and ends with it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keep()
                self?.chats.flush()
                self?.pipe?.stop()
                // The port dies with the app; nothing should be told of it.
                AgentTools.withdraw()
            }
        }
    }

    struct Failure: Error {
        let code: Int
        let message: String
    }

    var canSend: Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if asking?.isQuestion == true { return true }
        switch phase {
        case .ready, .asleep: return true
        // One message can wait for graff to be up, not a queue of them.
        case .starting: return held == nil
        default: return false
        }
    }

    // MARK: - starting and stopping

    /// The column opened: start graff if it isn't already.
    func wake() {
        lastActive = Date()
        if phase == .asleep { start() }
    }

    /// graff stopped after a long quiet, to give back what it holds: the
    /// conversation stays on screen and its session is picked up again
    /// with the next message (see idleLimit).
    func rest() {
        guard pipe != nil, phase == .ready, asking == nil, !prompting else { return }
        let carried = session
        keep()
        shutDown()
        resuming = carried
        AgentTools.shared.dropPages()
    }

    /// Checks once a minute, while graff runs, whether it has been quiet
    /// for idleLimit.
    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, self.pipe != nil else { return }
                if Date().timeIntervalSince(self.lastActive) > Agent.idleLimit {
                    self.rest()
                    return
                }
            }
        }
    }

    /// graff afresh: after signing in, after it stopped, after the path to
    /// it changed.
    func restart() {
        shutDown()
        start()
    }

    /// Turned off in Settings, or about to be started afresh.
    func shutDown() {
        let dying = pipe
        pipe = nil
        dying?.stop()
        session = nil
        replaying = false
        prompting = false
        fail(Failure(code: -1, message: "Stopped"))
        asking = nil
        owed = [:]
        held = nil
        phase = .asleep
    }

    /// A clean slate. graff owns one session for as long as it runs, so a
    /// new conversation is a new graff.
    func startOver() {
        keep()
        entries = []
        chatID = nil
        stumble = nil
        lost = nil
        resuming = nil
        restart()
    }

    /// A conversation from before, back on screen, and graff picking it up
    /// where it was left: its session loaded again, or — if graff has lost
    /// it — what was said, sent ahead of the next message.
    func resume(_ chat: Chat) {
        guard chat.id != chatID else { return }
        keep()
        shutDown()
        entries = chat.entries
        chatID = chat.id
        stumble = nil
        lost = chat.session == nil ? Agent.transcript(chat.entries) : nil
        resuming = chat.session
        start()
    }

    /// The conversation on screen, saved with the others.
    func keep() {
        guard let chatID, entries.contains(where: { $0.kind == .you }) else { return }
        let before = chats.all.first { $0.id == chatID }
        // Only when something changed: leaving a chat as it was mustn't
        // make it the newest.
        if let before, before.entries == entries, before.failed == stumble,
           session == nil || before.session == session { return }
        chats.keep(Chat(
            id: chatID,
            session: session ?? before?.session,
            title: Chat.title(for: entries),
            started: before?.started ?? entries.first?.at ?? Date(),
            updated: Date(),
            entries: entries,
            failed: stumble
        ))
    }

    /// One taken off the list; the one on screen goes back to a clean slate.
    func forget(_ chat: Chat) {
        chats.remove(chat.id)
        if chat.id == chatID {
            chatID = nil
            startOver()
        }
    }

    /// Another model. graff takes it at launch, so graff starts again — and
    /// picks the conversation up where it was.
    /// The models chosen last, newest first, for the top of the picker.
    var recentModels: [Model] {
        (Store.settings.stringArray(forKey: "agent.recent") ?? []).compactMap { id in
            models.first { $0.id == id }
        }
    }

    func choose(_ model: Model) {
        guard model != self.model else { return }
        var recent = Store.settings.stringArray(forKey: "agent.recent") ?? []
        if let leaving = self.model?.id { recent.removeAll { $0 == leaving }; recent.insert(leaving, at: 0) }
        recent.removeAll { $0 == model.id }
        recent.insert(model.id, at: 0)
        Store.settings.set(Array(recent.prefix(6)), forKey: "agent.recent")
        prefs.agentModel = model.id
        let carried = session
        shutDown()
        resuming = carried
        entries.append(Entry(kind: .note, text: "Now \(model.name)"))
        start()
    }

    private func start() {
        phase = .starting
        let custom = prefs.agentPath
        Task {
            // The browser's own tools first, so the file that tells graff
            // where they are is there before graff looks (see AgentTools.swift).
            // Without them graff still has its own; a file left from an
            // earlier launch would only send it knocking on a closed port.
            if !(await AgentTools.shared.start()) {
                AgentTools.withdraw()
            }
            Agent.leaveKuriOut()
            let found = await Agent.locate(custom: custom)
            guard phase == .starting, pipe == nil else { return }
            guard let found else {
                phase = .missing
                return
            }
            launch(found.program, path: found.path)
        }
    }

    private func launch(_ program: URL, path: String?) {
        self.program = program
        var arguments = ["acp", "--yolo"]
        if !prefs.agentModel.isEmpty { arguments += ["--model", prefs.agentModel] }
        let pipe = AcpPipe(program: program, arguments: arguments, environment: Agent.environment(for: program, path: path, lean: !prefs.agentAllTools), folder: Agent.folder)
        pipe.onMessage = { [weak self, weak pipe] message in
            guard let self, let pipe, self.pipe === pipe else { return }
            self.take(message)
        }
        pipe.onExit = { [weak self, weak pipe] status, said in
            guard let self, let pipe, self.pipe === pipe else { return }
            self.ended(status: status, said: said)
        }
        do {
            try pipe.start()
        } catch {
            phase = .broken("Couldn't run \(program.path): \(error.localizedDescription)")
            return
        }
        self.pipe = pipe
        // The same introduction the Codegraff app gives. graff works with
        // files and runs commands through its own tools, not the client's.
        call("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": [String: Any]()],
            "clientInfo": ["name": "browse", "title": "browse", "version": Updater.version],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.open()
            case .failure(let failure): self.stumbled(failure)
            }
        }
    }

    /// A session, in graff's own folder: the one being carried over if
    /// there is one, a new one otherwise. The first request that needs
    /// someone signed in — a graff with nobody signed in says so here.
    private func open() {
        let params: [String: Any] = ["cwd": Agent.folder.path, "mcpServers": [Any]()]
        if let carried = resuming {
            resuming = nil
            replaying = true
            var loading = params
            loading["sessionId"] = carried
            call("session/load", loading) { [weak self] result in
                guard let self else { return }
                self.replaying = false
                switch result {
                case .success(let value): self.opened(carried, value)
                case .failure(let failure):
                    if Agent.wantsSignIn(failure) {
                        self.stumbled(failure)
                    } else {
                        // A fresh session, told what was said in the old one.
                        self.lost = Agent.transcript(self.entries)
                        self.open()
                    }
                }
            }
            return
        }
        call("session/new", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                guard let id = (value as? [String: Any])?["sessionId"] as? String else {
                    self.stumbled(Failure(code: 0, message: "graff opened no session"))
                    return
                }
                self.opened(id, value)
            case .failure(let failure):
                self.stumbled(failure)
            }
        }
    }

    private func opened(_ id: String, _ reply: Any) {
        session = id
        phase = .ready
        lastActive = Date()
        watchIdle()
        introduced = false
        adopt(reply)
        // The level last chosen, where this model offers it.
        let wanted = prefs.agentEffort
        if let effort, !wanted.isEmpty, wanted != effort.current, effort.levels.contains(where: { $0.value == wanted }) {
            choose(effort: wanted)
        }
        listModels()
        if let blocks = held {
            held = nil
            prompt(blocks)
        }
    }

    /// What graff can reach with the keys it has, for the picker, and which
    /// one it is on — graff's own `graff/models`, the catalog its `/models`
    /// prints.
    private func listModels() {
        call("graff/models", [:]) { [weak self] result in
            guard let self, case .success(let value) = result, let reply = value as? [String: Any] else { return }
            let rows = reply["models"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            var models: [Model] = rows.compactMap { row in
                guard row["authenticated"] as? Bool == true,
                      let provider = row["provider"] as? String, let name = row["name"] as? String,
                      !provider.isEmpty, !name.isEmpty
                else { return nil }
                let model = Model(provider: provider, name: name, context: row["context"] as? Int ?? 0)
                // Pictures, video, batch-only: nothing to have a chat with.
                guard model.talks else { return nil }
                return seen.insert(model.id).inserted ? model : nil
            }
            if let current = reply["current"] as? [String: Any],
               let provider = current["provider"] as? String, let name = current["model"] as? String {
                let now = models.first { $0.provider == provider && $0.name == name } ?? Model(provider: provider, name: name)
                self.model = now
                // The one it is on first, as Harness lists them.
                models.removeAll { $0 == now }
                models.insert(now, at: 0)
            }
            self.models = models
        }
    }

    /// A reasoning level, for the session graff has now. The model decides
    /// which there are; the choice is remembered for the next session.
    func choose(effort value: String) {
        guard let session, let effort, effort.levels.contains(where: { $0.value == value }) else { return }
        prefs.agentEffort = value
        guard value != effort.current else { return }
        self.effort?.current = value
        call("session/set_config_option", ["sessionId": session, "configId": effort.id, "value": value]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply): self.adopt(reply)
            case .failure(let failure):
                self.effort?.current = effort.current
                self.entries.append(Entry(kind: .note, text: failure.message))
            }
        }
    }

    /// graff's session options, from opening a session or changing one: the
    /// `thought_level` select, the only one it has.
    private func adopt(_ reply: Any) {
        guard let options = (reply as? [String: Any])?["configOptions"] as? [[String: Any]] else { return }
        guard let option = options.first(where: {
            ($0["category"] as? String == "thought_level" || $0["id"] as? String == "thought_level")
                && ($0["type"] as? String ?? "select") == "select"
        }), let id = option["id"] as? String else {
            effort = nil
            return
        }
        let levels = (option["options"] as? [[String: Any]] ?? []).compactMap { choice -> (value: String, name: String)? in
            guard let value = choice["value"] as? String else { return nil }
            return (value, choice["name"] as? String ?? value.capitalized)
        }
        effort = levels.isEmpty ? nil : Effort(id: id, current: option["currentValue"] as? String ?? "", levels: levels)
    }

    /// A page graff read through the browser's tools, named in the column.
    func saw(_ url: URL, title: String) {
        entries.append(Entry(kind: .page, text: title, key: url.absoluteString))
    }

    /// What was said, with pages read one after another kept together, so
    /// the column can draw them as one card.
    static func grouped(_ entries: [Entry]) -> [[Entry]] {
        var runs: [[Entry]] = []
        for entry in entries {
            if entry.kind == .page, runs.last?.last?.kind == .page {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }

    private func stumbled(_ failure: Failure) {
        if Agent.wantsSignIn(failure) {
            phase = .signedOut
            held = nil
            return
        }
        phase = .broken(failure.message)
    }

    private func ended(status: Int32, said: String) {
        pipe = nil
        session = nil
        asking = nil
        owed = [:]
        prompting = false
        replaying = false
        let why = said.isEmpty ? "graff stopped (status \(status))." : said
        fail(Failure(code: Int(status), message: why))
        if phase == .signedOut || phase == .missing { return }
        phase = Agent.wantsSignIn(Failure(code: 0, message: why)) ? .signedOut : .broken(why)
        stumble = why
        keep()
    }

    /// `graff login`, in Terminal — the sign-in graff names for ACP clients.
    /// It asks which account and may open a browser to sign in, which is
    /// Terminal's to host, not ours. A .command file opens there on its own,
    /// without Search needing leave to drive Terminal.
    func signIn() {
        Task {
            let found: URL?
            if let program {
                found = program
            } else {
                found = await Agent.locate(custom: prefs.agentPath)?.program
            }
            guard let found else {
                phase = .missing
                return
            }
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("graff-login.command")
            let body = """
            #!/bin/sh
            clear
            \(Agent.quoted(found.path)) login
            echo
            echo "Done. Back in browse, press I've signed in."
            """
            do {
                try body.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            } catch {
                entries.append(Entry(kind: .note, text: "Couldn't open Terminal: \(error.localizedDescription)"))
                return
            }
            NSWorkspace.shared.open(script)
        }
    }

    // MARK: - talking

    /// What was typed. An answer, if graff is waiting on one; otherwise a
    /// prompt, with the page as an embedded resource — graff's way of taking
    /// a document along with the words.
    func send(page tab: Tab?) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let asking, asking.isQuestion {
            draft = ""
            entries.append(Entry(kind: .you, text: text))
            respond(asking, text: text)
            return
        }
        let pageTitle = tab.flatMap { tab -> String? in
            guard !tab.isBlank else { return nil }
            return tab.title.isEmpty ? (tab.address?.host() ?? "This page") : tab.title
        }
        guard Agent.wire([["type": "text", "text": text]]) < Agent.longestLine else {
            entries.append(Entry(kind: .note, text: "That's too long to send in one message"))
            return
        }
        draft = ""
        lastActive = Date()
        if chatID == nil { chatID = UUID() }
        entries.append(Entry(kind: .you, text: text, page: pageTitle))
        keep()
        if phase == .ready { phase = .working }
        Task {
            var page: (address: String, title: String, text: String, tab: String)?
            if let tab { page = await Agent.read(tab) }
            let blocks = Agent.blocks(text, page: page)
            switch phase {
            case .ready, .working:
                prompt(blocks)
            case .asleep, .starting:
                held = blocks
                wake()
            default:
                entries.append(Entry(kind: .note, text: "Codegraff isn't running"))
            }
        }
    }

    private func prompt(_ blocks: [[String: Any]]) {
        guard let session else {
            held = blocks
            return
        }
        phase = .working
        prompting = true
        var blocks = blocks
        if let lost {
            self.lost = nil
            blocks.insert(["type": "text", "text": "Earlier in this conversation, before you were restarted:\n\n" + lost], at: 0)
        }
        if !introduced {
            introduced = true
            blocks.insert(["type": "text", "text": Agent.introduction], at: 0)
        }
        call("session/prompt", ["sessionId": session, "prompt": blocks]) { [weak self] result in
            guard let self else { return }
            self.prompting = false
            if self.phase == .working { self.phase = .ready }
            self.asking = nil
            switch result {
            case .success(let value):
                let reason = (value as? [String: Any])?["stopReason"] as? String
                if reason == "cancelled" {
                    self.entries.append(Entry(kind: .note, text: "Stopped"))
                } else if reason == "max_turn_requests" {
                    self.entries.append(Entry(kind: .note, text: "Stopped at its limit for one turn"))
                }
                self.settle(reason == "end_turn")
                self.stumble = nil
            case .failure(let failure):
                self.settle(false)
                if Agent.wantsSignIn(failure) {
                    self.phase = .signedOut
                    self.stumble = failure.message
                } else if failure.code != -1 {
                    self.entries.append(Entry(kind: .note, text: failure.message))
                    self.stumble = failure.message
                }
            }
            self.keep()
        }
    }

    /// The turn is over: anything still spinning has finished, or never will.
    private func settle(_ finished: Bool) {
        for index in entries.indices where entries[index].kind == .tool
            && (entries[index].status == "pending" || entries[index].status == "in_progress") {
            entries[index].status = finished ? "completed" : "failed"
        }
    }

    /// Esc for graff: the turn ends at its next step. A question it was
    /// waiting on goes unanswered.
    func stop() {
        if let asking { answer(asking, with: nil) }
        guard let session else { return }
        notify("session/cancel", ["sessionId": session])
    }

    func answer(_ ask: Ask, with option: Ask.Option?) {
        guard asking?.id == ask.id else { return }
        switch ask.wants {
        case .permission(let request):
            asking = nil
            let outcome: [String: Any] = option.map { ["outcome": "selected", "optionId": $0.id] }
                ?? ["outcome": "cancelled"]
            reply(to: request, result: ["outcome": outcome])
        case .question:
            if let option { entries.append(Entry(kind: .you, text: option.name)) }
            respond(ask, text: option?.name)
        }
    }

    /// A question answered in words, or left — `session/answer` either way,
    /// or graff's turn waits for ever.
    private func respond(_ ask: Ask, text: String?) {
        asking = nil
        guard let session else { return }
        notify("session/answer", ["sessionId": session, "text": text ?? "", "cancelled": text == nil])
    }

    // MARK: - what graff says

    private func take(_ message: [String: Any]) {
        lastActive = Date()
        let method = message["method"] as? String
        let id = message["id"]
        if let method, let id, !(id is NSNull) {
            asked(method, id: id, params: message["params"] as? [String: Any] ?? [:])
        } else if let method {
            guard method == "session/update", !replaying,
                  let params = message["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any]
            else { return }
            if let session, let from = params["sessionId"] as? String, from != session { return }
            updated(update)
        } else if let id = Agent.number(id), let answer = waiting.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                answer(.failure(Failure(code: Agent.number(error["code"]) ?? 0, message: error["message"] as? String ?? "graff refused")))
            } else {
                answer(.success(message["result"] ?? NSNull()))
            }
        }
    }

    private func updated(_ update: [String: Any]) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            flow(.reply, Agent.text(update["content"]))
        case "agent_thought_chunk":
            flow(.thought, Agent.text(update["content"]))
        case "tool_call":
            let key = update["toolCallId"] as? String ?? ""
            let title = update["title"] as? String ?? "Working"
            // graff finding and unfolding its own tools: its business, not
            // something done.
            if Agent.plumbing.contains(title) { return }
            let status = update["status"] as? String ?? "pending"
            let act = update["kind"] as? String ?? ""
            if !key.isEmpty, let index = entries.lastIndex(where: { $0.kind == .tool && $0.key == key }) {
                entries[index].text = title
                entries[index].status = status
                if !act.isEmpty { entries[index].act = act }
            } else {
                entries.append(Entry(kind: .tool, text: title, key: key, status: status, act: act))
            }
        case "tool_call_update":
            let key = update["toolCallId"] as? String ?? ""
            guard let index = entries.lastIndex(where: { $0.kind == .tool && $0.key == key }) else { return }
            entries[index].until = Date()
            if let status = update["status"] as? String { entries[index].status = status }
            if let title = update["title"] as? String, !title.isEmpty { entries[index].text = title }
            let shown = Agent.shown(update["content"])
            if !shown.isEmpty { entries[index].output = String(shown.prefix(16_000)) }
        case "gui_ask_user":
            if let asking { answer(asking, with: nil) }
            let input = update["input"] as? [String: Any] ?? [:]
            let options = (input["options"] as? [Any] ?? []).compactMap { option -> Ask.Option? in
                let name = option as? String
                    ?? (option as? [String: Any]).flatMap { $0["label"] as? String ?? $0["name"] as? String ?? $0["value"] as? String }
                return name.map { Ask.Option(id: $0, name: $0, kind: "answer") }
            }
            asking = Ask(
                wants: .question,
                title: update["question"] as? String ?? "Codegraff has a question",
                detail: nil,
                options: options
            )
        case "config_option_update":
            adopt(update)
        case "gui_turn_end":
            // A turn graff woke up for on its own has ended; one Search
            // started ends with its answer instead.
            if !prompting { settle(true) }
        default:
            // Commands, plans, modes, usage: nothing the column shows yet.
            break
        }
    }

    /// A reply or a thought arrives a few words at a time; each piece goes
    /// on the end of the one before, until something else comes between.
    private func flow(_ kind: Entry.Kind, _ piece: String) {
        guard !piece.isEmpty else { return }
        if let last = entries.indices.last, entries[last].kind == kind {
            entries[last].text += piece
            entries[last].until = Date()
        } else {
            entries.append(Entry(kind: kind, text: piece))
        }
    }

    private func asked(_ method: String, id: Any, params: [String: Any]) {
        let key = "\(id)"
        owed[key] = id
        switch method {
        case "session/request_permission":
            // Only from a graff that wasn't started with --yolo, such as one
            // named in Settings that ignores it. Asked, not assumed.
            if let session, let from = params["sessionId"] as? String, from != session {
                reply(to: key, result: ["outcome": ["outcome": "cancelled"]])
                return
            }
            let call = params["toolCall"] as? [String: Any] ?? [:]
            let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> Ask.Option? in
                guard let id = option["optionId"] as? String else { return nil }
                return Ask.Option(id: id, name: option["name"] as? String ?? id, kind: option["kind"] as? String ?? "")
            }
            if let asking { answer(asking, with: nil) }
            asking = Ask(
                wants: .permission(request: key),
                title: call["title"] as? String ?? "Codegraff wants to do something on your Mac",
                detail: Agent.brief(call["rawInput"]),
                options: options
            )
        default:
            reply(to: key, error: ["code": -32601, "message": "Method not found: \(method)"])
        }
    }

    // MARK: - the wire

    private func call(_ method: String, _ params: [String: Any], then: @escaping (Result<Any, Failure>) -> Void) {
        guard let pipe else {
            then(.failure(Failure(code: -1, message: "graff isn't running")))
            return
        }
        let id = next
        next += 1
        waiting[id] = then
        if !pipe.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) {
            waiting[id] = nil
            then(.failure(Failure(code: 0, message: "That's too long to send in one message")))
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        pipe?.send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func reply(to key: String, result: Any? = nil, error: [String: Any]? = nil) {
        guard let id = owed.removeValue(forKey: key) else { return }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { message["error"] = error } else { message["result"] = result ?? NSNull() }
        pipe?.send(message)
    }

    /// Everything still waiting on graff hears that it won't come.
    private func fail(_ failure: Failure) {
        let answers = waiting.values
        waiting = [:]
        answers.forEach { $0(.failure(failure)) }
    }

    // MARK: - pieces

    /// graff's own browser, kuri, switched off for the graff that runs here:
    /// in a browser, the browser is the one to use, and a second one driven
    /// from the shell only competes with it. graff reads the switch from
    /// .harness/settings.json in the folder it works in — {"skills": {"kuri":
    /// false}}, the same one `/skills remove kuri` writes — so graff
    /// everywhere else keeps it. Anything else in the file is left as it is.
    static func leaveKuriOut() {
        let folder = Agent.folder.appendingPathComponent(".harness", isDirectory: true)
        let file = folder.appendingPathComponent("settings.json")
        var settings = (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var skills = settings["skills"] as? [String: Any] ?? [:]
        guard skills["kuri"] as? Bool != false else { return }
        skills["kuri"] = false
        settings["skills"] = skills
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// graff's own steps for finding and loading tools.
    private static let plumbing: Set<String> = ["mcp_search_tools", "load_tool_schemas", "mcp_select_tool", "read_tool_result"]

    /// Said once at the start of each session, ahead of the first message:
    /// where graff is, and what it has to hand here that it wouldn't at a
    /// terminal.
    private static let introduction = """
    You are Codegraff, running inside browse, the web browser the user is using right now; \
    they are talking to you from beside the page, or from a page of its own. For anything on \
    the web use the `browse` MCP tools (mcp__browse__*): `search`, then `read_pages` with many \
    links at once — they load in parallel in pages the user doesn't see — and `open` a page to \
    act on it. For steps on a page — a form, a search and its filters — `drive` takes the goal \
    and the values to type and does the clicking and typing quickly; `form_fields` and `fill` \
    are there too, and set many fields at once. When it is on the page the user is looking at, act on their tab \
    (its id comes with the page) so they watch it happen. Fill freely, but ask before \
    submitting anything that pays, sends, posts, books, deletes or signs them up, and never \
    make up details about them — ask. The folder you are in is just your scratch space, not a \
    project. Answer plainly and name your sources, as markdown links.
    """

    /// A conversation as words, for a graff that has lost its own record
    /// of it: what was asked and what was answered, the newest kept whole.
    static func transcript(_ entries: [Entry]) -> String? {
        let said = entries.compactMap { entry -> String? in
            switch entry.kind {
            case .you: return "User: " + entry.text
            case .reply: return "You: " + entry.text
            default: return nil
            }
        }
        guard !said.isEmpty else { return nil }
        let whole = said.joined(separator: "\n\n")
        return whole.count > 12_000 ? "…\n" + String(whole.suffix(12_000)) : whole
    }

    /// graff's folder for anything it makes when nobody said where: inside
    /// Search's own, so nothing lands loose in the home folder.
    static var folder: URL {
        let url = Store.folder.appendingPathComponent("Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// graff's "Authentication required: run `graff login`", however it
    /// arrives. By the words: graff uses the same code for other refusals.
    private static func wantsSignIn(_ failure: Failure) -> Bool {
        failure.message.localizedCaseInsensitiveContains("authentication required")
            || failure.message.localizedCaseInsensitiveContains("graff login")
    }

    /// An id or a code, whether it came as a number or as a string.
    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    /// The text of a content block.
    private static func text(_ content: Any?) -> String {
        guard let block = content as? [String: Any] else { return "" }
        return block["text"] as? String ?? ""
    }

    /// A tool update's content, as the column shows it: text as it is, a
    /// diff as its path and new text.
    private static func shown(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            switch item["type"] as? String {
            case "content": return text(item["content"])
            case "diff":
                let path = item["path"] as? String ?? ""
                let new = item["newText"] as? String ?? ""
                return path.isEmpty ? new : "\(path)\n\(new)"
            default: return nil
            }
        }
        .joined(separator: "\n")
    }

    /// The command or arguments behind a question, short enough to read.
    private static func brief(_ input: Any?) -> String? {
        guard let input else { return nil }
        if let object = input as? [String: Any] {
            for key in ["command", "cmd", "path", "file_path", "url"] {
                if let value = object[key] as? String { return value }
            }
        }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return String(string.prefix(600))
    }

    /// A reply's markdown, inline: bold, code, links. Anything it can't read
    /// shows as it was written.
    static func rich(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// How many bytes something takes on the wire.
    private static func wire(_ object: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))?.count ?? .max
    }

    /// The prompt: the page, cut to whatever room the words leave in one
    /// line, then the words.
    private static func blocks(_ text: String, page: (address: String, title: String, text: String, tab: String)?) -> [[String: Any]] {
        let words: [String: Any] = ["type": "text", "text": text]
        guard let page else { return [words] }
        func with(_ body: String) -> [[String: Any]] {
            [
                ["type": "text", "text": "I'm looking at this page in my browser (tab \(page.tab)):"],
                ["type": "resource", "resource": [
                    "uri": page.address,
                    "mimeType": "text/plain",
                    "text": body,
                ]],
                words,
            ]
        }
        let whole = page.title.isEmpty ? page.text : "\(page.title)\n\n\(page.text)"
        var body = whole
        // Room for the envelope around it — the method, the session's name —
        // and for the introduction and an earlier conversation, which may
        // go out ahead of it.
        let room = longestLine - 16_000
        var size = wire(with(body))
        while size > room, !body.isEmpty {
            let keep = Int(Double(body.count) * Double(room) / Double(size) * 0.95)
            body = String(body.prefix(max(0, keep)))
            size = wire(with(body + "\n…"))
        }
        if body.isEmpty { return [words] }
        return with(body.count < whole.count ? body + "\n…" : body)
    }

    /// The page's words, as a reader would take them: its text, not its
    /// markup — and the tab's id as the browser's tools know it, so graff can
    /// act on the page it was shown.
    private static func read(_ tab: Tab) async -> (address: String, title: String, text: String, tab: String)? {
        guard let web = tab.built, let address = tab.address else { return nil }
        let title = tab.title
        let text: String = await withCheckedContinuation { done in
            web.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                done.resume(returning: (value as? String) ?? "")
            }
        }
        return (address.absoluteString, title, text, String(tab.id.uuidString.prefix(8)).lowercased())
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What graff runs in: the app's own environment with the PATH a
    /// Terminal would have — an app opened from the Dock gets the bare
    /// system one, and graff's shell wants the tools Terminal finds — graff's
    /// own folder first. It stays in the folder it is given rather than
    /// making itself a worktree, and nothing Claude Code left in the
    /// environment makes it think it is running inside that.
    nonisolated private static func environment(for program: URL, path: String?, lean: Bool) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var folders: [String] = [program.deletingLastPathComponent().path]
        folders += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += (path ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let kept = folders.filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = kept.joined(separator: ":")
        environment["GRAFF_AUTO_ISOLATE"] = "0"
        // The browser's tools come ready to call, not folded away behind
        // graff's search for tools: in a browser they are the point.
        environment["GRAFF_MCP_EAGER"] = "browse"
        // Straight to SSE. graff's codex WebSocket prewarm goes out without a
        // model, is refused, and the first turn of every session retries a
        // socket and falls back — ~7 s of a 12 s "hey there", paid again by
        // each new chat's graff (justrach/codegraff#1250). Over SSE the first
        // word comes in ~2.5 s; with the fix, WS still takes 4–5 s for a
        // first turn, its prewarm round trip ahead of it (24 Sep 2026).
        if environment["GRAFF_CODEX_WS"] == nil { environment["GRAFF_CODEX_WS"] = "off" }
        // Lean, unless Settings says otherwise: the browser's tools and
        // graff's own, not every MCP server the user's other apps name. Those
        // come up with every graff — a node REPL, code indexes — and took a
        // chat from ~40 MB to ~200 MB (25 Sep 2026). graff reads Search's
        // config (AgentTools.own) in place of its own, and leaves Claude's,
        // Cursor's and Codex's alone (GRAFF_NO_PLUGINS; honoured before MCP
        // starts from the graff after justrach/codegraff 0.0.302.4).
        if lean {
            environment["GRAFF_MCP_CONFIG"] = AgentTools.own.path
            environment["GRAFF_NO_PLUGINS"] = "1"
        }
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION"] {
            environment[key] = nil
        }
        return environment
    }

    /// Where graff is. The place Settings names, if it names one; otherwise
    /// the newest of every copy on the Mac — the installer's, Homebrew's,
    /// Harness's and the Codegraff app's, and any on the login shell's PATH —
    /// as Harness chooses. That shell's PATH comes back too, for graff's own
    /// commands.
    nonisolated static func locate(custom: String) async -> (program: URL, path: String?)? {
        await Task.detached {
            let files = FileManager.default
            let home = files.homeDirectoryForCurrentUser.path
            let shell = Agent.loginPath()
            let named = (custom as NSString).expandingTildeInPath
            if !named.isEmpty {
                return files.isExecutableFile(atPath: named) ? (URL(fileURLWithPath: named), shell) : nil
            }
            var places = (shell ?? "").split(separator: ":").map { "\($0)/graff" }
            places += [
                "\(home)/.local/bin/graff",
                "\(home)/bin/graff",
                "/opt/homebrew/bin/graff",
                "/usr/local/bin/graff",
                "\(home)/.harness/bin/graff",
                "/Applications/Harness.app/Contents/Resources/bin/graff",
                "/Applications/Codegraff.app/Contents/Resources/graff",
            ]
            var seen = Set<String>()
            var best: (url: URL, version: [Int])?
            for place in places where files.isExecutableFile(atPath: place) {
                let url = URL(fileURLWithPath: place)
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let version = Agent.version(of: url)
                if let current = best, !Agent.newer(version, than: current.version) { continue }
                best = (url, version)
            }
            return best.map { ($0.url, shell) }
        }.value
    }

    /// Part by part, a missing part counting as nought; a tie keeps the
    /// copy found first.
    nonisolated private static func newer(_ one: [Int], than other: [Int]) -> Bool {
        for index in 0..<max(one.count, other.count) {
            let a = index < one.count ? one[index] : 0
            let b = index < other.count ? other[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// `graff --version`, as numbers to compare part by part:
    /// "graff 0.0.302.4" is [0, 0, 302, 4]. Nothing, for one that won't say.
    nonisolated private static func version(of program: URL) -> [Int] {
        guard let said = run(program.path, ["--version"]) else { return [] }
        let word = said.split(whereSeparator: { $0 == " " || $0.isNewline })
            .first { $0.first?.isNumber == true || ($0.first == "v" && $0.dropFirst().first?.isNumber == true) }
        guard let word else { return [] }
        return word.drop { $0 == "v" }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// The PATH a login shell has — what Terminal would give graff.
    nonisolated private static func loginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let path = run(shell, ["-l", "-c", "printf %s \"$PATH\""])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    /// A short program's output, or nothing if it fails or takes too long —
    /// a shell profile that hangs doesn't hang the column with it.
    nonisolated private static func run(_ program: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// graff itself: one process, one JSON-RPC message a line each way.
///
/// Reading happens off the main thread and each whole line is handed over
/// on it; writing goes through a queue of its own, so a long page never
/// holds the window up waiting for graff to take it in.
final class AcpPipe: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writes = DispatchQueue(label: "search.agent.write")
    private let lock = NSLock()
    private var buffer = Data()
    /// The last of what graff wrote to stderr, for when it stops.
    private var said = Data()
    private var over = false

    var onMessage: (@MainActor ([String: Any]) -> Void)?
    var onExit: (@MainActor (Int32, String) -> Void)?

    /// graff reads a line into 64 KiB and stops listening at a longer one.
    static let longest = 65_000

    init(program: URL, arguments: [String], environment: [String: String], folder: URL) {
        process.executableURL = program
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.take(chunk)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.said.append(chunk)
            if self.said.count > 4096 { self.said = Data(self.said.suffix(4096)) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let status = process.terminationStatus
            // Whatever was still on its way arrives before the news that
            // graff ended.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.lock.lock()
                let words = String(decoding: self.said, as: UTF8.self)
                let ended = self.over
                self.lock.unlock()
                let why = AcpPipe.lastLines(words)
                DispatchQueue.main.async {
                    guard !ended else { return }
                    MainActor.assumeIsolated { self.onExit?(status, why) }
                }
            }
        }
        try process.run()
    }

    /// Its input closed first, so it saves the session and ends on its own;
    /// told to, if it hasn't after a moment.
    func stop() {
        lock.lock()
        over = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let handle = input.fileHandleForWriting
        let process = process
        writes.async {
            try? handle.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// False when the message is too long for graff to take.
    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard var line = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
              line.count < AcpPipe.longest
        else { return false }
        line.append(0x0A)
        let handle = input.fileHandleForWriting
        writes.async {
            try? handle.write(contentsOf: line)
        }
        return true
    }

    private func take(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<end))
            buffer.removeSubrange(buffer.startIndex...end)
        }
        let ended = over
        lock.unlock()
        guard !ended else { return }
        // Anything that isn't a JSON-RPC message is graff talking to itself.
        let messages = lines.compactMap { line -> [String: Any]? in
            guard !line.isEmpty,
                  let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  message["jsonrpc"] as? String == "2.0"
            else { return nil }
            return message
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                messages.forEach { self.onMessage?($0) }
            }
        }
    }

    /// The end of stderr, which is where a program says why it stopped.
    private static func lastLines(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: "\n")
    }
}
