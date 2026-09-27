import Foundation
import Security
import SQLite3
import CommonCrypto

// Reading what another browser on this Mac already holds.
//
// Every Chromium browser — Chrome, Dia, Arc, Brave, Edge, the rest — keeps its
// passwords the same way: a SQLite file called "Login Data" (and "Login Data
// For Account" beside it for a signed-in Google account), each password
// encrypted with a key that the browser itself keeps in the macOS keychain
// under "<Name> Safe Storage". macOS asks you before handing that key to
// anyone else, which is the one thing here you have to say yes to. After
// that it is arithmetic: the key is stretched the way Chromium stretches it,
// and each password is unwrapped and put in the keychain under this app's
// name instead.
//
// The file is copied before it is read. The browser it belongs to is usually
// running, and reading its live database underneath it is how you get a lock
// error, or worse, its attention.

enum Chromium {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        let service: String
        let account: String
        /// The app itself, to say so when it is on this Mac but its data
        /// isn't where it should be.
        let app: String

        var id: String { name }

        var root: URL { Chromium.base.appendingPathComponent(folder, isDirectory: true) }

        /// Every profile's folder — Default, Profile 1 and on — known by
        /// having something of a person's in it. Chrome's own Guest and
        /// System profiles are nobody's. A browser that keeps its only
        /// profile in its own folder, as Opera does, has that one.
        var folders: [URL] {
            let inside = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return ([root] + inside)
                .filter { !["Guest Profile", "System Profile"].contains($0.lastPathComponent) }
                .filter { folder in
                    Chromium.marks.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
                }
        }

