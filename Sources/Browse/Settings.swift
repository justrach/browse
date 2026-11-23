import SwiftUI

/// Everything there is to set. Pages down the left, one page at a time on
/// the right, each a short list of lines with a hairline between them —
/// nothing to scroll through, nothing to hunt for. The same white and
/// hairline as the rest of the app; the same pill for the page you are on
/// as for the tab you are on.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @State private var isDefault = Links.isDefault
    @State private var page: Page = Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general
    /// The rail's row under the pointer, if any (see `pages`).
    @State private var hovered: Page?
    @FocusState private var searchFocused: Bool
    @Namespace private var glow
    @Environment(\.colorScheme) private var scheme

    private var trimmedQuery: String {
        browser.settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searching: Bool { !trimmedQuery.isEmpty }

    enum Page: String, CaseIterable, Identifiable {
        case general, themes, tabs, shortcuts, extensions, agent, passwords, downloads, privacy, sync, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .themes: return "Themes"
            case .tabs: return "Tabs"
            case .shortcuts: return "Shortcuts"
            case .extensions: return "Extensions"
            case .agent: return "Agent"
            case .passwords: return "Passwords"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .sync: return "Sync"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .themes: return "paintpalette"
            case .tabs: return "rectangle.split.3x1"
            case .shortcuts: return "command"
            case .extensions: return "puzzlepiece.extension"
            case .agent: return "sparkle"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .sync: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    private static let rail: CGFloat = 186
    private static let width: CGFloat = 688
    private static let height: CGFloat = 520

    var body: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(width: SettingsPanel.width, height: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
        .onChange(of: browser.settingsSearchFocusTick) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear {
            browser.settingsSearchQuery = ""
        }
    }

    // MARK: - the rail

    private var pages: some View {
        let dark = scheme == .dark
        return VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 8)

            // Search bar (⌘F focuses from anywhere in Settings).
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("Search", text: $browser.settingsSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = searchMatches.first {
                            jump(to: first)
                        }
                    }
                if !browser.settingsSearchQuery.isEmpty {
                    Button {
                        browser.settingsSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                } else if !searchFocused {
                    Text("⌘F")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.muted.opacity(0.75))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.ground.opacity(dark ? 0.92 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        searchFocused ? Palette.accent.opacity(0.55) : Palette.hairline,
                        lineWidth: searchFocused ? 1 : 0.75
                    )
            )
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            ForEach(Page.allCases) { item in
                PageRow(page: item, on: !searching && page == item, hovering: hovered == item, glow: glow) {
                    browser.settingsSearchQuery = ""
                    page = item
                }
                    // One row under the pointer for the whole rail, not one
                    // flag per row: a row that missed the pointer leaving —
                    // a quick sweep does that — stayed lit beside the one
                    // actually under it.
                    .onHover { over in
                        if over { hovered = item } else if hovered == item { hovered = nil }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: SettingsPanel.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.wash.opacity(0.45), in: Rectangle())
        // Out of the rail altogether: nothing under the pointer.
        .onHover { if !$0 { hovered = nil } }
        .animation(Motion.quick, value: hovered)
        .animation(Motion.quick, value: searchFocused)
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        let hovering: Bool
        /// The hover's own wash, one for the rail, gliding from row to row
        /// after the pointer.
        let glow: Namespace.ID
        let act: () -> Void

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: page.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(page.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background {
                    ZStack {
                        if hovering && !on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Palette.hover)
                                .matchedGeometryEffect(id: "hover", in: glow)
                        }
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                        }
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(searching ? "Search Results" : page.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if searching {
                    let count = searchMatches.count
                    Text(count == 1 ? "1 match" : "\(count) matches")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Palette.wash))
                }
                Spacer()
                Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
            }
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if searching {
                        searchResults
                    } else {
                        switch page {
                        case .general: general
                        case .themes: ThemesPage(browser: browser, prefs: prefs)
                        case .tabs: tabs
                        case .shortcuts: ShortcutsPage(browser: browser)
                        case .extensions: ExtensionsPage(browser: browser)
                        case .agent: AgentPage(browser: browser, prefs: prefs, agent: browser.agent)
                        case .passwords: passwords
                        case .downloads: downloads
                        case .privacy: privacy
                        case .sync: SyncPage(browser: browser, prefs: prefs)
                        case .about: about
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - settings search

    private struct SearchEntry: Identifiable {
        let id: String
        let page: Page
        let title: String
        let detail: String
        let keywords: String
        let badge: String?

        init(_ page: Page, _ title: String, _ detail: String, keywords: String = "", badge: String? = nil) {
            self.id = "\(page.rawValue)::\(title)"
            self.page = page
            self.title = title
            self.detail = detail
            self.keywords = keywords
            self.badge = badge
        }
    }

    private static let catalog: [SearchEntry] = [
        // General
        SearchEntry(.general, "Open links from other apps", "Make browse the default browser on this Mac", keywords: "default browser links mail slack"),
        SearchEntry(.general, "Search with", "Default search engine (Google, DuckDuckGo, Kagi, custom)", keywords: "search engine google duckduckgo kagi custom url"),
        SearchEntry(.general, "Show recent searches", "Offer recent searches in an empty address field", keywords: "omnibox history suggestions"),
        SearchEntry(.general, "Google search suggestions", "Autocomplete suggestions while typing in the address bar", keywords: "autocomplete google search"),
        SearchEntry(.general, "Appearance", "Light, dark, or System appearance", keywords: "dark mode light mode theme color scheme"),
        SearchEntry(.general, "Page zoom", "Default zoom level for websites", keywords: "font size scale text larger smaller"),
        SearchEntry(.general, "Correct spelling as you type", "macOS autocorrect inside web pages", keywords: "spellcheck grammar capitalize"),
        SearchEntry(.general, "Peek at a link with a shift-click", "Preview links in an overlay panel over the current page", keywords: "little arc preview shift click"),
        SearchEntry(.general, "Open links from other apps in a small window", "Little window for quick reading from external apps", keywords: "little window popup external links"),
        SearchEntry(.general, "Handoff", "Continue the active page on iPhone, iPad, or another Mac", keywords: "continuity apple account iphone ipad"),
        SearchEntry(.general, "Show where links go", "Status preview bar at the bottom of the page when hovering links", keywords: "status bar url hover bottom"),
        SearchEntry(.general, "Scroll with the middle button", "Middle-click autoscroll", keywords: "mouse wheel autoscroll windows"),
        SearchEntry(.general, "Pages at 120 Hz", "Smooth 120 FPS ProMotion scrolling and animations", keywords: "120fps promotion refresh rate battery 60hz smooth"),
        SearchEntry(.general, "Flick the floating video to a corner", "Two-finger flick gesture for picture-in-picture video", keywords: "pip picture in picture gesture"),
        SearchEntry(.general, "Float the video when you switch tabs", "Automatic picture-in-picture when leaving a tab", keywords: "pip youtube video float"),
        SearchEntry(.general, "Float the video when you switch apps", "Automatic picture-in-picture when switching applications", keywords: "pip youtube video float background"),
        SearchEntry(.general, "Let a script drive browse", "Local bench automation socket", keywords: "bench automation cli testing socket"),

        // Themes
        SearchEntry(.themes, "Themes", "Pick or create colour themes for light and dark mode", keywords: "color colour palette custom json style"),
        SearchEntry(.themes, "Make one with graff", "Generate a custom browser theme from a description", keywords: "ai theme generator colors"),

        // Tabs
        SearchEntry(.tabs, "Tabs in a sidebar", "Vertical sidebar on the left instead of top tab strip", keywords: "arc dia vertical sidebar layout"),
        SearchEntry(.tabs, "Hide the sidebar until the pointer reaches the edge", "Auto-hide sidebar for full-width reading", keywords: "fold autohide edge peek"),
        SearchEntry(.tabs, "Colour the sidebar like the page", "Tint the frosted sidebar glass with the active page hue", keywords: "color tint glass theme ambient"),
        SearchEntry(.tabs, "Compact top address bar", "Aside-style unified top bar with URL pill and graff toggle", keywords: "header toolbar url bar aside"),
        SearchEntry(.tabs, "Tabs show", "Favicons or letters on tabs and pins", keywords: "icons favicons monogram letters glyph"),
        SearchEntry(.tabs, "Show the bookmarks bar", "Bookmarks row above the page", keywords: "favorites bar folders"),
        SearchEntry(.tabs, "Show how far you've read", "Reading progress fill on the active tab", keywords: "scroll progress indicator"),
        SearchEntry(.tabs, "Sleep tabs you aren't using", "Suspend background tabs to save RAM and battery", keywords: "memory saver suspend hibernate ram"),
        SearchEntry(.tabs, "Memory profile", "Relaxed, Balanced, or Low RAM tab sleeping schedule", keywords: "ram memory relaxed low balanced sleep now"),
        SearchEntry(.tabs, "Spaces", "Separate sets of tabs and profiles switched with ⌃1–⌃9", keywords: "workspaces profiles containers arc"),

        // Extensions
        SearchEntry(.extensions, "Chrome extensions", "Install and manage Chrome Web Store or unpacked extensions", keywords: "addons plugins chrome web store"),
        SearchEntry(.extensions, "Import extensions from another browser", "Bring over Chrome, Arc, or Brave extensions", keywords: "import chrome arc brave"),
        SearchEntry(.extensions, "Allow on private tabs", "Run extensions inside private browsing tabs", keywords: "incognito private extensions"),
        SearchEntry(.extensions, "Load an unpacked extension", "Load a local manifest.json extension folder", keywords: "developer unpacked local folder"),

        // Agent
        SearchEntry(.agent, "graff", "Built-in browser agent and local Harness MCP tools", keywords: "codegraff ai agent assistant mcp harness acp"),
        SearchEntry(.agent, "Ask about selected text", "Right-click any selection to send it to graff", keywords: "selection passage context menu"),
        SearchEntry(.agent, "Task library", "Reusable prompt templates saved on this Mac", keywords: "prompts templates instructions"),
        SearchEntry(.agent, "Keep a draft per tab", "Remember unsent graff drafts independently for each tab", keywords: "drafts tabs composer"),
        SearchEntry(.agent, "Continue in browser", "Access this conversation from another device", keywords: "remote mobile browser chat"),
        SearchEntry(.agent, "Other accounts", "Sign into Codex, Kimi, and other providers via graff login", keywords: "providers models api key login"),

        // Passwords
        SearchEntry(.passwords, "Your passwords", "View saved logins in the macOS Keychain with Touch ID", keywords: "vault logins credentials keychain touch id"),
        SearchEntry(.passwords, "Offer to save passwords", "Prompt to save new logins per site", keywords: "autosave credentials"),
        SearchEntry(.passwords, "Fill in sign-ins", "Autofill saved accounts in login forms", keywords: "autofill login forms"),
        SearchEntry(.passwords, "Offer passkeys", "Touch ID and iCloud Keychain passkeys", keywords: "webauthn fido2 touch id icloud"),
        SearchEntry(.passwords, "Bring yours in (Import)", "Import passwords, bookmarks, history, and sign-ins from Chrome or other browsers", keywords: "import chrome safari arc brave firefox csv html"),

        // Downloads
        SearchEntry(.downloads, "Save to", "Default downloads folder location", keywords: "downloads directory folder path"),
        SearchEntry(.downloads, "Ask where to save each file", "Show save dialog before every download", keywords: "prompt save dialog"),

        // Privacy
        SearchEntry(.privacy, "Block ads and trackers", "Built-in content blocker shield", keywords: "adblock shield trackers ublock content blocker"),
        SearchEntry(.privacy, "Prevent cross-site tracking", "Safari-style tracking prevention and third-party cookie blocking", keywords: "cookies tracking itp privacy"),
        SearchEntry(.privacy, "Camera and microphone", "Reset per-site camera and mic permissions", keywords: "webcam audio permissions media"),
        SearchEntry(.privacy, "Clear history", "Remove visited pages and browsing history", keywords: "delete history clear data"),
        SearchEntry(.privacy, "Cookies and sign-ins", "Sign out of every site and clear site storage", keywords: "logout cookies localstorage clear"),
        SearchEntry(.privacy, "Clear cache", "Remove cached page assets", keywords: "cache storage clear"),

        // Sync
        SearchEntry(.sync, "Sync now", "Sync open tabs, bookmarks, spaces, and settings across Macs", keywords: "icloud cloud sync devices"),
        SearchEntry(.sync, "Add another Mac", "Pair another Mac with your sync code", keywords: "pair device code"),

        // About
        SearchEntry(.about, "Updates", "Check for new browse releases and automatic updates", keywords: "version update appcast changelog"),
        SearchEntry(.about, "Install updates automatically", "Download and apply updates in the background", keywords: "auto update"),
        SearchEntry(.about, "Keyboard shortcuts", "View the full keyboard shortcuts guide", keywords: "hotkeys keybindings help"),
        SearchEntry(.about, "Feedback & Source code", "Send feedback, view GitHub repo, releases, and license", keywords: "github issue bug report license"),
    ]

    private var searchMatches: [SearchEntry] {
        let tokens = trimmedQuery.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let shortcutEntries: [SearchEntry] = BrowserCommand.all.map { cmd in
            let keyText = shortcuts.key(for: cmd.id)?.display
            return SearchEntry(
                .shortcuts,
                cmd.title,
                "\(cmd.section.rawValue) shortcut",
                keywords: "shortcut hotkey keybinding \(cmd.section.rawValue) \(keyText ?? "")",
                badge: keyText
            )
        }

        let pool = Self.catalog + shortcutEntries
        return pool.compactMap { entry -> (entry: SearchEntry, score: Int)? in
            let title = entry.title.lowercased()
            let detail = entry.detail.lowercased()
            let keywords = entry.keywords.lowercased()
            let pageName = entry.page.title.lowercased()
            var score = 0
            for token in tokens {
                if title.hasPrefix(token) {
                    score += 120
                } else if title.contains(token) {
                    score += 85
                } else if pageName.contains(token) {
                    score += 65
                } else if detail.contains(token) {
                    score += 45
                } else if keywords.contains(token) {
                    score += 35
                } else {
                    return nil
                }
            }
            return (entry, score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.entry.title < $1.entry.title
        }
        .prefix(24)
        .map(\.entry)
    }

    private func jump(to entry: SearchEntry) {
        browser.settingsSearchQuery = ""
        searchFocused = false
        withAnimation(Motion.quick) {
            page = entry.page
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let matches = searchMatches
        if matches.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.muted.opacity(0.65))
                Text("No settings match “\(trimmedQuery)”")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.88))
                Text("Try searching for appearance, tabs, 120 Hz, import, privacy, or graff.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 84)
        } else {
            let grouped = Page.allCases.compactMap { section -> (page: Page, items: [SearchEntry])? in
                let items = matches.filter { $0.page == section }
                return items.isEmpty ? nil : (section, items)
            }
            ForEach(grouped, id: \.page.id) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: group.page.icon)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.muted)
                        Text(group.page.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.leading, 4)

                    Card {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                            if idx > 0 { Rule() }
                            SearchResultRow(entry: item) { jump(to: item) }
                        }
                    }
                }
            }
        }
    }

    private struct SearchResultRow: View {
        let entry: SearchEntry
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(entry.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    if let badge = entry.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.ink.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Palette.wash)
                            )
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(hovering ? Palette.ink.opacity(0.75) : Palette.muted.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    // MARK: - general

    private var general: some View {
        Card {
            Line(
                "Open links from other apps",
                isDefault ? "browse is the default browser on this Mac" : "Mail, Slack and the rest still send links elsewhere"
            ) {
                if isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 24)
                } else {
                    Pill("Make default", filled: true) {
                        Links.becomeDefault { worked in
                            isDefault = Links.isDefault
                            browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                        }
                    }
                }
            }
            Rule()
            Line("Search with", searchDetail) {
                Picker("", selection: $prefs.engine) {
                    ForEach(Engine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if prefs.engine == .custom {
                ZStack(alignment: .leading) {
                    if prefs.customEngine.isEmpty {
                        Text("https://example.com/search?q=%s")
                            .foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    TextField("", text: $prefs.customEngine)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }
            Rule()
            Line("Show recent searches", "Offer recent searches in an empty address field; never in private tabs") {
                Switch(on: $prefs.recentSearches)
            }
            Rule()
            Line("Google search suggestions", "When Google is your search engine, send eligible text you type to Google for suggestions. Never in private tabs") {
                Switch(on: $prefs.googleSuggestions)
            }
            Rule()
            Line("Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too") {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line("Page zoom", "Where every site starts. ⌘+ and ⌘− are still remembered for each site.") {
                // The number itself takes it back to 100%.
                StepPill(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
            }
            Rule()
            Line("Correct spelling as you type", "macOS's autocorrect inside pages — the one that capitalises for you") {
                Switch(on: $prefs.autocorrect)
            }
            Rule()
            Line("Peek at a link with a shift-click", "Its page opens in a panel over the one you're reading. Escape puts it away; the other button keeps it as a tab") {
                Switch(on: $prefs.peeksLinks)
            }
            Rule()
            Line("Open links from other apps in a small window", "To read and close, or keep with Open in browse (⌘O)") {
                Switch(on: $prefs.littleLinks)
            }
            Rule()
            Line("Handoff", "Offer the active page to your iPhone, iPad, and other Macs on the same Apple Account (never private tabs or isolated spaces)") {
                Switch(on: $prefs.handoff)
            }
            Rule()
            Line("Show where links go", "Point at a link and its address shows at the bottom of the page") {
                Switch(on: $prefs.showsLinks)
            }
            Rule()
            Line("Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop") {
                Switch(on: $prefs.autoScroll)
            }
            Rule()
            Line("Pages at 120 Hz", "Smooth 120 FPS scrolling and animations on ProMotion displays. Turn off to cap pages near 60 Hz for battery life") {
                Switch(on: $prefs.fastPages)
            }
            Rule()
            Line("Flick the floating video to a corner", "Two fingers on it send it to the corner or edge they point at, instead of pushing it along. Dragging still puts it anywhere") {
                Switch(on: $prefs.floatFlicks)
            }
            Rule()
            Line("Float the video when you switch tabs", "A video playing on YouTube and the like comes out into its floating window when you go to another tab, and back when you return. ⇧⌘P still floats one by hand") {
                Switch(on: $prefs.floatsOnLeave)
            }
            Rule()
            Line("Float the video when you switch apps", "A video playing on the site you're on comes out into its floating window as another app comes to the front, and goes back into its tab when you return") {
                Switch(on: $prefs.floatsAway)
            }
            Rule()
            Line("Let a script drive browse", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench") {
                Switch(on: $prefs.bench)
            }
        }
    }

    private var searchDetail: String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    // MARK: - tabs

    private var tabs: some View {
        Card {
            Line("Tabs in a sidebar", "Down the left instead of across the top. Pull its edge to make it wider; double-click the edge to reset.") {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line("Hide the sidebar until the pointer reaches the edge", "The page takes the whole window; push against its left edge for the tabs. ⌘S keeps them out.") {
                    Switch(on: $prefs.sideHides)
                }
                Rule()
                Line("Colour the sidebar like the page", "It takes on the colour of the page beside it, through the glass, and turns light on a dark page") {
                    Switch(on: $prefs.sideTint)
                }
            }
            Rule()
            Line("Compact top address bar", "Aside-style bar with domain | page title, sidebar toggle, passwords, extensions, and top-right Ask pill when tabs are in the sidebar or folded away") {
                Switch(on: $prefs.compactTopBar)
            }
            Rule()
            Line("Tabs show", "Beside the title, and on a pinned square") {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line("Show the bookmarks bar", "Your bookmarks in a row above the page, folders opening as menus. It folds away with the tabs") {
                Switch(on: $prefs.bookmarksBar)
            }
            Rule()
            Line("Show how far you've read", "The tab you're on fills with grey as you scroll down the page") {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line("Sleep tabs you aren't using", "Background tabs give their WebKit processes back and restore right where you left them. Audio, calls, downloads and unsaved forms stay awake.") {
                Switch(on: $prefs.sleepsTabs)
            }
            if prefs.sleepsTabs {
                let realTabs = (browser.tabs + browser.parkedTabs).filter { !$0.isBlank && !$0.bench }
                let asleepCount = realTabs.filter(\.asleep).count
                let awakeCount = realTabs.count - asleepCount
                let profileDetail: String = {
                    switch prefs.memoryMode {
                    case .relaxed:
                        return "Relaxed: keeps 12 background tabs awake, sleeps extras after 15 min, idle after 2 h"
                    case .balanced:
                        return "Balanced: keeps 6 background tabs awake, sleeps extras after 5 min, idle after 30 min"
                    case .low:
                        return "Low RAM: keeps 3 background tabs awake, sleeps extras after 2 min, idle after 10 min"
                    }
                }()
                Rule(inset: 28)
                Line(
                    "Memory profile",
                    profileDetail
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Segmented(options: Preferences.MemoryMode.allCases.map { ($0, $0.title) }, selection: $prefs.memoryMode)
                        HStack(spacing: 8) {
                            Text(asleepCount > 0 ? "\(awakeCount) awake · \(asleepCount) asleep" : "\(awakeCount) awake")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                                .lineLimit(1)
                            Pill("Sleep now") { browser.sleepInactiveNow() }
                        }
                    }
                }
                .padding(.leading, 14)
            }
            Rule()
            Line("Auto-archive unpinned tabs", "Quietly close untouched unpinned tabs to keep your sidebar clean (recoverable anytime with ⌘⇧T or History)") {
                Segmented(
                    options: [(0, "Never"), (12, "12h"), (24, "24h"), (168, "7d")],
                    selection: $prefs.autoArchiveHours
                )
            }
            Rule()
            Line("Spaces", "Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1–⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first.") {
                Switch(on: $prefs.usesSpaces)
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Search not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID") {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    "Offer passkeys",
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
                        : Passkeys.access == .denied
                        ? "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : "Touch ID or an iCloud passkey, on sites that offer one"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line("Sites never asked", "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line("Bring yours in", "From another browser on this Mac — nothing leaves it") {
                    Pill("Import…") {
                        browser.tuning = false
                        browser.bringingIn = ""
                    }
                }
            }
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        Card {
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            Rule()
            Line("Ask where to save each file") {
                Switch(on: $prefs.asksWhereToSave)
            }
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart the app") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line("Prevent cross-site tracking", "As in Safari. Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome. Private tabs keep it on") {
                    Switch(on: Binding(get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
                }
                Rule()
                Line("Camera and microphone", "What each site was allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
            }
            StatsCard(browser: browser, prefs: prefs)
            Card {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }
    }

    // MARK: - about

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BrandMark().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("browse")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("By Codegraff · WebKit on macOS")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Text("Version \(Updater.version) · build \(String(Updater.build)) · AGPL-3.0")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                Line(versionTitle, versionDetail) { versionControl }
                Rule()
                WebKitLine()
                Rule()
                Line("Install updates automatically", "Checks every 2 hours; when off, installation waits for your choice") {
                    Switch(on: $prefs.installsUpdates)
                }
                Rule()
                Line("Feedback", "Open a feedback draft with this build's details") {
                    Pill("Open draft") { Links.writeFeedback() }
                }
            }

            Card {
                Line("Keyboard shortcuts", "The full guide is also in Help") {
                    Pill("View guide") {
                        browser.tuning = false
                        browser.showShortcuts()
                    }
                }
                Rule()
                Line("Source code", "Browse the project on GitHub") {
                    Pill("View source") { openAbout("https://github.com/justrach/browse") }
                }
                Rule()
                Line("Releases", "Downloads and release notes") {
                    Pill("View releases") { openAbout("https://github.com/justrach/browse/releases") }
                }
                Rule()
                Line("License", "AGPL-3.0; other notices are in the app bundle") {
                    Pill("View license") { openAbout("https://github.com/justrach/browse/blob/main/LICENSE") }
                }
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "Downloading browse \(next.version)"
        case .ready(let next): return "browse \(next.version) ready"
        case .offered(let next), .waiting(let next): return "browse \(next.version) available"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named))) · checks every 2h" }
                ?? "Checks for updates every 2 hours"
        case .fetching:
            return "Downloading and preparing the update"
        case .ready:
            return "Update ready; relaunch to use this version"
        case .offered:
            return "Open the disk image to install manually"
        case .waiting:
            return "Select Install to apply the update"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("You're up to date — browse \(Updater.version)") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered(let next):
            Pill("Download", filled: true) {
                browser.tuning = false
                browser.open(next.dmg, foreground: true)
            }
        case .waiting:
            Pill("Install", filled: true) { updater.install() }
        }
    }

    // MARK: - doing

    private func openAbout(_ address: String) {
        guard let url = URL(string: address) else { return }
        browser.tuning = false
        browser.open(url, foreground: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool
    @Environment(\.settingName) private var name

    var body: some View {
        Toggle(name, isOn: $on)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .tint(Palette.accent)
    }
}

/// A value moved one stop at a time: − and + either side of it, in the same
/// outlined capsule as a pill. Pressing the value itself takes it home.
struct StepPill: View {
    let stops: [Double]
    @Binding var value: Double
    let home: Double
    let label: (Double) -> String

    /// The nearest stop either way — a value between stops, from before
    /// there were stops, still moves to a round one.
    private var below: Double? { stops.last { $0 < value - 0.001 } }
    private var above: Double? { stops.first { $0 > value + 0.001 } }

    var body: some View {
        HStack(spacing: 0) {
            Step(icon: "minus", to: below) { value = $0 }
            Button { value = home } label: {
                Text(label(value))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to \(label(home))")
            Step(icon: "plus", to: above) { value = $0 }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Step: View {
        let icon: String
        let to: Double?
        let act: (Double) -> Void
        @State private var hovering = false

        var body: some View {
            Button { if let to { act(to) } } label: {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(to == nil ? Palette.faint : Palette.ink)
                    .frame(width: 20, height: 20)
                    .background(hovering && to != nil ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(to == nil)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(filled ? Palette.onAccent : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.accent : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .fixedSize()
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
