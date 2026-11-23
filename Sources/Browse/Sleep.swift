import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for a while gives its page back,
// and keeps what it takes to come back exactly where it was: its history, its
// scroll position, and a picture to show while the page is rebuilt underneath
// (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (unless Low RAM retires very
// idle ones), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, holding something typed and not sent, or
// actively referenced by graff.
//
// When macOS signals memory pressure, decoded wake covers and preview caches
// are trimmed first; warning pressure only nudges long-idle tabs while
// protecting recent context, and critical pressure trims deeper after a
// cooldown so bursts never thrash active tabs.
//
// Past `awakeMost` background tabs, older ones past `crowdedAfter` sleep
// gradually so switching back and forth across your working set never reloads.

extension Browser {
    /// How long a tab has to go without being looked at, or `sleep.after` in
    /// seconds for the bench and measurements.
    var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        if set > 0 { return set }
        switch prefs.memoryMode {
        case .relaxed: return 2 * 60 * 60
        case .balanced: return 30 * 60
        case .low: return 10 * 60
        }
    }

    /// Tabs kept awake behind the one on screen, or `sleep.awake` for the
    /// bench and measurements.
    var awakeMost: Int {
        let set = Store.settings.integer(forKey: "sleep.awake")
        if set > 0 { return set }
        switch prefs.memoryMode {
        case .relaxed: return 12
        case .balanced: return 6
        case .low: return 3
        }
    }

    /// How long a tab past `awakeMost` is left before it sleeps anyway, or
    /// `sleep.crowded` in seconds.
    var crowdedAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.crowded")
        if set > 0 { return set }
        switch prefs.memoryMode {
        case .relaxed: return 15 * 60
        case .balanced: return 5 * 60
        case .low: return 2 * 60
        }
    }

    /// Started once, at launch.
    func watchForSleep() {
        // Keep shared URLCache bounded instead of letting macOS grow it unbounded,
        // while leaving enough room for fast Back/Forward and tab wakes.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)

        let every = min(30, max(5, sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepIdle()
                self?.archiveStaleTabs()
            }
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

    /// Reclaim memory immediately on pressure or on user request, debounced so
    /// pressure spikes never thrash your working tabs.
    func reclaimMemory(critical: Bool) {
        let now = Date()
        if critical {
            if let last = lastMemoryCritical, now.timeIntervalSince(last) < 15 { return }
            lastMemoryCritical = now
        } else {
            if let last = lastMemoryWarning, now.timeIntervalSince(last) < 60 { return }
            lastMemoryWarning = now
        }

        // Release decoded bitmap caches first (zero impact on live pages).
        for tab in tabs + parkedTabs where tab.asleep {
            tab.dropCover()
        }
        TabPreviewCache.shared.trim()

        if critical {
            URLCache.shared.removeAllCachedResponses()
            sleepIdle(within: 60, protectRecent: 1, protectFloor: 5 * 60)
            if AgentTools.shared.browser != nil {
                AgentTools.shared.reapIdlePages(olderThan: 30)
                if !consulting && agent.phase == .ready { agent.rest() }
            }
        } else {
            let warningWait = max(5 * 60, sleepAfter / 2)
            sleepIdle(within: warningWait, protectRecent: max(2, awakeMost / 2), protectFloor: sleepAfter)
            if AgentTools.shared.browser != nil {
                AgentTools.shared.reapIdlePages(olderThan: 120)
                if !consulting && agent.phase != .working { AgentTools.shared.dropPages() }
            }
        }
    }

    /// User-triggered one-click cleanup from Settings: puts eligible
    /// inactive unpinned tabs to sleep and trims caches right now.
    func sleepInactiveNow() {
        let eligible = (tabs + parkedTabs).filter { awake(because: $0, allowIdlePinned: false) == nil }
        eligible.forEach { sleep($0, allowIdlePinned: false) }
        URLCache.shared.removeAllCachedResponses()
        for tab in tabs + parkedTabs where tab.asleep { tab.dropCover() }
        TabPreviewCache.shared.trim()
        AgentTools.shared.reapIdlePages(olderThan: 60)
        if !eligible.isEmpty {
            announce("Put \(eligible.count) inactive tab\(eligible.count == 1 ? "" : "s") to sleep")
        } else {
            announce("Memory trimmed — no inactive tabs to sleep")
        }
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil, protectRecent: Int = 0, protectFloor: TimeInterval = 5 * 60) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? sleepAfter
        let now = Date()
        let lowRAM = prefs.memoryMode == .low

        var protectedIDs: Set<Tab.ID> = []
        if protectRecent > 0 {
            let recent = (tabs + parkedTabs)
                .filter { tab in
                    awake(because: tab, allowIdlePinned: false) == nil
                        && now.timeIntervalSince(tab.touched) < protectFloor
                }
                .sorted { $0.touched > $1.touched }
                .prefix(protectRecent)
            protectedIDs = Set(recent.map(\.id))
        }

        // The rows of the other spaces too: parked is not the same as used.
        let idle = (tabs + parkedTabs)
            .filter { tab in
                guard !protectedIDs.contains(tab.id) else { return false }
                let allowPinned = lowRAM && tab.pin != nil
                let threshold = allowPinned ? max(wait, 45 * 60) : wait
                return now.timeIntervalSince(tab.touched) >= threshold
                    && awake(because: tab, allowIdlePinned: allowPinned) == nil
            }
            .sorted { $0.touched < $1.touched }
        for tab in idle {
            self.sleep(tab, allowIdlePinned: lowRAM && tab.pin != nil)
        }

        // Pressure sweeps only retire long-idle tabs; skip crowd eviction there.
        guard given == nil else { return }

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
        if sleepingTabs.contains(tab.id) { return "going to sleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        if heldDialogs[tab.id]?.isEmpty == false { return "a question waiting" }
        if AgentTools.shared.browser != nil {
            if agent.pinned === tab { return "pinned to graff" }
            if agent.mentionedTabs.contains(where: { $0 === tab }) { return "attached to graff" }
            if agent.phase == .working && tab.isAgentTab { return "graff is working" }
        }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, allowIdlePinned: Bool = false, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab, allowIdlePinned: allowIdlePinned) {
            done?(reason)
            return
        }
        let tabID = tab.id
        sleepingTabs.insert(tabID)
        tab.unsaved { [weak self, weak tab] typed in
            guard let self else { return }
            guard let tab else {
                self.sleepingTabs.remove(tabID)
                return
            }
            if typed {
                self.sleepingTabs.remove(tabID)
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab, allowIdlePinned: allowIdlePinned) {
                self.sleepingTabs.remove(tabID)
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self else { return }
                self.sleepingTabs.remove(tabID)
                guard let tab else { return }
                if let reason = self.awake(because: tab, allowIdlePinned: allowIdlePinned) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
