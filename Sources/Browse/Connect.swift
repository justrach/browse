import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

// Connected apps: other apps on this Mac — Harness first — using the
// browser's tools (AgentTools.swift) with the user's own sign-ins
// (justrach/browse#4).
//
// graff gets a bearer token in a file, which is right for browse's own agent
// and wrong for anyone else: any process of the user's can read the file, and
// the token is everything. So an app pairs once instead. It sends its public
// key; both apps show a six-digit code made from both keys; the user checks
// they match and picks what the app may do. From then on every request is
// signed with a key that app can't give away (its Secure Enclave), stamped so
// it can't be replayed, and held to the scopes it was given; every answer is
// signed by browse, so the app knows who it's talking to. Revoked in a click;
// forgotten after thirty days unused.
//
//   connect.json   where to find the server — port and browse's key, no
//                  secret — while Settings › Agent › Connected apps is on
//   POST /pair     an app's key, name and nonce → browse's key and an id
//   POST /pair/status, /mcp, /session/close   signed, see `verify`
//
// Keys are P-256, sent as base64 of the X9.63 point; signatures are base64
// of DER ECDSA-SHA256; nonces are 16 bytes of lowercase hex.

@MainActor
final class Connect: ObservableObject {
    static let shared = Connect()
    static let version = "v1-p256-sig"

