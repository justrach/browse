import AppKit
import Foundation

/// Native Swift warm agent engine for `browse` (inspired by NanoHarness's
/// `harness-engine` + `model_catalogs.rs`):
///
/// 1. **One-shot binary & login-shell PATH cache**: resolves the user's login
///    shell `PATH` and all installed ACP CLIs (`graff`, `agy`, `opencode`,
///    `gemini`, `grok`, `devin`, `hermes`, `pi-acp`) once per launch instead of
///    spawning `zsh -lc` and `graff --version` on every switch or new chat.
/// 2. **Persistent on-disk model catalogs**: atomically saves each backend's
///    last live model list + effort ladder (and seeds from `~/.harness/model-catalogs`
///    on first cold run) so the model picker opens in <1 ms with zero spinner.
/// 3. **Multi-backend warm worker pool**: pre-warms the active backend at launch
///    and parks outgoing warm ACP processes on backend switch so switching
///    between Codegraff, Antigravity, OpenCode, Gemini, Grok, Devin, Hermes,
///    and Pi takes 0 ms — with automatic 10-minute idle reaping and clean exit.
@MainActor
final class AgentEngine {
    static let shared = AgentEngine()

    // MARK: - Persistent Model Catalog Cache

    struct CachedCatalog: Codable {
        struct SavedModel: Codable {
            let provider: String
            let name: String
            var displayName: String?
            var acpValue: String?
            var context: Int
            var rawMaker: String?
            var billing: String?
            var effortLevels: [String]
            var fastSupported: Bool
            var ultrafastSupported: Bool
            var serviceTiers: [String]

            init(from model: Agent.Model) {
                self.provider = model.provider
                self.name = model.name
                self.displayName = model.displayName
                self.acpValue = model.acpValue
                self.context = model.context
                self.rawMaker = model.rawMaker
                self.billing = model.billing
                self.effortLevels = model.effortLevels
                self.fastSupported = model.fastSupported
                self.ultrafastSupported = model.ultrafastSupported
                self.serviceTiers = model.serviceTiers
            }

            func toModel() -> Agent.Model {
                Agent.Model(
                    provider: provider,
                    name: name,
                    displayName: displayName,
                    acpValue: acpValue,
                    context: context,
                    rawMaker: rawMaker,
                    billing: billing,
                    effortLevels: effortLevels,
                    fastSupported: fastSupported,
                    ultrafastSupported: ultrafastSupported,
                    serviceTiers: serviceTiers
                )
            }
        }

        struct SavedEffort: Codable {
            struct Level: Codable {
                let value: String
                let name: String
            }
            let id: String
            let current: String
            let levels: [Level]

            init(from effort: Agent.Effort) {
                self.id = effort.id
                self.current = effort.current
                self.levels = effort.levels.map { Level(value: $0.value, name: $0.name) }
            }

            func toEffort() -> Agent.Effort {
                Agent.Effort(id: id, current: current, levels: levels.map { ($0.value, $0.name) })
            }
        }

        let schemaVersion: Int
        let savedAt: TimeInterval
        let models: [SavedModel]
        let currentModelID: String?
        let effort: SavedEffort?
        let modelConfigID: String?
    }

    private var memoryCatalogs: [Agent.Backend: CachedCatalog] = [:]

    private static var catalogDirectory: URL {
        Store.folder.appendingPathComponent("Agent/catalogs", isDirectory: true)
    }

    private static func catalogFile(for backend: Agent.Backend) -> URL {
        catalogDirectory.appendingPathComponent("\(backend.rawValue).json")
    }

    /// Returns cached models & effort for `backend` in <1 ms (memory → browse
    /// disk cache → optional NanoHarness disk cache seed).
    func cachedCatalog(for backend: Agent.Backend) -> (models: [Agent.Model], current: Agent.Model?, effort: Agent.Effort?, modelConfigID: String?)? {
        if let hit = memoryCatalogs[backend], !hit.models.isEmpty {
            return unpack(hit)
        }
        let path = Self.catalogFile(for: backend)
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode(CachedCatalog.self, from: data),
           decoded.schemaVersion == 1, !decoded.models.isEmpty {
            memoryCatalogs[backend] = decoded
            return unpack(decoded)
        }
        if let seeded = Self.seedFromHarnessCache(backend: backend), !seeded.models.isEmpty {
            memoryCatalogs[backend] = seeded
            return unpack(seeded)
        }
        return nil
    }

