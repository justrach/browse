import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for a quarter of an hour gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// When macOS says memory is short, the quarter hour shrinks: to five minutes on
// a warning, to nothing when it is critical — and Codegraff lets go of what it
// holds too: its own pages on a warning, graff itself when it is critical.
//
// Nor are more than a handful kept awake behind the one on screen. Twenty
// tabs opened in a burst were twenty content processes for half an hour —
// five real pages measured 400 MB between them, 65 MB once four slept (25 Sep
// 2026). Past `awakeMost`, the ones looked at longest ago sleep once they have
// been left a minute, so going back and forth between a few tabs never
// reloads anything. Three kept awake rather than six saved 280 MB of 1.7 GB
// with ten ordinary sites open (Wikipedia, YouTube, the news; 25 Sep 2026).

extension Browser {
    /// How long a tab has to go without being looked at. A quarter of an
    /// hour, or `sleep.after` in seconds — for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        return set > 0 ? set : 15 * 60
    }

    /// Tabs kept awake behind the one on screen, or `sleep.awake` — for the
    /// bench and the measurements.
    static var awakeMost: Int {
        let set = Store.settings.integer(forKey: "sleep.awake")
        return set > 0 ? set : 3
    }

    /// How long a tab past `awakeMost` is left before it sleeps anyway: a
    /// minute, or `sleep.crowded` in seconds.
    static var crowdedAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.crowded")
        return set > 0 ? set : 60
    }

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                let critical = event.contains(.critical)
                self.sleepIdle(within: critical ? 0 : 5 * 60)
                // Codegraff's share, if it has been started at all: its pages
                // are only kept for the next step; graff can be brought back.
                if AgentTools.shared.browser != nil {
                    if critical { self.agent.rest() } else if self.agent.phase != .working { AgentTools.shared.dropPages() }
                }
            }
        }
        source.resume()
        pressure = source
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? Browser.sleepAfter
        let now = Date()
        // The rows of the other spaces too: parked is not the same as used.
        let idle = (tabs + parkedTabs)
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab) }
        // Too many awake: the ones looked at longest ago, past the few kept,
        // once they have been left a little while.
        let crowd = (tabs + parkedTabs)
            .filter { tab in !idle.contains { $0 === tab } && awake(because: tab) == nil }
            .sorted { $0.touched > $1.touched }
        for tab in crowd.dropFirst(Browser.awakeMost) where now.timeIntervalSince(tab.touched) >= Browser.crowdedAfter {
            self.sleep(tab)
        }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        if tab.id == activeID { return "on screen" }
        if tab.pin != nil { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab) {
            done?(reason)
            return
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
