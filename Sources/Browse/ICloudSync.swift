import AppKit
import CloudKit
import Combine
import Security

// Sync with iCloud: open tabs, spaces, bookmarks, and shared settings across
// your Apple devices through your private CloudKit database (`CKSyncEngine`,
// container `iCloud.com.codegraff.search`, zone `"Browse"`, record type `"Item"`,
// JSON in `encryptedValues["data"]`, `"at"` for latest-wins).
//
// Off by default, and mutually exclusive with Codegraff Sync so the two never
// fight over bookmarks. CloudKit is only touched when the app bundle carries
// the iCloud container entitlement (and never during test runs). Every
// CKSyncEngine call runs in a detached task so we never await CloudKit inside
// one of its own delegate callbacks.

// MARK: - Synced Record Shapes

struct DeviceTabs: Codable, Equatable {
    struct Page: Codable, Equatable, Hashable {
        var url: String
        var title: String
    }

    var name: String
    var platform: String
    var at: Date
    var tabs: [Page]
}

struct SharedSettings: Codable, Equatable {
    var engine: String?
    var custom: String?
    var look: String?
}

// MARK: - Ledger (Pure Sync State & Conflict Rules)

struct ICloudLedger: Codable, Equatable {
    var device = UUID().uuidString
    var joined = false
    var at: [String: Date] = [:]
    var values: [String: Data] = [:]
    var fields: [String: Data] = [:]
    var state: Data?

    var deviceKey: String { "device." + device }

    mutating func offer(_ key: String, _ data: Data, now: Date) -> Bool {
        guard joined, values[key] != data else { return false }
        values[key] = data
        at[key] = now
        return true
    }

    enum Arrival: Equatable {
        case stale
        case taken
    }

    mutating func arrive(_ key: String, canonical: Data, at stamp: Date) -> Arrival {
        if let ours = at[key], ours > stamp, values[key] != nil { return .stale }
        values[key] = canonical
        at[key] = stamp
        return .taken
    }

    mutating func resolveConflict(_ key: String, serverCanonical: Data?, serverAt: Date, fields serverFields: Data) -> Bool {
        fields[key] = serverFields
        if let serverCanonical, let ours = at[key], serverAt > ours {
            values[key] = serverCanonical
            at[key] = serverAt
            return true
        }
        return false
    }
}

enum ICloudMerge {
    static func canonical(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return data }
        return out
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let raw = try? encoder.encode(value) else { return nil }
        return canonical(raw)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// Open tabs to publish: ordinary http(s) web pages, never private or pinned.
    static func pages(_ tabs: [(url: URL?, title: String, shy: Bool, pinned: Bool)]) -> [DeviceTabs.Page] {
        var seen = Set<String>()
        return tabs.compactMap { tab in
            guard !tab.shy, !tab.pinned, let url = tab.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted
            else { return nil }
            return DeviceTabs.Page(url: url.absoluteString, title: tab.title)
        }
    }

    static func union(bookmarks theirs: [Bookmark], _ ours: [Bookmark]) -> [Bookmark] {
        func flat(_ nodes: [Bookmark]) -> [Bookmark] { nodes.flatMap { [$0] + flat($0.children ?? []) } }
        let known = flat(theirs)
        let ids = Set(known.map(\.id))
        let urls = Set(known.compactMap(\.url))
        func missing(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.compactMap { node in
                guard !ids.contains(node.id) else { return nil }
                if let url = node.url { return urls.contains(url) ? nil : node }
                var folder = node
                folder.children = missing(node.children ?? [])
                return (folder.children ?? []).isEmpty && !(node.children ?? []).isEmpty ? nil : folder
            }
        }
        return theirs + missing(ours)
    }

    static func union(spaces theirs: [Space], _ ours: [Space]) -> [Space] {
        theirs + ours.filter { mine in !theirs.contains { $0.id == mine.id } }
    }

    static func forCloud(_ space: Space) -> Space {
        var copy = space
        copy.downloads = nil
        return copy
    }

    static func adopt(spaces theirs: [Space], local: [Space]) -> [Space] {
        var out = theirs.map { space -> Space in
            var copy = forCloud(space)
            if let mine = local.first(where: { $0.id == copy.id }) {
                copy.downloads = mine.downloads
                copy.sharesSignIns = mine.sharesSignIns
            }
            return copy
        }
        if !out.contains(where: \.isFirst) {
            out.insert(local.first(where: \.isFirst) ?? Space(id: Space.firstID, name: "Personal", colour: 0), at: 0)
        }
        return out
    }
}