    private func unpack(_ cached: CachedCatalog) -> (models: [Agent.Model], current: Agent.Model?, effort: Agent.Effort?, modelConfigID: String?) {
        let models = cached.models.map { $0.toModel() }
        let current = cached.currentModelID.flatMap { id in models.first { $0.id == id || $0.acpValue == id } } ?? models.first
        return (models, current, cached.effort?.toEffort(), cached.modelConfigID)
    }

    /// Atomically persists a live catalog for `backend` (0600 permissions,
    /// matching NanoHarness `model_catalogs.rs`).
    func saveCatalog(
        for backend: Agent.Backend,
        models: [Agent.Model],
        current: Agent.Model?,
        effort: Agent.Effort?,
        modelConfigID: String?
    ) {
        guard !models.isEmpty else { return }
        let snapshot = CachedCatalog(
            schemaVersion: 1,
            savedAt: Date().timeIntervalSince1970,
            models: models.map(CachedCatalog.SavedModel.init),
            currentModelID: current?.id,
            effort: effort.map(CachedCatalog.SavedEffort.init),
            modelConfigID: modelConfigID
        )
        memoryCatalogs[backend] = snapshot
        let dir = Self.catalogDirectory
        let dst = Self.catalogFile(for: backend)
        Task.detached(priority: .utility) {
            let files = FileManager.default
            try? files.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let staging = dir.appendingPathComponent(".\(backend.rawValue).\(UUID().uuidString).tmp")
            do {
                try data.write(to: staging, options: .atomic)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                if files.fileExists(atPath: dst.path) {
                    _ = try files.replaceItemAt(dst, withItemAt: staging)
                } else {
                    try files.moveItem(at: staging, to: dst)
                }
            } catch {
                try? files.removeItem(at: staging)
            }
        }
    }

