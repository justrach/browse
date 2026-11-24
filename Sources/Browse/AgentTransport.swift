import Foundation

extension Agent {
    nonisolated static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What graff runs in: the app's own environment with the PATH a
    /// Terminal would have — an app opened from the Dock gets the bare
    /// system one, and graff's shell wants the tools Terminal finds — graff's
    /// own folder first. It stays in the folder it is given rather than
    /// making itself a worktree, and nothing Claude Code left in the
    /// environment makes it think it is running inside that.
    nonisolated static func environment(for program: URL, path: String?, lean: Bool) -> [String: String] {
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
    /// Locate an ACP agent binary on this Mac (`graff`, `agy`, `opencode`,
    /// `gemini`, or `pi-acp`), plus the user's login shell PATH.
    nonisolated static func locate(backend: Backend = .graff, customGraff: String = "") async -> (program: URL, path: String?)? {
        if backend == .graff {
            return await locate(custom: customGraff)
        }
        return await Task.detached {
            let shell = Agent.loginPath()
            guard let url = Agent.findExecutable(for: backend, shellPath: shell) else { return nil }
            return (url, shell)
        }.value
    }

    /// Discover all supported ACP agent backends currently installed on this Mac.
    nonisolated static func discoverBackends(customGraff: String = "") async -> [Backend] {
        await Task.detached {
            let files = FileManager.default
            let home = files.homeDirectoryForCurrentUser.path
            let shell = Agent.loginPath()
            var found: [Backend] = []
            for candidate in Backend.allCases {
                if candidate == .graff {
                    let named = (customGraff as NSString).expandingTildeInPath
                    if !named.isEmpty && files.isExecutableFile(atPath: named) {
                        found.append(.graff)
                        continue
                    }
                    let graffPlaces = (shell ?? "").split(separator: ":").map { "\($0)/graff" } + [
                        "\(home)/.local/bin/graff", "\(home)/bin/graff",
                        "/opt/homebrew/bin/graff", "/usr/local/bin/graff",
                        "\(home)/.harness/bin/graff",
                        "/Applications/Harness.app/Contents/Resources/bin/graff",
                        "/Applications/Codegraff.app/Contents/Resources/graff",
                    ]
                    if graffPlaces.contains(where: { files.isExecutableFile(atPath: $0) }) {
                        found.append(.graff)
                    }
                } else if Agent.findExecutable(for: candidate, shellPath: shell) != nil {
                    found.append(candidate)
                }
            }
            return found
        }.value
    }

    /// Synchronously resolves the executable for `backend` using a pre-probed
    /// login-shell `PATH` (called once per launch by `AgentEngine`).
    nonisolated static func resolveBinarySync(backend: Backend, customGraff: String, shellPath: String?) -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        if backend == .graff {
            let named = (customGraff as NSString).expandingTildeInPath
            if !named.isEmpty {
                return files.isExecutableFile(atPath: named) ? URL(fileURLWithPath: named) : nil
            }
            var places = (shellPath ?? "").split(separator: ":").map { "\($0)/graff" }
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
            return best?.url
        }
        return findExecutable(for: backend, shellPath: shellPath)
    }

    nonisolated static func probeLoginPathOnce() -> String? {
        loginPath()
    }

    nonisolated private static func findExecutable(for backend: Backend, shellPath: String?) -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let pathDirs = (shellPath ?? "").split(separator: ":").map(String.init)
        var places: [String] = []
        switch backend {
        case .graff:
            return nil
        case .antigravity:
            places = pathDirs.map { "\($0)/agy" } + [
                "\(home)/.local/bin/agy",
                "\(home)/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
                "\(home)/.harness/bin/agy",
            ]
        case .opencode:
            places = pathDirs.map { "\($0)/opencode" } + [
                "\(home)/.opencode/bin/opencode",
                "\(home)/.local/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
            ]
        case .gemini:
            places = pathDirs.map { "\($0)/gemini" } + [
                "\(home)/.local/bin/gemini",
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
            ]
            if let versions = try? files.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
                for v in versions.sorted().reversed() {
                    places.append("\(home)/.nvm/versions/node/\(v)/bin/gemini")
                }
            }
        case .grok:
            places = pathDirs.map { "\($0)/grok" } + [
                "\(home)/.local/bin/grok",
                "\(home)/bin/grok",
                "/opt/homebrew/bin/grok",
                "/usr/local/bin/grok",
            ]
        case .devin:
            places = pathDirs.map { "\($0)/devin" } + [
                "\(home)/.local/bin/devin",
                "\(home)/bin/devin",
                "/opt/homebrew/bin/devin",
                "/usr/local/bin/devin",
            ]
        case .hermes:
            places = pathDirs.map { "\($0)/hermes" } + [
                "\(home)/.local/bin/hermes",
                "\(home)/.hermes/bin/hermes",
                "/opt/homebrew/bin/hermes",
                "/usr/local/bin/hermes",
            ]
        case .pi:
            places = pathDirs.map { "\($0)/pi-acp" } + [
                "\(home)/.local/bin/pi-acp",
                "/opt/homebrew/bin/pi-acp",
            ]
            let adaptersDir = "\(home)/.harness/adapters/pi-acp"
            if let versions = try? files.contentsOfDirectory(atPath: adaptersDir) {
                for v in versions.sorted().reversed() {
                    places.append("\(adaptersDir)/\(v)/node_modules/.bin/pi-acp")
                }
            }
        }
        for place in places where files.isExecutableFile(atPath: place) {
            return URL(fileURLWithPath: place)
        }
        return nil
    }

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

    var isRunning: Bool {
        lock.lock()
        let ended = over
        lock.unlock()
        return !ended && process.isRunning
    }

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
