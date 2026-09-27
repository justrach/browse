import CommonCrypto
import Foundation
import SQLite3

// Just enough of the app for Import.swift.
struct Bookmark {
    var title: String
    var url: String?
    var children: [Bookmark]?
    static func site(_ title: String, _ url: URL) -> Bookmark { Bookmark(title: title, url: url.absoluteString, children: nil) }
    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark { Bookmark(title: title, url: nil, children: children) }
}
struct Login: Hashable {
    var host: String
    var user: String
    var password: String
    var used: Date?
    var clear = false
    var id: String { host + "\u{1}" + user }
}
enum Bookmarks {
    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.children.map { count($0) } ?? 1) }
    }
    static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { $0.children.map(urls) ?? ($0.url.flatMap(URL.init(string:)).map { [$0] } ?? []) }
    }
}
enum Store {
    // As a test run does: made-up browsers under the test folder's Import/.
    static let testing = true
    static let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHROMIUM_TEST_DIR"]!, isDirectory: true)
}
enum Vault {
    static func host(of text: String) -> String { URL(string: text)?.host() ?? "" }
}

@main
struct ChromiumChecks {
    static func main() throws {
        // The key as Chromium makes it from its keychain passphrase.
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8), pass = Array("test passphrase".utf8)
        _ = pass.withUnsafeBufferPointer { p in
            salt.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pass.count,
                                     s.baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        func seal(_ plain: [UInt8]) -> Data {
            var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
            var moved = 0
            let iv = [UInt8](repeating: 0x20, count: 16)
            _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, iv, plain, plain.count, &out, out.count, &moved)
            return Data("v10".utf8) + Data(out.prefix(moved))
        }
        func seal(_ value: String, host: String) -> Data {
            // Version 24: a 32-byte hash of the site, then the value.
            var hash = [UInt8](repeating: 0, count: 32)
            _ = Array(host.utf8).withUnsafeBufferPointer { CC_SHA256($0.baseAddress, CC_LONG($0.count), &hash) }
            return seal(hash + Array(value.utf8))
        }
        func chrome(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

        let profile = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHROMIUM_TEST_DIR"]!, isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Network"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(profile.appendingPathComponent("Network/Cookies").path, &db) == SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version', '24');
        CREATE TABLE cookies(host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
          expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER);
        """, nil, nil, nil)
        let later = chrome(Date().addingTimeInterval(86400 * 30)), gone = chrome(Date().addingTimeInterval(-86400))
        let rows: [(String, String, String, String, Int64, Int32, Int32, Int32)] = [
            (".github.com", "", "user_session", "abc123", later, 1, 1, 1),
            ("github.com", "", "strict", "s", later, 1, 0, 2),
            (".example.com", "", "old", "x", gone, 0, 0, 0),
            (".tracker.example", "https://news.example", "partitioned", "p", later, 1, 0, 0),
            ("example.org", "", "session", "for now", 0, 0, 0, 0),
        ]
        for (host, top, name, value, expires, secure, httpOnly, sameSite) in rows {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?, ?, ?, '', ?, '/', ?, ?, ?, ?)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, host, -1, transient)
            sqlite3_bind_text(statement, 2, top, -1, transient)
            sqlite3_bind_text(statement, 3, name, -1, transient)
            let sealed = seal(value, host: host)
            _ = sealed.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(sealed.count), transient) }
            sqlite3_bind_int64(statement, 5, expires)
            sqlite3_bind_int(statement, 6, secure)
            sqlite3_bind_int(statement, 7, httpOnly)
            sqlite3_bind_int(statement, 8, sameSite)
            precondition(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)

        let cookies = try Chromium.cookies(in: Chromium.Profile(folder: profile, name: "Work"), key: key)
        let named = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        precondition(Set(named.keys) == ["user_session", "strict", "session"], "kept: \(named.keys.sorted())")
        let session = named["user_session"]!
        precondition(session.value == "abc123" && session.domain == ".github.com" && session.isSecure && session.isHTTPOnly, "decrypted: \(session)")
        precondition(session.sameSitePolicy == .sameSiteLax, "samesite lax")
        precondition(named["strict"]!.sameSitePolicy == .sameSiteStrict && named["strict"]!.domain == "github.com", "host-only, strict")
        precondition(named["session"]!.expiresDate == nil && named["session"]!.value == "for now", "session cookie")
        print("PASS: v10 + version-24 hash prefix decrypted, expired and partitioned left behind, flags and SameSite kept, session cookies")

        // History, from a browser that's still open: its visits are in the
        // write-ahead log, not yet folded into the file. The connection
        // stays open until the read, so they stay there.
        var history: OpaquePointer?
        precondition(sqlite3_open(profile.appendingPathComponent("History").path, &history) == SQLITE_OK)
        sqlite3_exec(history, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
        sqlite3_exec(history, """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
        INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES
          ('https://github.com/', 'GitHub', 40, \(chrome(Date().addingTimeInterval(-3600))), 0),
          ('https://news.ycombinator.com/', 'Hacker News', 12, \(chrome(Date().addingTimeInterval(-60))), 0),
          ('chrome://settings/', 'Settings', 5, \(chrome(Date())), 0),
          ('https://ads.example/pixel', '', 3, \(chrome(Date())), 1),
          ('https://never.example/', 'Never', 0, \(chrome(Date())), 0);
        """, nil, nil, nil)
        precondition(FileManager.default.fileExists(atPath: profile.appendingPathComponent("History-wal").path), "visits still in the WAL")
        let places = Chromium.places(in: [profile], limit: 10)
        sqlite3_close(history)
        precondition(places.map(\.url.absoluteString) == ["https://news.ycombinator.com/", "https://github.com/"], "places: \(places.map(\.url))")
        precondition(places[1].count == 40 && places[1].title == "GitHub", "counts and titles kept")
        print("PASS: history read with its WAL, newest first, counts kept, hidden, unvisited and non-web left behind")

        // Passwords: the profile's own file, and the signed-in account's
        // beside it, read as one list.
        func logins(_ name: String, _ rows: [(String, String, String, Int32)]) {
            var db: OpaquePointer?
            precondition(sqlite3_open(profile.appendingPathComponent(name).path, &db) == SQLITE_OK)
            sqlite3_exec(db, """
            CREATE TABLE logins(origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER, date_last_used INTEGER);
            """, nil, nil, nil)
            for (origin, user, password, never) in rows {
                var statement: OpaquePointer?
                sqlite3_prepare_v2(db, "INSERT INTO logins VALUES(?, ?, ?, ?, 0)", -1, &statement, nil)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, origin, -1, transient)
                sqlite3_bind_text(statement, 2, user, -1, transient)
                let sealed = seal(Array(password.utf8))
                _ = sealed.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(sealed.count), transient) }
                sqlite3_bind_int(statement, 4, never)
                precondition(sqlite3_step(statement) == SQLITE_DONE)
                sqlite3_finalize(statement)
            }
            sqlite3_close(db)
        }
        logins("Login Data", [("https://github.com/login", "me", "local secret", 0), ("https://spam.example/", "", "", 1)])
        logins("Login Data For Account", [("https://mail.example/", "me@example", "account secret", 0),
                                          ("https://github.com/session", "me", "same login", 0)])
        let found = try Chromium.read([profile], key: key)
        let byHost = Dictionary(uniqueKeysWithValues: found.logins.map { ($0.host, $0.password) })
        precondition(byHost == ["github.com": "local secret", "mail.example": "account secret"], "logins: \(byHost)")
        precondition(found.never == ["spam.example"], "never: \(found.never)")
        print("PASS: passwords from Login Data and Login Data For Account, one list, the first of a pair kept")

        // Bookmarks: the account's file beside the profile's own, and where
        // Chrome keeps only the sealed copy, that one opened with the key.
        func tree(_ bar: [(String, String)], other: [(String, String)] = []) -> Data {
            func kids(_ marks: [(String, String)]) -> [[String: Any]] { marks.map { ["type": "url", "name": $0.0, "url": $0.1] } }
            let roots: [String: Any] = ["bookmark_bar": ["children": kids(bar)], "other": ["children": kids(other)], "synced": ["children": []]]
            return try! JSONSerialization.data(withJSONObject: ["roots": roots])
        }
        try seal(Array(tree([("Local", "https://local.example/")], other: [("Filed", "https://filed.example/")])))
            .write(to: profile.appendingPathComponent("EncryptedBookmarks2"))
        try tree([("Account", "https://account.example/")]).write(to: profile.appendingPathComponent("AccountBookmarks"))
        var asked = 0
        let marks = Chromium.bookmarks(at: profile, key: { asked += 1; return key })
        precondition(marks.map(\.title) == ["Local", "Account", "Other"], "bar: \(marks.map(\.title))")
        precondition(marks[2].children?.map(\.title) == ["Filed"], "other: \(marks[2])")
        precondition(asked == 1, "the key asked for once, for the sealed file")
        try tree([("Clear", "https://clear.example/")]).write(to: profile.appendingPathComponent("Bookmarks"))
        asked = 0
        let clear = Chromium.bookmarks(at: profile, key: { asked += 1; return key })
        precondition(clear.map(\.title) == ["Clear", "Account"] && asked == 0, "clear file first, no key: \(clear.map(\.title)) asked \(asked)")
        print("PASS: bookmarks from Bookmarks and AccountBookmarks, EncryptedBookmarks2 opened only when it's all there is")

        // Counting before anything is brought: a browser under Import/, two
        // profiles, one of them keeping only sealed bookmarks. No key.
        let chrome = Chromium.base.appendingPathComponent("Test", isDirectory: true)
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: profile, to: chrome.appendingPathComponent("Default"))
        let sealedOnly = chrome.appendingPathComponent("Profile 2", isDirectory: true)
        try FileManager.default.createDirectory(at: sealedOnly, withIntermediateDirectories: true)
        try seal(Array(tree([("Hidden", "https://hidden.example/")]))).write(to: sealedOnly.appendingPathComponent("EncryptedBookmarks2"))
        let test = Chromium.Source(name: "Test", folder: "Test", service: "none", account: "none", app: "Test.app")
        precondition(Set(test.folders.map(\.lastPathComponent)) == ["Default", "Profile 2"], "profiles: \(test.folders)")
        let whole = Chromium.preview(of: test, profile: "Default")
        precondition(whole.places == 2 && whole.passwords == 3 && whole.bookmarks == 2 && !whole.sealedBookmarks,
                     "Default counted: \(whole)")
        let sealedPreview = Chromium.preview(of: test, profile: "Profile 2")
        precondition(sealedPreview.bookmarks == 0 && sealedPreview.sealedBookmarks && sealedPreview.passwords == 0, "sealed: \(sealedPreview)")
        precondition(Chromium.places(in: test, profile: "Profile 2", limit: 10).isEmpty, "one profile only")
        let loose = try Chromium.read([chrome.appendingPathComponent("Default")], key: key)
        precondition(loose.logins.count == 2 && loose.skipped == 0, "read: \(loose.logins.count), skipped \(loose.skipped)")
        print("PASS: counted per profile without the key, sealed bookmarks said to be there, one profile read alone")

        // Firefox: places.sqlite holds history and bookmarks together.
        let fox = Chromium.base.appendingPathComponent("Firefox/Profiles/abc.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: fox, withIntermediateDirectories: true)
        var foxDB: OpaquePointer?
        precondition(sqlite3_open(fox.appendingPathComponent("places.sqlite").path, &foxDB) == SQLITE_OK)
        func micro(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }
        sqlite3_exec(foxDB, """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER, hidden INTEGER);
        CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
        INSERT INTO moz_places VALUES
          (1, 'https://mozilla.org/', 'Mozilla', 9, \(micro(Date().addingTimeInterval(-30))), 0),
          (2, 'https://docs.example/', 'Docs', 1, \(micro(Date().addingTimeInterval(-600))), 0),
          (3, 'https://tagged.example/', 'Tagged', 0, NULL, 0);
        INSERT INTO moz_bookmarks VALUES
          (1, 2, NULL, 0, 0, '', 'root________'),
          (2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____'),
          (3, 2, NULL, 1, 1, 'tags', 'tags________'),
          (4, 1, 1, 2, 0, 'Mozilla', 'aaaaaaaaaaaa'),
          (5, 2, NULL, 2, 1, 'Work', 'bbbbbbbbbbbb'),
          (6, 1, 2, 5, 0, 'Docs', 'cccccccccccc'),
          (7, 1, 3, 3, 0, 'Tagged', 'dddddddddddd');
        """, nil, nil, nil)
        sqlite3_close(foxDB)
        let firefox = Mozilla.known.first { $0.name == "Firefox" }!
        precondition(Mozilla.present().map(\.name).contains("Firefox") && !Mozilla.locked(firefox), "Firefox found, open")
        let foxMarks = Mozilla.bookmarks(in: firefox)
        precondition(Bookmarks.urls(foxMarks).map(\.absoluteString) == ["https://mozilla.org/", "https://docs.example/"],
                     "Firefox bookmarks: \(Bookmarks.urls(foxMarks))")
        let foxPlaces = Mozilla.places(in: firefox, limit: 10)
        precondition(foxPlaces.map(\.title) == ["Mozilla", "Docs"] && foxPlaces[0].count == 9, "Firefox places: \(foxPlaces.map(\.title))")
        let foxPreview = ImportSource.mozilla(firefox).preview(profile: nil)
        precondition(foxPreview.places == 2 && foxPreview.bookmarks == 2, "Firefox counted: \(foxPreview)")
        print("PASS: Firefox bookmarks (toolbar and folders, tags left out) and history, found and counted")
    }
}
