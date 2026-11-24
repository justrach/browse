import AppKit
import AVFoundation
import WebKit
import Combine
import NaturalLanguage
import UserNotifications
import IOKit.pwr_mgt
import CryptoKit

// The Chrome APIs WebKit doesn't have, filled in by the browser itself.
//
// Safari's extension engine covers tabs, storage, scripting, request rules,
// cookies, menus, alarms and messaging. Chrome extensions also reach for
// bookmarks, history, downloads, the side panel, offscreen documents, tab
// groups and OAuth — and fall over when those are undefined.
//
// So when an extension is installed, a small script is put at the front of
// its background and of every page it ships: `chrome.bookmarks` and the rest
// are defined there, and every call becomes a native message to this app,
// which answers from its own bookmarks, history and downloads. To the
// extension it looks like Chrome. The files are changed after the store's
// signature has been checked, and only by adding.

@available(macOS 15.4, *)
@MainActor
enum ExtensionShims {
    /// The name native messages to the browser itself go to.
    static let application = "search"
    nonisolated static let file = "search-shim.js"
    /// Search's passkey patch, put first in every script an extension runs in
    /// a page's own world (see Passkeys.swift, and `first` in the script).
    nonisolated static let passkeys = "search-passkeys.js"
    /// The first line of a worker that already carries the shim.
    nonisolated static let marker = "/* Search: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* Search: end of shim */"

    // MARK: - at install