// MARK: - Sync Coordinator

@MainActor
final class ICloudSync: ObservableObject {
    static let shared = ICloudSync()

    nonisolated static let containerID = "iCloud.com.codegraff.search"
    nonisolated static let zoneName = "Browse"
    nonisolated static let recordType = "Item"

    private static let onKey = "icloud.sync.on"
    private static let offKey = "icloud.sync.offReason"
    private static let deletedElsewhere = "Turned off because Browse's data was deleted from iCloud on another device"

    enum Account: Equatable {
        case unknown, signedIn, signedOut, restricted
    }

    @Published private(set) var on: Bool
    @Published private(set) var account: Account = .unknown
    @Published private(set) var lastSynced: Date?
    @Published private(set) var problem: String?
    @Published private(set) var others: [String: DeviceTabs] = [:]

    var available: Bool { !Store.testing && ICloudSync.entitled }

    private weak var browser: Browser?
    private let defaults: UserDefaults
    private let file: URL
    private var ledger = ICloudLedger()
    private var ledgerLoaded = false
    private var engine: CloudKitEngine?
    private var applying = false
    private var tabTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var prefCancellables: Set<AnyCancellable> = []

    /// True only when this signed binary actually holds CloudKit entitlements
    /// for `containerID`. Touching `CKContainer` without them aborts the app.
    private nonisolated static let checkEntitled: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String]
        else { return false }
        return containers.contains(containerID) && services.contains("CloudKit")
    }()

    nonisolated static var entitled: Bool { checkEntitled }

    private init(defaults: UserDefaults = Store.settings, file: URL = Store.file("icloud.json")) {
        self.defaults = defaults
        self.file = file
        self.on = defaults.bool(forKey: ICloudSync.onKey)
    }

    private func ensureLedger() {
        guard !ledgerLoaded else { return }
        ledgerLoaded = true
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(ICloudLedger.self, from: data) {
            ledger = saved
        }
    }

    func attach(browser: Browser) {
        self.browser = browser
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard on, available, engine == nil, browser?.prefs.sync != true else { return }
        ensureLedger()
        bootEngine()
    }

    func turnOn() {
        guard available, !on, browser?.prefs.sync != true else { return }
        ensureLedger()
        on = true
        problem = nil
        defaults.set(true, forKey: ICloudSync.onKey)
        defaults.removeObject(forKey: ICloudSync.offKey)
        bootEngine()
    }

    func turnOff() {
        guard on else { return }
        on = false
        defaults.removeObject(forKey: ICloudSync.onKey)
        teardown()
    }

    func syncNow() {
        guard on, let engine else { return }
        ensureLedger()
        problem = nil
        let sync = self
        Task.detached {
            do {
                try await engine.fetch()
                await MainActor.run { sync.publishAll() }
                try await engine.send()
                await MainActor.run { sync.synced() }
            } catch {
                let message = ICloudSync.say(error)
                await MainActor.run { sync.failed(message) }
            }
        }
    }

    func erase() {
        ensureLedger()
        let activeEngine = engine
        on = false
        defaults.removeObject(forKey: ICloudSync.onKey)
        defaults.removeObject(forKey: ICloudSync.offKey)
        others = [:]
        ledger = ICloudLedger()
        saveLedger()
        teardown()
        guard available else { return }
        let sync = self
        Task.detached {
            let target = activeEngine ?? CloudKitEngine(owner: nil, state: nil)
            do {
                try await target.eraseZone()
            } catch {
                let message = ICloudSync.say(error)
                await MainActor.run { sync.failed(message) }
            }
            target.close()
        }
    }

    private func bootEngine() {
        guard engine == nil else { return }
        let ck = CloudKitEngine(owner: self, state: ledger.state)
        engine = ck

        observers.append(NotificationCenter.default.addObserver(forName: Spaces.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spacesChanged() }
        })
        if let prefs = browser?.prefs {
            prefs.$engine.dropFirst().sink { [weak self] _ in self?.settingsChanged() }.store(in: &prefCancellables)
            prefs.$customEngine.dropFirst().sink { [weak self] _ in self?.settingsChanged() }.store(in: &prefCancellables)
            prefs.$look.dropFirst().sink { [weak self] _ in self?.settingsChanged() }.store(in: &prefCancellables)
        }

        let sync = self
        Task.detached {
            let status = await ck.account()
            await MainActor.run { sync.account = status }
            guard status == .signedIn else { return }
            do {
                try await ck.fetch()
                await MainActor.run {
                    guard sync.on else { return }
                    sync.ledger.joined = true
                    sync.saveLedger()
                    sync.publishAll()
                }
                try await ck.send()
                await MainActor.run { sync.synced() }
            } catch {
                let message = ICloudSync.say(error)
                await MainActor.run { sync.failed(message) }
            }
        }
    }

    private func teardown() {
        tabTimer?.invalidate()
        tabTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        prefCancellables.removeAll()
        if let engine {
            self.engine = nil
            Task.detached { engine.close() }
        }
    }

    // MARK: - Local change hooks

    func tabsChanged() {
        guard on, ledger.joined, !applying else { return }
        tabTimer?.invalidate()
        tabTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishTabs() }
        }
    }

    func bookmarksChanged() {
        guard on, ledger.joined, !applying else { return }
        publishBookmarks()
    }

    func spacesChanged() {
        guard on, ledger.joined, !applying else { return }
        publishSpaces()
    }

    func settingsChanged() {
        guard on, ledger.joined, !applying else { return }
        publishSettings()
    }

    private func publishAll() {
        publishTabs()
        publishSpaces()
        publishBookmarks()
        publishSettings()
    }

    private func publishTabs() {
        guard let browser else { return }
        let pages = ICloudMerge.pages(browser.tabs.map { tab in
            (url: tab.address, title: tab.title, shy: tab.shy, pinned: tab.pin != nil)
        })
        let payload = DeviceTabs(
            name: Host.current().localizedName ?? "Mac",
            platform: "macos",
            at: Date(),
            tabs: pages
        )
        guard let data = ICloudMerge.encode(payload) else { return }
        offer(ledger.deviceKey, data)
    }

    private func publishSpaces() {
        let list = Spaces.read().map(ICloudMerge.forCloud)
        guard let data = ICloudMerge.encode(list) else { return }
        offer("spaces", data)
    }

    private func publishBookmarks() {
        guard let browser else { return }
        guard let data = ICloudMerge.encode(browser.bookmarks.roots) else { return }
        offer("bookmarks", data)
    }

    private func publishSettings() {
        guard let prefs = browser?.prefs else { return }
        let payload = SharedSettings(engine: prefs.engine.rawValue, custom: prefs.customEngine, look: prefs.look.rawValue)
        guard let data = ICloudMerge.encode(payload) else { return }
        offer("settings", data)
    }

    private func offer(_ key: String, _ data: Data) {
        guard ledger.offer(key, data, now: Date()) else { return }
        saveLedger()
        engine?.save([key])
    }

    // MARK: - Callbacks from CloudKitEngine

    func engineState(_ data: Data?) {
        ledger.state = data
        saveLedger()
    }

    func accountChanged(_ status: Account) {
        account = status
        if status == .signedIn, on, let engine {
            let sync = self
            Task.detached {
                do {
                    try await engine.fetch()
                    await MainActor.run {
                        guard sync.on else { return }
                        sync.ledger.joined = true
                        sync.saveLedger()
                        sync.publishAll()
                    }
                    try await engine.send()
                    await MainActor.run { sync.synced() }
                } catch {
                    let message = ICloudSync.say(error)
                    await MainActor.run { sync.failed(message) }
                }
            }
        }
    }

    func arrived(_ key: String, data: Data, at stamp: Date, fields: Data) {
        let canonical = ICloudMerge.canonical(data)
        ledger.fields[key] = fields
        guard ledger.arrive(key, canonical: canonical, at: stamp) == .taken else {
            engine?.save([key])
            return
        }
        saveLedger()
        applyRecord(key, data: canonical)
    }

    func removed(_ key: String) {
        ledger.values.removeValue(forKey: key)
        ledger.at.removeValue(forKey: key)
        ledger.fields.removeValue(forKey: key)
        if key.hasPrefix("device.") { others.removeValue(forKey: key) }
        saveLedger()
    }

    func saved(_ key: String, fields: Data) {
        ledger.fields[key] = fields
        saveLedger()
    }

    func conflict(_ key: String, serverData: Data?, serverAt: Date, fields: Data) {
        let canonical = serverData.map(ICloudMerge.canonical)
        let serverWon = ledger.resolveConflict(key, serverCanonical: canonical, serverAt: serverAt, fields: fields)
        saveLedger()
        if serverWon, let canonical {
            applyRecord(key, data: canonical)
        } else {
            engine?.save([key])
        }
    }

    func forgetFields(_ key: String) {
        ledger.fields.removeValue(forKey: key)
        saveLedger()
        engine?.save([key])
    }

    func zoneGone() {
        on = false
        defaults.removeObject(forKey: ICloudSync.onKey)
        defaults.set(ICloudSync.deletedElsewhere, forKey: ICloudSync.offKey)
        others = [:]
        ledger = ICloudLedger()
        saveLedger()
        teardown()
    }

    func outgoing(_ key: String) -> (data: Data, at: Date, fields: Data?)? {
        guard let data = ledger.values[key] else { return nil }
        return (data, ledger.at[key] ?? Date(), ledger.fields[key])
    }

    func synced() {
        problem = nil
        lastSynced = Date()
    }

    func failed(_ message: String) {
        problem = message
    }

    private func applyRecord(_ key: String, data: Data) {
        applying = true
        defer { applying = false }

        if key.hasPrefix("device.") {
            guard key != ledger.deviceKey else { return }
            if let device = ICloudMerge.decode(DeviceTabs.self, data) {
                others[key] = device
            }
            return
        }
        switch key {
        case "bookmarks":
            guard let browser, let incoming = ICloudMerge.decode([Bookmark].self, data) else { return }
            let merged = ledger.joined ? incoming : ICloudMerge.union(bookmarks: incoming, browser.bookmarks.roots)
            browser.bookmarks.adopt(merged)
        case "spaces":
            guard let incoming = ICloudMerge.decode([Space].self, data) else { return }
            let local = Spaces.read()
            let merged = ledger.joined ? incoming : ICloudMerge.union(spaces: incoming, local)
            Spaces.write(ICloudMerge.adopt(spaces: merged, local: local))
        case "settings":
            guard let prefs = browser?.prefs, let incoming = ICloudMerge.decode(SharedSettings.self, data) else { return }
            if let raw = incoming.engine, let engine = Engine(rawValue: raw), engine != prefs.engine { prefs.engine = engine }
            if let custom = incoming.custom, custom != prefs.customEngine { prefs.customEngine = custom }
            if let raw = incoming.look, let look = Look(rawValue: raw), look != prefs.look { prefs.look = look }
        default:
            break
        }
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - UI Helpers (Settings, History Menu, Omnibox)

    var devices: [(id: String, tabs: DeviceTabs)] {
        others.filter { !$0.value.tabs.isEmpty }
            .sorted { $0.value.at > $1.value.at }
            .map { ($0.key, $0.value) }
    }

    static func title(_ device: DeviceTabs) -> String {
        device.name.isEmpty ? (device.platform == "ios" ? "iPhone" : "Mac") : device.name
    }

    func offers(for typed: String, limit: Int = 2) -> [Suggestion] {
        let words = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard on, words.count >= 2 else { return [] }
        var out: [Suggestion] = []
        for (_, device) in devices {
            for page in device.tabs where page.title.lowercased().contains(words) || page.url.lowercased().contains(words) {
                guard let url = URL(string: page.url) else { continue }
                out.append(Suggestion(
                    key: Address.editable(url),
                    title: "On \(ICloudSync.title(device))",
                    url: url,
                    kind: .elsewhere
                ))
                if out.count == limit { return out }
            }
        }
        return out
    }

    var offReason: String? { on ? nil : defaults.string(forKey: ICloudSync.offKey) }

    func summary(codegraffSyncOn: Bool) -> String {
        guard available else {
            return Store.testing && ICloudSync.entitled
                ? "Off in a test run"
                : "Needs a provisioning profile with iCloud container \(ICloudSync.containerID)"
        }
        if codegraffSyncOn && !on { return "Turn off Codegraff Sync below first" }
        guard on else {
            return offReason ?? "Sync open tabs, spaces, bookmarks, and settings through your private iCloud database"
        }
        switch account {
        case .signedOut: return "Not signed in to iCloud — open System Settings › Apple Account"
        case .restricted: return "iCloud is restricted on this Mac"
        case .unknown: return problem ?? "Checking iCloud…"
        case .signedIn:
            if let problem { return "Signed in to iCloud · \(problem)" }
            guard let lastSynced else { return "Signed in to iCloud · syncing…" }
            let when = RelativeDateTimeFormatter().localizedString(for: lastSynced, relativeTo: Date())
            let count = devices.count
            let with = count == 0 ? "" : count == 1 ? " · 1 other device" : " · \(count) other devices"
            return "Signed in to iCloud · synced \(when)\(with)"
        }
    }

    nonisolated static func say(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return "Sign in to iCloud in System Settings to sync"
        case .quotaExceeded: return "Your iCloud storage is full"
        case .networkFailure, .networkUnavailable: return "Offline — sync resumes automatically"
        default: return error.localizedDescription
        }
    }
}

