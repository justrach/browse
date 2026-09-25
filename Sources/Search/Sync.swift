import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

// History and bookmarks, the same on every Mac you sign in to Codegraff on.
//
// Codegraff keeps them, and can't read them. Everything is sealed here first
// (AES-GCM) with a key that only your Macs hold: made on the first Mac, kept
// in its keychain, and carried to the next as a sync code you paste. A place
// in your history is filed under a keyed hash of its address, not the
// address, so the server holds nothing but sealed boxes and the order they
// changed in (gateway.codegraff.com/v1/sync, in justrach/zigrepper's
// codegraff-gateway). The key never leaves the Macs; lose every Mac and the
// code, and what was synced can't be opened by anyone, Codegraff included.
//
// Each round pulls what changed since the last one, then sends what changed
// here. History merges without conflicts: each Mac only ever raises its own
// visit count, and the latest visit wins the title. A bookmark is a record
// of its own — title, address, folder, place in the folder — and one changed
// here since the last round wins over the same one changed elsewhere.
// Forgetting a page, or clearing history, forgets it on every Mac; the 2,000
// places this Mac keeps on disk are only this Mac's cut, and nothing past
// them is deleted anywhere.
//
// Off until switched on in Settings › Sync.

@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()

    enum Phase: Equatable {
        case off
        /// No Codegraff sign-in on this Mac.
        case signedOut
        /// This account already syncs from another Mac: its code is wanted.
        case needsCode
        /// The code given doesn't open what's there.
        case wrongCode
        case syncing
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    weak var browser: Browser?

    /// Where to sync: the gateway, or SEARCH_SYNC_URL for a test run.
    nonisolated static let server = URL(string: ProcessInfo.processInfo.environment["SEARCH_SYNC_URL"]
        ?? "https://gateway.codegraff.com")!
    private static var testing: Bool { ProcessInfo.processInfo.environment["SEARCH_SYNC_URL"] != nil }

    /// This Mac, as history counts its visits. Made once.
    nonisolated static let device: String = {
        if let made = Store.settings.string(forKey: "sync.device") { return made }
        let made = UUID().uuidString.lowercased()
        Store.settings.set(made, forKey: "sync.device")
        return made
    }()

    private var state = State.load()
    private var running = false
    private var clock: Timer?
    private var soon: DispatchWorkItem?
    /// While a round writes what it pulled: those saves aren't changes to send.
    private var applying = false

    private init() {}

    // MARK: - when

    func start(for browser: Browser) {
        self.browser = browser
        clock?.invalidate()
        guard browser.prefs.sync else { phase = .off; return }
        clock = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now() }
        }
        clock?.tolerance = 60
        nudge(after: 3)
    }

    /// Something changed here: a round in a little while, once it settles.
    func nudge(after seconds: TimeInterval = 30) {
        guard !applying, browser?.prefs.sync == true else { return }
        soon?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.now() } }
        soon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Pages forgotten here, to be forgotten everywhere.
    func forgot(_ keys: [String]) {
        guard browser?.prefs.sync == true, !keys.isEmpty else { return }
        state.forgotten.formUnion(keys)
        state.save()
    }

    /// All of history cleared here.
    func forgotAll() {
        forgot(Array(state.pushedHistory.keys))
    }

    func now() {
        Task { await round() }
    }

    // MARK: - switching

    func switchOn() {
        browser?.prefs.sync = true
        if let browser { start(for: browser) }
    }

    func switchOff() {
        browser?.prefs.sync = false
        clock?.invalidate()
        soon?.cancel()
        phase = .off
    }

    /// The code from another Mac: checked against what that Mac left, kept,
    /// and everything pulled afresh.
    func join(_ typed: String) async -> String? {
        guard let master = Code.parse(typed) else { return "That isn't a sync code — it's 13 groups of four letters and digits" }
        guard let login = Sync.login else { phase = .signedOut; return "Sign in to Codegraff first" }
        let keys = Keys(master)
        do {
            if let check = try await checkRecord(login), keys.open(check, as: "meta", id: Keys.checkID) == nil {
                return "That code is for other Macs than the ones syncing to this account"
            }
        } catch {
            return describe(error)
        }
        Keychain.store(master)
        state = State()
        state.checked = true
        state.save()
        phase = .syncing
        await round()
        return nil
    }

    /// Where it stands, for ./bench probe on a test run — the code included,
    /// so a second test copy can join the first.
    var probe: [String: Any] {
        let phase: String
        switch self.phase {
        case .off: phase = "off"
        case .signedOut: phase = "signed out"
        case .needsCode: phase = "needs code"
        case .wrongCode: phase = "wrong code"
        case .syncing: phase = "syncing"
        case .synced: phase = "synced"
        case .failed(let why): phase = "failed: " + why
        }
        return ["phase": phase, "code": code ?? ""]
    }

    /// For the Mac that wants to join: this one's key, as letters to paste.
    var code: String? { Keychain.load().map(Code.make) }

    /// What was synced, gone from Codegraff. The Macs keep their own.
    func deleteEverywhere() async -> String? {
        guard let login = Sync.login else { return "Sign in to Codegraff first" }
        do {
            _ = try await request("DELETE", "/v1/sync", login: login)
        } catch {
            return describe(error)
        }
        Keychain.remove()
        state = State()
        state.save()
        switchOff()
        return nil
    }

    // MARK: - a round

    private func round() async {
        guard !running, let browser, browser.prefs.sync else { return }
        guard let login = Sync.login else { phase = .signedOut; return }
        running = true
        defer { running = false }
        phase = .syncing
        do {
            guard let master = Keychain.load() else {
                // The first Mac makes the key — unless another got there
                // first, and its code is wanted instead.
                if try await checkRecord(login) != nil {
                    phase = .needsCode
                    return
                }
                let master = SymmetricKey(size: .bits256)
                Keychain.store(master)
                try await writeCheck(Keys(master), login: login)
                state = State()
                state.checked = true
                state.save()
                return await finish(Keys(master), login: login, browser: browser)
            }
            let keys = Keys(master)
            if !state.checked {
                if let check = try await checkRecord(login) {
                    guard keys.open(check, as: "meta", id: Keys.checkID) != nil else {
                        phase = .wrongCode
                        return
                    }
                } else {
                    try await writeCheck(keys, login: login)
                }
                state.checked = true
                state.save()
            }
            await finish(keys, login: login, browser: browser)
        } catch {
            phase = .failed(describe(error))
        }
    }

    private func finish(_ keys: Keys, login: String, browser: Browser) async {
        do {
            try await history(keys, login: login, history: browser.history)
            try await bookmarks(keys, login: login, bookmarks: browser.bookmarks)
            state.save()
            phase = .synced(Date())
        } catch {
            state.save()
            phase = .failed(describe(error))
        }
    }

    // MARK: - history

    private func history(_ keys: Keys, login: String, history: History) async throws {
        // Back to a page from the hash it's filed under, for deletions.
        var named: [String: String] = [:]
        for place in history.synced() { named[keys.id("h:" + place.key)] = place.key }
        for key in state.forgotten { named[keys.id("h:" + key)] = key }

        var changed = false
        try await pull("history", login: login) { id, body in
            if let body {
                guard let data = keys.open(body, as: "history", id: id),
                      let place = try? Sync.decoder.decode(History.Synced.self, from: data)
                else { return }
                history.merge(place)
                self.state.pushedHistory[place.key] = Sync.signature(place)
                changed = true
            } else if let key = named[id], !self.state.forgotten.contains(key) {
                history.drop(key)
                self.state.pushedHistory[key] = nil
                changed = true
            }
        }
        if changed {
            applying = true
            history.settle()
            applying = false
        }

        // Deletions first: a page forgotten and then visited again goes up
        // deleted and then back, and the server keeps the last.
        var out: [(id: String, body: String?, key: String, signature: String?)] = []
        for key in state.forgotten.sorted() { out.append((keys.id("h:" + key), nil, key, nil)) }
        var present = Set<String>()
        for place in history.synced() {
            present.insert(place.key)
            let signature = Sync.signature(place)
            guard state.pushedHistory[place.key] != signature, let data = try? Sync.encoder.encode(place) else { continue }
            let id = keys.id("h:" + place.key)
            out.append((id, try keys.seal(data, as: "history", id: id), place.key, signature))
        }
        try await push("history", out.map { ($0.id, $0.body) }, login: login) { sent in
            for item in out[sent] {
                if let signature = item.signature { self.state.pushedHistory[item.key] = signature }
                else { self.state.forgotten.remove(item.key) }
            }
        }
        // Past the 2,000 this Mac keeps: not deleted, only no longer here.
        for key in state.pushedHistory.keys where !present.contains(key) { state.pushedHistory[key] = nil }
    }

    // MARK: - bookmarks

    /// A bookmark or a folder as it travels: where it sits is part of it.
    struct Node: Codable, Equatable {
        var title: String
        var url: String?
        var parent: String?
        var order: Int
    }

    private func bookmarks(_ keys: Keys, login: String, bookmarks: Bookmarks) async throws {
        var flat = Sync.flatten(bookmarks.roots)
        var changed = false
        try await pull("bookmarks", login: login) { id, body in
            // Changed here since the last round: this Mac's wins.
            if let mine = flat[id], Sync.signature(mine) != self.state.pushedBookmarks[id] { return }
            if let body {
                guard let data = keys.open(body, as: "bookmarks", id: id),
                      let node = try? Sync.decoder.decode(Node.self, from: data)
                else { return }
                flat[id] = node
                self.state.pushedBookmarks[id] = Sync.signature(node)
            } else {
                flat[id] = nil
                self.state.pushedBookmarks[id] = nil
            }
            changed = true
        }
        if changed {
            applying = true
            bookmarks.adopt(Sync.build(flat))
            applying = false
        }

        let now = Sync.flatten(bookmarks.roots)
        var out: [(id: String, body: String?, signature: String?)] = []
        for id in state.pushedBookmarks.keys.sorted() where now[id] == nil { out.append((id, nil, nil)) }
        for (id, node) in now.sorted(by: { $0.key < $1.key }) {
            let signature = Sync.signature(node)
            guard state.pushedBookmarks[id] != signature, let data = try? Sync.encoder.encode(node) else { continue }
            out.append((id, try keys.seal(data, as: "bookmarks", id: id), signature))
        }
        try await push("bookmarks", out.map { ($0.id, $0.body) }, login: login) { sent in
            for item in out[sent] { self.state.pushedBookmarks[item.id] = item.signature }
        }
    }

    /// The tree as records: every node by its id, with its folder and its
    /// place among that folder's children.
    static func flatten(_ nodes: [Bookmark], parent: String? = nil, into flat: inout [String: Node]) {
        for (order, node) in nodes.enumerated() {
            let id = node.id.uuidString
            flat[id] = Node(title: node.title, url: node.url, parent: parent, order: order)
            if let children = node.children { flatten(children, parent: id, into: &flat) }
        }
    }

    static func flatten(_ nodes: [Bookmark]) -> [String: Node] {
        var flat: [String: Node] = [:]
        flatten(nodes, parent: nil, into: &flat)
        return flat
    }

    /// Records back into a tree. One whose folder is gone, or that two Macs
    /// moved into each other, lands at the top rather than being lost.
    static func build(_ flat: [String: Node]) -> [Bookmark] {
        func rooted(_ id: String) -> Bool {
            var seen: Set<String> = [id]
            var at = flat[id]?.parent
            while let parent = at {
                guard let node = flat[parent], node.url == nil, seen.insert(parent).inserted else { return false }
                at = node.parent
            }
            return true
        }
        var children: [String: [(String, Node)]] = [:]
        var top: [(String, Node)] = []
        for (id, node) in flat {
            if let parent = node.parent, rooted(id) { children[parent, default: []].append((id, node)) }
            else { top.append((id, node)) }
        }
        func sorted(_ list: [(String, Node)]) -> [(String, Node)] {
            list.sorted { $0.1.order == $1.1.order ? $0.0 < $1.0 : $0.1.order < $1.1.order }
        }
        func make(_ id: String, _ node: Node) -> Bookmark? {
            guard let uuid = UUID(uuidString: id) else { return nil }
            let kids = node.url == nil ? sorted(children[id] ?? []).compactMap(make) : nil
            return Bookmark(id: uuid, title: node.title, url: node.url, children: kids)
        }
        return sorted(top).compactMap(make)
    }

    // MARK: - the wire

    private static var login: String? {
        testing ? ProcessInfo.processInfo.environment["SEARCH_SYNC_KEY"] : Jev.key()
    }

    private struct Failure: Error {
        let status: Int
        let message: String
    }

    private func pull(_ collection: String, login: String, take: (String, String?) -> Void) async throws {
        var since = state.cursors[collection] ?? 0
        while true {
            let answer = try await request("GET", "/v1/sync/\(collection)?since=\(since)&limit=500", login: login)
            for record in answer["records"] as? [[String: Any]] ?? [] {
                guard let id = record["id"] as? String else { continue }
                take(id, record["body"] as? String)
            }
            since = answer["next"] as? Int ?? since
            state.cursors[collection] = since
            guard answer["more"] as? Bool == true else { break }
        }
    }

    private func push(_ collection: String, _ records: [(String, String?)], login: String, sent: (Range<Int>) -> Void) async throws {
        var at = 0
        while at < records.count {
            let batch = at..<min(at + 500, records.count)
            let body: [[String: Any]] = records[batch].map { id, sealed in
                sealed.map { ["id": id, "body": $0] } ?? ["id": id, "deleted": true]
            }
            _ = try await request("POST", "/v1/sync/\(collection)", login: login, body: ["records": body])
            sent(batch)
            at = batch.upperBound
        }
    }

    private func checkRecord(_ login: String) async throws -> String? {
        let answer = try await request("GET", "/v1/sync/meta?since=0&limit=500", login: login)
        let records = answer["records"] as? [[String: Any]] ?? []
        return records.last { $0["id"] as? String == Keys.checkID }?["body"] as? String
    }

    /// A record only the right key opens, so a Mac given the wrong code
    /// finds out before it sends anything.
    private func writeCheck(_ keys: Keys, login: String) async throws {
        let sealed = try keys.seal(Data("browse sync".utf8), as: "meta", id: Keys.checkID)
        _ = try await request("POST", "/v1/sync/meta", login: login, body: ["records": [["id": Keys.checkID, "body": sealed]]])
    }

    private func request(_ method: String, _ path: String, login: String, body: Any? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: Sync.server) else { throw Failure(status: 0, message: "bad address") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(login)", forHTTPHeaderField: "Authorization")
        request.setValue("browse/\(Updater.version)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Sync.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (answer["error"] as? [String: Any])?["message"] as? String ?? "status \(status)"
            throw Failure(status: status, message: message)
        }
        return answer
    }

    private func describe(_ error: Error) -> String {
        guard let failure = error as? Failure else { return "Couldn't reach Codegraff" }
        switch failure.status {
        case 401, 403: return "Codegraff didn't accept this Mac's sign-in — run graff login"
        case 404: return "Codegraff's server doesn't sync yet"
        case 413: return "More than Codegraff keeps for one account"
        default: return failure.message
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// What a record says, to tell whether it changed since it was sent.
    static func signature<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    }

    // MARK: - what this Mac remembers

    private struct State: Codable {
        /// The last change seen, by collection.
        var cursors: [String: Int] = [:]
        /// What was last sent or taken, by page and by bookmark: a record
        /// whose signature differs has changed here since.
        var pushedHistory: [String: String] = [:]
        var pushedBookmarks: [String: String] = [:]
        /// Pages forgotten here and not yet forgotten everywhere.
        var forgotten: Set<String> = []
        /// The key was checked against the account's.
        var checked = false

        static var file: URL { Store.file("sync.json") }

        static func load() -> State {
            guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
            return state
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? FileManager.default.createDirectory(at: State.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: State.file, options: .atomic)
        }
    }
}

