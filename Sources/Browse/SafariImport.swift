import Foundation

// Reading what Safari hands over.
//
// Safari keeps its bookmarks and history where macOS lets only Safari look,
// short of giving this app Full Disk Access — too much to ask for a list of
// links. It hands them over instead: File › Export Browsing Data to File…
// writes a zip of Bookmarks.html, History.json (one for each profile) and,
// if asked, Passwords.csv. The names inside are in the Mac's language, so
// each file is known by what's in it rather than what it's called.
//
// The bookmarks are the old Netscape file every browser writes, so a
// bookmarks .html from Chrome, Firefox or anything else comes in the same way.

enum SafariExport {
    struct Found {
        var bookmarks: [Bookmark] = []
        var places: [Chromium.Place] = []
        /// A passwords export, as it was: Title,URL,Username,Password,…
        var passwords: String?
        /// Who made it, for the folder the bookmarks go in when there are
        /// bookmarks here already.
        var from = "Imported"
    }

    enum Trouble: Error {
        case unreadable
    }

    /// A zip as Safari writes it, or one file out of it.
    static func read(_ file: URL, limit: Int = 3000) throws -> Found {
        guard file.pathExtension.lowercased() == "zip" else {
            var found = Found()
            take(file, into: &found)
            guard !found.bookmarks.isEmpty || !found.places.isEmpty || found.passwords != nil else { throw Trouble.unreadable }
            found.places = Array(found.places.sorted { $0.last > $1.last }.prefix(limit))
            return found
        }
        // Unpacked beside nothing, and gone again before this returns: the
        // passwords in there are in the clear.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", file.path, temp.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Trouble.unreadable }

        var found = Found(from: "Safari")
        let walk = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        while let inside = walk?.nextObject() as? URL {
            take(inside, into: &found)
        }
        guard !found.bookmarks.isEmpty || !found.places.isEmpty || found.passwords != nil else { throw Trouble.unreadable }
        found.places = Array(found.places.sorted { $0.last > $1.last }.prefix(limit))
        return found
    }

    private static func take(_ file: URL, into found: inout Found) {
        guard let data = try? Data(contentsOf: file) else { return }
        switch file.pathExtension.lowercased() {
        case "html", "htm":
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
            found.bookmarks += bookmarks(in: text)
        case "json":
            // History.json, or the extensions and payment cards beside it —
            // told apart by what the file says it is.
            guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meta = top["metadata"] as? [String: Any],
                  meta["data_type"] as? String == "history"
            else { return }
            if let name = meta["browser_name"] as? String, !name.isEmpty { found.from = name }
            found.places += places(in: top["history"] as? [[String: Any]] ?? [])
        case "csv":
            guard let text = String(data: data, encoding: .utf8),
                  let header = text.split(whereSeparator: \.isNewline).first?.lowercased(),
                  header.contains("password")
            else { return }
            found.passwords = text
        default:
            return
        }
    }

    // MARK: - history

    /// Safari lists every step of a redirect as a place of its own. Only
    /// where each one ended is a place anyone went.
    static func places(in history: [[String: Any]]) -> [Chromium.Place] {
        history.compactMap { item in
            guard item["destination_url"] == nil,
                  item["latest_visit_was_load_failure"] as? Bool != true,
                  let text = item["url"] as? String, let url = URL(string: text),
                  url.scheme == "http" || url.scheme == "https"
            else { return nil }
            let stamp = (item["time_usec"] as? NSNumber)?.doubleValue ?? 0
            return Chromium.Place(
                url: url,
                title: item["title"] as? String ?? "",
                count: max(1, (item["visits_count"] as? NSNumber)?.intValue ?? 1),
                last: stamp > 0 ? Date(timeIntervalSince1970: stamp / 1_000_000) : Date()
            )
        }
    }

    // MARK: - bookmarks

    /// A Netscape bookmarks file: `<DT><H3>` names a folder whose `<DL>`
    /// follows, `<DT><A HREF>` is a site, and `</DL>` closes the folder.
    /// The toolbar folder, when the file marks one, opens at the top, as
    /// the bar does when Chrome's own come over.
    static func bookmarks(in html: String) -> [Bookmark] {
        struct Frame {
            var name: String
            var bar: Bool
            var nodes: [Bookmark] = []
        }
        let pattern = #"<DT>\s*<H3([^>]*)>(.*?)</H3>|<DT>\s*<A([^>]*)>(.*?)</A>|<DL[^>]*>|</DL>"#
        guard let tags = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let text = html as NSString
        var stack = [Frame(name: "", bar: false)]
        var named: (name: String, bar: Bool)?
        var opened = false

        for match in tags.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            func part(_ i: Int) -> String? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
            if let attributes = part(1), let name = part(2) {
                named = (plain(name), attribute("PERSONAL_TOOLBAR_FOLDER", in: attributes)?.lowercased() == "true")
            } else if let attributes = part(3), let title = part(4) {
                guard let href = attribute("HREF", in: attributes), let url = URL(string: plain(href)),
                      url.scheme == "http" || url.scheme == "https"
                else { continue }
                stack[stack.count - 1].nodes.append(.site(plain(title), url))
            } else if part(0)?.hasPrefix("</") == true {
                guard stack.count > 1 else { continue }
                let done = stack.removeLast()
                guard !done.nodes.isEmpty else { continue }
                if done.bar, stack.count == 1 {
                    stack[0].nodes.insert(contentsOf: done.nodes, at: 0)
                } else if done.name.isEmpty {
                    stack[stack.count - 1].nodes += done.nodes
                } else {
                    stack[stack.count - 1].nodes.append(.folder(done.name, done.nodes))
                }
            } else if let folder = named {
                stack.append(Frame(name: folder.name, bar: folder.bar))
                named = nil
            } else if opened {
                // A list no heading named: its sites belong where it is.
                stack.append(Frame(name: "", bar: false))
            } else {
                opened = true
            }
        }
        // A file cut short: whatever was still open is kept.
        while stack.count > 1 {
            let done = stack.removeLast()
            if !done.nodes.isEmpty { stack[stack.count - 1].nodes.append(.folder(done.name, done.nodes)) }
        }
        return stack[0].nodes
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let find = try? NSRegularExpression(pattern: name + #"\s*=\s*"([^"]*)""#, options: .caseInsensitive),
              let match = find.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
        else { return nil }
        return (attributes as NSString).substring(with: match.range(at: 1))
    }

    /// Tags out, entities back to what they stand for.
    private static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, character) in named { text = text.replacingOccurrences(of: entity, with: character) }
        if let numbered = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: .caseInsensitive) {
            let source = text as NSString
            var out = ""
            var at = 0
            for match in numbered.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                out += source.substring(with: NSRange(location: at, length: match.range.location - at))
                let hex = source.substring(with: match.range(at: 1)).lowercased() == "x"
                let value = UInt32(source.substring(with: match.range(at: 2)), radix: hex ? 16 : 10)
                out += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? source.substring(with: match.range)
                at = match.range.location + match.range.length
            }
            text = out + source.substring(from: at)
        }
        return text.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
