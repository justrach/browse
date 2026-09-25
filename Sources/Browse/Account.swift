import AppKit
import SwiftUI
import WebKit

// Signed in to Codegraff, from inside the browser.
//
// One sign-in serves everything that needs one: Codegraff beside the page,
// Jev's quick steps, and sync. It's the same device sign-in `graff login`
// does, and it lands where graff looks — ~/.simple-harness-codegraff.json,
// {"api_key": …}, readable by this user only — so the graff in a terminal
// is signed in too, and one that already was needs nothing here.
//
// The flow: the gateway hands out a short code and a page on codegraff.com
// where the person, signed in there, approves it; meanwhile this asks every
// couple of seconds whether they have, and gets the key once they did. The
// key is shown to nothing and nobody along the way.

@MainActor
final class CodegraffAccount: ObservableObject {
    static let shared = CodegraffAccount()

    enum Phase: Equatable {
        case signedOut
        /// Waiting for the code to be approved on codegraff.com.
        case waiting(code: String, page: URL)
        case signedIn
        case failed(String)
    }

    @Published private(set) var phase: Phase = .signedOut
    /// Who, as codegraff.com knows them.
    @Published private(set) var email: String?

    private var polling: Task<Void, Never>?

    /// The gateway, or SEARCH_LOGIN_URL for a test run.
    static let base = URL(string: ProcessInfo.processInfo.environment["SEARCH_LOGIN_URL"] ?? "https://gateway.codegraff.com")!

    /// Where the key is kept: graff's own file — except on a test run, which
    /// keeps one of its own in its profile and never signs the Mac in or out.
    nonisolated static var file: URL {
        if Store.testing { return Store.file("codegraff-login.json") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".simple-harness-codegraff.json")
    }

    private init() {
        email = Store.settings.string(forKey: "codegraff.email")
        phase = CodegraffAccount.key() == nil ? .signedOut : .signedIn
    }

    /// The key, read where graff reads it and in its order, each time — a
    /// `graff login` in a terminal counts at once.
    nonisolated static func key() -> String? {
        if !Store.testing, let key = ProcessInfo.processInfo.environment["CODEGRAFF_API_KEY"], !key.isEmpty { return key }
        if let data = try? Data(contentsOf: file),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let key = saved["api_key"] as? String, !key.isEmpty {
            return key
        }
        guard !Store.testing else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let data = try? Data(contentsOf: home.appendingPathComponent("forge/.credentials.json")),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let entry = saved.first(where: { $0["id"] as? String == "codegraff" }),
           let key = (entry["auth_details"] as? [String: Any])?["api_key"] as? String, !key.isEmpty {
            return key
        }
        return nil
    }

    /// Looked at again: after a `graff login` elsewhere, or at launch.
    func refresh() {
        guard CodegraffAccount.key() != nil else {
            if case .waiting = phase { return }
            phase = .signedOut
            return
        }
        phase = .signedIn
        if email == nil { Task { await fetchEmail() } }
    }

    // MARK: - signing in

    /// A code from the gateway, its page handed to `show`, and then the
    /// wait for it to be approved. `done` runs once signed in.
    func signIn(show: @escaping (URL) -> Void, done: (() -> Void)? = nil) {
        polling?.cancel()
        polling = Task {
            do {
                let label = "browse on \(Host.current().localizedName ?? "a Mac")"
                let start = try await post("/v1/device/start", ["device_label": label])
                guard let device = start["device_code"] as? String,
                      let code = start["user_code"] as? String,
                      let page = (start["verification_uri_complete"] as? String ?? start["verification_uri"] as? String).flatMap(URL.init(string:))
                else { throw Trouble("Codegraff didn't hand out a code — try again") }
                let every = max(1, start["interval"] as? Int ?? 2)
                let until = Date().addingTimeInterval(TimeInterval(start["expires_in"] as? Int ?? 600))
                phase = .waiting(code: code, page: page)
                show(page)
                while Date() < until {
                    try await Task.sleep(nanoseconds: UInt64(every) * 1_000_000_000)
                    // A dropped connection is only a missed turn.
                    guard let answer = try? await post("/v1/device/poll", ["device_code": device]) else { continue }
                    switch answer["status"] as? String {
                    case "ok":
                        guard let key = answer["api_key"] as? String, key.hasPrefix("cg_sk_") else { throw Trouble("Codegraff's answer had no key in it") }
                        try CodegraffAccount.save(key)
                        remember(answer["email"] as? String)
                        phase = .signedIn
                        done?()
                        return
                    case "denied": throw Trouble("The sign-in was turned down on codegraff.com")
                    case "expired", "not_found", "consumed": throw Trouble("That code ran out — sign in again")
                    default: continue
                    }
                }
                throw Trouble("That code ran out — sign in again")
            } catch is CancellationError {
                phase = CodegraffAccount.key() == nil ? .signedOut : .signedIn
            } catch let trouble as Trouble {
                phase = .failed(trouble.why)
            } catch {
                phase = .failed("Couldn't reach Codegraff")
            }
        }
    }

