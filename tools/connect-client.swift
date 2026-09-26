// A connected app, as small as one can be: the reference for Harness and
// anything else that pairs with browse (Sources/Browse/Connect.swift,
// justrach/browse#4), and the end-to-end check of the protocol.
//
//   swift tools/connect-client.swift [--world NAME] pair [APP NAME]
//   swift tools/connect-client.swift [--world NAME] mcp JSON [--session ID]
//   swift tools/connect-client.swift [--world NAME] close SESSION
//   swift tools/connect-client.swift [--world NAME] check
//
// Its key is a software P-256 key kept in $TMPDIR — a real app keeps its in
// the Secure Enclave. `check` sends what browse must refuse and says whether
// it did.

import CryptoKit
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var world: String?
if let at = args.firstIndex(of: "--world"), at + 1 < args.count {
    world = args[at + 1]
    args.removeSubrange(at...(at + 1))
}
var session: String?
if let at = args.firstIndex(of: "--session"), at + 1 < args.count {
    session = args[at + 1]
    args.removeSubrange(at...(at + 1))
}

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data((why + "\n").utf8))
    exit(1)
}

// MARK: - where browse is

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let folder = support.appendingPathComponent(world.map { "browse (\($0))" } ?? "browse", isDirectory: true)
guard let found = (try? Data(contentsOf: folder.appendingPathComponent("Agent/connect.json")))
    .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
    let port = found["port"] as? Int,
    let browseKey = (found["browse_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
    let browse = try? P256.Signing.PublicKey(x963Representation: browseKey)
else { fail("no connect.json — is browse running with Settings › Agent › Connected apps on?") }

// MARK: - this app's key and id

let saved = FileManager.default.temporaryDirectory.appendingPathComponent("browse-connect-\(world ?? "main").json")
var state = (try? Data(contentsOf: saved)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
let key: P256.Signing.PrivateKey = state["key"].flatMap { Data(base64Encoded: $0) }.flatMap { try? P256.Signing.PrivateKey(rawRepresentation: $0) } ?? {
    let made = P256.Signing.PrivateKey()
    state["key"] = made.rawRepresentation.base64EncodedString()
    return made
}()
func keep() { try? JSONSerialization.data(withJSONObject: state).write(to: saved) }

func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
func nonce() -> String { hex((0..<16).map { _ in UInt8.random(in: 0...255) }) }

// MARK: - HTTP, by hand, so nothing is added or changed on the way

struct Reply {
    let status: Int
    let headers: [String: String]
    let body: Data
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

func send(_ path: String, _ body: Data, headers: [String: String] = [:], host: String? = nil) -> Reply {
    var input: InputStream?
    var output: OutputStream?
    Stream.getStreamsToHost(withName: "127.0.0.1", port: port, inputStream: &input, outputStream: &output)
    guard let input, let output else { fail("can't connect to 127.0.0.1:\(port)") }
    input.open()
    output.open()
    var head = "POST \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    let request = Data((head + "\r\n").utf8) + body
    _ = request.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: request.count) }
    var got = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = input.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        got.append(buffer, count: n)
    }
    input.close()
    output.close()
    guard let split = got.range(of: Data("\r\n\r\n".utf8)), let text = String(data: got[..<split.lowerBound], encoding: .utf8) else { fail("no answer") }
    var lines = text.components(separatedBy: "\r\n")
    let status = Int(lines.removeFirst().split(separator: " ")[1]) ?? 0
    var fields: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return Reply(status: status, headers: fields, body: Data(got[split.upperBound...]))
}

/// A request signed as browse wants it, and the answer's signature checked.
/// Each part can be spoiled, for `check`.
func signed(_ path: String, _ body: Data, id: String? = nil, with signer: P256.Signing.PrivateKey? = nil,
            stamp: Int64? = nil, reuse: String? = nil, signedBody: Data? = nil, extra: [String: String] = [:], host: String? = nil) -> (Reply, Bool) {
    let id = id ?? state["client"] ?? ""
    let stamp = stamp ?? Int64(Date().timeIntervalSince1970 * 1000)
    let once = reuse ?? nonce()
    let text = "POST|\(path)|\(hex(SHA256.hash(data: signedBody ?? body)))|\(stamp)|\(once)|\(id)"
    let signature = try! (signer ?? key).signature(for: Data(text.utf8)).derRepresentation.base64EncodedString()
    var headers = ["X-Client-Id": id, "X-Timestamp": String(stamp), "X-Nonce": once, "X-Signature": signature]
    extra.forEach { headers[$0] = $1 }
    let reply = send(path, body, headers: headers, host: host)
    let answered = "\(hex(SHA256.hash(data: reply.body)))|\(once)"
    let trusted = reply.headers["x-signature"].flatMap { Data(base64Encoded: $0) }
        .flatMap { try? P256.Signing.ECDSASignature(derRepresentation: $0) }
        .map { browse.isValidSignature($0, for: Data(answered.utf8)) } ?? false
    return (reply, trusted)
}

func show(_ reply: Reply, _ trusted: Bool) {
    print("\(reply.status) \(trusted ? "signed by browse" : "NOT SIGNED BY BROWSE")")
    print(String(data: reply.body, encoding: .utf8) ?? "")
}

// MARK: - what to do

switch args.first {
case "pair":
    let name = args.dropFirst().joined(separator: " ").isEmpty ? "Reference client" : args.dropFirst().joined(separator: " ")
    let once = nonce()
    let body = try! JSONSerialization.data(withJSONObject: [
        "client_key": key.publicKey.x963Representation.base64EncodedString(), "name": name, "nonce": once, "protocol": ["v1-p256-sig"],
    ])
    let reply = send("/pair", body)
    guard reply.status == 200, let id = reply.json["client_id"] as? String,
          reply.json["browse_key"] as? String == browseKey.base64EncodedString()
    else { fail("pair: \(reply.status) \(String(data: reply.body, encoding: .utf8) ?? "")") }
    let digest = Array(SHA256.hash(data: browseKey + key.publicKey.x963Representation + Data(stride(from: 0, to: once.count, by: 2).map {
        UInt8(once[once.index(once.startIndex, offsetBy: $0)..<once.index(once.startIndex, offsetBy: $0 + 2)], radix: 16)!
    })))
    let code = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
    print("code: \(String(format: "%06u", code)) — check browse shows the same")
    state["client"] = id
    keep()
    for _ in 0..<130 {
        let (status, trusted) = signed("/pair/status", Data("{}".utf8))
        guard trusted else { fail("status answer not signed by browse") }
        let said = status.json["status"] as? String ?? "?"
        if said != "pending" {
            print(said, status.json["scopes"] ?? "")
            exit(said == "paired" ? 0 : 1)
        }
        Thread.sleep(forTimeInterval: 1)
    }
    fail("no answer in time")

case "mcp":
    guard args.count >= 2, var message = (try? JSONSerialization.jsonObject(with: Data(args[1].utf8))) as? [String: Any] else { fail("mcp JSON") }
    if let session {
        var params = message["params"] as? [String: Any] ?? [:]
        params["_meta"] = ["browse/session": session]
        message["params"] = params
    }
    let (reply, trusted) = signed("/mcp", try! JSONSerialization.data(withJSONObject: message))
    show(reply, trusted)

case "close":
    guard args.count >= 2 else { fail("close SESSION") }
    let (reply, trusted) = signed("/session/close", try! JSONSerialization.data(withJSONObject: ["session": args[1]]))
    show(reply, trusted)

case "check":
    let list = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    var failures = 0
    func expect(_ what: String, _ reply: Reply, _ trusted: Bool, _ status: Int, _ error: String?, signed: Bool = true) {
        let said = reply.json["error"] as? String
        let ok = reply.status == status && (error == nil || said == error) && (!signed || trusted)
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(what): \(reply.status) \(said ?? "")\(trusted ? "" : " (unsigned)")")
    }
    var (r, t) = signed("/mcp", list)
    expect("valid request", r, t, 200, nil)
    let names = ((r.json["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    print("     tools offered: \(names.joined(separator: ", "))")
    (r, t) = signed("/mcp", list, with: P256.Signing.PrivateKey())
    expect("wrong key", r, t, 401, "bad_signature")
    (r, t) = signed("/mcp", Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_js"}}"#.utf8), signedBody: list)
    expect("tampered body", r, t, 401, "bad_signature")
    (r, t) = signed("/mcp", list, stamp: Int64(Date().timeIntervalSince1970 * 1000) - 120_000)
    expect("stale timestamp", r, t, 401, "stale")
    let once = nonce()
    _ = signed("/mcp", list, reuse: once)
    (r, t) = signed("/mcp", list, reuse: once)
    expect("replayed nonce", r, t, 401, "replayed")
    (r, t) = signed("/mcp", list, id: UUID().uuidString.lowercased())
    expect("unknown client", r, t, 401, "unknown_client")
    let theme = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "theme", "arguments": [:]]])
    (r, t) = signed("/mcp", theme)
    expect("tool no app may use", r, t, 403, "out_of_scope")
    (r, t) = signed("/mcp", list, extra: ["Origin": "https://example.com"])
    expect("a web page's Origin", r, t, 403, "bad_origin", signed: false)
    (r, t) = signed("/mcp", list, host: "evil.example:\(port)")
    expect("another Host", r, t, 403, "bad_origin", signed: false)
    r = send("/mcp", list, headers: ["Authorization": "Bearer nope"])
    expect("bearer only", r, false, 401, nil, signed: false)
    print(failures == 0 ? "PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)

default:
    fail("usage: connect-client.swift [--world NAME] pair [NAME] | mcp JSON [--session ID] | close SESSION | check")
}
