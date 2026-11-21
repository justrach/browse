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
    /// How long a tab has to go without being looked at, or `sleep.after` in
    /// seconds for the bench and measurements.
    var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        if set > 0 { return set }
        return prefs.memoryMode == .low ? 3 * 60 : 10 * 60
    }

    /// Tabs kept awake behind the one on screen, or `sleep.awake` for the
    /// bench and measurements.
    var awakeMost: Int {
        let set = Store.settings.integer(forKey: "sleep.awake")
        if set > 0 { return set }
        return prefs.memoryMode == .low ? 1 : 2
    }

    /// How long a tab past `awakeMost` is left before it sleeps anyway, or
    /// `sleep.crowded` in seconds.
    var crowdedAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.crowded")
        if set > 0 { return set }
        return prefs.memoryMode == .low ? 20 : 45
    }

    /// Started once, at launch.
    func watchForSleep() {
        // Keep shared URLCache tightly bounded instead of letting macOS grow it unbounded.
        URLCache.shared = URLCache(memoryCapacity: 12 * 1024 * 1024, diskCapacity: 48 * 1024 * 1024)

        let every = min(30, max(5, sleepAfter / 4))
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
                self.reclaimMemory(critical: critical)
            }
        }
        source.resume()
        pressure = source
    }

    /// Reclaim memory immediately on pressure or on user request.
    func reclaimMemory(critical: Bool) {
        URLCache.shared.removeAllCachedResponses()
        for tab in tabs + parkedTabs where tab.asleep {
            tab.dropCover()
        }
        sleepIdle(within: critical ? 0 : 2 * 60)
        if AgentTools.shared.browser != nil {
            if critical {
                agent.rest()
                AgentTools.shared.reapIdlePages(olderThan: 0)
            } else {
                AgentTools.shared.reapIdlePages(olderThan: 30)
                if agent.phase != .working { AgentTools.shared.dropPages() }
            }
        }
    }

    /// User-triggered one-click cleanup from Settings: puts every eligible
    /// inactive tab to sleep and trims caches right now.
    func sleepInactiveNow() {
        let eligible = (tabs + parkedTabs).filter { awake(because: $0, allowIdlePinned: prefs.memoryMode == .low) == nil }
        eligible.forEach { sleep($0) }
        URLCache.shared.removeAllCachedResponses()
        for tab in tabs + parkedTabs where tab.asleep { tab.dropCover() }
        AgentTools.shared.reapIdlePages(olderThan: 15)
        if !eligible.isEmpty {
            announce("Put \(eligible.count) inactive tab\(eligible.count == 1 ? "" : "s") to sleep")
        } else {
            announce("Memory trimmed — no inactive tabs to sleep")
        }
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? sleepAfter
        let now = Date()
        let lowRAM = prefs.memoryMode == .low
        // The rows of the other spaces too: parked is not the same as used.
        let idle = (tabs + parkedTabs)
            .filter { tab in
                let threshold = (tab.pin != nil && lowRAM) ? max(wait, 20 * 60) : wait
                return now.timeIntervalSince(tab.touched) >= threshold
                    && awake(because: tab, allowIdlePinned: lowRAM) == nil
            }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab) }
        // Too many awake: the ones looked at longest ago, past the few kept,
        // once they have been left a little while.
        let crowd = (tabs + parkedTabs)
            .filter { tab in !idle.contains { $0 === tab } && awake(because: tab) == nil }
            .sorted { $0.touched > $1.touched }
        for tab in crowd.dropFirst(awakeMost) where now.timeIntervalSince(tab.touched) >= crowdedAfter {
            self.sleep(tab)
        }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab, allowIdlePinned: Bool = false) -> String? {
        if tab.id == activeID || showing(inSplit: tab) { return "on screen" }
        if tab.pin != nil && !allowIdlePinned { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        if heldDialogs[tab.id]?.isEmpty == false { return "a question waiting" }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, done: ((String) -> Void)? = nil) {
        let allowPinned = prefs.memoryMode == .low
        if let reason = awake(because: tab, allowIdlePinned: allowPinned) {
            done?(reason)
            return
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab, allowIdlePinned: allowPinned) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab, allowIdlePinned: allowPinned) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