    /// Written beside a prepared extension: which shim it carries. The same
    /// one needs nothing redone, which matters at launch — preparing reads
    /// every script and page an extension ships.
    nonisolated static let stamp = ".search-shim"
    nonisolated private static let preparation = "9"
    nonisolated static let version: String = {
        SHA256.hash(data: Data((script + PasskeyRelay.page + preparation).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + (Store.testing ? "-test" : "")
    }()

    /// `fresh`: a package just unpacked or copied in. What only Search writes
    /// beside an extension — which permissions it added, which shim it
    /// carries — is Search's to say, never the package's: anything by those
    /// names that came inside it goes before a word of it is read.
    nonisolated static func prepare(_ folder: URL, fresh: Bool = false) throws {
        let files = FileManager.default
        if fresh {
            for name in [stamp, ".search-added"] { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        }
        let stampURL = folder.appendingPathComponent(stamp)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == version { return }
        defer { try? version.write(to: stampURL, atomically: true, encoding: .utf8) }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw Crx.Refused.unpack }

        let script = shim(for: folder)
        try script.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try PasskeyRelay.page.write(to: folder.appendingPathComponent(passkeys), atomically: true, encoding: .utf8)

        // Native messaging is how the shim reaches the browser; user scripts
        // are carried out through WebKit's registered content scripts, which
        // need scripting. What is added is written down, so the extension is
        // described by what it asked for, not by what Search gave it.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String] ?? []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? data.write(to: folder.appendingPathComponent(".search-added"))
        }

        // The background, whichever kind it is, gets the shim first. A
        // classic service worker gets it written at the top of its own file;
        // a module one imports it first, as its imports run before anything
        // written above them.
        if var background = manifest["background"] as? [String: Any] {
            // Hybrid MV3 manifests (such as Vimium C) may list both `service_worker`
            // and legacy `scripts`; WebKit picks `scripts` as a background page and
            // fails when MV3 code expects a worker. Keep `service_worker` in MV3.
            if (manifest["manifest_version"] as? Int) == 3,
               let worker = background["service_worker"] as? String, !worker.isEmpty,
               background["scripts"] != nil {
                background.removeValue(forKey: "scripts")
                background.removeValue(forKey: "persistent")
            }
            // A manifest is not a way out of its own package: a worker path
            // that resolves outside the folder, or is a link, is left alone.
            if let worker = background["service_worker"] as? String,
               let path = inside(worker, of: folder) {
                if var source = try? String(contentsOf: path, encoding: .utf8) {
                    // Already carrying one: take the old one off, so a newer
                    // Search puts its newer shim in its place.
                    if source.hasPrefix(marker), let end = source.range(of: ender) {
                        source = String(source[end.upperBound...]).trimmingPrefix("\n").description
                    }
                    // A copy from before there was an end marker: it ends
                    // where its function does, the first `})();` that
                    // starts a line.
                    while source.hasPrefix(marker), let end = source.range(of: "\n})();\n") {
                        source = String(source[end.upperBound...])
                    }
                    let first = "import \"/\(file)\";\n"
                    while source.hasPrefix(first) { source.removeFirst(first.count) }
                    let module = (background["type"] as? String) == "module"
                    try (module ? first + source : marker + "\n" + script + "\n" + ender + "\n" + source).write(to: path, atomically: true, encoding: .utf8)
                }
            }
            // Scripts, alone or beside a worker — WebKit runs them as a page
            // when a manifest names both.
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts too — there only Chrome's behaviour is mended. One
        // that runs in the page's own world has Search's passkey patch before
        // it: a password manager's there keeps a reference to
        // navigator.credentials as it finds it, and that has to be Search's,
        // not WebKit's (see Passkeys.swift).
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String] {
                    if !js.contains(file) { js.insert(file, at: 0) }
                    if (entry["world"] as? String)?.uppercased() == "MAIN", !js.contains(passkeys) { js.insert(passkeys, at: 0) }
                    entry["js"] = js
                }
                return entry
            }
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Every page it ships — popup, options, background page, side panel.
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        let signature: [UInt8] = [0xEF, 0xBB, 0xBF]
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  let bytes = try? Data(contentsOf: url),
                  let page = String(data: bytes, encoding: .utf8)
            else { continue }
            let hasBOM = page.hasPrefix("\u{FEFF}") || bytes.starts(with: signature)
            let base = page.hasPrefix("\u{FEFF}") || !bytes.starts(with: signature) ? page : "\u{FEFF}" + page
            let patched = ExtensionShims.withShim(base)
            var out = Data(patched.utf8)
            if hasBOM, !out.starts(with: signature) {
                out.insert(contentsOf: signature, at: 0)
            }
            guard out != bytes else { continue }
            try? out.write(to: url, options: .atomic)
        }
    }

    /// Places the shim script tag first in `<head>` (ignoring `<header>`), or
    /// immediately after BOM / whitespace / comments / doctype / `<html>` when no
    /// `<head>` tag is present so WebKit stays in standards mode (`CSS1Compat`).
    nonisolated static func withShim(_ page: String) -> String {
        let tag = "<script src=\"/\(file)\"></script>"
        var html = page
        if html.contains(tag) { html = html.replacingOccurrences(of: tag, with: "") }
        if let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: tag, at: head.upperBound)
            return html
        }
        var at = html.startIndex
        if html.hasPrefix("\u{FEFF}") { at = html.index(after: at) }
        let prolog = [#"\s+"#, #"<!--[\s\S]*?-->"#, #"<!doctype[^>]*>"#]
        var pastHTML = false
        while at < html.endIndex {
            let rest = html[at...]
            if let found = prolog.lazy.compactMap({ rest.range(of: $0, options: [.regularExpression, .caseInsensitive, .anchored]) }).first {
                at = found.upperBound
            } else if !pastHTML, let found = rest.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive, .anchored]) {
                at = found.upperBound
                pastHTML = true
            } else {
                break
            }
        }
        html.insert(contentsOf: tag, at: at)
        return html
    }

    /// A path a package names, resolved and kept inside the folder it came
    /// in: `..` in a manifest is not a way out of the package. Nor is a
    /// symbolic link, which a folder install keeps as it is: the worker is
    /// read through it and written back over it as a regular file, so a
    /// link to a file elsewhere would put that file's bytes in the package.
    /// A folder on the way that is a link is caught by where it resolves.
    nonisolated private static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim as this extension gets it: with the events its code mentions
    /// — `chrome.tabs.onUpdated`, `e.runtime.onInstalled` — so its worker
    /// can take their listeners late (see the end of the script).
    nonisolated static func shim(for folder: URL) -> String {
        var found = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file,
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let list = (try? JSONSerialization.data(withJSONObject: found.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // And the scripts it ships, so its worker can be told at once that
        // one isn't there (see importScripts in the script).
        var scripts: [String] = []
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            // An empty one is marked: there is nothing to run in it.
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let shipped = (try? JSONSerialization.data(withJSONObject: scripts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return script.replacingOccurrences(of: "__SEARCH_EVENTS__", with: list)
            .replacingOccurrences(of: "__SEARCH_SCRIPTS__", with: shipped)
            .replacingOccurrences(of: "__SEARCH_CHROME__", with: Crx.chromeVersion)
            .replacingOccurrences(of: "__SEARCH_VERBOSE__", with: Store.testing ? "true" : "false")
    }


    // MARK: - answering

    /// Remembered per extension: the side panel it set, and whether its
    /// button should open it.
    static var panelPath: [String: String] = [:]
    static var panelTabPath: [String: [UUID: String]] = [:]
    static var panelOnClick: Set<String> = []
    /// Offscreen documents, one per extension, as Chrome allows.
    static var offscreen: [String: WKWebView] = [:]
    /// Hidden off-screen host window so offscreen WKWebViews stay scheduled
    /// for timers and WebAssembly (e.g. Bitwarden Argon2) instead of throttling.
    private static let offscreenHost: NSWindow = {
        let w = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.orderOut(nil)
        return w
    }()

    static func closeOffscreen(_ id: String) {
        guard let page = offscreen.removeValue(forKey: id) else { return }
        page.stopLoading()
        page.removeFromSuperview()
    }

    private static func visibleTab(_ raw: Any?, in owner: Extensions) -> Tab? {
        guard let index = (raw as? NSNumber)?.intValue,
              index >= 0, owner.visibleTabs.indices.contains(index)
        else { return nil }
        return owner.visibleTabs[index]
    }
    /// One voice for every extension that reads aloud.
    static let speaker = AVSpeechSynthesizer()

    static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not a Search message"]
        }
        let args = body["args"] as? [Any] ?? []
        do {
            return ["value": try await run(api, args, context: context, owner: owner) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// The families whose answers leave the extension's own origin: what the
    /// browser knows about the person using it. WebKit keeps no permission
    /// object for them, they are the APIs this shim exists to supply, so the
    /// gate reads the names the extension's own manifest asked for.
    private static let gates: [String: String] = [
        "bookmarks": "bookmarks",
        "history": "history",
        "downloads": "downloads",
        "sessions": "sessions",
        "topSites": "topSites",
        "browsingData": "browsingData",
        "readingList": "readingList",
        "userScripts": "userScripts",
        "identity": "identity",
        "search": "search",
        "notifications": "notifications",
        "idle": "idle",
        "power": "power",
        "tts": "tts",
    ]

    /// What this extension asked for: the names in its manifest and any
    /// optional ones granted since. The checks inside the shim are a
    /// courtesy to honest code, the shim runs beside the extension's own,
    /// so the one that counts is here. The manifest is the one WebKit
    /// already holds, not the file read again on every call.
    static func allowed(_ id: String, context: WKWebExtensionContext) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []))
    }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let browser = owner.browser else { throw Unsupported(what: "No browser window") }
        let first = args.first
        let id = context.uniqueIdentifier

        if api.hasPrefix("setting.") {
            // A browser setting (chrome.privacy…) belongs to the family its
            // name starts with, and only an extension that asked for that
            // family may read or change it, as in Chrome.
            let name = api.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let family = String(name.prefix(while: { $0 != "." }))
            guard !family.isEmpty, allowed(id, context: context).contains(family) else {
                throw Unsupported(what: "The extension never asked for \u{201C}\(family)\u{201D}")
            }
            return setting(api, first as? [String: Any] ?? [:], extension: id, owner: owner)
        }

        // What leaves this app is answered here, not in the injected script:
        // the shim runs beside the extension's own code, so its checks stop
        // only the honest. A family this extension never asked for is an
        // error, the way Chrome answers a call to an API it lacks.
        // `tabs.describe` is the one call inside a family WebKit does own
        // where the permission guards reading a tab rather than moving or
        // selecting it. WebKit keeps that permission, optional grants
        // included, so it is asked.
        if api == "tabs.describe", !context.hasPermission(.tabs) {
            throw Unsupported(what: "The extension never asked for \u{201C}tabs\u{201D}")
        }
        if let needed = gates[String(api.prefix(while: { $0 != "." }))], !allowed(id, context: context).contains(needed) {
            throw Unsupported(what: "The extension never asked for \u{201C}\(needed)\u{201D}")
        }

        switch api {
        // MARK: bookmarks
        case "bookmarks.getTree":
            return [root(browser.bookmarks.roots)]
        case "bookmarks.getSubTree":
            guard let key = first as? String else { return [] }
            if key == "0" { return [root(browser.bookmarks.roots)] }
            if key == "1" { return [bar(browser.bookmarks.roots)] }
            return find(key, in: browser.bookmarks.roots).map { [node($0.node, parent: $0.parent, index: $0.index, deep: true)] } ?? []
        case "bookmarks.getChildren":
            let key = first as? String ?? "1"
            if key == "0" { return [bar(browser.bookmarks.roots, deep: false)] }
            let kids = key == "1" ? browser.bookmarks.roots : (find(key, in: browser.bookmarks.roots)?.node.children ?? [])
            return kids.enumerated().map { node($1, parent: key, index: $0, deep: false) }
        case "bookmarks.get":
            let keys = (first as? [String]) ?? (first as? String).map { [$0] } ?? []
            return keys.compactMap { key in
                find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
            }
        case "bookmarks.getRecent":
            let count = (first as? Int) ?? 10
            return flat(browser.bookmarks.roots).filter { !$0.node.isFolder }.suffix(count).reversed()
                .map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.search":
            let query = (first as? String) ?? ((first as? [String: Any])?["query"] as? String) ?? ""
            let wantURL = (first as? [String: Any])?["url"] as? String
            let wantTitle = (first as? [String: Any])?["title"] as? String
            let words = query.lowercased().split(separator: " ").map(String.init)
            return flat(browser.bookmarks.roots).filter { hit in
                let n = hit.node
                if let wantURL, n.url != wantURL { return false }
                if let wantTitle, n.title != wantTitle { return false }
                let hay = (n.title + " " + (n.url ?? "")).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }.map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.create":
            let spec = first as? [String: Any] ?? [:]
            let title = spec["title"] as? String ?? ""
            let parent = (spec["parentId"] as? String).flatMap(UUID.init(uuidString:))
            let made: Bookmark
            if let url = (spec["url"] as? String).flatMap(URL.init(string:)) {
                made = browser.bookmarks.insert(.site(title, url), into: parent)
            } else {
                made = browser.bookmarks.insert(.folder(title, []), into: parent)
            }
            return node(made, parent: parent?.uuidString ?? "1", index: 0, deep: false)
        case "bookmarks.update":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let changes = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            browser.bookmarks.update(uuid, title: changes["title"] as? String, url: changes["url"] as? String)
            return find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.move":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let target = (args.count > 1 ? args[1] as? [String: Any] : nil)?["parentId"] as? String
            browser.bookmarks.move(uuid, into: target.flatMap(UUID.init(uuidString:)))
            return find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.remove", "bookmarks.removeTree":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            browser.bookmarks.remove(uuid)
            return nil

        // MARK: history
        case "history.search":
            let spec = first as? [String: Any] ?? [:]
            let text = spec["text"] as? String ?? ""
            let start = (spec["startTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date().addingTimeInterval(-24 * 3600)
            let end = (spec["endTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
            let limit = spec["maxResults"] as? Int ?? 100
            return browser.history.everything(matching: text)
                .filter { $0.last >= start && $0.last <= end }
                .sorted { $0.last > $1.last }
                .prefix(limit)
                .map(visit)
        case "history.getVisits":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            return browser.history.everything().filter { $0.url.absoluteString == url }.map { trace in
                ["id": trace.key, "visitId": "1", "visitTime": trace.last.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link"]
            }
        case "history.addUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                browser.history.record(url, title: "")
            }
            return nil
        case "history.deleteUrl":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            for trace in browser.history.everything() where trace.url.absoluteString == url {
                browser.history.forget(trace.key)
            }
            return nil
        case "history.deleteRange":
            let spec = first as? [String: Any] ?? [:]
            let start = Date(timeIntervalSince1970: (spec["startTime"] as? Double ?? 0) / 1000)
            let end = Date(timeIntervalSince1970: (spec["endTime"] as? Double ?? 0) / 1000)
            for trace in browser.history.everything() where trace.last >= start && trace.last <= end {
                browser.history.forget(trace.key)
            }
            return nil
        case "history.deleteAll":
            browser.history.forget()
            return nil

        // MARK: downloads
        case "downloads.download":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No url to download") }
            guard let web = browser.active?.built ?? browser.tabs.lazy.compactMap(\.built).first else {
                throw Unsupported(what: "No page to download through")
            }
            if let name = spec["filename"] as? String, !name.isEmpty {
                // A name it asks for, which may carry folders: only the last part is kept.
                browser.namedDownloads[url] = (name as NSString).lastPathComponent
            }
            ExtensionShims.askedDownloads[url] = id
            let download = await web.startDownload(using: URLRequest(url: url))
            browser.keep(download)
            return browser.loot.kept.count + 1
        case "downloads.search":
            return browser.loot.kept.enumerated().map { index, keep in
                ["id": index + 1, "url": keep.url.absoluteString, "finalUrl": keep.url.absoluteString,
                 "filename": keep.path, "state": "complete", "exists": keep.stillThere,
                 "startTime": ISO8601DateFormatter().string(from: keep.date), "mime": ""] as [String: Any]
            }
        case "downloads.open", "downloads.show":
            guard let index = first as? Int, browser.loot.kept.indices.contains(index - 1) else { return nil }
            let keep = browser.loot.kept[index - 1]
            if api == "downloads.open" {
                // As in Chrome, opening asks for its own permission; and only
                // a file this extension downloaded itself, not any of yours.
                guard allowed(id, context: context).contains("downloads.open") else {
                    throw Unsupported(what: "The extension never asked for \u{201C}downloads.open\u{201D}")
                }
                guard ExtensionShims.ownDownloads[id]?.contains(keep.path) == true else {
                    throw Unsupported(what: "Only a download this extension started can be opened by it")
                }
                browser.loot.open(keep)
            } else {
                browser.loot.reveal(keep)
            }
            return nil
        case "downloads.showDefaultFolder":
            NSWorkspace.shared.open(browser.prefs.downloads)
            return nil
        case "downloads.erase":
            return []
        case "downloads.pause", "downloads.resume", "downloads.cancel", "downloads.removeFile", "downloads.getFileIcon":
            throw Unsupported(what: "\(api) isn't available in browse yet")

        // MARK: side panel — docked beside the page (falling back to a tab when unavailable)
        case "sidePanel.setOptions":
            let opts = first as? [String: Any] ?? [:]
            if let tab = visibleTab(opts["tabId"], in: owner) {
                if let path = opts["path"] as? String {
                    panelTabPath[id, default: [:]][tab.id] = path
                }
            } else if let path = opts["path"] as? String {
                panelPath[id] = path
            }
            return nil
        case "sidePanel.getOptions":
            let opts = first as? [String: Any] ?? [:]
            let tabSpecific = visibleTab(opts["tabId"], in: owner).flatMap { panelTabPath[id]?[$0.id] }
            return ["enabled": true, "path": tabSpecific ?? panelPath[id] ?? defaultPanel(context) ?? ""]
        case "sidePanel.setPanelBehavior":
            if let on = (first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                if on { panelOnClick.insert(id) } else { panelOnClick.remove(id) }
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": panelOnClick.contains(id)]
        case "sidePanel.open":
            let opts = first as? [String: Any] ?? [:]
            openPanel(context, owner: owner, tab: visibleTab(opts["tabId"], in: owner)?.id)
            return nil

        // MARK: offscreen — a page with a DOM for a worker that has none
        case "offscreen.createDocument":
            guard offscreen[id] == nil else { throw Unsupported(what: "Only a single offscreen document may be created.") }
            guard let path = (first as? [String: Any])?["url"] as? String,
                  let configuration = context.webViewConfiguration
            else { throw Unsupported(what: "No page for the offscreen document") }
            let frame = offscreenHost.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            let page = WKWebView(frame: frame, configuration: configuration)
            guard let url = ExtensionShims.page(path, in: context) else { throw Unsupported(what: "No page for the offscreen document") }
            offscreenHost.contentView?.addSubview(page)
            page.load(URLRequest(url: url))
            offscreen[id] = page
            // Answered once the page has loaded, as Chrome does: the worker's
            // next line is a message to it, and a page still loading has no
            // one listening yet.
            for _ in 0..<250 where page.isLoading || page.url == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        case "offscreen.closeDocument":
            closeOffscreen(id)
            return nil
        case "offscreen.hasDocument":
            return offscreen[id] != nil

        // MARK: fonts — what the Mac has; the page's own fonts stay the page's
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFontSize":
            return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFixedFontSize":
            return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "fontSettings.getMinimumFontSize":
            return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"):
            return nil

        // MARK: management — only itself
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension", "installType": id.hasPrefix("local-") ? "development" : "normal",
                    "mayDisable": true, "offlineEnabled": true, "isApp": false, "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "management.setEnabled", "management.uninstallSelf":
            throw Unsupported(what: "Extensions are turned on and off in Settings › Extensions")

        // MARK: language
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }.map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] }]
        case "runtime.getContexts":
            // The extension's own pages that Chrome would list: its worker,
            // its popup while it is up, its offscreen document. Bitwarden
            // asks for these to know where to send its messages.
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append([
                    "contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                    "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                    "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "",
                    "incognito": false,
                ])
            }
            if context.webExtension.hasBackgroundContent {
                let manifest = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = manifest["service_worker"] as? String ?? manifest["page"] as? String
                add("BACKGROUND", script.map { context.baseURL.appendingPathComponent($0) })
            }
            if ExtensionPopup.shared.extensionID == id { add("POPUP", ExtensionPopup.shared.view?.url) }
            if let panelURL = SidePanelPages.shared.activeURL(for: id) { add("SIDE_PANEL", panelURL) }
            if let page = offscreen[id] { add("OFFSCREEN_DOCUMENT", page.url) }
            return found

        // MARK: notifications — the Mac's own
        case "notifications.create":
            let named = first as? String
            let options = (named == nil ? first : (args.count > 1 ? args[1] : nil)) as? [String: Any] ?? [:]
            let key = named ?? UUID().uuidString
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? (context.webExtension.displayName ?? "")
            content.body = options["message"] as? String ?? ""
            content.subtitle = context.webExtension.displayName ?? ""
            try? await center.add(UNNotificationRequest(identifier: "\(id).\(key)", content: content, trigger: nil))
            return key
        case "notifications.clear":
            if let key = first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(id).\(key)"])
            }
            return true
        case "notifications.getAll":
            return [String: Any]()
        case "notifications.getPermissionLevel":
            return "granted"
        case "notifications.update":
            return false

        // MARK: speech
        case "tts.speak":
            let options = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if !(options["enqueue"] as? Bool ?? false) { speaker.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: first as? String ?? "")
            if let voice = options["voiceName"] as? String,
               let match = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voice }) {
                utterance.voice = match
            }
            if let rate = options["rate"] as? Double {
                utterance.rate = max(
                    AVSpeechUtteranceMinimumSpeechRate,
                    min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Swift.Float(rate))
                )
            }
            speaker.speak(utterance)
            return nil
        case "tts.stop":
            speaker.stopSpeaking(at: .immediate)
            return nil
        case "tts.pause":
            speaker.pauseSpeaking(at: .immediate)
            return nil
        case "tts.resume":
            speaker.continueSpeaking()
            return nil
        case "tts.isSpeaking":
            return speaker.isSpeaking
        case "tts.getVoices":
            return AVSpeechSynthesisVoice.speechVoices().map { voice -> [String: Any] in
                ["voiceName": voice.name,
                 "lang": voice.language,
                 "remote": false, "eventTypes": ["start", "end"]]
            }

        // MARK: the worker, up before a page talks to it
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            // WebKit sometimes fails to start a worker again after unloading
            // it, and then never tries again: every message waits for ever.
            // Tried twice more, then the extension is taken up afresh.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts; eight
                // seconds without an answer counts as a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(Unsupported(what: "no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
            owner.revive(id, because: "its worker wouldn't start")
            return nil
        // Whether this extension was loaded before in this run of the
        // browser — an "install" then is really a restart (see the shim).
        case "background.loadedBefore":
            return owner.loadedBefore.contains(id)
        // A page found the worker gone though WebKit believes it runs (see
        // the shim's ping).
        case "background.revive":
            owner.revive(id, because: "its worker stopped answering")
            return nil

        // MARK: what went wrong inside
        case "debug.error":
            owner.noteError(first as? String ?? "?", for: id)
            return nil

        // MARK: its own pages, for clients.matchAll() (see the shim)
        case "clients.pages":
            var pages: [[String: Any]] = []
            if let popup = ExtensionPopup.shared.client(of: id) { pages.append(popup) }
            for tab in browser.tabs {
                guard let web = tab.built, let url = web.url, Browser.extensionHost(of: url) == id else { continue }
                let shown = tab.id == browser.activeID && web.window?.occlusionState.contains(.visible) == true
                pages.append(["id": tab.id.uuidString, "url": url.absoluteString, "visible": shown, "focused": shown && web.window?.isKeyWindow == true])
            }
            // Its offscreen document too, as Chrome lists it.
            if let url = offscreen[id]?.url { pages.append(["id": "offscreen", "url": url.absoluteString, "visible": false, "focused": false]) }
            return pages

        // MARK: the button's popup
        case "action.popup":
            let path = first as? String ?? ""
            let index = args.dropFirst().first as? Int ?? -1
            if index >= 0, owner.visibleTabs.indices.contains(index) {
                popups[id, default: [:]][owner.visibleTabs[index].id.uuidString] = path
            } else {
                popups[id, default: [:]]["*"] = path
                popups[id] = popups[id]?.filter { $0.key == "*" }
            }
            return nil

        // MARK: user scripts
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: Extensions.folder(for: id))
        case "userScripts.list":
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: Extensions.folder(for: id).appendingPathComponent("_search/userscripts.json")))) ?? []
        case "userScripts.save":
            let folder = Extensions.folder(for: id).appendingPathComponent("_search", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scripts = first as? [[String: Any]] ?? []
            try JSONSerialization.data(withJSONObject: scripts).write(to: folder.appendingPathComponent("userscripts.json"), options: .atomic)
            // Files no saved script is written in any more, once a moment
            // has passed — one being injected right now is left alone.
            let keep = Set(scripts.compactMap { try? userScriptFile($0, in: Extensions.folder(for: id)) }.map { URL(fileURLWithPath: $0).lastPathComponent })
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.lastPathComponent.hasPrefix("us-") && !keep.contains(file.lastPathComponent) {
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 999
                if age > 60 { try? FileManager.default.removeItem(at: file) }
            }
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = Extensions.folder(for: id).appendingPathComponent("_search/worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        // MARK: permissions Search grants itself
        case "permissions.granted":
            return Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
        case "permissions.request":
            let wanted = (first as? [String]) ?? []
            // As in Chrome: only what the manifest named, as a permission or
            // an optional one. What was agreed to at install still describes
            // the extension; it can't ask later for something it never named.
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
            guard wanted.allSatisfy(named.contains) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            // Those Chrome grants without a word, having nothing to warn of.
            let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                       "system.cpu", "system.memory", "system.display", "favicon"]
            let names = wanted.map { $0.replacingOccurrences(of: ".", with: " ") }.joined(separator: ", ")
            let yes = wanted.allSatisfy(silent.contains) ? true : await owner.ask(more: names, context: context)
            guard yes else { return false }
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(Array(Set(had + wanted)).sorted(), forKey: "extensions.granted.\(id)")
            return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(had.filter { !gone.contains($0) }, forKey: "extensions.granted.\(id)")
            return true

        // MARK: tabs, by where they are in the row
        case "tabs.describe":
            let visible = owner.visibleTabs
            return ((first as? [Int]) ?? []).map { index -> Any in
                guard visible.indices.contains(index) else { return NSNull() }
                return ["url": visible[index].address?.absoluteString ?? "", "title": visible[index].title]
            }
        case "tabs.move", "tabs.discard", "tabs.activate":
            let visible = owner.visibleTabs
            guard let from = first as? Int, visible.indices.contains(from) else { throw Unsupported(what: "No tab there") }
            let tab = visible[from]
            switch api {
            case "tabs.move":
                let wanted = args.dropFirst().first as? Int ?? -1
                let target = visible[wanted < 0 || wanted >= visible.count ? visible.count - 1 : wanted]
                if let index = browser.tabs.firstIndex(where: { $0.id == target.id }) { browser.move(tab, to: index) }
            case "tabs.discard":
                if tab.id != browser.activeID { browser.sleep(tab) }
            default:
                browser.select(tab)
            }
            return nil

        // MARK: search
        case "search.query":
            let spec = first as? [String: Any] ?? [:]
            // Words to search for, as in Chrome — never an address, file:
            // and data: included, which the address field would take.
            guard let url = browser.searchURL(for: spec["text"] as? String ?? "") else { return nil }
            switch spec["disposition"] as? String {
            case "NEW_TAB", "NEW_WINDOW": browser.open(url, foreground: true)
            default: browser.visit(url)
            }
            return nil

        // MARK: idle
        case "idle.queryState":
            let threshold = (first as? Double) ?? 60
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            return 0

        // MARK: power
        case "power.requestKeepAwake":
            let display = (first as? String) == "display"
            if let old = awake[id] { IOPMAssertionRelease(old) }
            var assertion: IOPMAssertionID = 0
            let kind = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), "An extension in browse" as CFString, &assertion) == kIOReturnSuccess {
                awake[id] = assertion
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = awake.removeValue(forKey: id) { IOPMAssertionRelease(old) }
            return nil
        case "power.reportActivity":
            var assertion: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("An extension in browse" as CFString, kIOPMUserActiveLocal, &assertion)
            return nil

        // MARK: browsing data
        case "browsingData.settings":
            return ["options": ["since": 0], "dataToRemove": [:], "dataRemovalPermitted": [
                "cache": true, "cookies": true, "history": true, "downloads": true, "localStorage": true,
                "indexedDB": true, "serviceWorkers": true, "cacheStorage": true, "fileSystems": true, "webSQL": true,
            ]]
        case let api where api.hasPrefix("browsingData."):
            let options = first as? [String: Any] ?? [:]
            let what: [String: Bool]
            if api == "browsingData.remove" {
                what = (args.dropFirst().first as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            } else {
                let key = String(api.dropFirst("browsingData.remove".count))
                what = [key.prefix(1).lowercased() + key.dropFirst(): true]
            }
            try await clear(what, options: options, browser: browser)
            return nil

        // MARK: sessions — the tabs you closed
        case "sessions.getRecentlyClosed":
            let limit = (first as? [String: Any])?["maxResults"] as? Int ?? 25
            return browser.ghosts.reversed().prefix(limit).map { ghost in
                ["lastModified": Int(Date().timeIntervalSince1970),
                 "tab": ["sessionId": ghost.id.uuidString, "url": ghost.url.absoluteString, "title": ghost.title,
                         "index": ghost.index, "windowId": 1, "active": false, "pinned": false, "highlighted": false,
                         "incognito": false, "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]] as [String: Any]
            }
        case "sessions.getDevices":
            return []
        case "sessions.restore":
            let ghost = (first as? String).flatMap { key in browser.ghosts.first { $0.id.uuidString == key } } ?? browser.ghosts.last
            guard let ghost else { throw Unsupported(what: "Nothing to restore") }
            browser.reopen(ghost)
            return ["lastModified": Int(Date().timeIntervalSince1970),
                    "tab": ["url": ghost.url.absoluteString, "title": ghost.title, "index": ghost.index, "windowId": 1]]

        // MARK: top sites — the most visited in history
        case "topSites.get":
            var visits: [String: (url: URL, title: String, count: Int)] = [:]
            for trace in browser.history.everything() {
                guard let host = trace.url.host() else { continue }
                visits[host, default: (trace.url, trace.title, 0)].count += 1
            }
            return visits.values.sorted { $0.count > $1.count }.prefix(10).map {
                ["url": $0.url.absoluteString, "title": $0.title]
            }

        // MARK: reading list — none kept
        case "readingList.query":
            return []
        case "readingList.addEntry", "readingList.removeEntry", "readingList.updateEntry":
            throw Unsupported(what: "Search has no reading list")

        // MARK: system
        case "system.cpu.getInfo":
            return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": "arm64",
                    "modelName": "Apple silicon", "features": [], "processors": [], "temperatures": []]
        case "system.memory.getInfo":
            return ["capacity": Double(ProcessInfo.processInfo.physicalMemory), "availableCapacity": Double(ProcessInfo.processInfo.physicalMemory) / 2]
        case "system.storage.getInfo":
            return []
        case "system.display.getInfo":
            return NSScreen.screens.enumerated().map { index, screen in
                let f = screen.frame, v = screen.visibleFrame
                return ["id": String(index), "name": screen.localizedName, "isPrimary": index == 0, "isInternal": index == 0,
                        "isEnabled": true, "dpiX": 96 * screen.backingScaleFactor, "dpiY": 96 * screen.backingScaleFactor,
                        "rotation": 0, "bounds": ["left": f.minX, "top": f.minY, "width": f.width, "height": f.height],
                        "workArea": ["left": v.minX, "top": v.minY, "width": v.width, "height": v.height]] as [String: Any]
            }

        // MARK: tab groups
        case "tabGroups.query":
            let query = first as? [String: Any] ?? [:]
            return browser.tabGroups.compactMap { g -> [String: Any]? in
                if let collapsed = query["collapsed"] as? Bool, g.collapsed != collapsed { return nil }
                if let title = query["title"] as? String, g.name != title { return nil }
                return Self.chromeTabGroup(g)
            }
        case "tabGroups.get":
            guard let wanted = (first as? NSNumber)?.intValue,
                  let g = browser.tabGroups.first(where: { TabGroup.number($0.id) == wanted })
            else { throw Unsupported(what: "No tab group with id \(first ?? "")") }
            return Self.chromeTabGroup(g)
        case "tabGroups.update":
            guard let wanted = (first as? NSNumber)?.intValue,
                  let g = browser.tabGroups.first(where: { TabGroup.number($0.id) == wanted })
            else { throw Unsupported(what: "No tab group with id \(first ?? "")") }
            let props = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if let title = props["title"] as? String { browser.renameTabGroup(g.id, to: title) }
            if let collapsed = props["collapsed"] as? Bool, g.collapsed != collapsed {
                browser.toggleTabGroup(g.id)
            }
            if let color = props["color"] as? String,
               let idx = Self.chromeGroupColours.firstIndex(of: color) {
                browser.setTabGroupColour(g.id, to: idx)
            }
            return browser.tabGroups.first(where: { $0.id == g.id }).map(Self.chromeTabGroup)
        case "tabGroups.move":
            guard let wanted = (first as? NSNumber)?.intValue,
                  let g = browser.tabGroups.first(where: { TabGroup.number($0.id) == wanted })
            else { throw Unsupported(what: "No tab group with id \(first ?? "")") }
            let props = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if let idx = (props["index"] as? NSNumber)?.intValue {
                let target = max(0, min(idx, max(0, browser.tabGroups.count - 1)))
                browser.moveTabGroup(g.id, to: target)
            }
            return browser.tabGroups.first(where: { $0.id == g.id }).map(Self.chromeTabGroup)

        // MARK: identity
        case "identity.launchWebAuthFlow":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No authorization url") }
            return try await ExtensionAuth.run(url, extension: id, browser: browser).absoluteString
        case "identity.getProfileUserInfo":
            return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            throw Unsupported(what: "getAuthToken needs a Google account signed into Chrome; this extension would need launchWebAuthFlow instead")

        default:
            throw Unsupported(what: "\(api) isn't available in browse")
        }
    }

    // MARK: - the side panel

    /// A user script as a file WebKit can inject: its code — inline, or read
    /// from the extension's own files — inside a block that leaves at once
    /// on a page its globs rule out and, for Chrome's USER_SCRIPT world,
    /// gives the code a `chrome` whose messages are marked as a user
    /// script's. Named by what is in it, so a changed script is a new file
    /// and never a stale one WebKit has already read.
    static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String,
                      // One of the extension's own files, and nothing outside
                      // its folder: a name is resolved before it is read.
                      let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __searchUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "search-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* Search: a user script (chrome.userScripts) */
        search_user_script: {
          const __searchHref = location.href;
          const __searchGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __searchIn = \#(json(script["includeGlobs"] ?? [])), __searchOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__searchIn.length && !__searchIn.some((g) => __searchGlob(g).test(__searchHref))) || __searchOut.some((g) => __searchGlob(g).test(__searchHref))) break search_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "_search/" + name
    }

    /// Popups extensions set for their buttons: per tab, or "*" for all.
    static var popups: [String: [String: String]] = [:]
    /// Downloads an extension asked for, by address, until they land; then
    /// the files they became, which are the only ones it may open.
    static var askedDownloads: [URL: String] = [:]
    static var ownDownloads: [String: Set<String>] = [:]

    /// Keep-awake assertions, one per extension that asked.
    static var awake: [String: IOPMAssertionID] = [:]

    /// chrome.privacy and chrome.proxy: what each extension set, kept across
    /// launches as Chrome keeps it. Search acts on one of them — an
    /// extension turning the browser's own offer to save passwords off,
    /// which is how every password manager asks Chrome to step aside.
    private static func setting(_ api: String, _ details: [String: Any], extension id: String, owner: Extensions) -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        var mine = Extensions.settings(for: id)
        switch parts[0] {
        case "setting.set":
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultSetting(name, owner: owner)
            let controlledByOther = name == "proxy.settings"
                && ExtensionProxy.activeExtensionID != nil
                && ExtensionProxy.activeExtensionID != id
            let level = controlledByOther
                ? "controlled_by_other_extensions"
                : (mine[name] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension")
            return ["value": value ?? NSNull(), "levelOfControl": level]
        }
        Extensions.setSettings(mine, for: id)
        if name == "proxy.settings", let problem = ExtensionProxy.sync(owner: owner) {
            owner.noteError(problem.issue, for: problem.id)
        }
        owner.objectWillChange.send()
        return nil
    }

    private static func defaultSetting(_ name: String, owner: Extensions) -> Any? {
        switch name {
        case "privacy.services.passwordSavingEnabled": return owner.browser?.prefs.savesPasswords ?? true
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        case "proxy.settings": return ["mode": "system"]
        default: return true
        }
    }

    /// chrome.browsingData, from what WebKit and Search keep.
    private static func clear(_ what: [String: Bool], options: [String: Any], browser: Browser) async throws {
        let since = Date(timeIntervalSince1970: (options["since"] as? Double ?? 0) / 1000)
        let origins = (options["origins"] as? [String])?.compactMap { URL(string: $0)?.host() }
        var types = Set<String>()
        let map: [String: [String]] = [
            "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            "cacheStorage": [WKWebsiteDataTypeFetchCache], "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
            "cookies": [WKWebsiteDataTypeCookies], "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
            "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases], "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
            "webSQL": [WKWebsiteDataTypeWebSQLDatabases], "fileSystems": [WKWebsiteDataTypeFileSystem],
        ]
        for (key, on) in what where on { types.formUnion(map[key] ?? []) }
        let store = Store.websites
        if !types.isEmpty {
            if let origins {
                let records = await store.dataRecords(ofTypes: types)
                let hit = records.filter { record in origins.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) } }
                await store.removeData(ofTypes: types, for: hit)
            } else {
                await store.removeData(ofTypes: types, modifiedSince: since)
            }
        }
        if what["history"] == true, origins == nil {
            for trace in browser.history.everything() where trace.last >= since { browser.history.forget(trace.key) }
        }
    }

    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    /// One of the extension's own pages, from the path it gave: resolved
    /// rather than appended, since a path can carry a query (Claude's side
    /// panel names its tab, sidepanel.html?tabId=…), which appended would be
    /// escaped into the file's name. Never anywhere but inside the
    /// extension: a full address given as a "path" is refused.
    static func page(_ path: String, in context: WKWebExtensionContext) -> URL? {
        let base = context.baseURL
        guard let url = URL(string: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host
        else { return nil }
        return url
    }

    private static let chromeGroupColours = ["grey", "blue", "green", "orange", "red", "purple"]

    private static func chromeTabGroup(_ g: TabGroup) -> [String: Any] {
        let color = chromeGroupColours[max(0, g.colour ?? 0) % chromeGroupColours.count]
        return [
            "id": TabGroup.number(g.id),
            "title": g.name,
            "collapsed": g.collapsed,
            "color": color,
            "windowId": 1,
        ]
    }

    static func openPanel(_ context: WKWebExtensionContext, owner: Extensions, tab: Tab.ID? = nil) {
        let id = context.uniqueIdentifier
        guard let path = tab.flatMap({ panelTabPath[id]?[$0] }) ?? panelPath[id] ?? defaultPanel(context) else { return }
        guard let url = ExtensionShims.page(path, in: context), let browser = owner.browser else { return }
        if browser.showSidePanel(context, url: url, for: tab) == .noPanel {
            browser.open(url, foreground: true)
        }
    }

    static func togglePanel(_ context: WKWebExtensionContext, owner: Extensions, tab: Tab.ID? = nil) {
        let id = context.uniqueIdentifier
        guard let path = tab.flatMap({ panelTabPath[id]?[$0] }) ?? panelPath[id] ?? defaultPanel(context) else { return }
        guard let url = ExtensionShims.page(path, in: context), let browser = owner.browser else { return }
        if browser.toggleSidePanel(context, url: url, for: tab) == .noPanel {
            browser.open(url, foreground: true)
        }
    }

    // MARK: - bookmarks, as Chrome shapes them

    private typealias Hit = (node: Bookmark, parent: String, index: Int)

    private static func flat(_ nodes: [Bookmark], parent: String = "1") -> [Hit] {
        nodes.enumerated().flatMap { index, n -> [Hit] in
            [(n, parent, index)] + flat(n.children ?? [], parent: n.id.uuidString)
        }
    }

    private static func find(_ key: String, in nodes: [Bookmark]) -> Hit? {
        flat(nodes).first { $0.node.id.uuidString == key }
    }

    private static func node(_ n: Bookmark, parent: String, index: Int, deep: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": n.id.uuidString, "parentId": parent, "index": index, "title": n.title,
                                  "dateAdded": 0, "syncing": false]
        if let url = n.url { out["url"] = url }
        if n.isFolder {
            out["dateGroupModified"] = 0
            if deep {
                out["children"] = (n.children ?? []).enumerated().map { node($1, parent: n.id.uuidString, index: $0, deep: true) }
            }
        }
        return out
    }

    private static func bar(_ roots: [Bookmark], deep: Bool = true) -> [String: Any] {
        var out: [String: Any] = ["id": "1", "parentId": "0", "index": 0, "title": "Bookmarks", "dateAdded": 0,
                                  "folderType": "bookmarks-bar", "syncing": false]
        if deep { out["children"] = roots.enumerated().map { node($1, parent: "1", index: $0, deep: true) } }
        return out
    }

    private static func root(_ roots: [Bookmark]) -> [String: Any] {
        ["id": "0", "title": "", "dateAdded": 0, "syncing": false, "children": [bar(roots)]]
    }

    private static func visit(_ trace: History.Trace) -> [String: Any] {
        ["id": trace.key, "url": trace.url.absoluteString, "title": trace.title,
         "lastVisitTime": trace.last.timeIntervalSince1970 * 1000, "visitCount": trace.count, "typedCount": 0]
    }
}

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in, and
/// the moment it tries to go to https://<id>.chromiumapp.org/, that address
/// is the answer and the tab goes. Browser asks `intercept` about every
/// navigation; nothing is ever loaded from chromiumapp.org.
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab.ID, finish: (Result<URL, Error>) -> Void)] = [:]
    private static var watch: AnyCancellable?

    struct Declined: LocalizedError {
        var errorDescription: String? { "The user did not approve access." }
    }

    static func run(_ url: URL, extension id: String, browser: Browser) async throws -> URL {
        if #available(macOS 15.4, *) { try Extensions.mayOpen(url) }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id]?.finish(.failure(Declined()))
            let tab = browser.open(url, foreground: true)
            waiting[id] = (tab.id, { result in continuation.resume(with: result) })
            // Closing the tab is saying no.
            watch = browser.$tabs.sink { tabs in
                for (key, entry) in waiting where !tabs.contains(where: { $0.id == entry.tab }) {
                    waiting[key] = nil
                    entry.finish(.failure(Declined()))
                }
            }
        }
    }

    /// True when the address is an extension's OAuth redirect arriving in
    /// the tab that began the sign-in, which is then handed over and never
    /// loaded. Any page can go to an address shaped like one of these, and
    /// what it carries would be delivered as the flow's answer: only the
    /// tab the flow was started in may finish it, or a window that tab's
    /// page opened, since some providers finish the sign-in in a popup.
    static func intercept(_ url: URL, browser: Browser, from webView: WKWebView) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard let entry = waiting[id], let from = browser.tab(for: webView),
              from.id == entry.tab || from.opener == entry.tab
        else { return false }
        waiting.removeValue(forKey: id)
        entry.finish(.success(url))
        // The popup, when the answer came in one, goes with the flow's tab:
        // left behind, it would hold a redirect that never loads.
        if from.id != entry.tab { browser.close(from) }
        if let tab = browser.tabs.first(where: { $0.id == entry.tab }) { browser.close(tab) }
        return true
    }

    /// The same redirect with no launchWebAuthFlow waiting for it. Some
    /// extensions open the provider's page with tabs.create and watch that
    /// tab's address until it reaches their chromiumapp.org one, then close
    /// the tab (Figma's does). In Chrome the navigation fails onto an error
    /// page that still carries the address, and tabs.onUpdated reports it;
    /// in WebKit a failed load never commits, so nothing would. The tab takes
    /// the address without loading anything, for an installed extension
    /// that asked for identity. What each extension sees of it is WebKit's
    /// call, as for any address: tabs or host access, as in Chrome. Left
    /// open, the tab says what Chrome's would.
    static func handOver(_ url: URL, mainFrame: Bool, browser: Browser, from webView: WKWebView) -> Bool {
        guard mainFrame, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard #available(macOS 15.4, *), let context = Extensions.shared.contexts[id],
              ExtensionShims.allowed(id, context: context).contains("identity"),
              let tab = browser.tab(for: webView)
        else { return false }
        tab.hold(url)
        Task { @MainActor [weak tab] in
            try? await Task.sleep(for: .seconds(4))
            guard let tab, tab.held == url else { return }
            tab.failure = "No site at that address."
        }
        return true
    }
}
