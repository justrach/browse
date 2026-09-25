import AppKit
import SwiftUI
import WebKit

// Whether the web engine under the browser has its security fixes.
//
// browse doesn't carry an engine of its own: it uses the WebKit built into
// macOS, the one Safari uses, and Apple fixes it through Software Update
// (macOS updates, Rapid Security Responses, and Safari updates on older
// macOS). A Mac that is kept up to date has a browser that is. One that
// isn't runs pages on an engine with holes Apple has already closed — so
// the browser says so, at each update check, and points at Software Update.
//
// What counts as up to date comes with the updater's appcast: a floor for
// each macOS's line of WebKit builds, taken from webkit-floor.json when a
// release is built, and raised on the live release by ./webkit-floor when
// Apple ships a fix that matters (docs/releasing.md). A WebKit build is
// 22625.1.29.11.27; its first number over a thousand, 22, is the macOS it
// belongs to, and builds are only ever compared within one line.

@MainActor
final class WebKitCheck: ObservableObject {
    static let shared = WebKitCheck()

    /// The WebKit this process runs: SEARCH_WEBKIT_VERSION on a test run,
    /// to see what an older Mac sees.
    nonisolated static let version: String = {
        if Store.testing, let pretend = ProcessInfo.processInfo.environment["SEARCH_WEBKIT_VERSION"], !pretend.isEmpty {
            return pretend
        }
        return Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? ""
    }()

    /// Which macOS's builds this is one of: 22625.… → "22".
    nonisolated static var line: String {
        let first = Int(version.split(separator: ".").first ?? "") ?? 0
        return String(first / 1000)
    }

    /// The build as people read it: its first three numbers.
    nonisolated static var short: String {
        version.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// The oldest build of this line that has every fix that matters, as
    /// the feed last said. Nil when it says nothing about this line.
    @Published private(set) var floor: String?

    private init() {
        floor = Store.settings.string(forKey: "webkit.floor")
    }

    /// Missing fixes: older than the floor of its own line.
    var behind: Bool {
        guard let floor, !WebKitCheck.version.isEmpty else { return false }
        return WebKitCheck.older(WebKitCheck.version, than: floor)
    }

    /// The floors from the feed, one per line.
    func take(_ floors: [String: String]) {
        floor = floors[WebKitCheck.line]
        Store.settings.set(floor, forKey: "webkit.floor")
    }

    /// Dotted numbers, compared a part at a time; a missing part is 0.
    nonisolated static func older(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q }
        }
        return false
    }

    static func openSoftwareUpdate() {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(pane)
        }
    }

    /// For ./bench probe on a test run.
    var probe: [String: Any] {
        ["version": WebKitCheck.version, "line": WebKitCheck.line, "floor": floor ?? "", "behind": behind]
    }
}

/// Settings › About: the engine, and whether it has its fixes.
struct WebKitLine: View {
    @ObservedObject private var check = WebKitCheck.shared

    var body: some View {
        Line(
            check.behind ? "WebKit \(WebKitCheck.short) is missing security fixes" : "WebKit \(WebKitCheck.short)",
            check.behind
                ? "Pages run on the web engine built into macOS, and this Mac's is behind the fixes Apple has shipped. Updating macOS brings them"
                : "Pages run on the web engine built into macOS — the one Safari uses — and Software Update keeps it patched"
        ) {
            if check.behind {
                Pill("Software Update", filled: true) { WebKitCheck.openSoftwareUpdate() }
            }
        }
    }
}