    /// Best-effort read-only seed from NanoHarness's `~/.harness/model-catalogs/`
    /// on first cold start so users who already run Harness see instant models.
    private static func seedFromHarnessCache(backend: Agent.Backend) -> CachedCatalog? {
        let folderName: String
        switch backend {
        case .graff: folderName = "graff"
        case .antigravity: folderName = "antigravity"
        case .opencode: folderName = "opencode"
        case .grok: folderName = "grok"
        case .devin: folderName = "devin"
        case .pi: folderName = "pi"
        case .gemini, .hermes: return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".harness/model-catalogs/\(folderName)", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let newest = entries
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .first
        guard let newest,
              let data = try? Data(contentsOf: newest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["catalog"] as? [[String: Any]], !rows.isEmpty
        else { return nil }

        var saved: [CachedCatalog.SavedModel] = []
        var seen = Set<String>()
        for row in rows {
            guard let rawID = row["id"] as? String, !rawID.isEmpty else { continue }
            let label = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let rawMaker = (row["maker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let billing = (row["billing"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let context = row["context"] as? Int ?? 0
            let levels = (row["reasoning_levels"] as? [Any] ?? []).compactMap { ($0 as? String)?.lowercased() }
            let provider: String
            let name: String
            if (backend == .graff || backend == .opencode), let slash = rawID.firstIndex(of: "/") {
                provider = String(rawID[..<slash])
                name = String(rawID[rawID.index(after: slash)...])
            } else {
                provider = backend.providerKey
                name = rawID
            }
            let model = Agent.Model(
                provider: provider,
                name: name,
                displayName: label,
                acpValue: backend == .graff ? nil : rawID,
                context: context,
                rawMaker: rawMaker,
                billing: billing ?? "plan",
                effortLevels: levels
            )
            guard model.talks, seen.insert(model.id).inserted else { continue }
            saved.append(CachedCatalog.SavedModel(from: model))
        }
        guard !saved.isEmpty else { return nil }
        return CachedCatalog(
            schemaVersion: 1,
            savedAt: Date().timeIntervalSince1970,
            models: saved,
            currentModelID: saved.first.map { "\($0.provider)/\($0.name)" },
            effort: nil,
            modelConfigID: nil
        )
    }

    // MARK: - Cached Binary & Login Shell PATH Resolution

    struct ResolvedBinary: Sendable {
        let program: URL
        let shellPath: String?
    }

    private var cachedShellPath: String?
    private var resolvedShell = false
    private var binaryCache: [Agent.Backend: ResolvedBinary] = [:]
    private var cachedCustomGraff: String = ""
    private var discoveredBackends: [Agent.Backend] = []
    private var discoveryTask: Task<[Agent.Backend], Never>?

    func invalidateBinaries() {
        binaryCache = [:]
        discoveredBackends = []
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    /// Resolves the login shell PATH and all installed ACP backends once per
    /// launch (coalescing concurrent callers).
    func discoverAll(customGraff: String) async -> [Agent.Backend] {
        if customGraff != cachedCustomGraff {
            cachedCustomGraff = customGraff
            binaryCache.removeValue(forKey: .graff)
            discoveredBackends = []
            discoveryTask = nil
        }
        if !discoveredBackends.isEmpty { return discoveredBackends }
        if let existing = discoveryTask { return await existing.value }

        let existingShell = resolvedShell ? cachedShellPath : nil
        let alreadyHaveShell = resolvedShell
        let task = Task<[Agent.Backend], Never> {
            let result = await Task.detached(priority: .userInitiated) {
                let shell = alreadyHaveShell ? existingShell : Agent.probeLoginPathOnce()
                var map: [Agent.Backend: ResolvedBinary] = [:]
                var found: [Agent.Backend] = []
                for backend in Agent.Backend.allCases {
                    if let url = Agent.resolveBinarySync(backend: backend, customGraff: customGraff, shellPath: shell) {
                        map[backend] = ResolvedBinary(program: url, shellPath: shell)
                        found.append(backend)
                    }
                }
                return (shell, map, found)
            }.value
            self.cachedShellPath = result.0
            self.resolvedShell = true
            self.binaryCache = result.1
            self.discoveredBackends = result.2
            self.discoveryTask = nil
            return result.2
        }
        discoveryTask = task
        return await task.value
    }

    func binary(for backend: Agent.Backend, customGraff: String) async -> ResolvedBinary? {
        if customGraff == cachedCustomGraff, let cached = binaryCache[backend] {
            return cached
        }
        _ = await discoverAll(customGraff: customGraff)
        return binaryCache[backend]
    }

    // MARK: - Multi-Backend Warm Worker Pool

    /// A parked, already-initialized ACP subprocess ready for 0 ms checkout.
    final class WarmWorker {
        let backend: Agent.Backend
        let pipe: AcpPipe
        let program: URL
        var session: String?
        var models: [Agent.Model] = []
        var model: Agent.Model?
        var effort: Agent.Effort?
        var modelConfigID: String?
        var serviceTier: Agent.ServiceTier = .standard
        var commands: [String] = []
        var nextID: Int = 1
        var lastUsed = Date()
        var ready = false
        var failed = false
        /// Callers waiting on an in-flight background pre-warm to finish.
        var waiters: [(Bool) -> Void] = []

        init(backend: Agent.Backend, pipe: AcpPipe, program: URL) {
            self.backend = backend
            self.pipe = pipe
            self.program = program
        }

        var isAlive: Bool { !failed && pipe.isRunning }

        func finishWaiters(_ ok: Bool) {
            let list = waiters
            waiters = []
            list.forEach { $0(ok) }
        }
    }

    private var pool: [Agent.Backend: WarmWorker] = [:]
    private var reaper: Task<Void, Never>?
    private static let poolIdleTTL: TimeInterval = 10 * 60
    /// Keep up to 3 warm ACP backends parked in memory so switching between
    /// favorite agents (e.g. Codegraff ↔ Antigravity ↔ OpenCode) is 0 ms.
    private static let maxParkedWorkers = 3

    /// Parks an already-live worker back into the warm pool (e.g. when the
    /// user switches to another backend), detaching it cleanly from `Agent`.
    func park(_ worker: WarmWorker) {
        guard worker.isAlive, worker.session != nil else {
            worker.pipe.stop()
            return
        }
        worker.lastUsed = Date()
        // Neutralize callbacks while parked so stray notifications don't leak
        // into whatever backend is currently active in the UI.
        let backend = worker.backend
        worker.pipe.onMessage = { _ in }
        worker.pipe.onExit = { [weak self, weak worker] _, _ in
            guard let self, let worker else { return }
            worker.failed = true
            if self.pool[backend] === worker {
                self.pool.removeValue(forKey: backend)
            }
        }
        if let old = pool[backend], old !== worker {
            old.pipe.stop()
        }
        pool[backend] = worker
        trimPool()
        ensureReaper()
    }

    /// Immediately checks out a warm, alive worker for `backend` if one is
    /// parked in the pool (0 ms warm time!).
    func checkout(_ backend: Agent.Backend) -> WarmWorker? {
        guard let worker = pool[backend] else { return nil }
        if !worker.isAlive {
            pool.removeValue(forKey: backend)
            return nil
        }
        if worker.ready {
            pool.removeValue(forKey: backend)
            worker.lastUsed = Date()
            return worker
        }
        return nil
    }

    /// Returns an in-flight pre-warming worker if one is already mid-handshake
    /// so `Agent` can attach to it rather than spawning a duplicate process.
    func pendingWorker(for backend: Agent.Backend) -> WarmWorker? {
        guard let worker = pool[backend], worker.isAlive, !worker.ready else { return nil }
        return worker
    }

    /// Speculatively pre-warms `backend` in the background (starting MCP tools,
    /// spawning the ACP process, running `initialize` + `session/new`, and
    /// caching its live model catalog) so switching to it takes 0 ms.
    func prewarm(backend: Agent.Backend, prefs: Preferences) {
        guard prefs.usesAgent else { return }
        if let existing = pool[backend], existing.isAlive {
            existing.lastUsed = Date()
            return
        }
        let custom = prefs.agentPath
        let lean = !prefs.agentAllTools
        let savedModel = prefs.agentModel(for: backend.rawValue)
        let savedEffort = prefs.agentEffort

        Task { [weak self] in
            guard let self, prefs.usesAgent else { return }
            if !(await AgentTools.shared.start()) {
                AgentTools.withdraw()
            }
            guard let resolved = await self.binary(for: backend, customGraff: custom) else { return }
            // Re-check in case another prewarm or foreground start beat us.
            if let existing = self.pool[backend], existing.isAlive { return }
            if backend == .graff { Agent.leaveKuriOut() }

            var args = backend.acpArguments
            if backend == .graff, !savedModel.isEmpty {
                args += ["--model", savedModel]
            }
            let pipe = AcpPipe(
                program: resolved.program,
                arguments: args,
                environment: Agent.environment(for: resolved.program, path: resolved.shellPath, lean: lean),
                folder: Agent.folder
            )
            let worker = WarmWorker(backend: backend, pipe: pipe, program: resolved.program)
            var pending: [Int: (Result<Any, Agent.Failure>) -> Void] = [:]

            func sendCall(_ method: String, _ params: [String: Any], then: @escaping (Result<Any, Agent.Failure>) -> Void) {
                let id = worker.nextID
                worker.nextID += 1
                pending[id] = then
                if !pipe.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) {
                    pending.removeValue(forKey: id)
                    then(.failure(Agent.Failure(code: -1, message: "Message too long")))
                }
            }

            pipe.onMessage = { [weak worker] msg in
                guard let worker else { return }
                if let method = msg["method"] as? String, let id = msg["id"], !(id is NSNull) {
                    // Auto-decline unexpected prompts during idle prewarm.
                    _ = worker.pipe.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Prewarm idle"]])
                    _ = method
                    return
                }
                if let id = Agent.number(msg["id"]), let cb = pending.removeValue(forKey: id) {
                    if let error = msg["error"] as? [String: Any] {
                        cb(.failure(Agent.Failure(code: Agent.number(error["code"]) ?? 0, message: error["message"] as? String ?? "ACP error")))
                    } else {
                        cb(.success(msg["result"] ?? NSNull()))
                    }
                }
            }

            pipe.onExit = { [weak self, weak worker] _, _ in
                guard let self, let worker else { return }
                worker.failed = true
                let callbacks = pending.values
                pending.removeAll()
                callbacks.forEach { $0(.failure(Agent.Failure(code: -1, message: "Exited during prewarm"))) }
                worker.finishWaiters(false)
                if self.pool[backend] === worker {
                    self.pool.removeValue(forKey: backend)
                }
            }

            do {
                try pipe.start()
            } catch {
                worker.failed = true
                return
            }

            self.pool[backend] = worker
            self.trimPool(keeping: backend)
            self.ensureReaper()

            sendCall("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": [String: Any]()],
                "clientInfo": ["name": "browse", "title": "browse", "version": Updater.version],
            ]) { [weak self, weak worker] initRes in
                guard let self, let worker, !worker.failed else { return }
                guard case .success = initRes else {
                    worker.failed = true
                    worker.pipe.stop()
                    if self.pool[backend] === worker { self.pool.removeValue(forKey: backend) }
                    worker.finishWaiters(false)
                    return
                }
                sendCall("session/new", ["cwd": Agent.folder.path, "mcpServers": AgentTools.shared.acpServers]) { [weak self, weak worker] sesRes in
                    guard let self, let worker, !worker.failed else { return }
                    guard case .success(let value) = sesRes,
                          let id = (value as? [String: Any])?["sessionId"] as? String
                    else {
                        worker.failed = true
                        worker.pipe.stop()
                        if self.pool[backend] === worker { self.pool.removeValue(forKey: backend) }
                        worker.finishWaiters(false)
                        return
                    }
                    worker.session = id
                    let parsed = Agent.parseSessionOptions(value, backend: backend)
                    worker.effort = parsed.effort
                    worker.modelConfigID = parsed.modelConfigID
                    if !parsed.models.isEmpty {
                        worker.models = parsed.models
                        worker.model = parsed.current
                        self.saveCatalog(for: backend, models: parsed.models, current: parsed.current, effort: parsed.effort, modelConfigID: parsed.modelConfigID)
                    }
                    worker.ready = true
                    worker.lastUsed = Date()
                    worker.finishWaiters(true)

                    // Apply remembered model/effort silently on the parked worker.
                    if backend == .graff {
                        sendCall("graff/models", [:]) { [weak self, weak worker] modelsRes in
                            guard let self, let worker, !worker.failed,
                                  case .success(let mVal) = modelsRes,
                                  let reply = mVal as? [String: Any]
                            else { return }
                            let catalog = Agent.parseGraffModels(reply)
                            if !catalog.models.isEmpty {
                                worker.models = catalog.models
                                worker.model = catalog.current
                                worker.serviceTier = catalog.serviceTier
                                self.saveCatalog(for: .graff, models: catalog.models, current: catalog.current, effort: worker.effort, modelConfigID: nil)
                            }
                        }
                    } else if !savedModel.isEmpty,
                              let match = worker.models.first(where: { $0.id == savedModel || $0.acpValue == savedModel }),
                              match != worker.model {
                        let wire = match.acpValue ?? match.name
                        if let configId = worker.modelConfigID {
                            sendCall("session/set_config_option", ["sessionId": id, "configId": configId, "value": wire]) { [weak worker] res in
                                if case .success(let r) = res, let worker {
                                    let next = Agent.parseSessionOptions(r, backend: backend)
                                    worker.effort = next.effort
                                    worker.model = match
                                }
                            }
                        } else {
                            sendCall("session/set_model", ["sessionId": id, "modelId": wire]) { [weak worker] res in
                                if case .success = res { worker?.model = match }
                            }
                        }
                    }
                    if let effort = worker.effort, !savedEffort.isEmpty,
                       savedEffort != effort.current,
                       effort.levels.contains(where: { $0.value == savedEffort }) {
                        sendCall("session/set_config_option", ["sessionId": id, "configId": effort.id, "value": savedEffort]) { [weak worker] res in
                            if case .success(let r) = res, let worker {
                                worker.effort = Agent.parseSessionOptions(r, backend: backend).effort ?? worker.effort
                            }
                        }
                    }
                }
            }
        }
    }

    func shutdown(backend: Agent.Backend) {
        if let w = pool.removeValue(forKey: backend) {
            w.failed = true
            w.finishWaiters(false)
            w.pipe.stop()
        }
    }

    func shutdownAll() {
        reaper?.cancel()
        reaper = nil
        let all = Array(pool.values)
        pool.removeAll()
        for w in all {
            w.failed = true
            w.finishWaiters(false)
            w.pipe.stop()
        }
    }

    private func trimPool(keeping protected: Agent.Backend? = nil) {
        while pool.count > Self.maxParkedWorkers {
            let victim = pool
                .filter { $0.key != protected }
                .min { $0.value.lastUsed < $1.value.lastUsed }
            guard let victim else { break }
            pool.removeValue(forKey: victim.key)
            victim.value.failed = true
            victim.value.finishWaiters(false)
            victim.value.pipe.stop()
        }
    }

    private func ensureReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                let now = Date()
                let expired = self.pool.filter { now.timeIntervalSince($0.value.lastUsed) > Self.poolIdleTTL }
                for (backend, worker) in expired {
                    self.pool.removeValue(forKey: backend)
                    worker.failed = true
                    worker.finishWaiters(false)
                    worker.pipe.stop()
                }
                if self.pool.isEmpty {
                    self.reaper = nil
                    return
                }
            }
        }
    }
}
