import AppKit
import Network
import WebKit

// The browser's own hands, lent to Codegraff.
//
// graff has its shell and its files; what it doesn't have is a browser. This
// is a small MCP server inside Search — the protocol graff takes its extra
// tools over — that gives it one: search, open pages, read them, click and
// type in them, look at them, and read many at once.
//
// It works in pages of its own, out of sight — not in the row of tabs, which
// stays yours. Each page it reads is named in its column, and a click there
// opens it as a real tab. It can see your tabs too, and read or act in one
// when asked about it.
//
// graff doesn't take tool servers over ACP; it reads them from a .mcp.json
// in the folder it works in. That folder is Search's (see Agent.folder), so
// the file is written there, pointing at this server on 127.0.0.1 with a
// token made fresh each launch. Nothing but this user can read the file,
// and nothing but a request carrying the token is answered.

@MainActor
final class AgentTools: ObservableObject {
    static let shared = AgentTools()

    weak var browser: Browser?

    private var listener: NWListener?
    private var port: UInt16?
    private let token = UUID().uuidString + UUID().uuidString
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private let queue = DispatchQueue(label: "search.agent.tools")

    /// graff's own pages, out of sight, oldest first.
    private var pages: [Sheet] = []
    struct OpenPage: Identifiable, Equatable {
        let id: String
        let title: String
        let url: URL
        let loading: Bool
    }
    @Published private(set) var openPages: [OpenPage] = []
    private var made = 0
    /// Off every screen: a page wants a window to be drawn and to run at
    /// full speed, and this is it.
    private var room: NSWindow?

    /// graff's cap on one answer is a MiB; kept clear of it.
    private static let largest = 900_000
    /// Pages kept at once. The oldest goes when another is wanted. Each is a
    /// WebKit process of its own, tens of MB; pages only read close as soon
    /// as they are read, so these are the ones graff/MCP is acting on.
    private static let most = 6
    nonisolated private static let idleSheetTTL: TimeInterval = 300
    private var idleReaper: Timer?

    // MARK: - the server

    /// Listening, and the file that tells graff where, written. False if the
    /// port couldn't be had — graff then runs with its own tools only.
    func start() async -> Bool {
        guard await listening() else { return false }
        return announce()
    }

    private var passkeysWired = false
    /// Deduplicates auto-opening a focused tab for conditional passkeys per (sheet, rp).
    private var passkeyFocused: Set<String> = []

    /// Only listening, not telling graff: for connected apps (Connect.swift),
    /// which find the server through a file of their own.
    func listening() async -> Bool {
        wirePasskeys()
        if port != nil { return true }
        if listener == nil { listen() }
        strip()
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func wirePasskeys() {
        guard !passkeysWired else { return }
        passkeysWired = true

        Passkeys.shared.onFocusForCeremony = { [weak self] web, rp in
            guard let self, let browser = self.browser else { return nil }
            let isSheet = self.pages.contains { $0.web === web }
            let tab = browser.tabs.first { $0.built === web }
            let agentDriving = Connect.shared.driving != nil || browser.agent.phase == .working
            guard isSheet || (tab != nil && (agentDriving || tab?.id == browser.activeID)) else { return nil }
            if let tab, tab.id != browser.activeID {
                browser.select(tab)
            }
            guard let window = Links.window ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) && !$0.isExcludedFromWindowsMenu }) else {
                return nil
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            browser.announce("Passkey requested for \(rp)")
            return window
        }

