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
    /// Pages kept at once. The oldest goes when another is wanted.
    private static let most = 16

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
    /// will show its tools by.
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
        let file = Agent.folder.appendingPathComponent(".mcp.json")
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
    once — it loads them in parallel — rather than one page at a time. `open` a page to act on \
    it (click, type, submit, run_js, screenshot). `tabs` lists the user's own tabs too; one of \
    theirs can be read or acted on by its id. `show` puts a page in front of the user as a tab.
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
            var said = "\(sheet.id) · \(sheet.title)\n\n" + AgentTools.cut(text as? String ?? "", 20_000)
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
                        return (index, "## \(sheet.id) · \(sheet.title)\n\(sheet.address)\n\n\(body)")
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

        case "click", "type", "submit":
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
