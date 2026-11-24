import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for — in Settings, which is also what leaves
    /// the mark it needs at launch (see Bench.Consent).
    @Published var bench: Bool {
        didSet {
            store.set(bench, forKey: "bench")
            bench ? Bench.Consent.grant() : Bench.Consent.revoke()
        }
    }
    /// The theme in use, by id (see Theme.swift). browse's own unless chosen.
    @Published var theme: String {
        didSet {
            store.set(theme, forKey: "theme")
            Themes.use(theme)
        }
    }
    /// The setting said on at launch with no mark from the switch behind it,
    /// and was put back to off.
    private(set) var benchRefused = false
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// Titles down the left instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// Show the compact Aside-style top address bar (domain | title + top-right
    /// Ask pill) when tabs are in the sidebar or folded away.
    @Published var compactTopBar: Bool {
        didSet { store.set(compactTopBar, forKey: "chrome.asideBar") }
    }
    /// Always show an address bar above the page (opt-in #15), including in top-tab mode.
    @Published var alwaysShowAddressBar: Bool {
        didSet { store.set(alwaysShowAddressBar, forKey: "toolbar.alwaysShowAddress") }
    }
    /// Tint the top window title strip to the active page's colour even in top-tab mode (#25).
    @Published var tintedTitleBar: Bool {
        didSet { store.set(tintedTitleBar, forKey: "chrome.tintedTitleBar") }
    }
    /// Eases notched mouse-wheel steps smoothly over frames (`WheelGlide`). Off unless turned on.
    @Published var smoothWheel: Bool {
        didSet {
            store.set(smoothWheel, forKey: "scroll.smoothWheel")
            WheelGlide.on = smoothWheel
        }
    }
    /// Docked extension side panel width (`ExtensionSidePanel`).
    @Published var sidePanelWidth: CGFloat {
        didSet { store.set(Double(sidePanelWidth), forKey: "sidePanel.width") }
    }
    /// The column folded away whenever the pointer isn't at the left edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    @Published var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    /// The column takes on the page's own colour (SideBar, PageTint). On
    /// unless turned off.
    @Published var sideTint: Bool {
        didSet { store.set(sideTint, forKey: "sidebar.tint") }
    }
    /// True while dragging the sidebar edge — suppresses 120 Hz UserDefaults
    /// disk writes until mouse-up (verified by `Browse.ScrollFastPath`).
    var isDraggingSideWidth = false
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet {
            guard !isDraggingSideWidth else { return }
            store.set(Double(sideWidth), forKey: "sidebar.width")
        }
    }
    func commitSideWidth() {
        isDraggingSideWidth = false
        store.set(Double(sideWidth), forKey: "sidebar.width")
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Recent searches under an empty address field. Off until asked for.
    @Published var recentSearches: Bool {
        didSet { store.set(recentSearches, forKey: "search.recent") }
    }
    /// Sends eligible text to Google's suggestion service while typing.
    @Published var googleSuggestions: Bool {
        didSet { store.set(googleSuggestions, forKey: "search.google.suggestions") }
    }
    enum MemoryMode: String, CaseIterable, Identifiable {
        case relaxed
        case balanced
        case low
        var id: String { rawValue }
        var title: String {
            switch self {
            case .relaxed: return "Relaxed"
            case .balanced: return "Balanced"
            case .low: return "Low RAM"
            }
        }
    }

    /// Tabs nobody has looked at give their page back and keep where they were.
    /// On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// How aggressively inactive tabs and background WebKit processes are put to sleep.
    @Published var memoryMode: MemoryMode {
        didSet { store.set(memoryMode.rawValue, forKey: "tabs.memoryMode") }
    }
    @Published var showsReading: Bool {
        didSet {
            store.set(showsReading, forKey: "tabs.reading")
            ScrollRelay.on = showsReading
        }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// Settings › Privacy › Prevent cross-site tracking, turned off: WebKit's
    /// tracking prevention off, as Safari's same switch does (see
    /// Store.keepsSignIns). On unless turned off.
    @Published var keepsSignIns: Bool {
        didSet {
            store.set(keepsSignIns, forKey: "sites.keep")
            Store.keepsSignIns = keepsSignIns
        }
    }
    /// A private tab gets extensions too, not just every other page. Off
    /// unless asked for - a private tab keeps nothing by default, extensions
    /// included, and some watch what a page does.
    @Published var extensionsInPrivate: Bool {
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. Off unless asked for.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }
    /// How big every site is drawn until it has been zoomed on its own.
    @Published var pageZoom: Double {
        didSet { store.set(pageZoom, forKey: "pageZoom") }
    }
    /// The stops the setting steps through — every 5%, from as small as
    /// anyone reads to as big as a page is worth.
    static let zooms: [Double] = stride(from: 50, through: 300, by: 5).map { Double($0) / 100 }

    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Space and ← → control a clicked video showing native browser controls.
    @Published var videoKeys: Bool {
        didSet {
            store.set(videoKeys, forKey: "video.keys")
            VideoKeys.on = videoKeys
        }
    }
    /// Plain link clicks in pinned tabs open in a new foreground loose tab.
    @Published var pinLinksOpenTabs: Bool {
        didSet { store.set(pinLinksOpenTabs, forKey: "pins.linksNewTab") }
    }
    /// Pages draw at 120 frames a second on a screen that can (see FrameRate.swift).
    /// Off unless asked for.
    @Published var fastPages: Bool {
        didSet {
            store.set(fastPages, forKey: "pages.120")
            FrameRate.fast = fastPages
        }
    }
    /// Where a link goes, at the bottom of the page while the pointer is on
    /// it (see StatusLine.swift). Off unless asked for.
    /// Shift-click on a link opens it in a panel over the page (see
    /// Peek.swift). Off unless asked for.
    @Published var peeksLinks: Bool {
        didSet { store.set(peeksLinks, forKey: "links.peek") }
    }
    /// A link from another app opens in a small window of its own (see
    /// Little.swift). Off unless asked for.
    @Published var littleLinks: Bool {
        didSet { store.set(littleLinks, forKey: "links.little") }
    }
    /// Offer the active page to your iPhone, iPad, and other Macs via Handoff.
    /// Off by default since the URL is broadcast to your Apple Account devices.
    @Published var handoff: Bool {
        didSet { store.set(handoff, forKey: "handoff") }
    }
    /// The bookmarks bar above the page (see BookmarksBar.swift). Off
    /// unless asked for.
    @Published var bookmarksBar: Bool {
        didSet { store.set(bookmarksBar, forKey: "bookmarks.bar") }
    }
    @Published var showsLinks: Bool {
        didSet {
            store.set(showsLinks, forKey: "links.show")
            HoveredLink.on = showsLinks
        }
    }
    /// Two fingers flick the floating video to a corner (see Float.swift).
    /// Off unless asked for.
    @Published var floatFlicks: Bool {
        didSet {
            store.set(floatFlicks, forKey: "float.flicks")
            Float.flicks = floatFlicks
        }
    }
    /// A video playing floats out when another app comes to the front, and
    /// back when Search does (see Browser.appLeft). Off unless asked for.
    @Published var floatsAway: Bool {
        didSet { store.set(floatsAway, forKey: "float.away") }
    }
    /// A video playing on a video site comes out into the floating window
    /// when you go to another tab (Browser.leaving). On, as it always was;
    /// the switch is for turning it off.
    @Published var floatsOnLeave: Bool {
        didSet { store.set(floatsOnLeave, forKey: "float.leave") }
    }
    /// A newer build is fetched, checked and put in place on its own, as it
    /// always was. Off, Search still looks once a day and says so, and waits
    /// for Install in Settings (see Updater.installsOnItsOwn).
    @Published var installsUpdates: Bool {
        didSet {
            store.set(installsUpdates, forKey: Updater.installKey)
            // Switched back on with one waiting: it goes in now.
            if installsUpdates { Updater.shared.install() }
        }
    }
    /// Video full screen fills this browser window instead of creating a new macOS Space.
    @Published var fullScreenInWindow: Bool {
        didSet {
            store.set(fullScreenInWindow, forKey: "fullscreen.inWindow")
            WindowFullScreen.on = fullScreenInWindow
        }
    }
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// Off unless asked for.
    @Published var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }
    /// Spaces that share sign-ins carry the same live pinned tabs across switches.
    @Published var sharedPins: Bool {
        didSet { store.set(sharedPins, forKey: "spaces.sharedPins") }
    }
    /// Codegraff, over the Agent Client Protocol (see Agent.swift): the Ask
    /// tab at the head of the row, and the conversation ⌘; opens.
    /// On until turned off in Settings › Agent.
    @Published var usesAgent: Bool {
        didSet { store.set(usesAgent, forKey: "agent") }
    }
    /// Anonymous stats about this Mac, sent once a day (see Stats.swift).
    /// Off unless switched on.
    @Published var shareStats: Bool {
        didSet { store.set(shareStats, forKey: "stats.share") }
    }
    /// Whether Codegraff brings up every MCP server the user's config and
    /// other apps name, rather than only the browser's tools and its own.
    /// Off: each of those is a process, for every chat (see Agent.environment).
    @Published var agentAllTools: Bool {
        didSet { store.set(agentAllTools, forKey: "agent.alltools") }
    }
    /// History and bookmarks sealed and kept in step across the Macs signed
    /// in to Codegraff (see Sync.swift). Off unless switched on.
    @Published var sync: Bool {
        didSet { store.set(sync, forKey: "sync.on") }
    }
    /// Passwords too, sealed the same way, behind a switch of their own.
    /// Off unless switched on.
    @Published var syncPasswords: Bool {
        didSet { store.set(syncPasswords, forKey: "sync.passwords") }
    }
    /// Whether Codegraff's `drive` tool may ask Jev to pick its steps on a
    /// page, through the Codegraff sign-in (see Jev.swift).
    @Published var agentJev: Bool {
        didSet { store.set(agentJev, forKey: "agent.jev") }
    }
    @Published var agentSelection: Bool {
        didSet { store.set(agentSelection, forKey: "agent.selection") }
    }
    @Published var agentTasks: Bool {
        didSet { store.set(agentTasks, forKey: "agent.tasks") }
    }
    @Published var agentDrafts: Bool {
        didSet { store.set(agentDrafts, forKey: "agent.drafts") }
    }
    /// Selected ACP agent backend (`graff`, `antigravity`, `opencode`, `gemini`, `pi`).
    @Published var agentBackend: String {
        didSet { store.set(agentBackend, forKey: "agent.backend") }
    }
    /// Where `graff` is, when it isn't anywhere Search already looks.
    @Published var agentPath: String {
        didSet { store.set(agentPath, forKey: "agent.path") }
    }
    /// The conversation panel's width, remembered between launches.
    /// The model it runs, as `provider/name`. Empty leaves it to graff.
    @Published var agentModel: String {
        didSet { store.set(agentModel, forKey: "agent.model") }
    }

    func agentModel(for backend: String) -> String {
        backend == "graff" ? agentModel : (store.string(forKey: "agent.model.\(backend)") ?? "")
    }

    func setAgentModel(_ model: String, for backend: String) {
        if backend == "graff" {
            agentModel = model
        } else {
            store.set(model, forKey: "agent.model.\(backend)")
        }
    }
    /// How hard it thinks, as graff names the level. Empty leaves it to graff.
    @Published var agentEffort: String {
        didSet { store.set(agentEffort, forKey: "agent.effort") }
    }
    /// Codex / ChatGPT service tier: "", "default", "fast", or "ultrafast".
    @Published var agentServiceTier: String {
        didSet { store.set(agentServiceTier, forKey: "agent.serviceTier") }
    }
    /// True while dragging the Agent sidebar edge — suppresses 120 Hz
    /// UserDefaults disk writes until mouse-up (verified by `Browse.ScrollFastPath`).
    var isDraggingAgentWidth = false
    @Published var agentWidth: CGFloat {
        didSet {
            guard !isDraggingAgentWidth else { return }
            store.set(Double(agentWidth), forKey: "agent.width")
        }
    }
    func commitAgentWidth() {
        isDraggingAgentWidth = false
        store.set(Double(agentWidth), forKey: "agent.width")
    }
    /// Local personal instructions & preferences included once per agent
    /// session (Dia-style personal memory — stored strictly on this Mac).
    @Published var agentMemory: String {
        didSet { store.set(agentMemory, forKey: "agent.memory") }
    }
    /// Floating Dia-style action pill above highlighted text (Ask, Explain,
    /// Rewrite, Copy).
    @Published var selectionToolbar: Bool {
        didSet {
            store.set(selectionToolbar, forKey: "agent.selectionBar")
            SelectionRelay.on = selectionToolbar
        }
    }
    /// Auto-archive untouched unpinned tabs after N hours (0 = Never, 12, 24, 168).
    @Published var autoArchiveHours: Int {
        didSet { store.set(autoArchiveHours, forKey: "tabs.archiveHours") }
    }

    enum ReaderTheme: String, CaseIterable, Identifiable {
        case auto, light, sepia, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .light: return "Light"
            case .sepia: return "Sepia"
            case .dark: return "Dark"
            }
        }
    }

    enum ReaderFont: String, CaseIterable, Identifiable {
        case serif, sans, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .serif: return "Serif"
            case .sans: return "Sans"
            case .mono: return "Mono"
            }
        }
    }

    @Published var readerTheme: ReaderTheme {
        didSet { store.set(readerTheme.rawValue, forKey: "reader.theme") }
    }
    @Published var readerFont: ReaderFont {
        didSet { store.set(readerFont.rawValue, forKey: "reader.font") }
    }
    @Published var readerSize: Int {
        didSet {
            let clamped = min(26, max(14, readerSize))
            if clamped != readerSize {
                readerSize = clamped
                return
            }
            store.set(clamped, forKey: "reader.size")
        }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        let scripted = store.bool(forKey: "bench")
        let allowed = scripted && (Store.testing || Bench.Consent.given)
        bench = allowed
        if scripted, !allowed {
            benchRefused = true
            store.set(false, forKey: "bench")
        }
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        compactTopBar = store.object(forKey: "chrome.asideBar") as? Bool ?? true
        alwaysShowAddressBar = store.bool(forKey: "toolbar.alwaysShowAddress")
        tintedTitleBar = store.bool(forKey: "chrome.tintedTitleBar")
        let glide = store.bool(forKey: "scroll.smoothWheel")
        smoothWheel = glide
        WheelGlide.on = glide
        let panelW = store.object(forKey: "sidePanel.width") as? Double ?? Double(Preferences.sidePanelStart)
        sidePanelWidth = min(Preferences.sidePanelWidths.upperBound, max(Preferences.sidePanelWidths.lowerBound, CGFloat(panelW)))
        sideHides = store.bool(forKey: "sidebar.hides")
        sideTint = store.object(forKey: "sidebar.tint") as? Bool ?? true
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        recentSearches = store.bool(forKey: "search.recent")
        googleSuggestions = store.bool(forKey: "search.google.suggestions")
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        memoryMode = store.string(forKey: "tabs.memoryMode").flatMap(MemoryMode.init) ?? .balanced
        let reading = store.object(forKey: "tabs.reading") as? Bool ?? true
        showsReading = reading
        ScrollRelay.on = reading
        shielded = store.object(forKey: "shield") as? Bool ?? true
        let keeps = store.bool(forKey: "sites.keep")
        keepsSignIns = keeps
        // Before the first page is loaded into the store.
        Store.keepsSignIns = keeps
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        if store.object(forKey: "passkeys.entitled") as? Bool != entitled {
            store.set(entitled, forKey: "passkeys.entitled")
        }
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        let inWinFS = store.bool(forKey: "fullscreen.inWindow")
        fullScreenInWindow = inWinFS
        WindowFullScreen.on = inWinFS
        usesSpaces = store.bool(forKey: "spaces")
        sharedPins = store.bool(forKey: "spaces.sharedPins")
        // On until turned off: all it costs unasked is the Ask tab, and graff
        // only starts once something is asked of it.
        usesAgent = store.object(forKey: "agent") as? Bool ?? true
        shareStats = store.bool(forKey: "stats.share")
        agentAllTools = store.bool(forKey: "agent.alltools")
        let chosenTheme = store.string(forKey: "theme") ?? Themes.plain.id
        theme = chosenTheme
        // Before anything is drawn, so nothing is drawn twice.
        Themes.start(chosenTheme)
        agentJev = store.object(forKey: "agent.jev") as? Bool ?? true
        agentSelection = store.object(forKey: "agent.selection") as? Bool ?? false
        agentTasks = store.bool(forKey: "agent.tasks")
        agentDrafts = store.bool(forKey: "agent.drafts")
        sync = store.bool(forKey: "sync.on")
        syncPasswords = store.bool(forKey: "sync.passwords")
        agentBackend = store.string(forKey: "agent.backend") ?? "graff"
        agentPath = store.string(forKey: "agent.path") ?? ""
        agentModel = store.string(forKey: "agent.model") ?? ""
        agentEffort = store.string(forKey: "agent.effort") ?? ""
        agentServiceTier = store.string(forKey: "agent.serviceTier") ?? ""
        let agentWide = store.object(forKey: "agent.width") as? Double ?? Double(Metrics.agent)
        agentWidth = min(Metrics.agentMax, max(Metrics.agentMin, CGFloat(agentWide)))
        agentMemory = store.string(forKey: "agent.memory") ?? ""
        let selBar = store.object(forKey: "agent.selectionBar") as? Bool ?? true
        selectionToolbar = selBar
        SelectionRelay.on = selBar
        autoArchiveHours = store.object(forKey: "tabs.archiveHours") as? Int ?? 0
        readerTheme = store.string(forKey: "reader.theme").flatMap(ReaderTheme.init) ?? .auto
        readerFont = store.string(forKey: "reader.font").flatMap(ReaderFont.init) ?? .serif
        let storedReaderSize = store.object(forKey: "reader.size") as? Int ?? 18
        readerSize = min(26, max(14, storedReaderSize))
        let flicks = store.bool(forKey: "float.flicks")
        floatFlicks = flicks
        Float.flicks = flicks
        floatsAway = store.bool(forKey: "float.away")
        floatsOnLeave = store.object(forKey: "float.leave") as? Bool ?? true
        installsUpdates = store.object(forKey: Updater.installKey) as? Bool ?? true
        peeksLinks = store.bool(forKey: "links.peek")
        littleLinks = store.bool(forKey: "links.little")
        handoff = store.bool(forKey: "handoff")
        bookmarksBar = store.bool(forKey: "bookmarks.bar")
        let links = store.bool(forKey: "links.show")
        showsLinks = links
        HoveredLink.on = links
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        let vKeys = store.bool(forKey: "video.keys")
        videoKeys = vKeys
        VideoKeys.on = vKeys
        pinLinksOpenTabs = store.bool(forKey: "pins.linksNewTab")
        let fast = store.object(forKey: "pages.120") as? Bool ?? true
        fastPages = fast
        FrameRate.fast = fast
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        if store.object(forKey: "inspector") != nil {
            store.removeObject(forKey: "inspector")
        }
        let corrects = store.bool(forKey: "autocorrect")
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        pageZoom = store.object(forKey: "pageZoom") as? Double ?? 1
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"]
        where store.object(forKey: key) != nil {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "WebAutomaticSpellingCorrectionEnabled") as? Bool != autocorrect {
            defaults.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
        }
        if defaults.object(forKey: "WebAutomaticQuoteSubstitutionEnabled") as? Bool != false {
            defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        }
        if defaults.object(forKey: "WebAutomaticDashSubstitutionEnabled") as? Bool != false {
            defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
        }
    }
}