        /// Whether the app is in /Applications or ~/Applications.
        var appInstalled: Bool {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            return [URL(fileURLWithPath: "/Applications"), home].contains {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(app).path)
            }
        }
    }

    /// What makes a folder a profile: its passwords, its bookmarks or its
    /// history, in any of the files Chrome has kept them in.
    static let marks = ["Login Data", "Login Data For Account", "Bookmarks", "AccountBookmarks",
                        "EncryptedBookmarks2", "EncryptedAccountBookmarks2", "History"]

    static let known: [Source] = [
        Source(name: "Dia", folder: "Dia/User Data", service: "Dia Safe Storage", account: "Dia", app: "Dia.app"),
        Source(name: "Chrome", folder: "Google/Chrome", service: "Chrome Safe Storage", account: "Chrome", app: "Google Chrome.app"),
        Source(name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc", app: "Arc.app"),
        Source(name: "Brave", folder: "BraveSoftware/Brave-Browser", service: "Brave Safe Storage", account: "Brave", app: "Brave Browser.app"),
        Source(name: "Edge", folder: "Microsoft Edge", service: "Microsoft Edge Safe Storage", account: "Microsoft Edge", app: "Microsoft Edge.app"),
        Source(name: "Vivaldi", folder: "Vivaldi", service: "Vivaldi Safe Storage", account: "Vivaldi", app: "Vivaldi.app"),
        Source(name: "Chromium", folder: "Chromium", service: "Chromium Safe Storage", account: "Chromium", app: "Chromium.app"),
    ]

    /// Where browsers keep their data: ~/Library/Application Support. A test
    /// run reads made-up profiles from its own folder instead, never a real
    /// browser's (see ./bench import).
    static var base: URL {
        if Store.testing { return Store.folder.appendingPathComponent("Import", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Only the browsers actually on this Mac, with something to read.
    static func installed() -> [Source] {
        known.filter { !$0.folders.isEmpty }
    }

    /// Browsers whose app is on this Mac with no folder where their data
    /// should be — said by name, with where browse looked, rather than
    /// "no other browser". A folder macOS keeps shut is there, and is
    /// Chromium.locked's to explain instead.
    static func unreadable() -> [(source: Source, looked: String)] {
        guard !Store.testing else { return [] }
        return known.filter { $0.appInstalled && !FileManager.default.fileExists(atPath: $0.root.path) }.map {
            ($0, $0.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
    }

    /// macOS has shut the browser's folder to other apps. From macOS 27,
    /// Chrome's, Brave's and Edge's (and Firefox's) are kept to their own
    /// developer by a list built into the system, marked com.apple.macl on
    /// the folder; only Full Disk Access lets another app in (see
    /// Browser.unlock).
    static func locked(_ source: Source) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: source.root.path)
            return false
        } catch {
            return FileManager.default.fileExists(atPath: source.root.path)
        }
    }

    /// The browsers whose folder is on this Mac, found without looking
    /// inside it. macOS guards what's inside another app's folder and asks
    /// before letting anyone read it; this is for lists drawn before anyone
    /// has asked for anything, so the question comes when they pick one.
    static func present() -> [Source] {
        known.filter { FileManager.default.fileExists(atPath: $0.root.path) }
    }

    enum Trouble: Error {
        case noPassphrase
        case unreadable
    }

    struct Found {
        var logins: [Login]
        /// Sites the other browser was told never to ask about.
        var never: [String]
    }

    static func read(_ source: Source) throws -> Found {
        guard let passphrase = safeStorage(source) else { throw Trouble.noPassphrase }
        return try read(source.folders, key: stretch(passphrase))
    }

    /// Every profile folder's passwords, opened with the browser's key.
    static func read(_ folders: [URL], key: [UInt8]) throws -> Found {
        var logins: [Login] = []
        var never: [String] = []
        var seen = Set<String>()
        var readAny = false

        // Signed in to Chrome, what's saved goes to the account's own file
        // beside the old one; Chrome shows both as one list, and so do we.
        let files = folders.flatMap { folder in
            ["Login Data", "Login Data For Account"].map { folder.appendingPathComponent($0) }
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            guard let rows = try? rows(in: file) else { continue }
            readAny = true
            for row in rows {
                let host = Vault.host(of: row.origin)
                guard !host.isEmpty else { continue }
                if row.never {
                    never.append(host)
                    continue
                }
                guard let password = unwrap(row.blob, key: key), !password.isEmpty else { continue }
                let clear = row.origin.lowercased().hasPrefix("http://")
                let login = Login(host: host, user: row.user, password: password, used: row.used, clear: clear)
                guard seen.insert(login.id).inserted else { continue }
                logins.append(login)
            }
        }
        guard readAny else { throw Trouble.unreadable }
        return Found(logins: logins, never: never)
    }

    // MARK: - what they kept

    /// The other browser's bookmarks: the bar first, then anything filed
    /// elsewhere, folders and all. Chromium keeps them as one JSON file a
    /// profile; with more than one profile, each comes in as a folder under
    /// the profile's name.
    static func bookmarks(in source: Source) -> [Bookmark] {
        // The keychain is asked only if a profile keeps nothing but sealed
        // files, and then once.
        var asked: [UInt8]??
        let key = { () -> [UInt8]? in
            if asked == nil { asked = .some(try? Chromium.key(for: source)) }
            return asked ?? nil
        }
        let all = profiles(in: source)
        guard all.count > 1 else { return all.first.map { bookmarks(at: $0.folder, key: key) } ?? [] }
        return all.compactMap { profile in
            let marks = bookmarks(at: profile.folder, key: key)
            return marks.isEmpty ? nil : .folder(profile.name, marks)
        }
    }

    /// A profile's bookmarks, from both the files Chrome keeps: "Bookmarks",
    /// and "AccountBookmarks" for what's saved to a signed-in account
    /// without sync. Chrome shows the two side by side; here they merge.
    static func bookmarks(at folder: URL, key: () -> [UInt8]?) -> [Bookmark] {
        let roots = [("Bookmarks", "EncryptedBookmarks2"), ("AccountBookmarks", "EncryptedAccountBookmarks2")]
            .compactMap { clear, sealed -> [String: Any]? in
                guard let data = bookmarkFile(clear, sealed: sealed, in: folder, key: key),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return top["roots"] as? [String: Any]
            }
        func kids(_ root: String) -> [Bookmark] {
            roots.flatMap { nodes(in: ($0[root] as? [String: Any])?["children"] as? [[String: Any]] ?? []) }
        }
        var out = kids("bookmark_bar")
        for (root, name) in [("other", "Other"), ("synced", "Mobile")] {
            let more = kids(root)
            if !more.isEmpty { out.append(.folder(name, more)) }
        }
        return out
    }

    /// One bookmarks file as JSON: the clear one Chrome has always written,
    /// or where Chrome has moved on to keeping only a sealed copy, that one
    /// opened — "v10" and the passwords' own key, over the whole file.
    private static func bookmarkFile(_ clear: String, sealed: String, in folder: URL, key: () -> [UInt8]?) -> Data? {
        if let data = try? Data(contentsOf: folder.appendingPathComponent(clear)) { return data }
        guard let blob = try? Data(contentsOf: folder.appendingPathComponent(sealed)), let key = key() else { return nil }
        return decrypt(blob, key: key)
    }

    private static func nodes(in raw: [[String: Any]]) -> [Bookmark] {
        raw.compactMap { entry in
            let name = entry["name"] as? String ?? ""
            switch entry["type"] as? String {
            case "folder":
                return .folder(name, nodes(in: entry["children"] as? [[String: Any]] ?? []))
            case "url":
                guard let text = entry["url"] as? String, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https"
                else { return nil }
                return .site(name, url)
            default:
                return nil
            }
        }
    }

    /// The other browser's icons for the given pages, host by host: the
    /// largest bitmap it kept for the page itself, or failing that for the
    /// site's front door. Read from a copy of its "Favicons" file.
    static func icons(in source: Source, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var out: [String: Data] = [:]
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = url.host()?.lowercased(), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return out }

        for folder in source.folders {
            let icons = folder.appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: icons.path), let temp = try? snapshot(icons) else { continue }
            defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            let sql = """
            SELECT b.image_data FROM icon_mapping m
            JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ? AND b.width BETWEEN 16 AND 256
            ORDER BY b.width DESC LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }

            for (host, url) in wanted where out[host] == nil {
                var doors = [url.absoluteString]
                if let scheme = url.scheme, let home = url.host() {
                    doors.append("\(scheme)://\(home)/")
                }
                for door in doors {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, door, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { continue }
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    guard count > 60 else { continue }
                    out[host] = Data(bytes: bytes, count: count)
                    break
                }
            }
        }
        return out
    }

    // MARK: - profiles and their sign-ins

    /// One person's side of the other browser: its folder, and the name it
    /// goes by there ("Work", "Personal"), from the browser's Local State.
    struct Profile: Identifiable, Hashable {
        let folder: URL
        let name: String
        var id: String { folder.path }
    }

    /// Every profile with something in it, the one it opens with first.
    static func profiles(in source: Source) -> [Profile] {
        let state = (try? Data(contentsOf: source.root.appendingPathComponent("Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: Any] ?? [:]
        return source.folders.map { folder -> Profile in
            let name = (cache[folder.lastPathComponent] as? [String: Any])?["name"] as? String
            return Profile(folder: folder, name: name?.isEmpty == false ? name! : folder.lastPathComponent)
        }
        .sorted { ($0.folder.lastPathComponent == "Default" ? 0 : 1, $0.name) < ($1.folder.lastPathComponent == "Default" ? 0 : 1, $1.name) }
    }

    /// The key the other browser seals its cookies and passwords with.
    /// macOS asks once, as it does for the passwords.
    static func key(for source: Source) throws -> [UInt8] {
        guard let passphrase = safeStorage(source) else { throw Trouble.noPassphrase }
        return stretch(passphrase)
    }

    /// A profile's cookies — its sign-ins — as WebKit takes them. Ones
    /// partitioned under another site, and ones already expired, stay behind.
    static func cookies(in profile: Profile, key: [UInt8]) throws -> [HTTPCookie] {
        let file = [profile.folder.appendingPathComponent("Network/Cookies"), profile.folder.appendingPathComponent("Cookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file else { return [] }
        let temp = try snapshot(file)
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        // From version 24 each value starts with a hash of its site.
        var version = 0
        var meta: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &meta, nil) == SQLITE_OK, let meta {
            if sqlite3_step(meta) == SQLITE_ROW, let text = sqlite3_column_text(meta, 0) { version = Int(String(cString: text)) ?? 0 }
            sqlite3_finalize(meta)
        }
        let partitioned = version >= 18 ? "AND top_frame_site_key = ''" : ""
        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite
        FROM cookies WHERE 1 = 1 \(partitioned)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Trouble.unreadable }
        defer { sqlite3_finalize(statement) }

        var out: [HTTPCookie] = []
        let now = Date()
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            let host = text(0), name = text(1), path = text(4)
            var value = text(2)
            if let bytes = sqlite3_column_blob(statement, 3) {
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
                guard let opened = open(blob, key: key, hashed: version >= 24) else { continue }
                value = opened
            }
            guard !host.isEmpty, !name.isEmpty else { continue }
            let stamp = sqlite3_column_int64(statement, 5)
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: host, .path: path.isEmpty ? "/" : path, .name: name, .value: value]
            if stamp > 0 {
                let expires = Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600)
                guard expires > now else { continue }
                properties[.expires] = expires
            }
            if sqlite3_column_int(statement, 6) != 0 { properties[.secure] = "TRUE" }
            if sqlite3_column_int(statement, 7) != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch sqlite3_column_int(statement, 8) {
            case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            default: break
            }
            if let cookie = HTTPCookie(properties: properties) { out.append(cookie) }
        }
        return out
    }

    /// A cookie's value: "v10" and AES-128-CBC, as a password is, and past
    /// version 24 a 32-byte hash of its site in front. Nil if it won't open.
    private static func open(_ blob: Data, key: [UInt8], hashed: Bool) -> String? {
        guard !blob.isEmpty else { return "" }
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return String(data: blob, encoding: .utf8) }
        guard var plain = decrypt(blob, key: key) else { return nil }
        if hashed {
            guard plain.count >= 32 else { return nil }
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - where they have been

    struct Place {
        let url: URL
        let title: String
        let count: Int
        let last: Date
    }

    /// The other browser's history — what it takes to finish an address on
    /// the first day. Same file rules as the passwords: a copy, read once.
    static func places(in source: Source, limit: Int = 10_000) -> [Place] {
        places(in: source.folders, limit: limit)
    }

    /// Each profile folder's History, newest first across them all.
    static func places(in folders: [URL], limit: Int) -> [Place] {
        var out: [Place] = []
        for folder in folders {
            let history = folder.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            out += (try? placeRows(in: history, limit: limit)) ?? []
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Place] {
        let temp = try snapshot(file)
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT url, title, visit_count, last_visit_time FROM urls
        WHERE hidden = 0 AND visit_count > 0
        ORDER BY last_visit_time DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600) : Date()
            out.append(Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }

    // MARK: - the key

    private static func safeStorage(_ source: Source) -> String? {
        // A test run's made-up browser keeps its key beside its profiles,
        // not in the keychain.
        if Store.testing {
            let file = source.root.appendingPathComponent("Safe Storage")
            return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source.service,
            kSecAttrAccount as String: source.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    /// Chromium's own recipe, unchanged for a decade: PBKDF2 over SHA-1, the
    /// salt "saltysalt", 1003 rounds, sixteen bytes out.
    private static func stretch(_ passphrase: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let pass = Array(passphrase.utf8)
        pass.withUnsafeBufferPointer { p in
            salt.withUnsafeBufferPointer { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pass.count,
                    s.baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    &key, key.count
                )
            }
        }
        return key
    }

    /// "v10" and then AES-128-CBC with an IV of sixteen spaces.
    private static func unwrap(_ blob: Data, key: [UInt8]) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            // Not encrypted at all, on some very old profiles.
            return String(data: blob, encoding: .utf8)
        }
        guard let plain = decrypt(blob, key: key) else { return nil }
        if let text = String(data: plain, encoding: .utf8) { return text }
        // Newer builds prefix the password with a hash of the site. Past it,
        // the password is the same as ever.
        guard plain.count > 32 else { return nil }
        return String(data: plain.dropFirst(32), encoding: .utf8)
    }

    /// Everything Chromium seals on a Mac — passwords, cookies, now its
    /// bookmarks — is "v10" and then AES-128-CBC with an IV of sixteen
    /// spaces. Nil for anything else, or anything that won't open.
    private static func decrypt(_ blob: Data, key: [UInt8]) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let body = [UInt8](blob.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv,
            body, body.count,
            &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    // MARK: - the file

    /// A copy of one of the other browser's databases, in a folder of its
    /// own the caller removes, with its journal beside it: a browser that's
    /// open hasn't folded what it last did into the file yet. The copy is so
    /// nothing reads the live file underneath it.
    private static func snapshot(_ file: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = file.lastPathComponent
        for suffix in ["", "-wal", "-journal"] {
            let from = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                do {
                    try FileManager.default.copyItem(at: from, to: folder.appendingPathComponent(name + suffix))
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
            }
        }
        return folder.appendingPathComponent(name)
    }

    private struct Row {
        let origin: String
        let user: String
        let blob: Data
        let never: Bool
        let used: Date?
    }

    private static func rows(in file: URL) throws -> [Row] {
        let temp = try snapshot(file)
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT origin_url, username_value, password_value, blacklisted_by_user, date_last_used
        FROM logins
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let origin = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let user = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var blob = Data()
            if let bytes = sqlite3_column_blob(statement, 2) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            }
            let never = sqlite3_column_int(statement, 3) != 0
            // Microseconds since 1601, Chromium's idea of a date.
            let stamp = sqlite3_column_int64(statement, 4)
            let used = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600) : nil
            out.append(Row(origin: origin, user: user, blob: blob, never: never, used: used))
        }
        return out
    }
}
