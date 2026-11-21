import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct BrowseApp: App {
    @StateObject private var browser = Browser()
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @ObservedObject private var icloud = ICloudSync.shared
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    var body: some Scene {
        // Where you left it, at the size you left it. SwiftUI saves a
        // window's frame under its id and puts it back before the window
        // first shows; set by hand once the window was up, it showed at the
        // default size first and then jumped (#202). The id is the name the
        // frame has always been kept under. A test run keeps its own: the
        // name lives in the app's standard defaults, which every copy
        // shares, and a probe resized for a test once changed the size the
        // real window came back at.
        Window("browse", id: Store.world.map { "search (\($0))" } ?? "search") {
            ContentView(browser: browser)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            // One window. Tabs are the only kind of "new" there is.
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { browser.newTab() }
                    .shortcut(shortcuts.key(for: .newTab))
                Button("New Private Tab") { browser.newShyTab() }
                    .shortcut(shortcuts.key(for: .newPrivateTab))
                Button("Reopen Closed Tab") { browser.reopen() }
                    .shortcut(shortcuts.key(for: .reopenTab))
                    .disabled(browser.ghosts.isEmpty)
                Divider()
                Button("Open Address…") { browser.edit() }
                    .shortcut(shortcuts.key(for: .openAddress))
                Divider()
                Button("Close Tab") { if let tab = browser.active { browser.close(tab) } }
                    .shortcut(shortcuts.key(for: .closeTab))
            }
            CommandGroup(replacing: .printItem) {
                Button("Share…") { browser.share() }
                    .shortcut(shortcuts.key(for: .share))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Print…") { browser.printPage() }
                    .shortcut(shortcuts.key(for: .printPage))
                    .disabled(browser.active?.isBlank ?? true)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find on Page…") { browser.openFind() }
                    .shortcut(shortcuts.key(for: .findOnPage))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Find Next") { browser.look(forward: true) }
                    .shortcut(shortcuts.key(for: .findNext))
                    .disabled(!browser.finding)
                Button("Find Previous") { browser.look(forward: false) }
                    .shortcut(shortcuts.key(for: .findPrevious))
                    .disabled(!browser.finding)
            }
            CommandGroup(replacing: .toolbar) {
                Toggle("Show Tabs in Sidebar", isOn: Binding(
                    get: { browser.prefs.sidebar },
                    set: { _ in browser.toggleSidebar() }
                ))
                .shortcut(shortcuts.key(for: .toggleSidebarLayout))
                // Folded away, not moved (see Fold.swift) — the column, or the
                // strip across the top.
                Button(browser.prefs.sidebar
                       ? (browser.folded ? "Show Sidebar" : "Hide Sidebar")
                       : (browser.folded ? "Show Tab Bar" : "Hide Tab Bar")) { browser.toggleFold() }
                    .shortcut(shortcuts.key(for: .toggleFold))
                Picker("Tabs Wear", selection: Binding(
                    get: { browser.prefs.glyph },
                    set: { browser.prefs.glyph = $0 }
                )) {
                    ForEach(Glyph.allCases) { glyph in
                        Text(glyph.title).tag(glyph)
                    }
                }
                Divider()
                Button("Reload Page") { browser.reload() }
                    .shortcut(shortcuts.key(for: .reloadPage))
                Button("Reload Page From Origin") { browser.reload(fromOrigin: true) }
                    .shortcut(shortcuts.key(for: .reloadFromOrigin))
                Button("Reading Mode") { browser.toggleReader() }
                    .shortcut(shortcuts.key(for: .readingMode))
                Button("Float Video") { browser.toggleFloat() }
                    .shortcut(shortcuts.key(for: .floatVideo))
                // Two tabs side by side (Split.swift): this one and the one
                // before it.
                Button(browser.shownSplit != nil ? "Leave Split View" : "Split View") { browser.toggleSplit() }
                    .shortcut(shortcuts.key(for: .toggleSplit))
                    .disabled(browser.shownSplit == nil && !browser.tabs.contains { !$0.isBlank })
                if browser.shownSplit != nil {
                    Button("Swap Sides") { browser.swapSplit() }
                        .shortcut(shortcuts.key(for: .swapSplit))
                }
                Button("Enter Full Screen") { browser.toggleFullScreen() }
                    .shortcut(shortcuts.key(for: .fullScreen))
                Divider()
                Button(browser.consulting && browser.prefs.usesAgent ? "Hide Agent Sidebar" : "Show Agent Sidebar") { browser.toggleAgent() }
                    .shortcut(shortcuts.key(for: .toggleAgent))
                Button(browser.talkOnStage ? "Move Agent to Sidebar" : "Expand Agent Full Screen") { browser.toggleAgentFull() }
                    .shortcut(shortcuts.key(for: .expandAgent))
                Divider()
                Button("Hide Elements…") { browser.toggleHiding() }
                    .shortcut(shortcuts.key(for: .hideElements))
                Button("Hidden on This Site…") { browser.reviewing.toggle() }
                    .shortcut(shortcuts.key(for: .hiddenOnSite))
                Button("Tidy This Page") { browser.tidy() }
                    .shortcut(shortcuts.key(for: .tidyPage))
                    .disabled(browser.tidying || browser.active?.isBlank != false)
                Button("Fill In This Form with Codegraff") {
                    if let tab = browser.active { browser.talk(about: tab, task: Browser.fillTask) }
                }
                .shortcut(shortcuts.key(for: .fillFormWithAgent))
                .disabled(browser.active?.isBlank != false)
                Divider()
                Button("Zoom In") { browser.zoom(by: 1.1) }
                    .shortcut(shortcuts.key(for: .zoomIn))
                Button("Zoom Out") { browser.zoom(by: 1 / 1.1) }
                    .shortcut(shortcuts.key(for: .zoomOut))
                Button("Actual Size") { browser.resetZoom() }
                    .shortcut(shortcuts.key(for: .actualSize))
                Divider()
                // The Web Inspector, on the keys Chrome and Arc use (see Inspector.swift).
                Button("Web Inspector") { browser.toggleInspector() }
                    .shortcut(shortcuts.key(for: .webInspector))
                Button("JavaScript Console") { browser.showConsole() }
                    .shortcut(shortcuts.key(for: .jsConsole))
                Button("Inspect Element") { browser.inspectElement() }
                    .shortcut(shortcuts.key(for: .inspectElement))
            }
            CommandMenu("Tabs") {
                Button("Back") { browser.back() }
                    .shortcut(shortcuts.key(for: .back))
                    .disabled(browser.active?.canGoBack != true)
                Button("Forward") { browser.forward() }
                    .shortcut(shortcuts.key(for: .forward))
                    .disabled(browser.active?.canGoForward != true)
                Divider()
                Button("Next Tab") { browser.step(1) }
                    .shortcut(shortcuts.key(for: .nextTab))
                Button("Previous Tab") { browser.step(-1) }
                    .shortcut(shortcuts.key(for: .previousTab))
                Button("Search Tabs…") { browser.summon() }
                    .shortcut(shortcuts.key(for: .searchTabs))
                Divider()
                if let tab = browser.active {
                    if tab.pin == nil {
                        Button("Pin Tab") { browser.pin(tab) }
                            .shortcut(shortcuts.key(for: .pinTab))
                            .disabled(tab.isBlank)
                    } else {
                        Button("Change Letter") { browser.editLetter(tab) }
                        Button("Unpin Tab") { browser.unpin(tab) }
                            .shortcut(shortcuts.key(for: .pinTab))
                    }
                }
                Button("Rename Tab") { if let tab = browser.active { browser.beginTabRename(tab) } }
                    .shortcut(shortcuts.key(for: .renameTab))
                    .disabled(browser.active == nil)
                Button("Duplicate Tab") { browser.duplicate() }
                    .shortcut(shortcuts.key(for: .duplicateTab))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Copy Address") { browser.copyAddress() }
                    .shortcut(shortcuts.key(for: .copyAddress))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
                    .shortcut(shortcuts.key(for: .copyMarkdownLink))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Paste and Go") { browser.pasteAndGo() }
                    .shortcut(shortcuts.key(for: .pasteAndGo))
                Divider()
                Button("Close Other Tabs") { if let tab = browser.active { browser.closeOthers(but: tab) } }
                    .shortcut(shortcuts.key(for: .closeOtherTabs))
                    .disabled(browser.tabs.count < 2)
                Button("Stop Sound in Tab") { browser.pauseMedia() }
                    .shortcut(shortcuts.key(for: .stopMedia))
            }
            CommandMenu("Bookmarks") {
                Button("Add This Page") { browser.bookmarkCurrent() }
                    .shortcut(shortcuts.key(for: .bookmarkPage))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Show Bookmarks…") { browser.bookmarking = true }
                    .shortcut(shortcuts.key(for: .showBookmarks))
                Toggle("Show Bookmarks Bar", isOn: Binding(
                    get: { browser.prefs.bookmarksBar },
                    set: { on in withAnimation(Motion.glide) { browser.prefs.bookmarksBar = on } }
                ))
                .shortcut(shortcuts.key(for: .toggleBookmarksBar))
                // The bookmarks themselves follow, put in by AppKit (see
                // BookmarkMenu in Bookmarks.swift).
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
                        }
                    }
                }
                if !browser.ghosts.isEmpty {
                    Section("Recently Closed") {
                        ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                            Button {
                                browser.reopen(ghost)
                            } label: {
                                MenuLine(title: ghost.label, url: ghost.url)
                            }
                        }
                    }
                }
                if icloud.on, !icloud.devices.isEmpty {
                    Section("Tabs on Your Other Devices") {
                        ForEach(icloud.devices, id: \.id) { device in
                            Menu(ICloudSync.title(device.tabs)) {
                                ForEach(device.tabs.tabs, id: \.self) { page in
                                    if let url = URL(string: page.url) {
                                        Button {
                                            browser.open(url, foreground: true)
                                        } label: {
                                            MenuLine(
                                                title: page.title.isEmpty ? Address.pretty(url) : page.title,
                                                url: url
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Show History…") { browser.recalling = true }
                    .shortcut(shortcuts.key(for: .showHistory))
                Button("Downloads…") { browser.hoarding = true }
                    .shortcut(shortcuts.key(for: .showDownloads))
                Divider()
                Button("Clear Browsing Data…") { browser.recallMode = .clearing }
                    .shortcut(shortcuts.key(for: .clearData))
                Button("Clear History") { browser.clearHistory() }
                    .shortcut(shortcuts.key(for: .clearHistory))
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") { browser.tuning = true }
                    .shortcut(shortcuts.key(for: .settings))
                Button("Welcome…") { browser.welcoming = true }
                    .shortcut(shortcuts.key(for: .welcome))
                Button("Passwords…") { browser.managing = true }
                    .shortcut(shortcuts.key(for: .passwords))
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") { browser.showShortcuts() }
                    .shortcut(shortcuts.key(for: .showShortcuts))
                Button("Send Feedback…") { Links.writeFeedback() }
            }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// The base a sheet draws on, and the reason a panel is legible over a page
/// that has hidden its own cursor.
///
/// WebKit turns `cursor: none` into an AppKit cursor rect over the whole web
/// view. SwiftUI panels layered on top add no rect of their own, so when the
/// pointer crosses from the page into a sheet the invisible rect still wins,
/// and the sheet reads as empty air. This gives the sheet one arrow-sized
/// rect to win with, frontmost because its NSView sits above the web view
/// (a sheet is drawn by `.overlay { panels }` on `ContentView.body`).
private struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorGroundView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorGroundView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Re-arm the rect each time this view joins a window or changes size, so
    // AppKit notices it even if the pointer has not moved since the sheet
    // appeared. Without this the arrow only shows after a twitch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

struct ContentView: View {
    @ObservedObject var browser: Browser
    /// Each theme put on (Theme.swift). What the window draws is built again
    /// once for it — the pages and the window's own set-up are kept.
    @ObservedObject private var themes = ThemeClock.shared

    @State private var keys: Any?
    @State private var window: NSWindow?
    @State private var resting: RestingLights?
    /// The room the page leaves for the column and the strip, set without
    /// animation (see `make(room:after:)`); nil only before the window is up.
    @State private var room: CGSize?
    @State private var roomTicket = 0


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: .topLeading) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            (browser.active?.immersed == true ? Color.black : Palette.ground)

            // One stage, always. It starts beside the column and under the
            // strip, not behind them — a page sliding beneath floating chrome
            // is a browser showing off, and it costs a compositing pass.
            //
            // When the column or the strip comes or goes, the page slides with
            // it and is resized once, not on every frame of the slide: laid out
            // again thirty times a second, the page juddered along its right
            // edge and overshot the window with the spring (see `room`).
            stage
                .padding(.leading, roomed.width)
                .padding(.top, roomed.height)
                .offset(x: chrome.width - roomed.width, y: chrome.height - roomed.height)

            // The column of tabs, in the way that has one. It takes the full
            // height, so the traffic lights sit in its own corner rather than
            // over the page.
            if sidebar {
                SideBar(browser: browser, prefs: browser.prefs)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .leading))
            }

            if !browser.prefs.sidebar, !browser.folded, browser.active?.immersed != true {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if asideBarShown {
                AsideBar(browser: browser, sidebarOpen: sidebar)
                    .padding(.leading, chrome.width)
                    .transition(.opacity)
            }

            // The bookmarks bar, under the strip or beside the column's top.
            if barShown {
                BookmarksBar(browser: browser, bookmarks: browser.bookmarks)
                    .padding(.leading, chrome.width)
                    .padding(.top, band)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(Motion.glide, value: browser.prefs.sidebar)
        .animation(Motion.glide, value: consulting)
        .animation(Motion.glide, value: browser.agentFull)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
        .onAppear { if room == nil { room = chrome } }
        .onChange(of: chrome) { old, new in make(room: new, after: old) }
    }

    /// The page, or Codegraff's talk filling the stage — or the page with the
    /// talk in a column beside it, so what it's about stays in view (see
    /// Agent.swift).
    private var stage: some View {
        HStack(spacing: 0) {
            if consulting && browser.agentFull {
                AgentColumn(browser: browser, agent: browser.agent, prefs: browser.prefs, full: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else {
                page
                    // A tab carried out of the sidebar: the half it would
                    // open on (Split.swift).
                    .overlay { SplitDropZone(browser: browser) }
                if consulting {
                    AgentColumn(browser: browser, agent: browser.agent, prefs: browser.prefs)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(Motion.gentle, value: browser.agentFull)
    }

    @ViewBuilder
    private var page: some View {
        if let pair = browser.shownSplit {
            // Two tabs side by side (Split.swift). StageView lives directly in
            // AppKit; SwiftUI only supplies overlays for Find, links and forms.
            SplitStage(browser: browser, left: pair.left, right: pair.right) { tab in
                paneOverlays(tab)
            }
            .transition(.opacity)
        } else if let tab = browser.active {
            pane(tab)
        } else {
            Palette.ground
        }
    }

    /// A tab's page, with what goes over the page in front: the link under
    /// the pointer, Find, the offer to fill a form, saved sign-ins.
    private func pane(_ tab: Tab, corner: CGFloat = 0) -> some View {
        Page(tab: tab, corner: corner)
            .overlay { paneOverlays(tab, includePageOverlays: false) }
    }

    @ViewBuilder
    private func paneOverlays(_ tab: Tab, includePageOverlays: Bool = true) -> some View {
        let front = tab.id == browser.activeID
        ZStack {
            if includePageOverlays { PageOverlays(tab: tab) }
            if front, browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
        }
        .overlay(alignment: .topTrailing) {
            if front, browser.finding {
                FindBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // A form on the page: Codegraff offered to fill it in.
        .overlay(alignment: .bottomTrailing) {
            if front { FormPill(browser: browser, tab: tab) }
        }
        .overlay(alignment: .topLeading) {
            if let asked = browser.suggesting, asked.tab == tab.id {
                AccountList(browser: browser, asked: asked)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: browser.suggesting)
    }

    /// What the column and the strip take from the page right now: animated
    /// as they come and go.
    private var chrome: CGSize {
        CGSize(width: sidebar ? browser.prefs.sideWidth : 0, height: band + (barShown ? BookmarksBar.height : 0))
    }

    /// The bookmarks bar is up: asked for, there are bookmarks, and the tabs
    /// aren't folded away or under a video filling the screen.
    private var barShown: Bool {
        browser.prefs.bookmarksBar && !browser.bookmarks.isEmpty && !browser.folded
            && browser.active?.immersed != true
    }

    /// The room the page is laid out to leave them, which is not animated.
    private var roomed: CGSize { room ?? chrome }

    /// Chrome going away gives the page its room at once, the page sliding
    /// out from under it at its new size. Chrome arriving slides over a page
    /// still at its old size, which gives up the room once the slide is over.
    /// A column being dragged wider or narrower is followed as it goes.
    private func make(room new: CGSize, after old: CGSize) {
        let now = roomed
        let arriving = (old.width == 0 && new.width > 0, old.height == 0 && new.height > 0)
        var at = now
        if !arriving.0 { at.width = new.width }
        if !arriving.1 { at.height = new.height }
        roomTicket += 1
        var still = Transaction()
        still.disablesAnimations = true
        // With Reduce Motion on, nothing slides: the page takes its new room
        // with the chrome, not after a slide that isn't there.
        withTransaction(still) { room = Motion.reduced ? new : at }
        guard !Motion.reduced, arriving.0 || arriving.1 else { return }
        let ticket = roomTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard ticket == roomTicket else { return }
            withTransaction(still) { room = chrome }
        }
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            announcement
            ConnectPill()
            if let ask = browser.asking {
                captureAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.offering {
                keepAsking(offer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: browser.asking)
        .animation(Motion.settle, value: browser.offering)
    }

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        // The blank tab's field stands in the middle of the stage — where the
        // chat's own field takes its place when the talk fills it — so it
        // stands down there. One raised by ⌘L or ⌘K is still welcome over.
        if !browser.welcoming, !browser.tuning, browser.fieldShowing, browser.editing || !(consulting && browser.agentFull) {
            Omnibox(browser: browser, over: !(browser.active?.isBlank ?? true))
                // Centred on the page, not on the window. The column of tabs
                // is not what the field is standing over, and dimming it along
                // with the page says otherwise.
                .padding(.leading, (sidebar ? browser.prefs.sideWidth : 0) + otherHalf.leading)
                .padding(.trailing, (consulting && !browser.agentFull ? browser.prefs.agentWidth : 0) + otherHalf.trailing)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    /// In a split, the field stands over the half in front — the empty
    /// side ⌘D just opened, say — not across both pages.
    private var otherHalf: (leading: CGFloat, trailing: CGFloat) {
        guard let pair = browser.shownSplit, let split = browser.split else { return (0, 0) }
        let width = browser.stageFrame.width
        let usable = max(1, width - Split.gap * 3)
        let left = Split.gap * 1.5 + usable * min(0.8, max(0.2, split.fraction))
        return pair.left.id == browser.activeID ? (0, width - left) : (left, 0)
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser) } close: { browser.recalling = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot) }
                close: { browser.hoarding = false }
        }
        if browser.tuning {
            sheet { SettingsPanel(browser: browser, prefs: browser.prefs) }
                close: { browser.tuning = false }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
        if browser.showingShortcuts {
            sheet { ShortcutGuide(browser: browser) }
                close: { browser.showingShortcuts = false }
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser) } close: { browser.managing = false }
        }
        if browser.bringingIn != nil {
            sheet { ImportPanel(browser: browser) } close: { browser.bringingIn = nil }
        }
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, Metrics.strip + 8)
                    .padding(.trailing, 14 + (consulting && !browser.agentFull ? browser.prefs.agentWidth : 0))
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    var body: some View {
        window_
            .id(themes.tick)
            .accessibilityHidden(browser.welcoming || browser.tuning)
            .disabled(browser.welcoming || browser.tuning)
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: .leading) { Fold(browser: browser, prefs: browser.prefs).id(themes.tick) }
            .overlay(alignment: .bottom) { bars.id(themes.tick) }
            .overlay {
                // Over the page only: the column, the strip and the bookmarks
                // bar stay as they are, uncovered and in reach.
                PeekLayer(browser: browser)
                    .padding(.leading, chrome.width)
                    .padding(.top, chrome.height)
                    // From the window's own top edge, as the page is:
                    // the title bar's band is page too.
                    .ignoresSafeArea()
            }
            .overlay { field.id(themes.tick) }
            .overlay(alignment: .top) {
                if browser.shortcutReminder, !browser.welcoming {
                    ShortcutReminder(
                        show: { browser.showShortcuts() },
                        dismiss: { browser.shortcutReminder = false }
                    )
                    .padding(.top, Metrics.strip + 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay { panels.id(themes.tick) }
            // The field comes on its spring, and goes quickly: once Return
            // is pressed the page is on its way, and the field is not what
            // there is to watch.
            .animation(browser.fieldShowing ? Motion.settle : Motion.quick, value: browser.fieldShowing)
            .background {
                ZStack {
                    WindowSetup { window = $0; dress($0) }
                    if let tab = browser.active {
                        Handoff(tab: tab, prefs: browser.prefs, window: window).id(tab.id)
                    }
                }
                .onChange(of: browser.activeID) { _, id in
                    if id == nil, let window { Handoff.offer(nil, in: window) }
                }
            }
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                measureLights()
                resting?.isHidden = false
                // Only the window you were in, or every window's video would come.
                browser.appLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window, (note.object as? NSWindow) === window { Browser.front = browser }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
                browser.appBack()
            }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async { browser.askFocus() }
                } else {
                    handBack()
                }
            }
            .onChange(of: browser.activeID) { _, _ in handBack() }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.shortcutReminder)
            .animation(Motion.settle, value: browser.showingShortcuts)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.bringingIn != nil)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
            BookmarkMenu.shared.start(for: browser)
            // Anonymous stats, if they have been switched on (Stats.swift).
            Stats.shared.start(for: browser)
            Sync.shared.start(for: browser)
            ICloudSync.shared.attach(browser: browser)
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard let web = browser.active?.web, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A page asking to see or hear you. Named by the site, in its own words,
    /// with the answer remembered so it is asked once and not every call.
    private func captureAsking(_ ask: Browser.CaptureAsk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ask.wants == "microphone" ? "mic" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text("\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { browser.allowCapture() } label: {
                Text("Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { browser.denyCapture() } label: {
                Text("Don't allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    /// Offered once, answered once. The password is never shown back to you —
    /// there is nothing to be learned from reading your own password.
    private func keepAsking(_ offer: Browser.Offer) -> some View {
        let login = offer.login
        return HStack(spacing: 12) {
            Text(offer.changed
                 ? "Update the password for \(login.user) on \(login.host)?"
                 : (login.user.isEmpty
                    ? "Save this password for \(login.host)?"
                    : "Save the password for \(login.user) on \(login.host)?"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button(offer.changed ? "Update" : "Save") { browser.keepOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Not now") { browser.dropOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if !offer.changed {
                Button("Never here") { browser.neverOffer() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }


    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    private func sheet<Panel: View>(
        @ViewBuilder _ panel: () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        ZStack {
            // The floor owns the cursor; see CursorGround.
            CursorGround()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// True while Codegraff's column is showing: opened, still turned on, and
    /// not behind a page that has taken the whole screen.
    private var consulting: Bool {
        browser.consulting && browser.prefs.usesAgent && browser.active?.immersed != true
    }

    /// True while the tabs are down the left, and not folded away (see Fold.swift).
    private var sidebar: Bool {
        browser.prefs.sidebar && !browser.folded && browser.active?.immersed != true
    }

    /// True when the compact Aside-style top bar is showing (tabs in sidebar
    /// or folded away, and not in full-screen video).
    private var asideBarShown: Bool {
        browser.prefs.compactTopBar
            && (browser.prefs.sidebar || browser.folded)
            && browser.active?.immersed != true
    }

    /// The column has its own corner for the lights; the top strip or Aside
    /// address bar takes a band across the top of the page.
    private var band: CGFloat {
        guard browser.active?.immersed != true else { return 0 }
        if asideBarShown { return Metrics.strip }
        // Folded without the compact top bar: the page takes the full height.
        return browser.prefs.sidebar || browser.folded ? 0 : Metrics.strip
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    private func measureLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    private func dress(_ window: NSWindow) {
        Links.window = window
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Palette.NS.ground
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead.
        window.isMovable = false

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        guard keys == nil else { return }
        HotKey.pressed = { browser.summonFromElsewhere() }
        ShortcutStore.shared.applyGlobalHotKey()
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else {
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            return take(event) ? nil : event
        }
        ContentView.keyHook = { event in take(event) ? nil : event }
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path.
    static var keyHook: ((NSEvent) -> NSEvent?)?

    /// The last key handed to the page before Search acted on it (see
    /// `pageFirst`): if WebKit sends it back unused, it is Search's.
    private static var passed: NSEvent?

    /// A key a page may want for itself — ⌘K in Slack, ⌘F in a Google Doc,
    /// ⌘S in an editor — goes to the page first, as it does in Chrome, and is
    /// Search's only if the page leaves it unused: WebKit then sends the same
    /// event back through the app, and it comes here a second time. Only
    /// while the page has the keyboard; in the address field or a panel,
    /// Search's keys are Search's. The keys that make and close tabs and move
    /// between them stay Search's first, as Chrome keeps them its own.
    ///
    /// ⌘K is always Search's, on every page: the way to any open page is
    /// the one key that must never be taken (Drice; #238). Slack, X, GitHub
    /// and ChatGPT use it themselves, and given it first they kept it.
    /// ⌘; belongs to Codegraff too, including while a page editor has focus.
    ///
    /// ⌘← and ⌘→ are Search's too while nothing is being typed: WebKit takes
    /// them to scroll the page sideways and never hands them back, so
    /// passing them on left them dead for going back and forward (#324).
    private func pageFirst(_ event: NSEvent, alwaysOurs: Bool) -> Bool {
        guard !alwaysOurs, event.window?.firstResponder is PageView else { return false }
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            return false
        }
        ContentView.passed = event
        return true
    }

    /// Whether the caret is in something editable: the address field or a
    /// panel's, or a text box on the page. The page's own word on typing
    /// misses a click straight into a frame and never reaches into another
    /// site's, such as an embedded comment box; the web view has an input
    /// context while the caret is in something editable, in any frame.
    private func caretIn(_ event: NSEvent) -> Bool {
        event.window?.firstResponder is NSTextView || browser.active?.typing == true
            || browser.active?.built?.inputContext != nil
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // While recording a custom shortcut in Settings › Shortcuts, let the recorder have every key.
        if ShortcutStore.shared.recording { return false }
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // A period while reading opens the enabled agent beside the page.
        // Editors, including those in cross-origin frames, keep punctuation.
        if event.characters == ".", flags.isDisjoint(with: [.command, .option, .control, .shift]),
           !event.isARepeat, browser.prefs.usesAgent, !browser.editing, browser.editingTab == nil,
           event.window?.firstResponder is PageView,
           event.window?.firstResponder === browser.active?.built,
           browser.active?.immersed != true, !caretIn(event) {
            browser.talkToColumn()
            return true
        }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.peekTab != nil {
                browser.closePeek()
                return true
            }
            if browser.makingSpace {
                withAnimation(Motion.glide) { browser.makingSpace = false }
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.showingShortcuts {
                browser.showingShortcuts = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.bringingIn != nil {
                browser.bringingIn = nil
                return true
            }
            if browser.recalling {
                browser.recalling = false
                return true
            }
            if browser.hoarding {
                browser.hoarding = false
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // One step at a time: the list first, then the field.
            if browser.picked != nil {
                browser.picked = nil
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the row and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that.
        //
        // While an address is being typed, the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option) {
            if flags.contains(.control) {
                browser.step(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if browser.editingTab != nil { return true }
            if browser.fieldShowing, !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        // ⌃1–⌃9 go to that space, when there are spaces — by the key, as
        // ⌘1–⌘9 are below, so the top row works on every layout.
        if browser.prefs.usesSpaces, flags.contains(.control),
           flags.isDisjoint(with: [.command, .option, .shift]),
           let number = ContentView.digits[event.keyCode], number > 0 {
            browser.switchSpace(index: number - 1)
            return true
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, unless
        // the user bound that key to a browser command in Settings › Shortcuts.
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           let combo = KeyCombo(event: event), ShortcutStore.shared.command(for: combo) == nil,
           Extensions.shared.take(event) {
            return true
        }

        let shifted = flags.contains(.shift)

        // ⌘↩ in the address field: the words go to Codegraff, not to a page.
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
           event.keyCode == 36, browser.fieldShowing {
            browser.ask(browser.typed)
            return true
        }

        // ⌘1 through ⌘9, by the key rather than the character it types (AZERTY, etc.).
        if flags.contains(.command), !shifted, !flags.contains(.option), !flags.contains(.control),
           let number = ContentView.digits[event.keyCode], number > 0 {
            browser.select(index: number == 9 ? browser.tabs.count - 1 : number - 1)
            return true
        }

        // ⌘Z while pointing to hide elements undoes the last veil.
        if flags.contains(.command), !shifted, !flags.contains(.option), !flags.contains(.control),
           key == "z", browser.veiling {
            browser.undoHiding()
            return true
        }

        // Custom and default shortcuts from ShortcutStore.
        if let combo = KeyCombo(event: event), combo.isUsable,
           let command = ShortcutStore.shared.command(for: combo) {
            if combo.movesCaret, caretIn(event) { return false }
            if pageFirst(event, alwaysOurs: command.alwaysOurs) { return false }
            return perform(command.id, event: event)
        }

        // ⌘← and ⌘→, for hands that never learned the brackets.
        if flags.contains(.command), !shifted, !flags.contains(.option), !flags.contains(.control),
           !caretIn(event) {
            if event.keyCode == 123 { browser.back(); return true }
            if event.keyCode == 124 { browser.forward(); return true }
        }
        return false
    }

    private func perform(_ id: CommandID, event: NSEvent) -> Bool {
        switch id {
        case .newTab:
            browser.newTab()
        case .newPrivateTab:
            browser.newShyTab()
        case .reopenTab:
            browser.reopen()
        case .openAddress:
            browser.edit()
        case .closeTab:
            if browser.peekTab != nil {
                browser.closePeek()
            } else if let tab = browser.active {
                browser.close(tab)
            }
        case .share:
            browser.share()
        case .printPage:
            browser.printPage()
        case .findOnPage:
            browser.openFind()
        case .findNext:
            browser.look(forward: true)
        case .findPrevious:
            browser.look(forward: false)
        case .toggleSidebarLayout:
            browser.toggleSidebar()
        case .toggleFold:
            browser.toggleFold()
        case .reloadPage:
            browser.reload()
        case .reloadFromOrigin:
            browser.reload(fromOrigin: true)
        case .readingMode:
            browser.toggleReader()
        case .floatVideo:
            browser.toggleFloat()
        case .toggleSplit:
            browser.toggleSplit()
        case .swapSplit:
            if browser.shownSplit != nil { browser.swapSplit() }
        case .fullScreen:
            browser.toggleFullScreen()
        case .hideElements:
            browser.toggleHiding()
        case .hiddenOnSite:
            browser.reviewing.toggle()
        case .tidyPage:
            browser.tidy()
        case .zoomIn:
            browser.zoom(by: 1.1)
        case .zoomOut:
            browser.zoom(by: 1 / 1.1)
        case .actualSize:
            browser.resetZoom()
        case .webInspector:
            browser.toggleInspector()
        case .jsConsole:
            browser.showConsole()
        case .inspectElement:
            browser.inspectElement()
        case .toggleAgent:
            browser.toggleAgent()
        case .expandAgent:
            browser.toggleAgentFull()
        case .fillFormWithAgent:
            if let tab = browser.active, !tab.isBlank { browser.talk(about: tab, task: Browser.fillTask) }
        case .back:
            browser.back()
        case .forward:
            browser.forward()
        case .nextTab:
            browser.step(1)
        case .previousTab:
            browser.step(-1)
        case .searchTabs:
            if browser.editing, !browser.offers.isEmpty {
                browser.stepSummon()
            } else {
                browser.summon()
            }
        case .pinTab:
            browser.togglePin()
        case .renameTab:
            if let tab = browser.active { browser.beginTabRename(tab) }
        case .duplicateTab:
            browser.duplicate()
        case .copyAddress:
            browser.copyAddress()
        case .copyMarkdownLink:
            browser.copyMarkdownLink()
        case .pasteAndGo:
            // In a text field ⇧⌘V is paste without formatting; only Paste and Go when not typing.
            if browser.active?.typing == true || browser.active?.built?.inputContext != nil
                || browser.editing || event.window?.firstResponder is NSTextView {
                _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            } else {
                browser.pasteAndGo()
            }
        case .closeOtherTabs:
            if let tab = browser.active { browser.closeOthers(but: tab) }
        case .stopMedia:
            browser.pauseMedia()
        case .bookmarkPage:
            browser.bookmarkCurrent()
        case .showBookmarks:
            browser.bookmarking.toggle()
        case .toggleBookmarksBar:
            withAnimation(Motion.glide) { browser.prefs.bookmarksBar.toggle() }
        case .showHistory:
            browser.recalling.toggle()
        case .showDownloads:
            browser.hoarding.toggle()
        case .clearData:
            browser.recallMode = .clearing
        case .clearHistory:
            browser.clearHistory()
        case .settings:
            browser.tuning.toggle()
        case .passwords:
            browser.managing.toggle()
        case .showShortcuts:
            browser.showingShortcuts.toggle()
        case .welcome:
            browser.welcoming.toggle()
        }
        return true
    }
}