/// The two keys made from the one a sync code carries: one seals records,
/// the other names pages without saying what they are.
private struct Keys {
    static let checkID = "browse-sync-check"
    let sealing: SymmetricKey
    let naming: SymmetricKey

    init(_ master: SymmetricKey) {
        sealing = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("browse sync v1 seal".utf8), outputByteCount: 32)
        naming = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("browse sync v1 name".utf8), outputByteCount: 32)
    }

    /// The same page gets the same name on every Mac, and it says nothing.
    func id(_ text: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: naming)
        return String(Data(code).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "").prefix(32))
    }

    /// Sealed to its collection and id, so a box can't be moved to stand in
    /// for another.
    func seal(_ data: Data, as collection: String, id: String) throws -> String {
        let box = try AES.GCM.seal(data, using: sealing, authenticating: Data("\(collection)/\(id)".utf8))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined.base64EncodedString()
    }

    func open(_ sealed: String, as collection: String, id: String) -> Data? {
        guard let data = Data(base64Encoded: sealed), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: sealing, authenticating: Data("\(collection)/\(id)".utf8))
    }
}

/// The key as something to copy and paste: base32, in groups of four.
enum Code {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func make(_ key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Array($0) }
        var bits = 0, value = 0
        var out = ""
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { start in
            let from = out.index(out.startIndex, offsetBy: start)
            return String(out[from..<(out.index(from, offsetBy: 4, limitedBy: out.endIndex) ?? out.endIndex)])
        }.joined(separator: "-")
    }

    static func parse(_ typed: String) -> SymmetricKey? {
        let letters = typed.uppercased().filter { alphabet.contains($0) }
        guard letters.count == 52 else { return nil }
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for letter in letters {
            guard let index = alphabet.firstIndex(of: letter) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        guard bytes.count >= 32 else { return nil }
        return SymmetricKey(data: Data(bytes.prefix(32)))
    }
}

/// The key, in this Mac's keychain, for this profile only.
private enum Keychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.codegraff.browse.sync",
            kSecAttrAccount as String: Store.folder.lastPathComponent,
        ]
    }

    static func load() -> SymmetricKey? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func store(_ key: SymmetricKey) {
        remove()
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