// MARK: - CloudKit Engine (macOS 14+ CKSyncEngine)

private final class CloudKitEngine: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: ICloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    private weak var owner: ICloudSync?
    private let container: CKContainer
    nonisolated(unsafe) private var engine: CKSyncEngine!

    init(owner: ICloudSync?, state: Data?) {
        self.owner = owner
        self.container = CKContainer(identifier: ICloudSync.containerID)
        super.init()
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        engine = CKSyncEngine(config)
        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitEngine.zoneID))])
        }
    }

    private static func recordID(_ key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: key, zoneID: zoneID)
    }

    func save(_ keys: [String]) {
        engine.state.add(pendingRecordZoneChanges: keys.map { .saveRecord(Self.recordID($0)) })
    }

    func fetch() async throws {
        try await engine.fetchChanges()
    }

    func send() async throws {
        try await engine.sendChanges()
    }

    func eraseZone() async throws {
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
        try await engine.sendChanges()
    }

    func account() async -> ICloudSync.Account {
        guard let status = try? await container.accountStatus() else { return .unknown }
        switch status {
        case .available: return .signedIn
        case .noAccount, .temporarilyUnavailable: return .signedOut
        case .restricted: return .restricted
        default: return .unknown
        }
    }

    func close() {
        owner = nil
    }

    private static func fields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func record(fields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }

    private static func contents(_ record: CKRecord) -> (data: Data, at: Date)? {
        guard let data = record.encryptedValues["data"] as? Data else { return nil }
        return (data, record["at"] as? Date ?? record.modificationDate ?? .distantPast)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let owner else { return }
        switch event {
        case .stateUpdate(let update):
            let data = try? JSONEncoder().encode(update.stateSerialization)
            await MainActor.run { owner.engineState(data) }
        case .accountChange(let change):
            let now: ICloudSync.Account
            switch change.changeType {
            case .signIn: now = .signedIn
            case .signOut, .switchAccounts: now = .signedOut
            @unknown default: now = .unknown
            }
            await MainActor.run { owner.accountChanged(now) }
            if case .switchAccounts = change.changeType {
                await MainActor.run { owner.accountChanged(.signedIn) }
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudKitEngine.zoneID }) {
                await MainActor.run { owner.zoneGone() }
            }
        case .fetchedRecordZoneChanges(let changes):
            let arrivals = changes.modifications.compactMap { mod -> (String, Data, Date, Data)? in
                let record = mod.record
                guard let found = CloudKitEngine.contents(record) else { return nil }
                return (record.recordID.recordName, found.data, found.at, CloudKitEngine.fields(of: record))
            }
            let gone = changes.deletions.map(\.recordID.recordName)
            await MainActor.run {
                for (key, data, at, fields) in arrivals { owner.arrived(key, data: data, at: at, fields: fields) }
                for key in gone { owner.removed(key) }
                owner.synced()
            }
        case .sentRecordZoneChanges(let changes):
            let saved = changes.savedRecords.map { ($0.recordID.recordName, CloudKitEngine.fields(of: $0)) }
            var problems: [String] = []
            var actions: [@MainActor () -> Void] = []
            for failure in changes.failedRecordSaves {
                let key = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if let theirs = failure.error.serverRecord {
                        let found = CloudKitEngine.contents(theirs)
                        let fields = CloudKitEngine.fields(of: theirs)
                        actions.append { owner.conflict(key, serverData: found?.data, serverAt: found?.at ?? .distantPast, fields: fields) }
                    }
                case .zoneNotFound:
                    actions.append { owner.zoneGone() }
                case .unknownItem:
                    actions.append { owner.forgetFields(key) }
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                    break
                default:
                    problems.append(ICloudSync.say(failure.error))
                }
            }
            let finalActions = actions
            let firstProblem = problems.first
            await MainActor.run {
                for (key, fields) in saved { owner.saved(key, fields: fields) }
                for action in finalActions { action() }
                if let firstProblem { owner.failed(firstProblem) } else if !saved.isEmpty { owner.synced() }
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            guard let owner = self?.owner else { return nil }
            guard let out = await MainActor.run(body: { owner.outgoing(id.recordName) }) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            let record = out.fields.flatMap { CloudKitEngine.record(fields: $0) }
                ?? CKRecord(recordType: ICloudSync.recordType, recordID: id)
            record.encryptedValues["data"] = out.data as NSData
            record["at"] = out.at as NSDate
            return record
        }
    }
}