    enum Scope: String, CaseIterable, Codable, Identifiable {
        case read
        case ownPages = "act-own-pages"
        case userTabs = "act-user-tabs"
        case runJS = "run-js"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .read: return "Search and read the web"
            case .ownPages: return "Open pages of its own and act in them"
            case .userTabs: return "Read and act in your tabs"
            case .runJS: return "Run scripts in its pages"
            }
        }

        var detail: String {
            switch self {
            case .read: return "Search, read pages, and see your tabs' titles and addresses"
            case .ownPages: return "Out of sight, with your sign-ins: go, click, fill in forms, take pictures. Never a password field"
            case .userTabs: return "The same in the tabs you have open. Asked once each time browse opens"
            case .runJS: return "Any script, in the pages it opened — in your tabs too, if it has those"
            }
        }

        var byDefault: Bool { self == .read || self == .ownPages }
    }

    struct Client: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        let key: Data
        var scopes: [Scope]
        let created: Date
        var used: Date?
    }

    /// Who a signed request came from.
    struct Caller {
        let id: String
        let name: String
        let scopes: [Scope]
        /// Mid-pairing: only /pair/status is open to it.
        let pending: Bool

        func may(_ scope: Scope) -> Bool { scopes.contains(scope) }
    }

    enum Refusal: String, Error {
        case unknown = "unknown_client"
        case badSignature = "bad_signature"
        case stale
        case replayed
    }

    /// Which scope a tool is in. Nil for one no connected app may use.
    static func scope(of tool: String) -> Scope? {
        switch tool {
        case "search", "read_pages", "tabs", "read", "links": return .read
        case "open", "go", "back", "forward", "reload", "form_fields", "fill", "click", "type", "submit", "drive", "screenshot", "close", "show":
            return .ownPages
        case "run_js": return .runJS
        default: return nil
        }
    }

    @Published private(set) var on: Bool
    @Published private(set) var clients: [Client]

    /// The app driving right now, for the pill over the page.
    struct Driving: Equatable {
        let name: String
        let pages: Int
    }
    @Published private(set) var driving: Driving?

    weak var browser: Browser?

    private init() {
        on = Store.settings.bool(forKey: "connect.on")
        clients = (Store.settings.data(forKey: "connect.clients"))
            .flatMap { try? JSONDecoder().decode([Client].self, from: $0) } ?? []
    }

    // MARK: - on and off

    func start(for browser: Browser) {
        self.browser = browser
        if AgentTools.shared.browser == nil { AgentTools.shared.browser = browser }
        expire()
        if on { Task { await serve() } }
    }

    func switchOn(_ wanted: Bool) {
        on = wanted
        Store.settings.set(wanted, forKey: "connect.on")
        if wanted {
            Task { await serve() }
        } else {
            Connect.withdraw()
            pairing = nil
        }
    }

    /// The server up, and where it is written down for apps to find.
    private func serve() async {
        guard on, await AgentTools.shared.listening(), let port = AgentTools.shared.listeningPort else { return }
        let found: [String: Any] = [
            "protocol": [Connect.version],
            "port": Int(port),
            "browse_key": signer.publicKey.x963Representation.base64EncodedString(),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: found, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: Connect.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Connect.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Connect.file.path)
    }

    nonisolated static var file: URL {
        Store.folder.appendingPathComponent("Agent", isDirectory: true).appendingPathComponent("connect.json")
    }

    /// Nothing to find: switched off, or the app is quitting.
    nonisolated static func withdraw() {
        try? FileManager.default.removeItem(at: file)
    }

    func revoke(_ id: String) {
        clients.removeAll { $0.id == id }
        confirmed.remove(id)
        save()
    }

    func set(_ scope: Scope, _ wanted: Bool, for id: String) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[index].scopes.removeAll { $0 == scope }
        if wanted { clients[index].scopes.append(scope) }
        if scope == .userTabs { confirmed.remove(id) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(clients) { Store.settings.set(data, forKey: "connect.clients") }
    }

    /// Thirty days without a word: gone, as if revoked.
    private func expire() {
        let before = clients.count
        clients.removeAll { Date().timeIntervalSince($0.used ?? $0.created) > 30 * 86400 }
        if clients.count != before { save() }
    }

    // MARK: - pairing

    private struct Pairing {
        let id: String
        let name: String
        let key: Data
        let code: String
        let started: Date
        var status = "pending"
        var scopes: [Scope] = []
    }
    private var pairing: Pairing?

    /// The question up now, pairing or tabs, so a test run can answer it
    /// (./bench ui connect yes|no) — nothing else ever does.
    private var question: (window: NSWindow, alert: NSAlert)?

    func answer(_ yes: Bool) {
        guard Store.testing, let question else { return }
        question.window.endSheet(question.alert.window, returnCode: yes ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    /// POST /pair: nothing signed yet — the code the user checks is what
    /// makes it safe. One at a time.
    func pair(_ body: Data) -> (Int, [String: Any]) {
        guard on else { return (403, ["error": "connected_apps_off"]) }
        if let pairing, pairing.status == "pending", Date().timeIntervalSince(pairing.started) < 120 {
            return (409, ["error": "pairing_in_progress"])
        }
        guard let asked = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let key = (asked["client_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              (try? P256.Signing.PublicKey(x963Representation: key)) != nil,
              let nonce = (asked["nonce"] as? String).flatMap(Connect.hex), nonce.count == 16,
              let name = (asked["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...64).contains(name.count),
              (asked["protocol"] as? [String] ?? []).contains(Connect.version)
        else { return (400, ["error": "bad_request"]) }

        let mine = signer.publicKey.x963Representation
        let digest = Array(SHA256.hash(data: mine + key + nonce))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let code = String(format: "%06u", number)
        let id = UUID().uuidString.lowercased()
        pairing = Pairing(id: id, name: name, key: key, code: code, started: Date())
        ask(id)
        return (200, ["protocol": Connect.version, "client_id": id, "browse_key": mine.base64EncodedString(), "expires_in": 120])
    }

    /// POST /pair/status, signed with the key it paired with.
    func status(_ caller: Caller) -> [String: Any] {
        if let client = clients.first(where: { $0.id == caller.id }) {
            return ["status": "paired", "scopes": client.scopes.map(\.rawValue)]
        }
        guard let pairing, pairing.id == caller.id else { return ["status": "expired"] }
        if pairing.status == "pending", Date().timeIntervalSince(pairing.started) >= 120 { return ["status": "expired"] }
        return ["status": pairing.status]
    }

    /// The question, over the window: the code to compare and what to allow.
    private func ask(_ id: String) {
        guard let pairing, pairing.id == id else { return }
        let alert = NSAlert()
        alert.messageText = "Connect “\(pairing.name)” to browse?"
        alert.informativeText = "Check that \(pairing.name) shows this code:\n\n\(pairing.code.prefix(3)) \(pairing.code.suffix(3))\n\nIf it doesn't, or you didn't ask for this, don't connect. \(pairing.name) will be able to:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Don't Connect")
        let boxes = Scope.allCases.map { scope -> NSButton in
            let box = NSButton(checkboxWithTitle: scope.title, target: nil, action: nil)
            box.state = scope.byDefault ? .on : .off
            box.toolTip = scope.detail
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack

        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] answer in
            self?.question = nil
            guard let self, var pairing = self.pairing, pairing.id == id, pairing.status == "pending" else { return }
            if answer == .alertFirstButtonReturn, Date().timeIntervalSince(pairing.started) < 120 {
                pairing.status = "paired"
                pairing.scopes = zip(Scope.allCases, boxes).filter { $0.1.state == .on }.map(\.0)
                self.clients.removeAll { $0.key == pairing.key }
                self.clients.append(Client(id: pairing.id, name: pairing.name, key: pairing.key, scopes: pairing.scopes, created: Date(), used: nil))
                self.save()
                self.browser?.announce("\(pairing.name) is connected")
            } else {
                pairing.status = "declined"
            }
            self.pairing = pairing
        }
        NSApp.requestUserAttention(.informationalRequest)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
            decide(alert.runModal())
            return
        }
        question = (window, alert)
        alert.beginSheetModal(for: window, completionHandler: decide)
        // Unanswered in two minutes: the app has stopped asking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard self?.pairing?.id == id, self?.pairing?.status == "pending" else { return }
            window.endSheet(alert.window, returnCode: .cancel)
        }
    }

    // MARK: - every request

    /// Nonces seen in the last two minutes, by client.
    private var seen: [String: Date] = [:]

    /// A request's signature, stamp and nonce, checked. The string signed is
    /// METHOD|path|sha256hex(body)|timestamp|nonce|client_id.
    func verify(method: String, path: String, headers: [String: String], body: Data) -> Result<Caller, Refusal> {
        guard let id = headers["x-client-id"]?.lowercased(),
              let stamp = headers["x-timestamp"].flatMap({ Int64($0) }),
              let nonce = headers["x-nonce"], Connect.hex(nonce)?.count == 16,
              let signature = headers["x-signature"].flatMap({ Data(base64Encoded: $0) })
        else { return .failure(.badSignature) }

        let caller: Caller
        let key: Data
        if let client = clients.first(where: { $0.id == id }) {
            guard Date().timeIntervalSince(client.used ?? client.created) <= 30 * 86400 else {
                expire()
                return .failure(.unknown)
            }
            caller = Caller(id: id, name: client.name, scopes: client.scopes, pending: false)
            key = client.key
        } else if let pairing, pairing.id == id {
            caller = Caller(id: id, name: pairing.name, scopes: [], pending: true)
            key = pairing.key
        } else {
            return .failure(.unknown)
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(now - stamp) <= 60_000 else { return .failure(.stale) }
        let signed = "\(method)|\(path)|\(Connect.hex(SHA256.hash(data: body)))|\(stamp)|\(nonce)|\(id)"
        guard let public_ = try? P256.Signing.PublicKey(x963Representation: key),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              public_.isValidSignature(parsed, for: Data(signed.utf8))
        else { return .failure(.badSignature) }

        let cutoff = Date().addingTimeInterval(-120)
        seen = seen.filter { $0.value > cutoff }
        guard seen.updateValue(Date(), forKey: id + "|" + nonce) == nil else { return .failure(.replayed) }

        if !caller.pending, let index = clients.firstIndex(where: { $0.id == id }) {
            clients[index].used = Date()
            // Written down at most once an hour: it's only for expiry and the list.
            if Date().timeIntervalSince(Store.settings.object(forKey: "connect.saved") as? Date ?? .distantPast) > 3600 {
                Store.settings.set(Date(), forKey: "connect.saved")
                save()
            }
        }
        return .success(caller)
    }

    /// browse's signature over what it answered: sha256hex(body)|request nonce.
    func sign(_ body: Data, nonce: String) -> String {
        let text = "\(Connect.hex(SHA256.hash(data: body)))|\(nonce)"
        return signer.signature(for: Data(text.utf8))?.base64EncodedString() ?? ""
    }

    // MARK: - the user's tabs

    /// Granted once a session: the first time an app reaches into a tab of
    /// the user's, browse asks, and the answer holds until it quits.
    private var confirmed = Set<String>()
    private var confirming: [String: Task<Bool, Never>] = [:]

    func allowTabs(_ caller: Caller) async -> Bool {
        guard caller.may(.userTabs) else { return false }
        if confirmed.contains(caller.id) { return true }
        if let asking = confirming[caller.id] { return await asking.value }
        let asking = Task { @MainActor in await self.askTabs(caller.name) }
        confirming[caller.id] = asking
        let yes = await asking.value
        confirming[caller.id] = nil
        if yes { confirmed.insert(caller.id) }
        return yes
    }

    private func askTabs(_ name: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let “\(name)” use your tabs?"
        alert.informativeText = "\(name) wants to read and act in the tabs you have open, with your sign-ins, until browse quits. It never fills in a password."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.requestUserAttention(.criticalRequest)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { done in
            var answered = false
            question = (window, alert)
            alert.beginSheetModal(for: window) { answer in
                self.question = nil
                guard !answered else { return }
                answered = true
                done.resume(returning: answer == .alertFirstButtonReturn)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard !answered else { return }
                window.endSheet(alert.window, returnCode: .cancel)
            }
        }
    }

    // MARK: - the pill

    private var quiet: DispatchWorkItem?

    /// An app just did something: named over the page, and gone a few
    /// seconds after it stops.
    func drove(_ caller: Caller, pages: Int) {
        driving = Driving(name: caller.name, pages: pages)
        quiet?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.driving = nil }
        quiet = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - browse's own key

    private lazy var signer = Signer.load()

    /// A P-256 key made on this Mac: in its Secure Enclave when it has one,
    /// kept in the keychain as the Enclave's wrapped form, useless anywhere
    /// else; in software, in the keychain, when it hasn't.
    private enum Signer {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .enclave(let key): return key.publicKey
            case .software(let key): return key.publicKey
            }
        }

        func signature(for data: Data) -> Data? {
            switch self {
            case .enclave(let key): return (try? key.signature(for: data))?.derRepresentation
            case .software(let key): return (try? key.signature(for: data))?.derRepresentation
            }
        }

        private static var query: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.codegraff.browse.connect",
                kSecAttrAccount as String: Store.world.map { "browse (\($0))" } ?? "browse",
            ]
        }

        static func load() -> Signer {
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let kept = out as? Data, let kind = kept.first {
                let body = kept.dropFirst()
                if kind == 0x45, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body) { return .enclave(key) }
                if kind == 0x53, let key = try? P256.Signing.PrivateKey(rawRepresentation: body) { return .software(key) }
            }
            let made: Signer
            let kept: Data
            if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
                made = .enclave(key)
                kept = Data([0x45]) + key.dataRepresentation
            } else {
                let key = P256.Signing.PrivateKey()
                made = .software(key)
                kept = Data([0x53]) + key.rawRepresentation
            }
            SecItemDelete(self.query as CFDictionary)
            var add = self.query
            add[kSecValueData as String] = kept
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
            return made
        }
    }

    // MARK: - hex

    nonisolated static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var out = Data()
        var at = text.startIndex
        while at < text.endIndex {
            let next = text.index(at, offsetBy: 2)
            guard let byte = UInt8(text[at..<next], radix: 16) else { return nil }
            out.append(byte)
            at = next
        }
        return out
    }
}

