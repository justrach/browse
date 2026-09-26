import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("search suggestions: \(message)\n", stderr)
        exit(1)
    }
}

let now = Date(timeIntervalSince1970: 1_700_000_000)
let searches = Searched([
    (words: "Swift Concurrency", count: 2, last: now.addingTimeInterval(-100)),
    (words: "swift concurrency", count: 3, last: now.addingTimeInterval(-200)),
    (words: "C++ Templates", count: 1, last: now.addingTimeInterval(-50)),
    (words: "C language", count: 8, last: now.addingTimeInterval(-300)),
    (words: "Swift actor guide", count: 2, last: now.addingTimeInterval(-400)),
    (words: "actor Swift guide", count: 2, last: now.addingTimeInterval(-400)),
])

expect(searches.recent(limit: 2) == ["C++ Templates", "Swift Concurrency"],
       "recent searches should preserve display case and newest order")
expect(searches.matching("s", limit: 5, now: now).contains("Swift Concurrency"),
       "one typed character should match a past search")
expect(searches.matching("swift actor ", limit: 5, now: now).first == "Swift actor guide",
       "BM25 should prefer the query's word order")
expect(searches.matching("C++", limit: 5, now: now) == ["C++ Templates"],
       "trailing punctuation must not broaden C++ to C language")
expect(searches.matching("concurrency swift", limit: 5, now: now).contains("Swift Concurrency"),
       "BM25 should match words in a different order")

let pages = Searched.Pages(["https://www.google.com/search?q=%s"])
expect(pages.words(in: URL(string: "https://www.google.com/search?q=C%2B%2B+Templates")!) == "C++ Templates",
       "history should recover encoded plus signs and form spaces")

expect(GoogleSuggestions.eligible("swift actor"), "ordinary search text should qualify")
for address in ["s", "https://example.com/path", "github.com", "www.example.com",
                "mailto:alice", "person@example.com", "swift/path", "localhost:8000"] {
    expect(!GoogleSuggestions.eligible(address), "address-like text should stay local: \(address)")
}
let request = GoogleSuggestions.request(for: "C++ templates")
expect(request?.url?.scheme == "https" && request?.url?.host == "suggestqueries.google.com",
       "Google requests must use the intended HTTPS host")
expect(request?.httpShouldHandleCookies == false, "Google requests must not send cookies")
expect(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?
    .queryItems?.first(where: { $0.name == "q" })?.value == "C++ templates",
       "query text should survive URL encoding")

let good = Data(#"["swift",["swift","Swift Concurrency","swift concurrency","Swift actor","Swift code","Swift language"]]"#.utf8)
expect(GoogleSuggestions.decode(good, for: "swift") ==
       ["Swift Concurrency", "Swift actor", "Swift code", "Swift language"],
       "remote rows should be deduplicated, omit the query, and stop at four")
expect(GoogleSuggestions.decode(good, for: "other").isEmpty,
       "a stale response must not be used for a different query")
expect(GoogleSuggestions.decode(Data("not json".utf8), for: "swift").isEmpty,
       "malformed payloads should leave local suggestions alone")
expect(GoogleSuggestions.decode(Data(repeating: 32, count: GoogleSuggestions.maximumBytes + 1),
                                for: "swift").isEmpty,
       "oversized payloads should be refused")

print("search suggestions: passed")
