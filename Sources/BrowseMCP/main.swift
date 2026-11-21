import CryptoKit
import Foundation
import MCP
import Network

// Stdio MCP server for browse, built on modelcontextprotocol/swift-sdk.
//
// Bridges any MCP coding agent (Antigravity, Claude Code, Codex, Cursor, etc.)
// to a running browse.app using browse's signed Connected Apps protocol
// (v1-p256-sig). On first tool use, browse pops up its 6-digit pairing dialog
// where you choose scopes (including whether the agent may inspect/screenshot
// your open tabs).
//
//   browse-mcp [--name "Antigravity"] [--world NAME] [--session ID] [--pair-only]

@main
struct BrowseMCP {
    static func main() async {
        let config = Config.parse(Array(CommandLine.arguments.dropFirst()))
        let bridge = BrowseBridge(config: config)

        if config.pairOnly {
            do {
                try await bridge.ensurePaired()
                log("Paired with browse as \"\(config.name)\".")
                exit(0)
            } catch {
                log("Pairing failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        let server = Server(
            name: "browse",
            version: "1.5.0",
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            do {
                return try await bridge.listTools()
            } catch {
                log("tools/list error: \(error.localizedDescription)")
                return .init(tools: [])
            }
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await bridge.callTool(name: params.name, arguments: params.arguments)
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [
                Resource(
                    name: "Open Tabs",
                    uri: "browse://tabs",
                    description: "JSON list of open browser tabs and this agent's pages (ids, titles, URLs, frontmost tab).",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "Active Tab (Markdown)",
                    uri: "browse://active",
                    description: "Structured Markdown of the user's currently active browser tab (requires “Read and act in your tabs” scope).",
                    mimeType: "text/markdown"
                ),
            ])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await bridge.readResource(uri: params.uri)
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            log("server error: \(error.localizedDescription)")
            exit(1)
        }
        await bridge.closeSession()
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data(("[browse-mcp] \(message)\n").utf8))
}

// MARK: - CLI configuration

private struct Config: Sendable {
    let name: String
    let world: String?
    let session: String
    let pairOnly: Bool

    static func parse(_ args: [String]) -> Config {
        var name = "Coding Agent"
        var world: String? = ProcessInfo.processInfo.environment["SEARCH_PROBE"]
        var session = "mcp-" + UUID().uuidString.prefix(12).lowercased()
        var pairOnly = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--name" where i + 1 < args.count:
                name = args[i + 1]
                i += 2
            case "--world" where i + 1 < args.count:
                world = args[i + 1]
                i += 2
            case "--session" where i + 1 < args.count:
                session = args[i + 1]
                i += 2
            case "--pair-only":
                pairOnly = true
                i += 1
            default:
                i += 1
            }
        }
        return Config(name: name, world: world, session: session, pairOnly: pairOnly)
    }

    var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let world, !world.isEmpty else {
            return base.appendingPathComponent("browse", isDirectory: true)
        }
        let cleaned = world.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let suffix = cleaned.isEmpty || cleaned == "1" ? "test" : cleaned
        return base.appendingPathComponent("browse (\(suffix))", isDirectory: true)
    }

    var connectFile: URL {
        supportFolder.appendingPathComponent("Agent/connect.json")
    }

    var clientStateFile: URL {
        let slug = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? String($0) : "-" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safe = slug.isEmpty ? "agent" : slug
        return supportFolder.appendingPathComponent("Agent/mcp-clients/\(safe).json")
    }
}

// MARK: - Signed bridge to browse.app (v1-p256-sig)

private enum BridgeError: LocalizedError {
    case notRunning
    case pairingFailed(String)
    case httpError(Int, String)
    case untrustedResponse
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "browse isn't accepting connected apps right now. Open browse and turn on Settings › Agent › Connected apps."
        case .pairingFailed(let msg):
            return "Could not pair with browse: \(msg)"
        case .httpError(let code, let msg):
            return "browse refused the request (\(code)): \(msg)"
        case .untrustedResponse:
            return "Response signature from browse did not verify."
        case .badResponse(let msg):
            return "Unexpected response from browse: \(msg)"
        }
    }
}

private struct Endpoint {
    let port: Int
    let browseKey: Data
    let publicKey: P256.Signing.PublicKey
}

private struct ClientState: Codable {
    var key: String
    var clientID: String?
}