        Passkeys.shared.onConditionalAvailable = { [weak self] web, rp, _ in
            guard let self, let browser = self.browser, !Store.testing else { return }
            if let sheet = self.pages.first(where: { $0.web === web }), let url = web.url {
                let key = "\(sheet.id)|\(rp)"
                guard self.passkeyFocused.insert(key).inserted else { return }
                NSApp.activate(ignoringOtherApps: true)
                if let window = Links.window ?? NSApp.mainWindow {
                    window.makeKeyAndOrderFront(nil)
                }
                if let existing = browser.tabs.first(where: { $0.address == url }) {
                    browser.select(existing)
                } else {
                    _ = browser.open(url, foreground: true, atEnd: true, agentGroup: "Agent")
                }
                browser.announce("Passkey available for \(rp) — sign in here")
                return
            }
            if Connect.shared.driving != nil, let tab = browser.tabs.first(where: { $0.built === web }) {
                if tab.id != browser.activeID { browser.select(tab) }
                NSApp.activate(ignoringOtherApps: true)
                if let window = Links.window ?? NSApp.mainWindow {
                    window.makeKeyAndOrderFront(nil)
                }
                browser.announce("Passkey available for \(rp)")
            }
        }
    }

    var listeningPort: UInt16? { port }

    /// ACP asks the client for its MCP servers on each new or restored
    /// session. Pass the browser itself there, as well as in graff's config.
    /// An empty list leaves tool discovery to graff's background startup.
    var acpServers: [[String: Any]] {
        guard let port else { return [] }
        return [[
            "type": "http",
            "name": "browse",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": [["name": "Authorization", "value": "Bearer \(token)"]],
        ]]
    }

    /// For a page opened only to be read, then closed (search, read_pages):
    /// no pictures, video or fonts, which are most of what a page fetches
    /// and none of its text. Style sheets stay; they decide what is shown,
    /// and so what innerText has. Not for a page graff acts on, which it
    /// may want a screenshot of.
    private var bare: WKContentRuleList?

    private func strip() {
        guard bare == nil, let store = WKContentRuleListStore.default() else { return }
        let rules = #"[{"trigger": {"url-filter": ".*", "resource-type": ["image", "media", "font"]}, "action": {"type": "block"}}]"#
        store.compileContentRuleList(forIdentifier: "graff-reading", encodedContentRuleList: rules) { [weak self] list, _ in
            MainActor.assumeIsolated { self?.bare = list }
        }
    }

    private func listen() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            settle(false)
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.settle(self.port != nil)
                case .failed, .cancelled:
                    self.listener = nil
                    self.port = nil
                    self.settle(false)
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }

    private func settle(_ ok: Bool) {
        let all = waiting
        waiting = []
        all.forEach { $0.resume(returning: ok) }
    }

    private final class HarnessCache: @unchecked Sendable {
        let lock = NSLock()
        var checked = false
        var url: URL?
    }

    nonisolated private static let harnessCache = HarnessCache()

    nonisolated static func refreshHarnessCache() -> URL? {
        let cache = harnessCache
        guard !Store.testing else {
            cache.lock.lock()
            cache.url = nil
            cache.checked = true
            cache.lock.unlock()
            return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/harness"),
            home.appendingPathComponent("Applications/Harness.app/Contents/MacOS/harness"),
            home.appendingPathComponent(".harness/bin/harness"),
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        cache.lock.lock()
        cache.url = found
        cache.checked = true
        cache.lock.unlock()
        return found
    }

    /// Locate the local Harness CLI (`harness mcp`) so Browse's graff worker
    /// can talk directly to the running NanoHarness engine on 127.0.0.1:27664.
    nonisolated static func harnessExecutable() -> URL? {
        guard !Store.testing else { return nil }
        let cache = harnessCache
        cache.lock.lock()
        if cache.checked {
            let hit = cache.url
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()
        return refreshHarnessCache()
    }

    nonisolated static var harnessAvailable: Bool { harnessExecutable() != nil }

    /// The .mcp.json in graff's folder: this server, under the name graff
    /// will show its tools by, plus the local Harness engine (`harness mcp`)
    /// when Harness.app is installed. The same goes in `own`, which graff reads
    /// instead of the user's own MCP config when it runs lean.
    private func announce() -> Bool {
        guard let port else { return false }
        var servers: [String: Any] = [
            "browse": [
                "url": "http://127.0.0.1:\(port)/mcp",
                "headers": ["Authorization": "Bearer \(token)"],
                // Served in full up front, not behind graff's tool
                // search: in a browser these tools are the point.
                "eager": true,
            ] as [String: Any],
        ]
        if let harness = AgentTools.refreshHarnessCache() {
            servers["harness"] = [
                "command": harness.path,
                "args": ["mcp"],
                "eager": false,
            ] as [String: Any]
        }
        let config: [String: Any] = ["mcpServers": servers]
        return AgentTools.write(config, to: Agent.folder.appendingPathComponent(".mcp.json"))
            && AgentTools.write(config, to: AgentTools.own)
    }

    /// graff's MCP config when it runs lean: this server, or — if it couldn't
    /// be started — none at all, which graff reads as MCP switched off.
    nonisolated static var own: URL {
        Store.folder.appendingPathComponent("Agent", isDirectory: true).appendingPathComponent("mcp.json")
    }

    /// Nothing to connect to: the lean config says so, and the folder's
    /// .mcp.json goes, so no graff comes knocking on a closed port.
    static func withdraw() {
        try? FileManager.default.removeItem(at: Agent.folder.appendingPathComponent(".mcp.json"))
        _ = write(["mcpServers": [String: Any]()], to: own)
    }

    private static func write(_ config: [String: Any], to file: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    /// One HTTP request a connection: read it whole, answer, close. Each is
    /// answered as soon as it is done, so graff can have many going at once.
    nonisolated private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    nonisolated private func read(_ connection: NWConnection, _ so: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, error in
            var got = so
            if let chunk { got.append(chunk) }
            if let request = HTTPRequest(got) {
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    let reply = await self.answer(request)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if done || error != nil || got.count > 4 << 20 {
                connection.cancel()
            } else {
                self?.read(connection, got)
            }
        }
    }

    private func answer(_ request: HTTPRequest) async -> Data {
        guard request.method == "POST" else {
            return HTTPRequest.reply(405, nil)
        }
        // A connected app, which signs instead of carrying the token.
        if request.headers["x-client-id"] != nil || request.path.hasPrefix("/pair") || request.path == "/session/close" {
            return await connected(request)
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return HTTPRequest.reply(401, nil)
        }
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return HTTPRequest.reply(400, nil)
        }
        guard let reply = await rpc(message, owner: AgentTools.graff, caller: nil) else {
            return HTTPRequest.reply(202, nil)
        }
        let body = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPRequest.reply(200, body)
    }

    /// graff's pages are graff's; each connected app's, and each of its
    /// sessions', are its own.
    private static let graff = "graff"

    /// A connected app's request (Connect.swift): from this Mac and no web
    /// page, signed by a key that paired, and inside what it was allowed.
    /// Every answer is signed back.
    private func connected(_ request: HTTPRequest) async -> Data {
        let connect = Connect.shared
        func json(_ status: Int, _ value: [String: Any], signed nonce: String?) -> Data {
            let body = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data()
            return HTTPRequest.reply(status, body, headers: nonce.map { ["X-Signature": connect.sign(body, nonce: $0)] } ?? [:])
        }
        // A page in a browser can reach 127.0.0.1 too: it sends an Origin,
        // or — rebinding a name of its own to this address — the wrong Host.
        guard request.headers["origin"] == nil, let port, request.headers["host"] == "127.0.0.1:\(port)" else {
            return json(403, ["error": "bad_origin"], signed: nil)
        }
        if request.path == "/pair" {
            let (status, value) = connect.pair(request.body)
            return json(status, value, signed: nil)
        }
        let nonce = request.headers["x-nonce"] ?? ""
        let caller: Connect.Caller
        switch connect.verify(method: request.method, path: request.path, headers: request.headers, body: request.body) {
        case .failure(let refusal): return json(401, ["error": refusal.rawValue], signed: nonce)
        case .success(let who): caller = who
        }
        if request.path == "/pair/status" { return json(200, connect.status(caller), signed: nonce) }
        guard !caller.pending else { return json(401, ["error": Connect.Refusal.unknown.rawValue], signed: nonce) }
        let asked = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]

        switch request.path {
        case "/session/close":
            guard let session = asked?["session"] as? String, let owner = AgentTools.owner(caller, session) else {
                return json(400, ["error": "bad_request"], signed: nonce)
            }
            let closing = pages.filter { $0.owner == owner }
            closing.forEach(close)
            return json(200, ["closed": closing.count], signed: nonce)
        case "/mcp":
            guard let message = asked else { return json(400, ["error": "bad_request"], signed: nonce) }
            let params = message["params"] as? [String: Any] ?? [:]
            let session = (params["_meta"] as? [String: Any])?["browse/session"] as? String
            guard let owner = AgentTools.owner(caller, session) else { return json(400, ["error": "bad_session"], signed: nonce) }
            if message["method"] as? String == "tools/call" {
                let name = params["name"] as? String ?? ""
                let scope = Connect.scope(of: name)
                guard let scope, caller.may(scope) else {
                    return json(403, ["error": "out_of_scope", "tool": name, "scope": scope?.rawValue ?? "none"], signed: nonce)
                }
            }
            let toolName = (message["method"] as? String == "tools/call") ? (params["name"] as? String) : nil
            let clientPages = pages.filter { $0.owner.hasPrefix(caller.id) }
            let activeURL = clientPages.last?.web.url ?? browser?.active?.address
            connect.drove(caller, pages: clientPages.count, action: toolName.map(AgentTools.actionLabel), url: activeURL)
            guard let reply = await rpc(message, owner: owner, caller: caller) else {
                // A notification: nothing to say, and that is signed too.
                return HTTPRequest.reply(202, Data(), headers: ["X-Signature": connect.sign(Data(), nonce: nonce)])
            }
            let afterPages = pages.filter { $0.owner.hasPrefix(caller.id) }
            connect.drove(caller, pages: afterPages.count, action: nil, url: afterPages.last?.web.url ?? activeURL)
            if let result = reply["result"] as? [String: Any], let refusal = result[AgentTools.refusal] as? [String: Any] {
                return json(403, refusal, signed: nonce)
            }
            return json(200, reply, signed: nonce)
        default:
            return json(404, ["error": "not_found"], signed: nonce)
        }
    }

    /// A connected app's pages, or one session's of them: `browse/session`
    /// in a call's _meta, up to 64 of [A-Za-z0-9._:-]. Nil for one that isn't.
    private static func owner(_ caller: Connect.Caller, _ session: String?) -> String? {
        guard let session else { return caller.id }
        guard (1...64).contains(session.count), session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else { return nil }
        return caller.id + "/" + session
    }

    /// A tool's answer that is really a refusal — the user said no, or the
    /// app hasn't the scope for the tab it named — sent as a 403.
    private static let refusal = "__refusal"

    // MARK: - MCP

    /// One JSON-RPC message; nothing back for a notification.
    private func rpc(_ message: [String: Any], owner: String, caller: Connect.Caller?) async -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            reply["result"] = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "browse", "title": "browse", "version": Updater.version],
                "instructions": AgentTools.instructions,
            ]
        case "ping":
            reply["result"] = [String: Any]()
        case "tools/list":
            // A connected app sees only what it may use.
            let offered = caller.map { caller in
                AgentTools.tools.filter { tool in
                    Connect.scope(of: tool["name"] as? String ?? "").map(caller.may) ?? false
                }
            } ?? AgentTools.tools
            reply["result"] = ["tools": offered]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            reply["result"] = await call(name, arguments, owner: owner, caller: caller)
        default:
            // `server/discover` among them: graff asks it first, and an
            // error here is what tells it this is the simpler, older kind
            // of server.
            reply["error"] = ["code": -32601, "message": "Method not found: \(method)"]
        }
        return reply
    }

    static let instructions = """
    These tools are a web browser — browse, the one the user is looking at. They work in \
    pages of their own, out of the user's sight; each page read is listed for the user, who \
    can open it. For research, `search` first, then `read_pages` with every promising link at \
    once — it loads them in parallel — rather than one page at a time. Pages read that way \
    are closed once read; `open` one to keep it. `open` a page to act on \
    it (`snapshot`, `page_info`, `read_markdown`, `click`, `click_at`, `type`, `press_key`, \
    `scroll`, `hover`, `wait_for`, `submit`, `run_js`, `screenshot`). Use `snapshot` to see \
    interactive elements (buttons, links, tabs, inputs) with exact CSS selectors; password \
    and card values are redacted. `screenshot` returns an image of the viewport, a `full_page`, \
    a specific `selector`, or the whole `window` (`target: "window"`), and can also `save_to` \
    a file path. `tabs` lists the user's own tabs too; pass a tab id or `page: "active"` to \
    read or act on the tab in front. `open_tab` opens a visible tab directly in the browser, \
    and `show` puts a page in front of the user as a tab.
    """

    private static func annotations(for name: String) -> [String: Any] {
        switch name {
        case "search", "read_pages", "read", "read_markdown", "page_info", "links",
             "console_logs", "network_requests",
             "tabs", "snapshot", "form_fields", "screenshot", "wait_for":
            return ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        case "open", "open_tab", "go", "back", "forward", "reload", "scroll", "hover", "show":
            return ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true]
        case "close":
            return ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false]
        default:
            return ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": annotations(for: name),
        ]
    }

    private static let themeRoles: [String: Any] = Dictionary(uniqueKeysWithValues:
        ["ground", "ink", "muted", "faint", "hairline", "wash", "hover", "accent", "onAccent"].map { ($0, ["type": "string"] as [String: Any]) })

    private static let page: [String: Any] = ["type": "string", "description": "A page's id: one of yours (p1, p2…), a tab id from `tabs`, or \"active\" for the user's frontmost tab. Leave out for your latest page."]

    private static let tools: [[String: Any]] = [
        tool("search", "Search the web with the user's search engine. Returns the results' text and their links, ready for read_pages.", [
            "query": ["type": "string", "description": "What to search for."],
        ], required: ["query"]),
        tool("read_pages", "Load several pages at once, in parallel, and return the words on each. The fast way to go through many sources.", [
            "urls": ["type": "array", "items": ["type": "string"], "description": "Addresses to read, up to 12."],
            "limit": ["type": "integer", "description": "Most characters from each page. 8000 unless asked."],
        ], required: ["urls"]),
        tool("open", "Open an address in a page of your own and wait for it to load, to read or act on it. Returns its id.", [
            "url": ["type": "string", "description": "An address. Words that aren't one are searched for."],
        ], required: ["url"]),
        tool("read", "The words on a page, as a reader would take them, with its title and address.", [
            "page": page,
            "limit": ["type": "integer", "description": "Most characters to return. 60000 unless asked."],
        ]),
        tool("read_markdown", "Extract a page as clean structured Markdown (headings, paragraphs, lists, links, blockquotes and code blocks).", [
            "page": page,
            "limit": ["type": "integer", "description": "Most characters to return. 60000 unless asked."],
        ]),
        tool("page_info", "Fast page metadata: title, URL, loading state, viewport size, scroll position/height, and currently focused element.", [
            "page": page,
        ]),
        tool("console_logs", "Read captured browser console messages (log, info, warn, error) and uncaught runtime errors on a page.", [
            "page": page,
            "level": ["type": "string", "enum": ["all", "log", "info", "warn", "error"], "description": "Filter by console level (default all)."],
            "limit": ["type": "integer", "description": "Maximum number of recent entries to return (default 50, max 200)."],
            "clear": ["type": "boolean", "description": "Clear the buffered console entries after reading."],
        ]),
        tool("network_requests", "Read captured fetch and XMLHttpRequest calls on a page (method, URL, status, duration, failure state; omits headers/cookies/bodies).", [
            "page": page,
            "failed_only": ["type": "boolean", "description": "Only return failed or non-2xx/3xx requests."],
            "filter": ["type": "string", "description": "Case-insensitive URL substring filter."],
            "limit": ["type": "integer", "description": "Maximum number of recent requests to return (default 50, max 200)."],
            "clear": ["type": "boolean", "description": "Clear the buffered network entries after reading."],
        ]),
        tool("links", "The links on a page: their words and where they go.", ["page": page]),
        tool("go", "Take a page to another address and wait for it to load.", [
            "url": ["type": "string", "description": "An address. Words that aren't one are searched for."],
            "page": page,
        ], required: ["url"]),
        tool("back", "Go back a page.", ["page": page]),
        tool("forward", "Go forward a page.", ["page": page]),
        tool("reload", "Load a page again.", ["page": page]),
        tool("click", "Click the element a CSS selector names.", [
            "selector": ["type": "string"],
            "page": page,
        ], required: ["selector"]),
        tool("click_at", "Click at exact viewport coordinates (x, y) — useful for canvases, video scrubbers, maps, or custom controls without CSS selectors.", [
            "x": ["type": "number", "description": "Horizontal viewport coordinate in CSS pixels."],
            "y": ["type": "number", "description": "Vertical viewport coordinate in CSS pixels."],
            "button": ["type": "string", "enum": ["left", "right", "middle"], "description": "Mouse button (default left)."],
            "page": page,
        ], required: ["x", "y"]),
        tool("type", "Type text into the field a CSS selector names, replacing what is there.", [
            "selector": ["type": "string"],
            "text": ["type": "string"],
            "page": page,
        ], required: ["selector", "text"]),
        tool("submit", "Submit the form around the element a CSS selector names.", [
            "selector": ["type": "string"],
            "page": page,
        ], required: ["selector"]),
        tool("form_fields", "Every field a person could fill in on a page — text boxes, selects with their options, checkboxes, radio groups, editable areas — each with its label as a person reads it, its current value, whether it is required, and a CSS selector for `fill`. Also the buttons that submit.", [
            "page": page,
        ]),
        tool("fill", "Fill in many fields at once, the way typing and choosing would: text is typed, a select takes the option whose value or words match, a checkbox takes true or false, a radio group takes the value or words of its choice. Says what each field holds after.", [
            "fields": [
                "type": "array",
                "description": "The fields to fill, in order.",
                "items": [
                    "type": "object",
                    "properties": [
                        "selector": ["type": "string", "description": "From form_fields."],
                        "value": ["description": "Text; an option's value or words; true or false for a checkbox, or a list of the boxes to tick in a checkbox group."],
                    ],
                    "required": ["selector", "value"],
                ],
            ],
            "page": page,
        ], required: ["fields"]),
        tool("drive", "Carry out a goal of several steps on one page — a search form, its filters, a sign-up, a date picker — fast: Jev picks each click, choice and field in one quick call a step, and types only the values you give it. Returns each step, why it stopped, and the page as it is now. It stops before paying, sending, posting, booking, deleting or creating an account, and when a field wants a value you didn't give — call again with it. Check the page after; if Jev is unavailable, use form_fields, fill and click.", [
            "goal": ["type": "string", "description": "What should be true on the page when it's done, in full: every field, choice and filter."],
            "values": ["type": "array", "items": ["type": "string"], "description": "Every text the goal needs typed, each exactly as it should be typed — a name, an email, a city, a search. Nothing is made up past these."],
            "steps": ["type": "integer", "description": "Most steps to take. 25 unless asked."],
            "page": page,
        ], required: ["goal"]),
        tool("theme", "Make a colour theme for this browser, save it, and switch to it. Colours are #rrggbb, for light and for dark: ground (the window and panels), ink (text; must read on ground and wash, contrast 4.5+), muted (secondary text), faint (dots, a switch that's off), hairline (thin lines), wash (the selected tab), hover (under the pointer), accent (a switch that's on, the main button), onAccent (text on the accent, contrast 3+). Keep ground, wash and hover close; the accent is the one colour that stands out. Says what's wrong if a colour doesn't read.", [
            "name": ["type": "string", "description": "A short name for the theme."],
            "light": ["type": "object", "description": "The nine colours for a light window.", "properties": AgentTools.themeRoles],
            "dark": ["type": "object", "description": "The nine colours for a dark window.", "properties": AgentTools.themeRoles],
        ], required: ["name", "light", "dark"]),
        tool("run_js", "Run JavaScript in a page and return its value.", [
            "script": ["type": "string", "description": "An expression, or a function called at once."],
            "page": page,
        ], required: ["script"]),
        tool("snapshot", "Structured map of visible interactive elements (buttons, links, tabs, inputs, dialogs, headings) with their role, accessible name, state/value (secrets redacted), and exact CSS selector for click/type/hover/screenshot.", [
            "page": page,
            "selector": ["type": "string", "description": "Optional root CSS selector to scope the snapshot (e.g. a dialog or nav)."],
            "limit": ["type": "integer", "description": "Max elements to return. 150 unless asked."],
        ]),
        tool("scroll", "Scroll a page, a scrollable element, or bring a selector into view.", [
            "direction": ["type": "string", "enum": ["down", "up", "left", "right", "top", "bottom"], "description": "Direction to scroll (default down unless selector is scrolled into view)."],
            "amount": ["type": "integer", "description": "Pixels to scroll (default 600)."],
            "selector": ["type": "string", "description": "Optional CSS selector to scroll into view (or scroll inside if direction is given)."],
            "page": page,
        ]),
        tool("press_key", "Send a keyboard key press (Enter, Escape, Tab, ArrowDown, ArrowUp, Backspace, Space, etc.) to the focused element or a CSS selector.", [
            "key": ["type": "string", "description": "Key name such as Enter, Escape, Tab, ArrowDown, ArrowUp, ArrowLeft, ArrowRight, Backspace, Space, or a single character."],
            "selector": ["type": "string", "description": "Optional CSS selector to focus before pressing the key."],
            "modifiers": ["type": "array", "items": ["type": "string", "enum": ["shift", "alt", "ctrl", "meta"]], "description": "Optional modifier keys."],
            "page": page,
        ], required: ["key"]),
        tool("hover", "Hover over an element to reveal menus, tooltips or hover states.", [
            "selector": ["type": "string", "description": "CSS selector of the element to hover."],
            "page": page,
        ], required: ["selector"]),
        tool("wait_for", "Wait until a CSS selector or visible text appears (or disappears) on the page.", [
            "selector": ["type": "string", "description": "CSS selector to wait for."],
            "text": ["type": "string", "description": "Substring of visible page text to wait for."],
            "state": ["type": "string", "enum": ["visible", "hidden"], "description": "Wait for visible (default) or hidden."],
            "timeout": ["type": "number", "description": "Seconds to wait (default 10, max 30)."],
            "page": page,
        ]),
        tool("screenshot", "Take a screenshot of a page (viewport, full page, or a specific CSS selector) or the whole browse window. Returns an inline image and optionally writes it to a file path.", [
            "page": page,
            "full_page": ["type": "boolean", "description": "Capture the full scrollable page height (up to 8000 px) instead of only the viewport."],
            "selector": ["type": "string", "description": "Optional CSS selector to crop the screenshot to that element."],
            "target": ["type": "string", "enum": ["page", "window"], "description": "\"page\" (default) captures the web page; \"window\" captures the entire browse window including tabs and sidebar."],
            "save_to": ["type": "string", "description": "Optional absolute file path to also save the screenshot image (PNG if ending in .png, else JPEG)."],
        ]),
        tool("tabs", "Your pages and the user's own tabs: id, title, address, and which tab they have in front."),
        tool("open_tab", "Open a URL directly as a visible tab in the user's browser window.", [
            "url": ["type": "string", "description": "An address or search query."],
            "foreground": ["type": "boolean", "description": "Whether to bring the new tab to the front (default true)."],
        ], required: ["url"]),
        tool("show", "Put a page in front of the user as a tab of theirs, or bring one of their tabs to the front.", ["page": page], required: ["page"]),
        tool("close", "Close one of your pages, or a tab of the user's.", ["page": page], required: ["page"]),
    ]

    // MARK: - the tools

    private func call(_ name: String, _ arguments: [String: Any], owner: String, caller: Connect.Caller?) async -> [String: Any] {
        guard let browser else { return AgentTools.failed("browse has no window") }
        switch name {
        case "search":
            guard let query = arguments["query"] as? String, let url = browser.searchURL(for: query) else {
                return AgentTools.failed("search needs a query")
            }
            let sheet = await load(url, as: "Search: \(query)", reading: true, owner: owner)
            let (text, error) = await sheet.run(Agent.pageTextScript(limit: 22_000))
            if let error { return AgentTools.failed(error) }
            let (found, _) = await sheet.run(AgentTools.results(excluding: url.host() ?? ""))
            // Read, so closed: it is named in the talk, a click from being a tab.
            close(sheet)
            var said = "\(sheet.title)\n\n" + AgentTools.cut(text as? String ?? "", 20_000)
            if let found = found as? String, !found.isEmpty { said += "\n\nResults:\n" + found }
            return AgentTools.text(said)

        case "read_pages":
            let urls = (arguments["urls"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap { address($0, browser) } }
            guard !urls.isEmpty else { return AgentTools.failed("read_pages needs urls") }
            let limit = arguments["limit"] as? Int ?? 8_000
            let chosen = Array(urls.prefix(12))
            let each = min(limit, AgentTools.largest / chosen.count / 2)
            // Cap active concurrent reading sheets at `AgentTools.most` while
            // letting up to 12 URLs drain without hitting active-sheet limits.
            let read = await withTaskGroup(of: (Int, String).self) { group in
                let maxConcurrent = min(AgentTools.most, chosen.count)
                var nextIndex = 0
                while nextIndex < maxConcurrent {
                    let index = nextIndex
                    let url = chosen[index]
                    nextIndex += 1
                    group.addTask { @MainActor in (index, await self.readPage(url, limit: each, owner: owner)) }
                }
                var all: [(Int, String)] = []
                all.reserveCapacity(chosen.count)
                for await one in group {
                    all.append(one)
                    if nextIndex < chosen.count {
                        let index = nextIndex
                        let url = chosen[index]
                        nextIndex += 1
                        group.addTask { @MainActor in (index, await self.readPage(url, limit: each, owner: owner)) }
                    }
                }
                return all.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return AgentTools.text(read.joined(separator: "\n\n"))

        case "open":
            guard let url = address(arguments["url"], browser) else { return AgentTools.failed("open needs a url") }
            let sheet = await load(url, as: nil, owner: owner)
            return AgentTools.said(describe(sheet))

        case "read":
            return await on(arguments, browser, owner, caller) { target in
                let requestedLimit = arguments["limit"] as? Int ?? 60_000
                let scriptLimit = max(1_000, min(requestedLimit + 2_000, 200_000))
                let (text, error) = await target.run(Agent.pageTextScript(limit: scriptLimit))
                if let error { return AgentTools.failed(error) }
                let body = AgentTools.cut(text as? String ?? "", requestedLimit)
                return AgentTools.text("\(target.title)\n\(target.address)\n\n\(body)")
            }

        case "read_markdown":
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.markdownScript)
                if let error { return AgentTools.failed(error) }
                let body = AgentTools.cut(value as? String ?? "", arguments["limit"] as? Int ?? 60_000)
                return AgentTools.text("# \(target.title)\n\n<\(target.address)>\n\n\(body)")
            }

        case "page_info":
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.pageInfoScript)
                if let error { return AgentTools.failed(error) }
                var info = (value as? [String: Any]) ?? [:]
                let offered = Passkeys.shared.offered(in: target.web)
                info["page"] = target.id
                info["title"] = target.title
                info["url"] = target.address
                info["loading"] = target.web.isLoading
                info["passkeysAvailable"] = !offered.isEmpty
                info["passkeyCount"] = offered.count
                return AgentTools.said(info)
            }

        case "console_logs":
            return await on(arguments, browser, owner, caller) { target in
                let level = arguments["level"] as? String ?? "all"
                let limit = arguments["limit"] as? Int ?? 50
                let clear = arguments["clear"] as? Bool ?? false
                let (value, error) = await target.run(DevCapture.readConsoleScript(level: level, limit: limit, clear: clear))
                if let error { return AgentTools.failed(error) }
                if let dict = value as? [String: Any], (dict["active"] as? Bool) == false {
                    _ = await target.run(DevCapture.script)
                    let armed: [String: Any] = ["active": true, "justArmed": true, "total": 0, "entries": []]
                    return AgentTools.said(["page": target.id, "url": target.address, "console": armed])
                }
                return AgentTools.said(["page": target.id, "url": target.address, "console": value ?? [:]])
            }

        case "network_requests":
            return await on(arguments, browser, owner, caller) { target in
                let failedOnly = arguments["failed_only"] as? Bool ?? false
                let filter = arguments["filter"] as? String
                let limit = arguments["limit"] as? Int ?? 50
                let clear = arguments["clear"] as? Bool ?? false
                let (value, error) = await target.run(DevCapture.readNetworkScript(failedOnly: failedOnly, filter: filter, limit: limit, clear: clear))
                if let error { return AgentTools.failed(error) }
                if let dict = value as? [String: Any], (dict["active"] as? Bool) == false {
                    _ = await target.run(DevCapture.script)
                    let armed: [String: Any] = ["active": true, "justArmed": true, "total": 0, "entries": []]
                    return AgentTools.said(["page": target.id, "url": target.address, "network": armed])
                }
                return AgentTools.said(["page": target.id, "url": target.address, "network": value ?? [:]])
            }

        case "links":
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.allLinks)
                if let error { return AgentTools.failed(error) }
                return AgentTools.text(value as? String ?? "")
            }

        case "go":
            guard let url = address(arguments["url"], browser) else { return AgentTools.failed("go needs a url") }
            return await on(arguments, browser, owner, caller) { target in
                target.go(url)
                await target.settled()
                self.seen(target)
                return AgentTools.said(["page": target.id, "title": target.title, "url": target.address])
            }

        case "back", "forward", "reload":
            return await on(arguments, browser, owner, caller) { target in
                switch name {
                case "back": target.web.goBack()
                case "forward": target.web.goForward()
                default: target.web.reload()
                }
                await target.settled()
                return AgentTools.said(["page": target.id, "title": target.title, "url": target.address])
            }

        case "form_fields":
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.fields)
                if let error { return AgentTools.failed(error) }
                return AgentTools.text("\(target.id) · \(target.title)\n\(target.address)\n\n" + (value as? String ?? ""))
            }

        case "fill", "type":
            // `type` is one field filled; both go the way a person's typing
            // would, so a page's own scripts see it.
            var wanted = (arguments["fields"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            if name == "type", let selector = arguments["selector"] as? String {
                wanted = [["selector": selector, "value": arguments["text"] as? String ?? ""]]
            }
            guard !wanted.isEmpty else { return AgentTools.failed("\(name) needs fields, each a selector and a value") }
            // A connected app never types into a password field.
            guard let script = AgentTools.fill(wanted, passwords: caller == nil) else { return AgentTools.failed("Those values can't be sent to the page") }
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(script)
                if let error { return AgentTools.failed(error) }
                // A field's own scripts — a search as you type, a form that
                // grows another field — have a moment to answer.
                try? await Task.sleep(nanoseconds: 100_000_000)
                return AgentTools.text("\(target.id) · \(target.title)\n\n" + (value as? String ?? ""))
            }

        case "click", "submit":
            guard let selector = arguments["selector"] as? String else { return AgentTools.failed("\(name) needs a selector") }
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(Bench.act(name, selector: selector, text: arguments["text"] as? String ?? ""))
                if let error { return AgentTools.failed(error) }
                guard value as? String == "ok" else { return AgentTools.failed(value as? String ?? "didn't work") }
                // A click or a submit may have sent the page somewhere.
                await target.settledIfLoading()
                return AgentTools.said(["page": target.id, "title": target.title, "url": target.address])
            }

        case "click_at":
            let x = (arguments["x"] as? Double) ?? (arguments["x"] as? Int).map(Double.init)
            let y = (arguments["y"] as? Double) ?? (arguments["y"] as? Int).map(Double.init)
            guard let x, let y else { return AgentTools.failed("click_at needs numeric x and y coordinates") }
            let button = (arguments["button"] as? String ?? "left").lowercased()
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.clickAtScript(x: x, y: y, button: button))
                if let error { return AgentTools.failed(error) }
                if let dict = value as? [String: Any], let err = dict["error"] as? String {
                    return AgentTools.failed(err)
                }
                await target.settledIfLoading()
                var out = (value as? [String: Any]) ?? [:]
                out["page"] = target.id
                out["title"] = target.title
                out["url"] = target.address
                return AgentTools.said(out)
            }

        case "drive":
            guard browser.prefs.agentJev else {
                return AgentTools.failed("drive is switched off in Settings › Agent. Use form_fields, fill and click.")
            }
            guard let goal = (arguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
                return AgentTools.failed("drive needs a goal")
            }
            let values = (arguments["values"] as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
            let steps = min(max(arguments["steps"] as? Int ?? 25, 1), 60)
            return await on(arguments, browser, owner, caller) { target in
                let (said, failed) = await Jev.drive(goal: goal, values: values, steps: steps, on: target.web)
                self.seen(target)
                return failed ? AgentTools.failed(said) : AgentTools.text("\(target.id) · " + said)
            }

        case "theme":
            var raw = arguments
            raw["id"] = UUID().uuidString
            raw["author"] = "Codegraff"
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let theme = try? JSONDecoder().decode(Theme.self, from: data)
            else { return AgentTools.failed("theme needs a name, and light and dark each with ground, ink, muted, faint, hairline, wash and hover as #rrggbb") }
            if let trouble = Themes.save(theme) { return AgentTools.failed(trouble + ". Adjust those colours and call theme again.") }
            browser.prefs.theme = theme.id
            NotificationCenter.default.post(name: Themes.changed, object: nil)
            return AgentTools.text("Saved “\(theme.name)” and switched to it. It's in Settings › Themes.")

        case "run_js":
            guard let script = arguments["script"] as? String else { return AgentTools.failed("run_js needs a script") }
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(script)
                if let error { return AgentTools.failed(error) }
                let plain = Bench.plain(value)
                if let string = plain as? String { return AgentTools.text(string) }
                return AgentTools.said(plain)
            }

        case "snapshot":
            let root = arguments["selector"] as? String
            let limit = min(max(arguments["limit"] as? Int ?? 150, 1), 400)
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.snapshotScript(root: root, limit: limit))
                if let error { return AgentTools.failed(error) }
                return AgentTools.text("\(target.id) · \(target.title)\n\(target.address)\n\n" + (value as? String ?? ""))
            }

        case "scroll":
            let direction = arguments["direction"] as? String
            let amount = arguments["amount"] as? Int ?? 600
            let selector = arguments["selector"] as? String
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.scrollScript(direction: direction, amount: amount, selector: selector))
                if let error { return AgentTools.failed(error) }
                if let dict = value as? [String: Any] { return AgentTools.said(dict) }
                return AgentTools.text(String(describing: value ?? "ok"))
            }

        case "press_key":
            guard let key = arguments["key"] as? String, !key.isEmpty else { return AgentTools.failed("press_key needs a key") }
            let selector = arguments["selector"] as? String
            let modifiers = (arguments["modifiers"] as? [Any] ?? []).compactMap { $0 as? String }
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.pressKeyScript(key: key, selector: selector, modifiers: modifiers))
                if let error { return AgentTools.failed(error) }
                guard value as? String == "ok" else { return AgentTools.failed(value as? String ?? "press_key failed") }
                await target.settledIfLoading()
                return AgentTools.said(["page": target.id, "key": key, "title": target.title, "url": target.address])
            }

        case "hover":
            guard let selector = arguments["selector"] as? String, !selector.isEmpty else { return AgentTools.failed("hover needs a selector") }
            return await on(arguments, browser, owner, caller) { target in
                let (value, error) = await target.run(AgentTools.hoverScript(selector: selector))
                if let error { return AgentTools.failed(error) }
                guard value as? String == "ok" else { return AgentTools.failed(value as? String ?? "hover failed") }
                try? await Task.sleep(nanoseconds: 80_000_000)
                return AgentTools.said(["page": target.id, "hovered": selector])
            }

        case "wait_for":
            let selector = arguments["selector"] as? String
            let text = arguments["text"] as? String
            guard selector != nil || text != nil else { return AgentTools.failed("wait_for needs selector or text") }
            let state = (arguments["state"] as? String ?? "visible").lowercased()
            let timeout = min(max((arguments["timeout"] as? Double) ?? (arguments["timeout"] as? Int).map(Double.init) ?? 10.0, 0.5), 30.0)
            return await on(arguments, browser, owner, caller) { target in
                let deadline = Date().addingTimeInterval(timeout)
                let check = AgentTools.waitCheckScript(selector: selector, text: text)
                while true {
                    let (value, error) = await target.run(check)
                    if let error { return AgentTools.failed(error) }
                    let present = (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
                    if (state == "hidden" && !present) || (state != "hidden" && present) {
                        return AgentTools.said(["matched": true, "state": state, "page": target.id, "url": target.address])
                    }
                    if Date() >= deadline {
                        return AgentTools.failed("Timed out after \(Int(timeout))s waiting for \(selector ?? text ?? "condition") to be \(state)")
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }

        case "screenshot":
            let targetKind = (arguments["target"] as? String ?? "page").lowercased()
            let saveTo = (arguments["save_to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let wantPNG = saveTo?.lowercased().hasSuffix(".png") == true
            if targetKind == "window" {
                if let refused = await refusedTabs(caller) { return refused }
                guard let window = Links.window ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) }),
                      let (data, mime, rawPNG) = await AgentTools.windowPicture(window, wantPNG: wantPNG)
                else { return AgentTools.failed("No browse window available to capture") }
                return AgentTools.imageReply(data: data, mime: mime, rawPNG: rawPNG, saveTo: saveTo)
            }
            let fullPage = arguments["full_page"] as? Bool ?? false
            let selector = arguments["selector"] as? String
            return await on(arguments, browser, owner, caller) { target in
                guard target.web.window != nil else {
                    return AgentTools.failed("That tab isn't drawn right now — `show` it first")
                }
                if caller != nil { _ = await target.run(AgentTools.maskSecretsScript(mask: true)) }
                defer {
                    if caller != nil { Task { @MainActor in _ = await target.run(AgentTools.maskSecretsScript(mask: false)) } }
                }
                var cropRect: CGRect?
                if let selector, !selector.isEmpty {
                    let (rectVal, err) = await target.run(AgentTools.elementRectScript(selector: selector))
                    if let err { return AgentTools.failed(err) }
                    guard let dict = rectVal as? [String: Double],
                          let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"],
                          w > 0, h > 0
                    else { return AgentTools.failed("Element not found or not visible: \(selector)") }
                    cropRect = CGRect(x: x, y: y, width: w, height: h)
                } else if fullPage {
                    let (sizeVal, _) = await target.run("[document.documentElement.scrollWidth || window.innerWidth, Math.min(8000, Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0, window.innerHeight))]")
                    if let dims = sizeVal as? [NSNumber], dims.count == 2 {
                        let w = max(Double(target.web.bounds.width), dims[0].doubleValue)
                        let h = max(Double(target.web.bounds.height), dims[1].doubleValue)
                        cropRect = CGRect(x: 0, y: 0, width: w, height: h)
                    }
                }
                guard let (data, mime, rawPNG) = await AgentTools.picture(target.web, rect: cropRect, wantPNG: wantPNG) else {
                    return AgentTools.failed("No picture")
                }
                return AgentTools.imageReply(data: data, mime: mime, rawPNG: rawPNG, saveTo: saveTo)
            }

        case "tabs":
            let theirs = browser.tabs.filter { !$0.bench }.map { tab -> [String: Any] in
                [
                    "id": AgentTools.short(tab),
                    "title": tab.label,
                    "url": tab.address?.absoluteString ?? "",
                    "in front": tab.id == browser.activeID,
                    "group": tab.isAgentTab ? "agent" : "user",
                ]
            }
            return AgentTools.said(["your pages": pages.filter { $0.owner == owner }.map(describe), "the user's tabs": theirs])

        case "open_tab":
            guard let url = address(arguments["url"], browser) else { return AgentTools.failed("open_tab needs a url") }
            if let refused = await refusedTabs(caller) { return refused }
            let foreground = arguments["foreground"] as? Bool ?? true
            let tab = browser.open(url, foreground: foreground, atEnd: true, agentGroup: "Agent")
            return AgentTools.said(["tab": AgentTools.short(tab), "url": url.absoluteString, "foreground": foreground, "group": "agent"])

        case "show":
            let ref = (arguments["page"] as? String ?? "").lowercased()
            if let sheet = pages.first(where: { $0.id == ref && $0.owner == owner }) {
                guard let url = sheet.web.url else { return AgentTools.failed("\(ref) has no address yet") }
                let tab = browser.open(url, foreground: true, atEnd: true, agentGroup: "Agent")
                return AgentTools.said(["tab": AgentTools.short(tab), "url": url.absoluteString, "group": "agent"])
            }
            guard let tab = tab(ref, browser) else { return AgentTools.failed("No page or tab “\(ref)” — see `tabs`") }
            if let refused = await refusedTabs(caller) { return refused }
            browser.select(tab)
            return AgentTools.said(["tab": AgentTools.short(tab), "in front": true])

        case "close":
            let ref = (arguments["page"] as? String ?? "").lowercased()
            if let sheet = pages.first(where: { $0.id == ref && $0.owner == owner }) {
                close(sheet)
                return AgentTools.said(["closed": ref])
            }
            guard let tab = tab(ref, browser) else { return AgentTools.failed("No page or tab “\(ref)” — see `tabs`") }
            if let refused = await refusedTabs(caller) { return refused }
            browser.close(tab)
            return AgentTools.said(["closed": ref])

        default:
            return AgentTools.failed("No tool named \(name)")
        }
    }

    // MARK: - graff's pages

    /// A page of its own for whoever asked — graff, or a connected app —
    /// loaded, and for graff listed in its column. One only `reading` is to
    /// be read and closed, and loads without its pictures.
    private func load(_ url: URL, as label: String?, reading: Bool = false, owner: String) async -> Sheet {
        let sheet = make(reading: reading, owner: owner)
        sheet.go(url)
        await sheet.settled()
        seen(sheet, as: label)
        return sheet
    }

    /// Every page graff has open, gone: it has stopped (Agent.rest), and a
    /// page kept for a graff that isn't there holds memory for no one. A
    /// connected app's pages are its own to close; the off-screen window
    /// goes once nobody has one.
    func dropPages() {
        pages.filter { $0.owner == AgentTools.graff }.forEach(close)
        if pages.isEmpty {
            room?.close()
            room = nil
        }
    }

    /// Open or focus the latest page a connected app is working on so the user
    /// can watch live or step in (Follow button in ConnectPill).
    func followClient(_ clientID: String, fallbackURL: URL?) {
        guard let browser else { return }
        let url = pages.last(where: { ($0.owner == clientID || $0.owner.hasPrefix(clientID + "/")) && $0.web.url != nil })?.web.url ?? fallbackURL
        guard let url else { return }
        if browser.agentFull { browser.agentFull = false }
        if let existing = browser.tabs.first(where: { $0.address == url }) {
            browser.select(existing)
        } else {
            _ = browser.open(url, foreground: true, atEnd: true, agentGroup: "Agent")
        }
    }

    /// Close every page opened by a connected app (Stop button in ConnectPill).
    func stopClient(_ clientID: String) {
        let closing = pages.filter { $0.owner == clientID || $0.owner.hasPrefix(clientID + "/") }
        closing.forEach(close)
        releaseRoomIfEmpty()
    }

    /// Reap idle offscreen agent/MCP WebKit pages so long-lived MCP sessions
    /// don't hold hundreds of MB of background WebContent processes.
    func reapIdlePages(olderThan age: TimeInterval = AgentTools.idleSheetTTL) {
        let now = Date()
        let stale = pages.filter { now.timeIntervalSince($0.lastUsed) >= age }
        stale.forEach(close)
        releaseRoomIfEmpty()
    }

    private func releaseRoomIfEmpty() {
        if pages.isEmpty {
            idleReaper?.invalidate()
            idleReaper = nil
            room?.close()
            room = nil
        }
    }

    private func ensureReaper() {
        guard idleReaper == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapIdlePages() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        idleReaper = timer
    }

    /// Human-readable status for the live driving pill.
    private static func actionLabel(_ tool: String) -> String {
        switch tool {
        case "screenshot": return "Taking screenshot…"
        case "snapshot": return "Reading page elements…"
        case "page_info": return "Inspecting page…"
        case "console_logs": return "Reading console logs…"
        case "network_requests": return "Inspecting network requests…"
        case "search": return "Searching…"
        case "read_pages", "read", "read_markdown": return "Reading page…"
        case "open", "go": return "Loading page…"
        case "open_tab": return "Opening tab…"
        case "click", "click_at", "submit": return "Clicking…"
        case "fill", "type": return "Filling form…"
        case "press_key": return "Pressing key…"
        case "scroll": return "Scrolling…"
        case "hover": return "Hovering…"
        case "wait_for": return "Waiting for page…"
        case "drive": return "Driving page…"
        case "run_js": return "Running script…"
        default: return "Working…"
        }
    }

    /// Load, extract text, and close a disposable reading sheet for `read_pages`.
    private func readPage(_ url: URL, limit: Int, owner: String) async -> String {
        let sheet = await load(url, as: nil, reading: true, owner: owner)
        let scriptLimit = max(1_000, min(limit + 2_000, 200_000))
        let (text, error) = await sheet.run(Agent.pageTextScript(limit: scriptLimit))
        let body = error.map { "(couldn't read it: \($0))" } ?? AgentTools.cut(text as? String ?? "", limit)
        let said = "## \(sheet.title)\n\(sheet.address)\n\n\(body)"
        close(sheet)
        return said
    }

    /// A page put away once it has been read, or when asked.
    private func close(_ sheet: Sheet) {
        pages.removeAll { $0 === sheet }
        sheet.drop()
        if !sheet.reading { publishPages() }
    }

    /// Each owner keeps its latest few; its oldest goes when another is wanted.
    private func make(reading: Bool, owner: String) -> Sheet {
        made += 1
        let window = room ?? makeRoom()
        let sheet = Sheet(id: "p\(made)", owner: owner, in: window, reading: reading, bare: reading ? bare : nil)
        pages.append(sheet)
        if !reading {
            ensureReaper()
            sheet.onChange = { [weak self] in self?.publishPages() }
            publishPages()
            while pages.filter({ $0.owner == owner && !$0.reading }).count > AgentTools.most,
                  let oldest = pages.first(where: { $0.owner == owner && !$0.reading }) {
                close(oldest)
            }
        }
        return sheet
    }

    /// Named in graff's column, where a click opens it as a tab of the
    /// user's. A connected app's pages aren't graff's to list.
    private func seen(_ sheet: any Target, as label: String? = nil) {
        if let sheet = sheet as? Sheet, sheet.owner != AgentTools.graff { return }
        guard let url = sheet.web.url else { return }
        browser?.agent.saw(url, title: label ?? sheet.title)
        publishPages()
    }

    private func publishPages() {
        let current = pages.filter { $0.owner == AgentTools.graff && !$0.reading }.compactMap { sheet -> OpenPage? in
            guard let url = sheet.web.url else { return nil }
            return OpenPage(id: sheet.id, title: sheet.title, url: url, loading: sheet.web.isLoading)
        }
        if openPages != current { openPages = current }
    }

    /// A deliberate UI action opens a copy, using the browser's sign-ins.
    /// Metadata updates never select a tab or move keyboard focus.
    func inspectPage(_ id: String) {
        guard let browser, let page = openPages.first(where: { $0.id == id }) else { return }
        browser.agentFull = false
        if let tab = browser.tabs.first(where: { $0.address == page.url }) {
            browser.select(tab)
        } else {
            browser.open(page.url, foreground: true, atEnd: true, agentGroup: "Agent")
        }
    }

    private func makeRoom() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        room = window
        return window
    }

    /// The page an action is for: one of the owner's own, a tab of the
    /// user's, or — named by neither — the owner's latest. A connected app
    /// reaches a tab of the user's only with act-user-tabs and the user's
    /// yes (Connect.allowTabs).
    private func on(_ arguments: [String: Any], _ browser: Browser, _ owner: String, _ caller: Connect.Caller?, _ act: (Target) async -> [String: Any]) async -> [String: Any] {
        let ref = (arguments["page"] as? String ?? "").lowercased()
        let mine = pages.filter { $0.owner == owner }
        if ref == "active" {
            guard let active = browser.active else { return AgentTools.failed("No active tab") }
            if let refused = await refusedTabs(caller) { return refused }
            return await act(TabTarget(tab: active))
        }
        // Codegraff pinned to a tab (Agent.pinned): named by neither, it's
        // that tab — graff's own, never a connected app's.
        if ref.isEmpty, caller == nil, let pinned = browser.agent.pinned, browser.tabs.contains(where: { $0 === pinned }) {
            return await act(TabTarget(tab: pinned))
        }
        if ref.isEmpty, let latest = mine.last { latest.lastUsed = Date(); return await act(latest) }
        if let sheet = mine.first(where: { $0.id == ref }) { sheet.lastUsed = Date(); return await act(sheet) }
        if let tab = tab(ref, browser) {
            if let refused = await refusedTabs(caller) { return refused }
            return await act(TabTarget(tab: tab))
        }
        return AgentTools.failed(ref.isEmpty ? "No page open yet — `open` one, or pass `page: \"active\"` for the user's frontmost tab" : "No page or tab “\(ref)” — see `tabs`")
    }

    /// Nil when the user's tabs are this caller's to use; otherwise the
    /// refusal a connected app gets as a 403.
    private func refusedTabs(_ caller: Connect.Caller?) async -> [String: Any]? {
        guard let caller else { return nil }
        guard caller.may(.userTabs) else {
            return [AgentTools.refusal: ["error": "out_of_scope", "tool": "the user's tabs", "scope": Connect.Scope.userTabs.rawValue]]
        }
        guard await Connect.shared.allowTabs(caller) else { return [AgentTools.refusal: ["error": "declined"]] }
        return nil
    }

    private func tab(_ ref: String, _ browser: Browser) -> Tab? {
        guard !ref.isEmpty else { return nil }
        return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    private func address(_ value: Any?, _ browser: Browser) -> URL? {
        guard let typed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty else { return nil }
        return browser.destination(for: typed)
    }

    private func describe(_ sheet: Sheet) -> [String: Any] {
        ["page": sheet.id, "title": sheet.title, "url": sheet.address]
    }

    private static func short(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    /// A results page's own links — not the engine's menus and settings —
    /// with the words they carry.
    private static func results(excluding host: String) -> String {
        let engine = (try? JSONSerialization.data(withJSONObject: [host])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var engine = \(engine).split('.').slice(-2).join('.'), seen = {}, out = [];
          document.querySelectorAll('a[href^="http"]').forEach(function (a) {
            var host = a.hostname || '';
            if (!host || host.indexOf(engine) !== -1 || host.indexOf('google.') !== -1 || seen[a.href]) return;
            var words = (a.innerText || '').trim().replace(/\\s+/g, ' ');
            if (words.length < 12) return;
            seen[a.href] = 1;
            out.push(words.slice(0, 140) + ' — ' + a.href);
          });
          return out.slice(0, 20).join('\\n');
        })()
        """
    }

    private static let allLinks = """
    Array.from(document.querySelectorAll('a[href]')).slice(0, 300).map(function (a) {
      return ((a.innerText || a.title || '').trim().replace(/\\s+/g, ' ').slice(0, 120)) + ' — ' + a.href;
    }).join('\\n')
    """

    /// Shared by `form_fields` and `fill`: a field's words as a person reads
    /// them, and a selector that finds it and nothing else.
    private static let formKit = """
    function clean(t) { return String(t == null ? '' : t).replace(/\\s+/g, ' ').trim().slice(0, 140); }
    function esc(v) { return window.CSS && CSS.escape ? CSS.escape(v) : String(v).replace(/["\\\\]/g, '\\\\$&'); }
    function one(s) { try { return document.querySelectorAll(s).length === 1; } catch (e) { return false; } }
    function selector(el) {
      if (el.id && one('#' + esc(el.id))) return '#' + esc(el.id);
      var tag = el.tagName.toLowerCase();
      if (el.name) {
        var named = tag + '[name="' + esc(el.name) + '"]';
        if ((el.type === 'radio' || el.type === 'checkbox') && one(named + '[value="' + esc(el.value) + '"]')) return named + '[value="' + esc(el.value) + '"]';
        if (one(named)) return named;
      }
      var aria = el.getAttribute('aria-label');
      if (aria && one(tag + '[aria-label="' + esc(aria) + '"]')) return tag + '[aria-label="' + esc(aria) + '"]';
      var path = [], node = el;
      while (node && node.nodeType === 1 && node !== document.documentElement) {
        if (node.id && one('#' + esc(node.id))) { path.unshift('#' + esc(node.id)); break; }
        var i = 1, sib = node;
        while ((sib = sib.previousElementSibling)) if (sib.tagName === node.tagName) i++;
        path.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + i + ')');
        node = node.parentElement;
      }
      return path.join(' > ');
    }
    function label(el) {
      var words = [];
      if (el.labels) for (var i = 0; i < el.labels.length; i++) words.push(el.labels[i].innerText);
      var by = el.getAttribute('aria-labelledby');
      if (by) by.split(/\\s+/).forEach(function (id) { var n = document.getElementById(id); if (n) words.push(n.innerText); });
      if (el.getAttribute('aria-label')) words.push(el.getAttribute('aria-label'));
      if (!words.length && el.placeholder) words.push(el.placeholder);
      if (!words.length && el.title) words.push(el.title);
      if (!words.length) {
        var box = el.parentElement;
        for (var up = 0; box && up < 3 && !clean(box.innerText); up++) box = box.parentElement;
        if (box) words.push(box.innerText);
      }
      return clean(words.join(' '));
    }
    """

    /// Every field on the page a person could fill in, grouped by form,
    /// radios gathered into their groups, as lines graff reads easily.
    private static let fields = """
    (function () {
      \(formKit)
      function shown(el) {
        if (el.type === 'hidden' || el.disabled) return false;
        var s = getComputedStyle(el);
        if (s.display === 'none' || s.visibility === 'hidden') return false;
        // A styled checkbox is often the label drawn over a hidden input.
        if ((el.type === 'checkbox' || el.type === 'radio') && el.labels && el.labels.length) return true;
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      }
      var lines = [], groups = {}, count = 0, forms = [];
      var all = document.querySelectorAll('input, select, textarea, [contenteditable="true"], [contenteditable=""], [role="checkbox"], [role="switch"]');
      for (var i = 0; i < all.length && count < 160; i++) {
        var el = all[i], type = (el.type || el.getAttribute('role') || (el.isContentEditable ? 'editable' : el.tagName)).toLowerCase();
        if (['submit', 'button', 'reset', 'image', 'file'].indexOf(type) !== -1 || !shown(el)) continue;
        var form = el.form || el.closest('form'), at = form ? forms.indexOf(form) : -1;
        if (form && at === -1) { forms.push(form); at = forms.length - 1; }
        var where = form ? 'form ' + (at + 1) : 'page';
        if (type === 'radio' && el.name) {
          var key = where + '|' + el.name;
          if (!groups[key]) {
            groups[key] = { line: lines.length, choices: [], picked: '' };
            var set = el.closest('fieldset'), legend = set && set.querySelector('legend');
            lines.push({ where: where, text: '' , head: '- radio group "' + el.name + '" — ' + clean(legend ? legend.innerText : label(el)) + (el.required ? ' (required)' : '') });
            count++;
          }
          var g = groups[key];
          g.choices.push('    · ' + clean(label(el)) + ' → ' + selector(el) + (el.checked ? '  [chosen]' : ''));
          continue;
        }
        var line = '- ' + type + ' "' + label(el) + '"' + (el.required || el.getAttribute('aria-required') === 'true' ? ' (required)' : '');
        if (el.autocomplete && el.autocomplete !== 'on' && el.autocomplete !== 'off') line += ' autocomplete=' + el.autocomplete;
        line += ' → ' + selector(el);
        if (type === 'checkbox' || type === 'switch') {
          line += (el.checked || el.getAttribute('aria-checked') === 'true') ? '  [checked]' : '  [unchecked]';
        } else if (el.tagName === 'SELECT') {
          var options = [];
          for (var o = 0; o < el.options.length && o < 60; o++) {
            var opt = el.options[o];
            options.push((opt.selected ? '*' : '') + clean(opt.text) + (opt.value && opt.value !== opt.text ? ' (' + clean(opt.value) + ')' : ''));
          }
          line += '\\n    options: ' + options.join(' | ') + (el.options.length > 60 ? ' | …' : '');
        } else {
          var value = el.isContentEditable ? el.innerText : el.value;
          if (value) line += '  = "' + clean(el.type === 'password' ? '••••' : value) + '"';
          if (el.getAttribute('role') === 'combobox' || el.getAttribute('aria-autocomplete')) line += '  (suggests as you type — click a suggestion after filling)';
        }
        lines.push({ where: where, text: line });
        count++;
      }
      Object.keys(groups).forEach(function (key) {
        var g = groups[key];
        lines[g.line].text = lines[g.line].head + '\\n' + g.choices.join('\\n');
      });
      var out = [], last = '';
      lines.forEach(function (l) {
        if (l.where !== last) { out.push('', l.where === 'page' ? 'Outside any form:' : 'Form ' + l.where.slice(5) + ':'); last = l.where; }
        out.push(l.text);
      });
      var buttons = [];
      document.querySelectorAll('button, input[type=submit], input[type=button], [role=button]').forEach(function (b) {
        if (buttons.length >= 30 || !shown(b)) return;
        var words = clean(b.innerText || b.value || b.getAttribute('aria-label'));
        var submits = b.type === 'submit' || (b.tagName === 'BUTTON' && !b.getAttribute('type') && b.form);
        if (words && (submits || b.form || b.closest('form'))) buttons.push('- "' + words + '"' + (submits ? ' (submits)' : '') + ' → ' + selector(b));
      });
      if (buttons.length) out.push('', 'Buttons:', buttons.join('\\n'));
      var frames = document.querySelectorAll('iframe').length;
      if (frames) out.push('', frames + ' frame(s) on the page are not looked into; a card number field is often in one, and is for the user to fill.');
      return out.length ? out.join('\\n').trim() : 'No fields to fill on this page.';
    })()
    """

    /// The script that fills in fields as a person would: focused, typed
    /// through the editor so the page's own scripts hear real input, and
    /// read back after. Nil if the values can't be written as JSON.
    private static func fill(_ wanted: [[String: Any]], passwords: Bool = true) -> String? {
        let items = wanted.map { item -> [String: Any] in
            ["selector": item["selector"] as? String ?? "", "value": item["value"] ?? ""]
        }
        guard JSONSerialization.isValidJSONObject(items),
              let data = try? JSONSerialization.data(withJSONObject: items, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return """
        (function () {
          \(formKit)
          function fire(el, names) { names.forEach(function (n) { el.dispatchEvent(new Event(n, { bubbles: true })); }); }
          function yes(v) { return v === true || /^(true|yes|on|1|checked|x)$/i.test(String(v).trim()); }
          function same(a, b) { return clean(a).toLowerCase() === clean(b).toLowerCase(); }
          function set(el, value) {
            var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
            var d = Object.getOwnPropertyDescriptor(proto, 'value');
            if (d && d.set) d.set.call(el, value); else el.value = value;
          }
          function type(el, text) {
            el.focus();
            if (el.select) el.select();
            var typed = false;
            try { typed = document.execCommand('insertText', false, text); } catch (e) {}
            if (!typed || el.value !== text) { set(el, text); fire(el, ['input']); }
            fire(el, ['change']);
          }
          var out = [];
          // One field at a time, each on its own: a value a field can't take
          // is said about that field, and the rest are still filled.
          \(json).forEach(function (item) {
            try { fillOne(item); } catch (e) { out.push((item.selector || '?') + ': ' + (e && e.message ? e.message : 'could not be filled')); }
          });
          function fillOne(item) {
            var el = null;
            try { el = document.querySelector(item.selector); } catch (e) { out.push(item.selector + ': not a selector'); return; }
            if (!el) { out.push(item.selector + ': nothing matches'); return; }
            if (!\(passwords) && (el.type === 'password' || /password/i.test(el.autocomplete || ''))) { out.push((label(el) || item.selector) + ': a password field — that is for the user to fill'); return; }
            if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
            var v = item.value, kind = (el.type || el.getAttribute('role') || '').toLowerCase(), name = label(el) || item.selector;
            // A list for a group of checkboxes: those named are ticked, the
            // rest of the group left clear.
            if (Array.isArray(v) && kind === 'checkbox' && el.name) {
              var boxes = document.querySelectorAll('input[type=checkbox][name="' + esc(el.name) + '"]'), ticked = [];
              for (var b = 0; b < boxes.length; b++) {
                var box = boxes[b], want = v.some(function (w) { return same(box.value, w) || same(label(box), w); });
                if (box.checked !== want) box.click();
                if (box.checked !== want) { box.checked = want; fire(box, ['input', 'change']); }
                if (box.checked) ticked.push(clean(label(box)));
              }
              // Not `set`: a var is the whole function's, and would hide the
              // set() every select and text field needs.
              var fieldset = el.closest('fieldset'), legend = fieldset && fieldset.querySelector('legend');
              out.push(clean(legend ? legend.innerText : el.name) + ' → ' + (ticked.length ? ticked.join(', ') : 'none ticked'));
              return;
            }
            if (Array.isArray(v)) v = v.join(', ');
            if (el.tagName === 'SELECT') {
              var hit = null, want = String(v);
              for (var i = 0; i < el.options.length && !hit; i++) if (same(el.options[i].value, want) || same(el.options[i].text, want)) hit = el.options[i];
              for (var j = 0; j < el.options.length && !hit; j++) if (clean(el.options[j].text).toLowerCase().indexOf(clean(want).toLowerCase()) !== -1) hit = el.options[j];
              if (!hit) { out.push(name + ': no option "' + want + '"'); return; }
              el.focus(); set(el, hit.value); fire(el, ['input', 'change']);
              out.push(name + ' → ' + clean(hit.text));
            } else if (kind === 'radio') {
              var group = el.name ? document.querySelectorAll('input[type=radio][name="' + esc(el.name) + '"]') : [el], pick = null;
              for (var r = 0; r < group.length && !pick; r++) if (same(group[r].value, v) || same(label(group[r]), v)) pick = group[r];
              if (!pick && yes(v)) pick = el;
              if (!pick) { out.push(name + ': no choice "' + v + '"'); return; }
              if (!pick.checked) pick.click();
              if (!pick.checked) { pick.checked = true; fire(pick, ['input', 'change']); }
              out.push(clean(label(pick)) + ' → chosen');
            } else if (kind === 'checkbox' || kind === 'switch') {
              var on = yes(v), now = function () { return el.checked !== undefined && el.type === 'checkbox' ? el.checked : el.getAttribute('aria-checked') === 'true'; };
              if (now() !== on) el.click();
              if (el.type === 'checkbox' && el.checked !== on) { el.checked = on; fire(el, ['input', 'change']); }
              out.push(name + ' → ' + (now() ? 'checked' : 'unchecked'));
            } else if (el.isContentEditable) {
              el.focus();
              document.execCommand('selectAll', false, null);
              if (!document.execCommand('insertText', false, String(v))) { el.textContent = String(v); fire(el, ['input']); }
              out.push(name + ' → "' + clean(el.innerText) + '"');
            } else if ('value' in el) {
              type(el, String(v));
              var held = el.type === 'password' ? (el.value ? '••••' : '') : el.value;
              out.push(name + ' → "' + clean(held) + '"' + (el.type !== 'password' && el.value !== String(v) ? '  (the page changed it)' : ''));
            } else {
              out.push(name + ': not something to fill');
            }
          }
          if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
          return out.join('\\n');
        })()
        """
    }

    /// What a page shows, as a JPEG small enough to go back in one answer.
    private static func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    private static func snapshotScript(root: String?, limit: Int) -> String {
        let rootJS = root.map { jsonLiteral($0) } ?? "null"
        return """
        (function () {
          \(formKit)
          var rootSel = \(rootJS);
          var root = rootSel ? document.querySelector(rootSel) : document.body;
          if (!root) return 'Root element not found: ' + rootSel;
          var sel = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[contenteditable],[role],h1,h2,h3,h4';
          function isSecret(el) {
            if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return false;
            var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
            var hint = [el.name, el.id, el.getAttribute('aria-label'), el.placeholder, label(el)].join(' ');
            return (el.type || '').toLowerCase() === 'password'
              || /(^|\\s)(cc-|one-time-code|current-password|new-password)/.test(ac)
              || /pass|pwd|otp|2fa|totp|cvc|cvv|card.?num|cc.?num/i.test(hint);
          }
          function roleOf(el) {
            var r = (el.getAttribute('role') || '').trim().split(/\\s+/)[0];
            if (r && r !== 'none' && r !== 'presentation') return r;
            var t = el.tagName.toLowerCase();
            if (t === 'a') return 'link';
            if (t === 'button' || t === 'summary') return 'button';
            if (t === 'select') return 'combobox';
            if (t === 'textarea') return 'textbox';
            if (/^h[1-4]$/.test(t)) return 'heading';
            if (t === 'input') {
              var k = (el.type || 'text').toLowerCase();
              return { checkbox: 'checkbox', radio: 'radio', range: 'slider', search: 'searchbox',
                submit: 'button', button: 'button', reset: 'button' }[k] || 'textbox';
            }
            return el.isContentEditable ? 'textbox' : 'generic';
          }
          function shown(el) {
            var s = getComputedStyle(el);
            if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var out = [], seen = new Set(), nodes = root.querySelectorAll(sel);
          for (var i = 0; i < nodes.length && out.length < \(limit); i++) {
            var el = nodes[i];
            if (!shown(el)) continue;
            var r = roleOf(el);
            if (r === 'generic') continue;
            var nm = clean(el.getAttribute('aria-label') || label(el) || el.innerText || el.value || el.title || '');
            if (!nm && (r === 'link' || r === 'button' || r === 'heading')) continue;
            var css = selector(el);
            if (seen.has(css)) continue;
            seen.add(css);
            var parts = ['[' + r + ']'];
            if (nm) parts.push('"' + nm.slice(0, 90) + '"');
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
              if (el.type === 'checkbox' || el.type === 'radio') {
                parts.push(el.checked ? '(checked)' : '(unchecked)');
              } else if (isSecret(el)) {
                parts.push('(value: [secret])');
              } else if (el.value) {
                parts.push('(value: "' + clean(el.value).slice(0, 60) + '")');
              }
            }
            if (el.disabled) parts.push('(disabled)');
            if (el.getAttribute('aria-expanded') === 'true') parts.push('(expanded)');
            if (el.getAttribute('aria-selected') === 'true') parts.push('(selected)');
            if (el.tagName === 'A' && el.href) parts.push('<' + el.href.slice(0, 100) + '>');
            parts.push('-> ' + css);
            out.push(parts.join(' '));
          }
          return out.length ? out.join('\\n') : 'No visible interactive elements found.';
        })()
        """
    }

    private static func scrollScript(direction: String?, amount: Int, selector: String?) -> String {
        let dirJS = direction.map { jsonLiteral($0.lowercased()) } ?? "null"
        let selJS = selector.map { jsonLiteral($0) } ?? "null"
        return """
        (function () {
          var dir = \(dirJS), amt = \(amount), sel = \(selJS);
          var el = sel ? document.querySelector(sel) : null;
          if (sel && !el) return { error: 'Element not found: ' + sel };
          if (el && !dir) {
            el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
            var r = el.getBoundingClientRect();
            return { scrolledIntoView: sel, x: Math.round(r.left), y: Math.round(r.top) };
          }
          dir = dir || 'down';
          var target = el || window;
          if (el) {
            if (dir === 'top') el.scrollTop = 0;
            else if (dir === 'bottom') el.scrollTop = el.scrollHeight;
            else if (dir === 'down') el.scrollBy(0, amt);
            else if (dir === 'up') el.scrollBy(0, -amt);
            else if (dir === 'right') el.scrollBy(amt, 0);
            else if (dir === 'left') el.scrollBy(-amt, 0);
            return { scrollY: Math.round(el.scrollTop), scrollHeight: Math.round(el.scrollHeight), viewportHeight: Math.round(el.clientHeight) };
          }
          if (dir === 'top') target.scrollTo(0, 0);
          else if (dir === 'bottom') target.scrollTo(0, document.documentElement.scrollHeight);
          else if (dir === 'down') target.scrollBy(0, amt);
          else if (dir === 'up') target.scrollBy(0, -amt);
          else if (dir === 'right') target.scrollBy(amt, 0);
          else if (dir === 'left') target.scrollBy(-amt, 0);
          return { scrollY: Math.round(window.scrollY), scrollHeight: Math.round(document.documentElement.scrollHeight), viewportHeight: Math.round(window.innerHeight) };
        })()
        """
    }

    private static func pressKeyScript(key: String, selector: String?, modifiers: [String]) -> String {
        let keyJS = jsonLiteral(key)
        let selJS = selector.map { jsonLiteral($0) } ?? "null"
        let modsJS = jsonLiteral(modifiers.map { $0.lowercased() })
        return """
        (function () {
          var k = \(keyJS), sel = \(selJS), mods = \(modsJS);
          var el = sel ? document.querySelector(sel) : (document.activeElement || document.body);
          if (sel && !el) return 'Element not found: ' + sel;
          if (sel && el.focus) el.focus();
          if (k === 'Space') k = ' ';
          var opts = {
            key: k, code: k === ' ' ? 'Space' : k, bubbles: true, cancelable: true,
            shiftKey: mods.indexOf('shift') >= 0, altKey: mods.indexOf('alt') >= 0,
            ctrlKey: mods.indexOf('ctrl') >= 0, metaKey: mods.indexOf('meta') >= 0
          };
          var downOk = el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keypress', opts));
          if (downOk && k === 'Enter') {
            if (el.tagName === 'BUTTON' || el.tagName === 'A' || el.getAttribute('role') === 'button') el.click();
            else if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
          }
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
          return 'ok';
        })()
        """
    }

    private static func hoverScript(selector: String) -> String {
        let selJS = jsonLiteral(selector)
        return """
        (function () {
          var el = document.querySelector(\(selJS));
          if (!el) return 'Element not found: ' + \(selJS);
          el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
          var r = el.getBoundingClientRect();
          var opts = { bubbles: true, cancelable: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
          el.dispatchEvent(new PointerEvent('pointerover', opts));
          el.dispatchEvent(new PointerEvent('pointerenter', Object.assign({}, opts, { bubbles: false })));
          el.dispatchEvent(new MouseEvent('mouseover', opts));
          el.dispatchEvent(new MouseEvent('mouseenter', Object.assign({}, opts, { bubbles: false })));
          el.dispatchEvent(new MouseEvent('mousemove', opts));
          return 'ok';
        })()
        """
    }

    private static func clickAtScript(x: Double, y: Double, button: String) -> String {
        let btnCode = button == "right" ? 2 : (button == "middle" ? 1 : 0)
        return """
        (function () {
          var x = \(x), y = \(y), btn = \(btnCode);
          var el = document.elementFromPoint(x, y);
          if (!el) return { error: 'No element at (' + x + ', ' + y + ')' };
          var opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: btn, buttons: btn === 2 ? 2 : (btn === 1 ? 4 : 1) };
          el.dispatchEvent(new PointerEvent('pointerdown', opts));
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          if (el.focus) try { el.focus(); } catch (e) {}
          el.dispatchEvent(new PointerEvent('pointerup', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          if (btn === 2) {
            el.dispatchEvent(new MouseEvent('contextmenu', opts));
          } else {
            el.dispatchEvent(new MouseEvent('click', opts));
          }
          return {
            clicked: el.tagName.toLowerCase(),
            id: el.id || '',
            text: (el.innerText || el.getAttribute('aria-label') || '').trim().slice(0, 80),
            x: x, y: y
          };
        })()
        """
    }

    private static let pageInfoScript = """
    (function () {
      var doc = document.documentElement, body = document.body;
      var active = document.activeElement;
      return {
        scrollX: Math.round(window.scrollX),
        scrollY: Math.round(window.scrollY),
        scrollWidth: Math.round(Math.max(doc ? doc.scrollWidth : 0, body ? body.scrollWidth : 0)),
        scrollHeight: Math.round(Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0)),
        viewportWidth: Math.round(window.innerWidth),
        viewportHeight: Math.round(window.innerHeight),
        readyState: document.readyState,
        activeElement: active ? {
          tag: active.tagName.toLowerCase(),
          id: active.id || '',
          role: active.getAttribute('role') || ''
        } : null
      };
    })()
    """

    static let markdownScript = """
    (function () {
      var root = document.querySelector('main, article, [role="main"]') || document.body;
      if (!root) return '';
      var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, SVG: 1, TEMPLATE: 1, IFRAME: 1 };
      function clean(s) { return (s || '').replace(/\\s+/g, ' ').trim(); }
      function walk(node, depth) {
        if (!node) return '';
        if (node.nodeType === 3) return node.nodeValue.replace(/\\s+/g, ' ');
        if (node.nodeType !== 1 || skip[node.tagName]) return '';
        var s = getComputedStyle(node);
        if (s.display === 'none' || s.visibility === 'hidden') return '';
        var tag = node.tagName;
        if (tag === 'PRE') {
          var code = (node.innerText || '').trim();
          return code ? '\\n\\n```\\n' + code + '\\n```\\n\\n' : '';
        }
        if (tag === 'CODE' && node.parentElement && node.parentElement.tagName !== 'PRE') {
          var c = clean(node.textContent);
          return c ? '`' + c + '`' : '';
        }
        if (tag === 'A') {
          var txt = clean(node.innerText);
          var href = node.href || '';
          return txt && href && !href.startsWith('javascript:') ? '[' + txt + '](' + href + ')' : txt;
        }
        var kids = '';
        for (var i = 0; i < node.childNodes.length; i++) kids += walk(node.childNodes[i], depth + (tag === 'UL' || tag === 'OL' ? 1 : 0));
        if (/^H[1-6]$/.test(tag)) {
          var h = clean(kids);
          return h ? '\\n\\n' + '#'.repeat(parseInt(tag[1], 10)) + ' ' + h + '\\n\\n' : '';
        }
        if (tag === 'LI') {
          var li = clean(kids);
          return li ? '\\n' + '  '.repeat(Math.max(0, depth - 1)) + '- ' + li : '';
        }
        if (tag === 'BLOCKQUOTE') {
          var bq = clean(kids);
          return bq ? '\\n\\n> ' + bq + '\\n\\n' : '';
        }
        if (tag === 'P' || tag === 'DIV' || tag === 'SECTION' || tag === 'ARTICLE' || tag === 'TR') {
          var block = kids.trim();
          return block ? '\\n\\n' + block + '\\n\\n' : '';
        }
        if (tag === 'BR') return '\\n';
        return kids;
      }
      return walk(root, 0).replace(/\\n{3,}/g, '\\n\\n').trim();
    })()
    """

    private static func waitCheckScript(selector: String?, text: String?) -> String {
        let selJS = selector.map { jsonLiteral($0) } ?? "null"
        let textJS = text.map { jsonLiteral($0) } ?? "null"
        return """
        (function () {
          var sel = \(selJS), txt = \(textJS);
          if (sel) {
            var el = document.querySelector(sel);
            if (!el) return false;
            var s = getComputedStyle(el), r = el.getBoundingClientRect();
            if (s.display === 'none' || s.visibility === 'hidden' || r.width === 0 || r.height === 0) return false;
            if (txt) return (el.innerText || el.textContent || '').indexOf(txt) >= 0;
            return true;
          }
          return txt ? ((document.body && document.body.innerText) || '').indexOf(txt) >= 0 : false;
        })()
        """
    }

    private static func elementRectScript(selector: String) -> String {
        let selJS = jsonLiteral(selector)
        return """
        (function () {
          var el = document.querySelector(\(selJS));
          if (!el) return null;
          el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
          var r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) return null;
          return { x: Math.max(0, r.left), y: Math.max(0, r.top), w: r.width, h: r.height };
        })()
        """
    }

    private static func maskSecretsScript(mask: Bool) -> String {
        mask ? """
        (function () {
          var all = document.querySelectorAll('input, textarea');
          for (var i = 0; i < all.length; i++) {
            var el = all[i], ac = (el.getAttribute('autocomplete') || '').toLowerCase();
            var hint = [el.name, el.id, el.getAttribute('aria-label'), el.placeholder].join(' ');
            var secret = (el.type || '').toLowerCase() === 'password'
              || /(^|\\s)(cc-|one-time-code|current-password|new-password)/.test(ac)
              || /pass|pwd|otp|2fa|totp|cvc|cvv|card.?num|cc.?num/i.test(hint);
            if (secret) {
              el.dataset.__browseMask = el.style.filter || '';
              el.style.filter = 'brightness(0)';
            }
          }
        })()
        """ : """
        (function () {
          document.querySelectorAll('[data-__browse-mask]').forEach(function (el) {
            el.style.filter = el.dataset.__browseMask || '';
            delete el.dataset.__browseMask;
          });
        })()
        """
    }

    private static func picture(_ web: WKWebView, rect: CGRect? = nil, wantPNG: Bool = false) async -> (Data, String, Data?)? {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let rect {
            shot.rect = rect
            shot.snapshotWidth = NSNumber(value: min(1440, max(1, rect.width)))
        } else {
            shot.snapshotWidth = NSNumber(value: min(1280, max(1, web.bounds.width)))
        }
        let image: NSImage? = await withCheckedContinuation { done in
            web.takeSnapshot(with: shot) { image, _ in done.resume(returning: image) }
        }
        let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
        return await encodeCGImage(cg, wantPNG: wantPNG, maxBytes: largest)
    }

    private static func windowPicture(_ window: NSWindow, wantPNG: Bool = false) async -> (Data, String, Data?)? {
        guard let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return await encodeCGImage(rep.cgImage, wantPNG: wantPNG, maxBytes: largest)
    }

    nonisolated private static func encodeCGImage(_ cg: CGImage?, wantPNG: Bool, maxBytes: Int) async -> (Data, String, Data?)? {
        guard let cg else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let png = wantPNG ? bitmap.representation(using: .png, properties: [:]) : nil
            for quality in [0.78, 0.58, 0.38] {
                if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   jpeg.count * 4 / 3 < maxBytes {
                    return (jpeg, "image/jpeg", png)
                }
            }
            let fallbackPNG = png ?? bitmap.representation(using: .png, properties: [:])
            if let fallbackPNG, fallbackPNG.count * 4 / 3 < maxBytes {
                return (fallbackPNG, "image/png", fallbackPNG)
            }
            return nil
        }.value
    }

    private static func imageReply(data: Data, mime: String, rawPNG: Data?, saveTo: String?) -> [String: Any] {
        var content: [[String: Any]] = [
            ["type": "image", "data": data.base64EncodedString(), "mimeType": mime],
        ]
        if let saveTo, !saveTo.isEmpty {
            let expanded = (saveTo as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let bytes = expanded.lowercased().hasSuffix(".png") ? (rawPNG ?? data) : data
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
                content.append(["type": "text", "text": "Saved screenshot to \(url.path) (\(bytes.count) bytes)"])
            } catch {
                content.append(["type": "text", "text": "Returned image, but could not save to \(url.path): \(error.localizedDescription)"])
            }
        }
        return ["content": content]
    }

    private static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    private static func text(_ string: String) -> [String: Any] {
        var cut = string
        if cut.utf8.count > largest { cut = String(cut.prefix(largest / 2)) + "\n…" }
        return ["content": [["type": "text", "text": cut]]]
    }

    private static func said(_ value: Any) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8)
        else { return text(String(describing: value)) }
        return text(string)
    }

    private static func failed(_ why: String) -> [String: Any] {
        ["content": [["type": "text", "text": why]], "isError": true]
    }
}

/// Something graff can act on: one of its own pages, or a tab of the user's.
@MainActor
private protocol Target {
    var id: String { get }
    var web: WKWebView { get }
    var title: String { get }
    var address: String { get }
    func go(_ url: URL)
    func settled() async
    func settledIfLoading() async
}

extension Target {
    func run(_ script: String) async -> (Any?, String?) {
        await withCheckedContinuation { done in
            web.evaluateJavaScript(script) { value, error in
                done.resume(returning: (value, error?.localizedDescription))
            }
        }
    }

    /// Until there is something to read: the page stopped loading — or its
    /// document is parsed, has words on it, and has stopped growing, which on
    /// a page still pulling in its ads and trackers is long before it stops.
    /// Then a beat for its own scripts. Fifteen seconds at most. Waiting for
    /// the last tracker cost a read 15 s on a page whose text was there in
    /// two (25 Sep 2026); stopping at the first words read a tenth short on
    /// pages that fill in their stories just after, and so did stopping at
    /// the first pause, one look long, between two of them.
    func settled() async {
        await settled(initialWaitNs: 250_000_000, tailWaitNs: 300_000_000)
    }

    func settledIfLoading() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard web.isLoading else { return }
        await settled(initialWaitNs: 100_000_000, tailWaitNs: 200_000_000)
    }

    private func settled(initialWaitNs: UInt64, tailWaitNs: UInt64) async {
        let limit = Date().addingTimeInterval(15)
        try? await Task.sleep(nanoseconds: initialWaitNs)
        var last = -1
        var still = 0
        while web.isLoading, Date() < limit {
            let (state, _) = await run("document.readyState + '|' + (document.body ? document.body.textContent.length : 0)")
            let parts = (state as? String)?.split(separator: "|") ?? []
            let length = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            still = length == last ? still + 1 : 0
            if parts.count == 2, parts[0] != "loading", length > 400, still >= 2 { break }
            last = length
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: tailWaitNs)
    }
}

/// One of graff's pages: a web view of its own, in the room off screen, with
/// the user's sign-ins, as any page in the browser has.
@MainActor
private final class Sheet: Target {
    let id: String
    /// Whose it is: graff, a connected app, or one session of one.
    let owner: String
    let web: WKWebView
    let reading: Bool
    var lastUsed = Date()
    var onChange: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private let passkeyRelay = PasskeyRelay()

    init(id: String, owner: String, in room: NSWindow, reading: Bool, bare: WKContentRuleList?) {
        self.id = id
        self.owner = owner
        self.reading = reading
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Store.websites
        config.applicationNameForUserAgent = Web.userAgentName
        // Nobody is watching or listening: a video on a page graff opened
        // plays when graff clicks it, not on its own.
        config.mediaTypesRequiringUserActionForPlayback = .all
        // The ad blocker, as a tab has it: a page still fetching its ads and
        // trackers is a page settled() is still waiting on.
        Shield.shared.protect(config.userContentController)
        if !reading {
            config.userContentController.addUserScript(
                WKUserScript(source: DevCapture.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
            )
            config.userContentController.addScriptMessageHandler(passkeyRelay, contentWorld: Web.world, name: PasskeyRelay.name)
            config.userContentController.addUserScript(
                WKUserScript(source: PasskeyRelay.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
            config.userContentController.addUserScript(
                WKUserScript(source: PasskeyRelay.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
            )
        }
        if let bare { config.userContentController.add(bare) }
        web = WKWebView(frame: room.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        web.autoresizingMask = [.width, .height]
        room.contentView?.addSubview(web)
        if !reading {
            observations = [
                web.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } },
                web.observe(\.title, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } },
                web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } },
            ]
        }
    }

    var title: String { web.title?.isEmpty == false ? web.title ?? "" : (web.url?.host() ?? id) }
    var address: String { web.url?.absoluteString ?? "" }

    /// On or off for where it is going: off for a site it is paused on, and
    /// off everywhere once it is switched off in Settings.
    func go(_ url: URL) {
        Passkeys.shared.forget(web)
        Shield.shared.tune(web.configuration.userContentController, for: url.host())
        web.load(URLRequest(url: url))
    }

    func drop() {
        Passkeys.shared.forget(web)
        onChange = nil
        observations.forEach { $0.invalidate() }
        observations = []
        web.configuration.userContentController.removeScriptMessageHandler(forName: PasskeyRelay.name, contentWorld: Web.world)
        web.stopLoading()
        web.removeFromSuperview()
    }
}

/// A tab of the user's, when graff is asked about one.
@MainActor
private struct TabTarget: Target {
    let tab: Tab
    var id: String { String(tab.id.uuidString.prefix(8)).lowercased() }
    var web: WKWebView { tab.web }
    var title: String { tab.label }
    var address: String { tab.address?.absoluteString ?? "" }
    func go(_ url: URL) { tab.go(to: url) }
}

/// An HTTP/1.1 request, once all of it has arrived: its method, the path it
/// asked for, headers by lower-case name, and body.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard let method = first.first, first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        self.method = String(method)
        self.path = String(first[1])
        self.headers = headers
        self.body = Data(body.prefix(length))
    }

    static func reply(_ status: Int, _ body: Data?, headers: [String: String] = [:]) -> Data {
        let words = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(words)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }
}
