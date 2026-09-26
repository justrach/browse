import Foundation

// Just enough of the app for SafariImport.swift.
struct Bookmark: Equatable {
    var title: String
    var url: String?
    var children: [Bookmark]?
    var isFolder: Bool { url == nil }
    static func site(_ title: String, _ url: URL) -> Bookmark { Bookmark(title: title, url: url.absoluteString, children: nil) }
    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark { Bookmark(title: title, url: nil, children: children) }
}
enum Chromium {
    struct Place {
        let url: URL
        let title: String
        let count: Int
        let last: Date
    }
}

@main
struct SafariImportChecks {
    static func main() throws {
        // Chrome's and Firefox's export: the toolbar folder opens at the top.
        let chrome = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com/a?x=1&amp;y=2" ADD_DATE="1">Tom &amp; Jerry &#8212; &#x2603;</A>
                <DT><H3>Work</H3>
                <DL><p>
                    <DT><A HREF="https://work.example/">Work</A>
                    <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
                </DL><p>
                <DT><H3>Empty</H3>
                <DL><p>
                </DL><p>
            </DL><p>
            <DT><A HREF="https://other.example/">Other</A>
        </DL><p>
        """
        let marks = SafariExport.bookmarks(in: chrome)
        precondition(marks.count == 3, "top level: \(marks)")
        precondition(marks[0] == .site("Tom & Jerry — ☃", URL(string: "https://example.com/a?x=1&y=2")!), "entities: \(marks[0])")
        precondition(marks[1].title == "Work" && marks[1].children?.count == 1, "nested folder, non-web link dropped: \(marks[1])")
        precondition(marks[2].title == "Other", "after the bar: \(marks[2])")

        // Safari's: folders as they are, the Reading List among them.
        let safari = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML>
        <Title>Bookmarks</Title>
        <H1>Bookmarks</H1>
        <DT><H3 FOLDED>Favourites</H3>
        <DL><p>
        <DT><A HREF="https://apple.com/">Apple</A>
        </DL><p>
        <DT><H3 id="com.apple.ReadingList" FOLDED>Reading List</H3>
        <DL><p>
        <DT><A HREF="https://read.example/later">Later</A>
        </DL><p>
        </HTML>
        """
        let kept = SafariExport.bookmarks(in: safari)
        precondition(kept.map(\.title) == ["Favourites", "Reading List"], "safari folders: \(kept)")
        precondition(kept[1].children?.first?.url == "https://read.example/later", "reading list: \(kept[1])")

        // History: redirects and failures out, microseconds since 1970.
        let history: [[String: Any]] = [
            ["url": "https://maps.apple.com/", "time_usec": 1722367302951213, "destination_url": "https://www.apple.com/maps/", "visits_count": 1],
            ["url": "https://www.apple.com/maps/", "time_usec": 1722367302951310, "title": "Maps - Apple", "visits_count": 3],
            ["url": "https://down.example/", "time_usec": 1722367302951310, "visits_count": 1, "latest_visit_was_load_failure": true],
            ["url": "file:///etc/hosts", "time_usec": 1722367302951310, "visits_count": 1],
        ]
        let places = SafariExport.places(in: history)
        precondition(places.count == 1 && places[0].title == "Maps - Apple" && places[0].count == 3, "places: \(places)")
        precondition(abs(places[0].last.timeIntervalSince1970 - 1722367302.95131) < 0.001, "time: \(places[0].last)")

        // The zip as a whole, with the files Safari puts beside them ignored.
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAFARI_TEST_DIR"]!, isDirectory: true)
        let folder = scratch.appendingPathComponent("Safari Export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try safari.write(to: folder.appendingPathComponent("Bookmarks.html"), atomically: true, encoding: .utf8)
        let historyFile: [String: Any] = ["metadata": ["browser_name": "Safari", "data_type": "history"], "history": history]
        try JSONSerialization.data(withJSONObject: historyFile).write(to: folder.appendingPathComponent("Verlauf.json"))
        let cards: [String: Any] = ["metadata": ["data_type": "payment_cards"], "payment_cards": [["card_number": "0000"]]]
        try JSONSerialization.data(withJSONObject: cards).write(to: folder.appendingPathComponent("PaymentCards.json"))
        try "Title,URL,Username,Password,Notes,OTPAuth\nEx,https://ex.example/,me,secret,,\n"
            .write(to: folder.appendingPathComponent("Passwords.csv"), atomically: true, encoding: .utf8)
        let zip = scratch.appendingPathComponent("export.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        let found = try SafariExport.read(zip)
        precondition(found.from == "Safari", "from: \(found.from)")
        precondition(found.bookmarks.map(\.title) == ["Favourites", "Reading List"], "zip bookmarks: \(found.bookmarks)")
        precondition(found.places.count == 1, "zip places: \(found.places)")
        precondition(found.passwords?.contains("secret") == true, "zip passwords")

        // A lone bookmarks file, from any browser.
        let lone = scratch.appendingPathComponent("bookmarks.html")
        try chrome.write(to: lone, atomically: true, encoding: .utf8)
        let alone = try SafariExport.read(lone)
        precondition(alone.bookmarks.count == 3 && alone.passwords == nil && alone.from == "Imported", "lone html: \(alone)")

        print("PASS: toolbar at top, nesting, entities, non-web links, Safari folders, redirects and failures, zip by content, lone html")
    }
}