private actor BrowseBridge {
    private let config: Config
    private var state: ClientState
    private var privateKey: P256.Signing.PrivateKey
    private var rpcID = 0

    init(config: Config) {
        self.config = config
        if let data = try? Data(contentsOf: config.clientStateFile),
           let loaded = try? JSONDecoder().decode(ClientState.self, from: data),
           let raw = Data(base64Encoded: loaded.key),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            self.state = loaded
            self.privateKey = key
        } else {
            let key = P256.Signing.PrivateKey()
            self.privateKey = key
            self.state = ClientState(key: key.rawRepresentation.base64EncodedString(), clientID: nil)
            Self.persist(self.state, to: config.clientStateFile)
        }
    }

    private static func persist(_ state: ClientState, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func discover() throws -> Endpoint {
        guard let data = try? Data(contentsOf: config.connectFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = json["port"] as? Int,
              let keyString = json["browse_key"] as? String,
              let keyData = Data(base64Encoded: keyString),
              let pub = try? P256.Signing.PublicKey(x963Representation: keyData)
        else { throw BridgeError.notRunning }
        return Endpoint(port: port, browseKey: keyData, publicKey: pub)
    }

    func ensurePaired() async throws {
        let endpoint = try discover()
        if state.clientID != nil {
            let (status, trusted) = try await signedPOST("/pair/status", body: Data("{}".utf8), endpoint: endpoint)
            if trusted, status.status == 200,
               let dict = status.json, dict["status"] as? String == "paired" {
                return
            }
            // Revoked or expired — pair cleanly again.
            state.clientID = nil
            Self.persist(state, to: config.clientStateFile)
        }
        try await pair(endpoint: endpoint)
    }

    private func pair(endpoint: Endpoint) async throws {
        let nonce = Self.randomHex(bytes: 16)
        let payload: [String: Any] = [
            "client_key": privateKey.publicKey.x963Representation.base64EncodedString(),
            "name": config.name,
            "nonce": nonce,
            "protocol": ["v1-p256-sig"],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let reply = try await rawPOST("/pair", body: body, headers: [:], endpoint: endpoint)
        guard reply.status == 200,
              let dict = reply.json,
              let clientID = dict["client_id"] as? String,
              dict["browse_key"] as? String == endpoint.browseKey.base64EncodedString()
        else {
            throw BridgeError.pairingFailed(String(data: reply.body, encoding: .utf8) ?? "status \(reply.status)")
        }

        let nonceBytes = Self.hexBytes(nonce)
        let digest = Array(SHA256.hash(data: endpoint.browseKey + privateKey.publicKey.x963Representation + nonceBytes))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let code = String(format: "%06u", number)
        log("Pairing with browse — verify code \(code) in browse's window and click Connect.")

        state.clientID = clientID
        Self.persist(state, to: config.clientStateFile)

        for _ in 0..<125 {
            let (status, trusted) = try await signedPOST("/pair/status", body: Data("{}".utf8), endpoint: endpoint)
            guard trusted else { throw BridgeError.untrustedResponse }
            let phase = status.json?["status"] as? String ?? "unknown"
            if phase == "paired" {
                log("Paired with browse.")
                return
            }
            if phase != "pending" {
                state.clientID = nil
                Self.persist(state, to: config.clientStateFile)
                throw BridgeError.pairingFailed(phase)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        state.clientID = nil
        Self.persist(state, to: config.clientStateFile)
        throw BridgeError.pairingFailed("timed out waiting for confirmation in browse")
    }

    func listTools() async throws -> ListTools.Result {
        let result = try await forwardRPC(method: "tools/list", params: [:])
        guard let rawTools = result["tools"] as? [[String: Any]] else {
            return .init(tools: [])
        }
        let tools: [Tool] = rawTools.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let description = item["description"] as? String ?? ""
            let schema = Self.toMCPValue(item["inputSchema"] ?? ["type": "object"])
            return Tool(
                name: name,
                description: description,
                inputSchema: schema,
                annotations: Self.annotations(for: name)
            )
        }
        return .init(tools: tools)
    }

    func readResource(uri: String) async throws -> ReadResource.Result {
        switch uri {
        case "browse://tabs":
            let reply = try await callTool(name: "tabs", arguments: nil)
            let text = Self.extractText(reply)
            return .init(contents: [.text(text, uri: uri, mimeType: "application/json")])
        case "browse://active":
            let reply = try await callTool(name: "read_markdown", arguments: ["page": .string("active")])
            if reply.isError == true {
                throw BridgeError.badResponse(Self.extractText(reply))
            }
            let text = Self.extractText(reply)
            return .init(contents: [.text(text, uri: uri, mimeType: "text/markdown")])
        default:
            throw BridgeError.badResponse("Unknown resource URI: \(uri)")
        }
    }

    private static func extractText(_ result: CallTool.Result) -> String {
        result.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    private static func annotations(for tool: String) -> Tool.Annotations {
        switch tool {
        case "search", "read_pages", "read", "read_markdown", "page_info", "links", "tabs", "snapshot", "form_fields", "screenshot", "wait_for":
            return .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        case "open", "open_tab", "go", "back", "forward", "reload", "scroll", "hover", "show":
            return .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        case "close":
            return .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
        default:
            // click, click_at, type, fill, press_key, submit, drive, run_js
            return .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
        }
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        var jsonArgs: [String: Any] = [:]
        if let arguments {
            for (k, v) in arguments { jsonArgs[k] = Self.fromMCPValue(v) }
        }
        let params: [String: Any] = [
            "name": name,
            "arguments": jsonArgs,
            "_meta": ["browse/session": config.session],
        ]
        let result = try await forwardRPC(method: "tools/call", params: params)
        let isError = result["isError"] as? Bool ?? false
        let rawContent = result["content"] as? [[String: Any]] ?? []
        var items: [Tool.Content] = []
        for entry in rawContent {
            let kind = entry["type"] as? String ?? "text"
            if kind == "image",
               let data = entry["data"] as? String,
               let mime = entry["mimeType"] as? String {
                items.append(.image(data: data, mimeType: mime, annotations: nil, _meta: nil))
            } else if let text = entry["text"] as? String {
                items.append(.text(text: text, annotations: nil, _meta: nil))
            }
        }
        if items.isEmpty {
            items.append(.text(text: "ok", annotations: nil, _meta: nil))
        }
        return .init(content: items, isError: isError)
    }

    func closeSession() async {
        guard state.clientID != nil, let endpoint = try? discover() else { return }
        if let body = try? JSONSerialization.data(withJSONObject: ["session": config.session]) {
            _ = try? await signedPOST("/session/close", body: body, endpoint: endpoint)
        }
    }

    private func forwardRPC(method: String, params: [String: Any], retried: Bool = false) async throws -> [String: Any] {
        try await ensurePaired()
        let endpoint = try discover()
        rpcID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": rpcID,
            "method": method,
            "params": params,
        ]
        let body = try JSONSerialization.data(withJSONObject: message)
        let reply: HTTPReply
        let trusted: Bool
        do {
            (reply, trusted) = try await signedPOST("/mcp", body: body, endpoint: endpoint)
        } catch {
            // If browse restarted on a new port, re-read connect.json and retry once.
            if !retried {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return try await forwardRPC(method: method, params: params, retried: true)
            }
            throw BridgeError.notRunning
        }
        if reply.status == 401, !retried {
            state.clientID = nil
            Self.persist(state, to: config.clientStateFile)
            return try await forwardRPC(method: method, params: params, retried: true)
        }
        guard trusted else { throw BridgeError.untrustedResponse }
        if reply.status == 403, let dict = reply.json, let err = dict["error"] as? String {
            throw BridgeError.httpError(403, Self.explainRefusal(err, dict))
        }
        guard reply.status == 200, let dict = reply.json else {
            let text = String(data: reply.body, encoding: .utf8) ?? "status \(reply.status)"
            throw BridgeError.httpError(reply.status, text)
        }
        if let err = dict["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "RPC error"
            throw BridgeError.badResponse(msg)
        }
        guard let result = dict["result"] as? [String: Any] else {
            throw BridgeError.badResponse("missing result")
        }
        return result
    }

    private static func explainRefusal(_ code: String, _ payload: [String: Any]) -> String {
        switch code {
        case "out_of_scope":
            let scope = payload["scope"] as? String ?? ""
            let setting: String
            switch scope {
            case "act-user-tabs": setting = "“Read and act in your tabs”"
            case "act-own-pages": setting = "“Open pages of its own and act in them”"
            case "run-js": setting = "“Run scripts in its pages”"
            default: setting = "the required scope (\(scope))"
            }
            return "Permission required: enable \(setting) for this client in browse → Settings › Agent › Connected apps."
        case "declined":
            return "The user declined access to their open tabs for this session."
        case "connected_apps_off":
            return "Connected apps is turned off. Turn it on in browse → Settings › Agent › Connected apps."
        default:
            return code
        }
    }

    // MARK: - HTTP + ECDSA signing

    private struct HTTPReply {
        let status: Int
        let headers: [String: String]
        let body: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    private func signedPOST(_ path: String, body: Data, endpoint: Endpoint) async throws -> (HTTPReply, Bool) {
        let clientID = state.clientID ?? ""
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = Self.randomHex(bytes: 16)
        let digestHex = Self.hex(SHA256.hash(data: body))
        let canonical = "POST|\(path)|\(digestHex)|\(stamp)|\(nonce)|\(clientID)"
        let signature = try privateKey.signature(for: Data(canonical.utf8)).derRepresentation.base64EncodedString()
        let headers = [
            "X-Client-Id": clientID,
            "X-Timestamp": String(stamp),
            "X-Nonce": nonce,
            "X-Signature": signature,
        ]
        let reply = try await rawPOST(path, body: body, headers: headers, endpoint: endpoint)
        let expected = "\(Self.hex(SHA256.hash(data: reply.body)))|\(nonce)"
        let trusted = reply.headers["x-signature"]
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? P256.Signing.ECDSASignature(derRepresentation: $0) }
            .map { endpoint.publicKey.isValidSignature($0, for: Data(expected.utf8)) } ?? false
        return (reply, trusted)
    }

    private static let netQueue = DispatchQueue(label: "browse.mcp.net")

    /// Fresh TCP loopback HTTP/1.1 POST per request — AgentTools closes each
    /// connection after replying, which makes URLSession's keep-alive pool drop
    /// follow-up requests with "The network connection was lost".
    private func rawPOST(_ path: String, body: Data, headers: [String: String], endpoint: Endpoint) async throws -> HTTPReply {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw BridgeError.notRunning
        }
        var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(endpoint.port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        let payload = Data((head + "\r\n").utf8) + body

        let raw: Data = try await withCheckedThrowingContinuation { done in
            let conn = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
            var finished = false
            var collected = Data()
            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                conn.cancel()
                done.resume(with: result)
            }
            func receiveMore() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, isComplete, error in
                    if let chunk, !chunk.isEmpty { collected.append(chunk) }
                    if isComplete || error != nil {
                        if !collected.isEmpty {
                            finish(.success(collected))
                        } else {
                            finish(.failure(error ?? BridgeError.notRunning))
                        }
                    } else {
                        receiveMore()
                    }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { err in
                        if let err { finish(.failure(err)); return }
                        receiveMore()
                    })
                case .failed(let err):
                    finish(.failure(err))
                default:
                    break
                }
            }
            conn.start(queue: Self.netQueue)
        }

        guard let split = raw.range(of: Data("\r\n\r\n".utf8)),
              let headText = String(data: raw[..<split.lowerBound], encoding: .utf8)
        else { throw BridgeError.badResponse("malformed HTTP reply") }
        var lines = headText.components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ")
        let status = statusParts.count >= 2 ? (Int(statusParts[1]) ?? 0) : 0
        var lowered: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            lowered[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPReply(status: status, headers: lowered, body: Data(raw[split.upperBound...]))
    }

    // MARK: - Encoding helpers

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(bytes count: Int) -> String {
        hex((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func hexBytes(_ string: String) -> Data {
        var out = Data()
        var idx = string.startIndex
        while idx < string.endIndex, let next = string.index(idx, offsetBy: 2, limitedBy: string.endIndex) {
            if let byte = UInt8(string[idx..<next], radix: 16) { out.append(byte) }
            idx = next
        }
        return out
    }

    private static func toMCPValue(_ any: Any) -> Value {
        switch any {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if floor(n.doubleValue) == n.doubleValue, n.doubleValue >= Double(Int.min), n.doubleValue <= Double(Int.max) {
                return .int(n.intValue)
            }
            return .double(n.doubleValue)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(arr.map(toMCPValue))
        case let dict as [String: Any]:
            var obj: [String: Value] = [:]
            for (k, v) in dict { obj[k] = toMCPValue(v) }
            return .object(obj)
        default:
            return .string(String(describing: any))
        }
    }

    private static func fromMCPValue(_ value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .data(_, let d):
            return d.base64EncodedString()
        case .array(let arr):
            return arr.map(fromMCPValue)
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = fromMCPValue(v) }
            return out
        }
    }
}
