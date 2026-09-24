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
final class AgentTools {
    static let shared = AgentTools()

    weak var browser: Browser?

    private var listener: NWListener?
    private var port: UInt16?
    private let token = UUID().uuidString + UUID().uuidString
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private let queue = DispatchQueue(label: "search.agent.tools")

    /// graff's own pages, out of sight, oldest first.
    private var pages: [Sheet] = []
    private var made = 0
    /// Off every screen: a page wants a window to be drawn and to run at
    /// full speed, and this is it.
    private var room: NSWindow?

    /// graff's cap on one answer is a MiB; kept clear of it.
    private static let largest = 900_000
    /// Pages kept at once. The oldest goes when another is wanted. Each is a
    /// WebKit process of its own, tens of MB; pages only read close as soon
    /// as they are read, so these are the ones graff is acting on.
    private static let most = 6

    // MARK: - the server

    /// Listening, and the file that tells graff where, written. False if the
    /// port couldn't be had — graff then runs with its own tools only.
    func start() async -> Bool {
        if port != nil { return true }
        if listener == nil { listen() }
        return await withCheckedContinuation { waiting.append($0) }
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
            Task { @MainActor in self?.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.settle(self.announce())
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

    /// The .mcp.json in graff's folder: this server, under the name graff
    /// will show its tools by. The same goes in `own`, which graff reads
    /// instead of the user's own MCP config when it runs lean (see
    /// Agent.environment): then these are the only tools it adds to its own.
    private func announce() -> Bool {
        guard let port else { return false }
        let config: [String: Any] = [
            "mcpServers": [
                "search": [
                    "url": "http://127.0.0.1:\(port)/mcp",
                    "headers": ["Authorization": "Bearer \(token)"],
                ],
            ],
        ]
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
    private func serve(_ connection: NWConnection) {
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
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return HTTPRequest.reply(401, nil)
        }
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return HTTPRequest.reply(400, nil)
        }
        guard let reply = await rpc(message) else {
            return HTTPRequest.reply(202, nil)
        }
        let body = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPRequest.reply(200, body)
    }

    // MARK: - MCP

    /// One JSON-RPC message; nothing back for a notification.
    private func rpc(_ message: [String: Any]) async -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            reply["result"] = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "search", "title": "Search", "version": Updater.version],
                "instructions": AgentTools.instructions,
            ]
        case "ping":
            reply["result"] = [String: Any]()
        case "tools/list":
            reply["result"] = ["tools": AgentTools.tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            reply["result"] = await call(name, arguments)
        default:
            // `server/discover` among them: graff asks it first, and an
            // error here is what tells it this is the simpler, older kind
            // of server.
            reply["error"] = ["code": -32601, "message": "Method not found: \(method)"]
        }
        return reply
    }

    static let instructions = """
    These tools are a web browser — Search, the one the user is looking at. They work in \
    pages of their own, out of the user's sight; each page read is listed for the user, who \
    can open it. For research, `search` first, then `read_pages` with every promising link at \
    once — it loads them in parallel — rather than one page at a time. Pages read that way \
    are closed once read; `open` one to keep it. `open` a page to act on \
    it (click, type, submit, run_js, screenshot). For a form, `form_fields` then one `fill` with \
    every field, then check what it says each holds. `tabs` lists the user's own tabs too; one \
    of theirs can be read or acted on by its id. `show` puts a page in front of the user as a tab.
    """

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    private static let page: [String: Any] = ["type": "string", "description": "A page's id: one of yours (p1, p2…) or a tab of the user's from `tabs`. Leave out for your latest page."]

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
                        "value": ["description": "Text; an option's value or words; true or false for a checkbox."],
                    ],
                    "required": ["selector", "value"],
                ],
            ],
            "page": page,
        ], required: ["fields"]),
        tool("run_js", "Run JavaScript in a page and return its value.", [
            "script": ["type": "string", "description": "An expression, or a function called at once."],
            "page": page,
        ], required: ["script"]),
        tool("screenshot", "A picture of a page as it looks.", ["page": page]),
        tool("tabs", "Your pages and the user's own tabs: id, title, address, and which tab they have in front."),
        tool("show", "Put a page in front of the user as a tab of theirs, or bring one of their tabs to the front.", ["page": page], required: ["page"]),
        tool("close", "Close one of your pages, or a tab of the user's.", ["page": page], required: ["page"]),
    ]

    // MARK: - the tools

    private func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        guard let browser else { return AgentTools.failed("Search has no window") }
        switch name {
        case "search":
            guard let query = arguments["query"] as? String, let url = browser.searchURL(for: query) else {
                return AgentTools.failed("search needs a query")
            }
            let sheet = await load(url, as: "Search: \(query)")
            let (text, error) = await sheet.run("document.body ? document.body.innerText : ''")
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
            // All at once: the main thread only starts each load and reads
            // each page once it is there; the loading itself is WebKit's, in
            // processes of its own.
            let read = await withTaskGroup(of: (Int, String).self) { group in
                for (index, url) in chosen.enumerated() {
                    group.addTask { @MainActor in
                        let sheet = await self.load(url, as: nil)
                        let (text, error) = await sheet.run("document.body ? document.body.innerText : ''")
                        let body = error.map { "(couldn't read it: \($0))" } ?? AgentTools.cut(text as? String ?? "", each)
                        let said = "## \(sheet.title)\n\(sheet.address)\n\n\(body)"
                        // Read, so closed; `open` is for a page to act on.
                        self.close(sheet)
                        return (index, said)
                    }
                }
                var all: [(Int, String)] = []
                for await one in group { all.append(one) }
                return all.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return AgentTools.text(read.joined(separator: "\n\n"))

        case "open":
            guard let url = address(arguments["url"], browser) else { return AgentTools.failed("open needs a url") }
            let sheet = await load(url, as: nil)
            return AgentTools.said(describe(sheet))

        case "read":
            return await on(arguments, browser) { target in
                let (text, error) = await target.run("document.body ? document.body.innerText : ''")
                if let error { return AgentTools.failed(error) }
                let body = AgentTools.cut(text as? String ?? "", arguments["limit"] as? Int ?? 60_000)
                return AgentTools.text("\(target.title)\n\(target.address)\n\n\(body)")
            }

        case "links":
            return await on(arguments, browser) { target in
                let (value, error) = await target.run(AgentTools.allLinks)
                if let error { return AgentTools.failed(error) }
                return AgentTools.text(value as? String ?? "")
            }

        case "go":
            guard let url = address(arguments["url"], browser) else { return AgentTools.failed("go needs a url") }
            return await on(arguments, browser) { target in
                target.go(url)
                await target.settled()
                self.seen(target)
                return AgentTools.said(["page": target.id, "title": target.title, "url": target.address])
            }

        case "back", "forward", "reload":
            return await on(arguments, browser) { target in
                switch name {
                case "back": target.web.goBack()
                case "forward": target.web.goForward()
                default: target.web.reload()
                }
                await target.settled()
                return AgentTools.said(["page": target.id, "title": target.title, "url": target.address])
            }

        case "form_fields":
            return await on(arguments, browser) { target in
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
            guard let script = AgentTools.fill(wanted) else { return AgentTools.failed("Those values can't be sent to the page") }
            return await on(arguments, browser) { target in
                let (value, error) = await target.run(script)
                if let error { return AgentTools.failed(error) }
                // A field's own scripts — a search as you type, a form that
                // grows another field — have a moment to answer.
                try? await Task.sleep(nanoseconds: 250_000_000)
                return AgentTools.text("\(target.id) · \(target.title)\n\n" + (value as? String ?? ""))
            }

        case "click", "submit":
            guard let selector = arguments["selector"] as? String else { return AgentTools.failed("\(name) needs a selector") }
            return await on(arguments, browser) { target in
                let (value, error) = await target.run(Bench.act(name, selector: selector, text: arguments["text"] as? String ?? ""))
                if let error { return AgentTools.failed(error) }
                guard value as? String == "ok" else { return AgentTools.failed(value as? String ?? "didn't work") }
                // A click or a submit may have sent the page somewhere.
                try? await Task.sleep(nanoseconds: 400_000_000)
                await target.settled()
                return AgentTools.said(["page": target.id, "title": target.title, "url": target.address])
            }

        case "run_js":
            guard let script = arguments["script"] as? String else { return AgentTools.failed("run_js needs a script") }
            return await on(arguments, browser) { target in
                let (value, error) = await target.run(script)
                if let error { return AgentTools.failed(error) }
                let plain = Bench.plain(value)
                if let string = plain as? String { return AgentTools.text(string) }
                return AgentTools.said(plain)
            }

        case "screenshot":
            return await on(arguments, browser) { target in
                guard target.web.window != nil else {
                    return AgentTools.failed("That tab isn't drawn right now — `show` it first")
                }
                guard let jpeg = await AgentTools.picture(target.web) else { return AgentTools.failed("No picture") }
                return ["content": [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]]
            }

        case "tabs":
            let theirs = browser.tabs.filter { !$0.bench }.map { tab -> [String: Any] in
                [
                    "id": AgentTools.short(tab),
                    "title": tab.label,
                    "url": tab.address?.absoluteString ?? "",
                    "in front": tab.id == browser.activeID,
                ]
            }
            return AgentTools.said(["your pages": pages.map(describe), "the user's tabs": theirs])

        case "show":
            let ref = (arguments["page"] as? String ?? "").lowercased()
            if let sheet = pages.first(where: { $0.id == ref }) {
                guard let url = sheet.web.url else { return AgentTools.failed("\(ref) has no address yet") }
                let tab = browser.open(url, foreground: true, atEnd: true)
                return AgentTools.said(["tab": AgentTools.short(tab), "url": url.absoluteString])
            }
            guard let tab = tab(ref, browser) else { return AgentTools.failed("No page or tab “\(ref)” — see `tabs`") }
            browser.select(tab)
            return AgentTools.said(["tab": AgentTools.short(tab), "in front": true])

        case "close":
            let ref = (arguments["page"] as? String ?? "").lowercased()
            if let index = pages.firstIndex(where: { $0.id == ref }) {
                pages.remove(at: index).drop()
                return AgentTools.said(["closed": ref])
            }
            guard let tab = tab(ref, browser) else { return AgentTools.failed("No page or tab “\(ref)” — see `tabs`") }
            browser.close(tab)
            return AgentTools.said(["closed": ref])

        default:
            return AgentTools.failed("No tool named \(name)")
        }
    }

    // MARK: - graff's pages

    /// A page of graff's own, loaded and listed in its column.
    private func load(_ url: URL, as label: String?) async -> Sheet {
        let sheet = make()
        sheet.go(url)
        await sheet.settled()
        seen(sheet, as: label)
        return sheet
    }

    /// Every page graff has open, gone: it has stopped (Agent.rest), and a
    /// page kept for a graff that isn't there holds memory for no one. The
    /// off-screen window goes with them.
    func dropPages() {
        pages.forEach { $0.drop() }
        pages = []
        room?.close()
        room = nil
    }

    /// A page of graff's put away once it has been read.
    private func close(_ sheet: Sheet) {
        pages.removeAll { $0 === sheet }
        sheet.drop()
    }

    private func make() -> Sheet {
        made += 1
        let window = room ?? makeRoom()
        let sheet = Sheet(id: "p\(made)", in: window)
        pages.append(sheet)
        while pages.count > AgentTools.most { pages.removeFirst().drop() }
        return sheet
    }

    /// Named in the column, where a click opens it as a tab of the user's.
    private func seen(_ sheet: any Target, as label: String? = nil) {
        guard let url = sheet.web.url else { return }
        browser?.agent.saw(url, title: label ?? sheet.title)
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

    /// The page an action is for: one of graff's, a tab of the user's, or —
    /// named by neither — graff's latest.
    private func on(_ arguments: [String: Any], _ browser: Browser, _ act: (Target) async -> [String: Any]) async -> [String: Any] {
        let ref = (arguments["page"] as? String ?? "").lowercased()
        if ref.isEmpty, let latest = pages.last { return await act(latest) }
        if let sheet = pages.first(where: { $0.id == ref }) { return await act(sheet) }
        if let tab = tab(ref, browser) { return await act(TabTarget(tab: tab)) }
        return AgentTools.failed(ref.isEmpty ? "No page open yet — `open` one" : "No page or tab “\(ref)” — see `tabs`")
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
    function clean(t) { return (t || '').replace(/\\s+/g, ' ').trim().slice(0, 140); }
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
    private static func fill(_ wanted: [[String: Any]]) -> String? {
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
          \(json).forEach(function (item) {
            var el = null;
            try { el = document.querySelector(item.selector); } catch (e) { out.push(item.selector + ': not a selector'); return; }
            if (!el) { out.push(item.selector + ': nothing matches'); return; }
            if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
            var v = item.value, kind = (el.type || el.getAttribute('role') || '').toLowerCase(), name = label(el) || item.selector;
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
          });
          if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
          return out.join('\\n');
        })()
        """
    }

    /// What a page shows, as a JPEG small enough to go back in one answer.
    private static func picture(_ web: WKWebView) async -> Data? {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        shot.snapshotWidth = NSNumber(value: min(1280, web.bounds.width))
        let image: NSImage? = await withCheckedContinuation { done in
            web.takeSnapshot(with: shot) { image, _ in done.resume(returning: image) }
        }
        guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        for quality in [0.7, 0.5, 0.3] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count * 4 / 3 < largest {
                return jpeg
            }
        }
        return nil
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
}

extension Target {
    func run(_ script: String) async -> (Any?, String?) {
        await withCheckedContinuation { done in
            web.evaluateJavaScript(script) { value, error in
                done.resume(returning: (value, error?.localizedDescription))
            }
        }
    }

    /// Until the page has stopped loading, and a beat for its own scripts,
    /// or fifteen seconds, whichever is first.
    func settled() async {
        let limit = Date().addingTimeInterval(15)
        try? await Task.sleep(nanoseconds: 250_000_000)
        while web.isLoading, Date() < limit {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// One of graff's pages: a web view of its own, in the room off screen, with
/// the user's sign-ins, as any page in the browser has.
@MainActor
private final class Sheet: Target {
    let id: String
    let web: WKWebView

    init(id: String, in room: NSWindow) {
        self.id = id
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Store.websites
        config.applicationNameForUserAgent = Web.userAgentName
        web = WKWebView(frame: room.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        web.autoresizingMask = [.width, .height]
        room.contentView?.addSubview(web)
    }

    var title: String { web.title?.isEmpty == false ? web.title ?? "" : (web.url?.host() ?? id) }
    var address: String { web.url?.absoluteString ?? "" }

    func go(_ url: URL) { web.load(URLRequest(url: url)) }

    func drop() {
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

/// An HTTP/1.1 request, once all of it has arrived: its method, headers by
/// lower-case name, and body.
private struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard let method = first.first else { return nil }
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
        self.headers = headers
        self.body = Data(body.prefix(length))
    }

    static func reply(_ status: Int, _ body: Data?) -> Data {
        let words = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(words)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }
}