    /// Where it stands, for ./bench probe on a test run.
    var probe: [String: Any] {
        switch phase {
        case .signedOut: return ["phase": "signed out"]
        case .waiting(let code, let page): return ["phase": "waiting", "code": code, "page": page.absoluteString]
        case .signedIn: return ["phase": "signed in", "email": email ?? ""]
        case .failed(let why): return ["phase": "failed: " + why]
        }
    }

    func cancel() {
        polling?.cancel()
        polling = nil
        phase = CodegraffAccount.key() == nil ? .signedOut : .signedIn
    }

    /// Signed out on this Mac: the key revoked at Codegraff, and its file
    /// gone. graff shares it, so graff is signed out too.
    func signOut() async {
        if let key = CodegraffAccount.key() {
            _ = try? await post("/v1/keys/revoke", [:], key: key)
        }
        try? FileManager.default.removeItem(at: CodegraffAccount.file)
        remember(nil)
        phase = .signedOut
    }

    // MARK: - the wire

    private struct Trouble: Error {
        let why: String
        init(_ why: String) { self.why = why }
    }

    private func fetchEmail() async {
        guard let key = CodegraffAccount.key(),
              let me = try? await request("GET", "/v1/me", nil, key: key)
        else { return }
        remember(me["email"] as? String)
    }

    private func remember(_ email: String?) {
        self.email = email
        Store.settings.set(email, forKey: "codegraff.email")
    }

    private func post(_ path: String, _ body: [String: Any], key: String? = nil) async throws -> [String: Any] {
        try await request("POST", path, body, key: key)
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]?, key: String?) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: CodegraffAccount.base) else { throw Trouble("bad address") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("browse/\(Updater.version)", forHTTPHeaderField: "User-Agent")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Written the way graff writes it: whole or not at all, and readable by
    /// this user only, from the moment it exists.
    private static func save(_ key: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["api_key": key])
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".browse-login-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Trouble("Couldn't save the sign-in")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// The approval page, inside whatever asks for it — the welcome, say, where
/// a tab behind it wouldn't be seen. It keeps the browser's own sign-ins, so
/// someone already signed in to codegraff.com here only has to press
/// Approve.
struct ApprovalPage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Store.websites
        config.applicationNameForUserAgent = Web.userAgentName
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if web.url == nil { web.load(URLRequest(url: url)) }
    }
}

/// The account, as a card: who, or a way in. For Settings and the welcome.
struct AccountCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var account = CodegraffAccount.shared
    /// In place (the welcome) or in a tab (Settings, the column).
    var inline = false
    @State private var showing: URL?
    @State private var sure = false

    var body: some View {
        Card {
            switch account.phase {
            case .signedIn:
                Line("Signed in to Codegraff", account.email ?? "On this Mac, for Codegraff, Jev and sync — graff in a terminal too") {
                    if sure {
                        HStack(spacing: 6) {
                            Pill("Cancel") { sure = false }
                            Pill("Sign out", filled: true) {
                                sure = false
                                Task { await account.signOut() }
                            }
                        }
                    } else {
                        Pill("Sign out…") { sure = true }
                    }
                }
                if sure {
                    Text("Signs this Mac out of Codegraff, graff in a terminal included, and turns sync and Codegraff off until you sign in again.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.bottom, 10)
                }
            case .waiting(let code, let page):
                Line("Approve on codegraff.com", "Check the code there is \(code), then approve. This finishes on its own") {
                    HStack(spacing: 6) {
                        Ring(size: 12)
                        Pill("Cancel") { account.cancel(); showing = nil }
                    }
                }
                if inline, let url = showing ?? Optional(page) {
                    ApprovalPage(url: url)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                        .padding(.bottom, 12)
                }
            case .signedOut, .failed:
                Line(inline ? "Your Codegraff account" : "Sign in with Codegraff", failure ?? (inline
                    ? "A code, and one click on codegraff.com to approve it"
                    : "Keeps your bookmarks and history in step across your Macs, and lets Codegraff work beside the page")) {
                    Pill("Sign in", filled: true) { begin() }
                }
            }
        }
        .onAppear { account.refresh() }
    }

    private var failure: String? {
        if case .failed(let why) = account.phase { return why }
        return nil
    }

    private func begin() {
        account.signIn(show: { url in
            if inline {
                showing = url
            } else {
                browser.tuning = false
                browser.open(url, foreground: true)
            }
        }, done: {
            showing = nil
            browser.signedIn()
        })
    }
}
