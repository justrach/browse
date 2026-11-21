import AppKit
import SwiftUI

// Handoff: offers the active page to your iPhone, iPad, and other Macs via
// macOS Continuity (NSUserActivityTypeBrowsingWeb). Off unless enabled in
// Settings › General, and never offered for private tabs, isolated spaces,
// or non-http(s) URLs.
struct Handoff: View {
    @ObservedObject var tab: Tab
    @ObservedObject var prefs: Preferences
    let window: NSWindow?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: apply)
            .onChange(of: tab.pageAddress) { _, _ in apply() }
            .onChange(of: tab.title) { _, _ in apply() }
            .onChange(of: prefs.handoff) { _, _ in apply() }
    }

    private func apply() {
        if let window { Handoff.offer(prefs.handoff ? tab : nil, in: window) }
    }

    static func offer(_ tab: Tab?, in window: NSWindow) {
        guard let tab, let url = address(of: tab) else {
            window.userActivity?.invalidate()
            window.userActivity = nil
            return
        }
        let activity = window.userActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        activity.title = tab.name ?? tab.title
        window.userActivity = activity
    }

    static func address(of tab: Tab) -> URL? {
        guard !tab.shy, let url = tab.pageAddress, web(url) else { return nil }
        if Spaces.current != Space.firstID && !Spaces.sharing.contains(Spaces.current) { return nil }
        return url
    }

    static func incoming(_ activity: NSUserActivity) -> URL? {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL,
              web(url),
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func web(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