/// Settings › Agent › Connected apps.
struct ConnectCard: View {
    @ObservedObject private var connect = Connect.shared

    var body: some View {
        Card {
            Line(
                "Connected apps",
                "Other apps on this Mac, like Harness, using the browser for their agents — with your sign-ins, only what you allow, every request signed. Each one asks here first, with a code to check"
            ) {
                Switch(on: Binding(get: { connect.on }, set: { connect.switchOn($0) }))
            }
            if connect.on {
                ForEach(connect.clients) { client in
                    Rule()
                    Line(client.name, used(client)) {
                        Pill("Revoke") { connect.revoke(client.id) }
                    }
                    ForEach(Connect.Scope.allCases) { scope in
                        Line(scope.title, scope.detail) {
                            Switch(on: Binding(
                                get: { client.scopes.contains(scope) },
                                set: { connect.set(scope, $0, for: client.id) }
                            ))
                        }
                        .padding(.leading, 14)
                    }
                }
                if connect.clients.isEmpty {
                    Rule()
                    Line("None yet", "Connect from the other app — in Harness, Settings › Use browse for web tasks") { EmptyView() }
                }
            }
        }
    }

    private func used(_ client: Connect.Client) -> String {
        guard let used = client.used else { return "Connected \(client.created.formatted(date: .abbreviated, time: .omitted)), not used yet" }
        return "Last used \(used.formatted(.relative(presentation: .named)))"
    }
}

/// Over the page while a connected app is driving: which app, and how many
/// pages it has open.
struct ConnectPill: View {
    @ObservedObject private var connect = Connect.shared

    var body: some View {
        if let driving = connect.driving {
            HStack(spacing: 7) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                Text(driving.pages > 0 ? "\(driving.name) · \(driving.pages) page\(driving.pages == 1 ? "" : "s")" : "\(driving.name) is using browse")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
