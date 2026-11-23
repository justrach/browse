import SwiftUI

/// Five optional steps, with a first question ready to edit at the end.
/// Preferences take effect as they are chosen; leaving setup never sends a prompt.
struct WelcomePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// A test run can open on another page (the welcome.start setting), for
    /// pictures of it.
    @State private var page = Store.testing ? min(4, max(0, Store.settings.integer(forKey: "welcome.start"))) : 0
    @State private var forward = true
    @State private var graffInstalled = false

    // Bringing things over — scanned asynchronously off the main thread when
    // Step 3 opens so WelcomePanel.body never blocks on filesystem I/O.
    @State private var scannedSources = false
    @State private var scanningSources = false
    @State private var sources: [ImportSource] = []
    @State private var lockedSources: Set<String> = []
    @State private var unreadableNotes: [String] = []
    @State private var source: ImportSource?
    @State private var wantsPasswords = true
    @State private var wantsHistory = true
    @State private var wantsBookmarks = true
    @State private var wantsSignIns = true
    @State private var bringing = false
    @State private var brought: String?
    /// True only when an import finished without failures; partial/keychain
    /// failures leave `done = false` so the user can retry immediately.
    @State private var done = false
    @State private var hadFailure = false
    /// What came in from an export file: Safari's zip, or bookmarks.
    @State private var fromFile: String?

    // The default browser & starter draft.
    @State private var isDefault = Links.isDefault
    @State private var asked = false
    @State private var remindShortcuts = false
    @State private var chosenStarter = 0
    @Environment(\.colorScheme) private var scheme

    private static let steps = ["Welcome", "graff", "Import", "Style", "Ready"]
    private let pages = Self.steps.count

    private static let starterPrompts: [(label: String, prompt: String)] = [
        ("Research a topic", "Help me research a topic. Ask me what I want to learn, then help me compare reliable sources."),
        ("Summarize tabs", "Summarize my open tabs and highlight the key takeaways and contradictions."),
        ("Plan a project", "Help me break down a project into milestones, open questions, and next steps."),
    ]

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            Palette.ground.ignoresSafeArea()
            RadialGradient(
                colors: [
                    Palette.accent.opacity(dark ? 0.08 : 0.05),
                    Color.clear,
                ],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Window drag band under the traffic lights (window.isMovable is
            // false across the app so DragStrip moves the window everywhere).
            DragStrip()
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.strip)

            VStack(spacing: 20) {
                progress
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 16)
                            Group {
                                switch page {
                                case 0: welcome
                                case 1: account
                                case 2: bring
                                case 3: hold
                                default: links
                                }
                            }
                            .frame(maxWidth: 580)
                            .padding(.vertical, 8)
                            Spacer(minLength: 16)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollIndicators(.automatic)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .offset(x: Motion.reduced ? 0 : (forward ? 20 : -20)).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                foot
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 24)
        }
        .animation(Motion.glide, value: page)
        .transition(.opacity)
        .onAppear {
            isDefault = Links.isDefault
            if page == 2 && !scannedSources { scanSources() }
        }
        .onChange(of: page) { _, now in
            if now == 2 && !scannedSources { scanSources() }
            if now == pages - 1 { isDefault = Links.isDefault }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = Links.isDefault
        }
        .task {
            if prefs.usesAgent {
                graffInstalled = (await Agent.locate(custom: prefs.agentPath)) != nil
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 24, height: 24)
                Text("Welcome to browse")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("Step \(page + 1) of \(pages)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.wash))
                    .accessibilityLabel("Step \(page + 1) of \(pages): \(Self.steps[page])")
            }
            HStack(spacing: 8) {
                ForEach(Self.steps.indices, id: \.self) { index in
                    Button {
                        guard !bringing else { return }
                        forward = index > page
                        page = index
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule()
                                .fill(index <= page ? Palette.accent : Palette.wash)
                                .frame(height: 3)
                            HStack(spacing: 4) {
                                if index < page {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(Palette.accent)
                                }
                                Text(Self.steps[index])
                                    .font(.system(size: 11.5, weight: index == page ? .semibold : .regular))
                                    .foregroundStyle(index == page ? Palette.ink : Palette.muted)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(bringing)
                    .accessibilityLabel("Step \(index + 1): \(Self.steps[index])")
                    .accessibilityAddTraits(index == page ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - the pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("More room for the web.", "A fast 120 FPS Mac browser with graff built right beside your pages. Read, switch tabs visually, and think without clutter.")
            WelcomeResearchPreview()
            HStack(spacing: 10) {
                welcomeKey("⌘L", "Go anywhere")
                welcomeKey("⌘K", "Sneak-peek tabs")
                welcomeKey("⇧⌘\\", "Tab overview")
                welcomeKey("⌘;", "Open graff")
            }
            Text("Every step is optional, takes effect live, and can be revisited any time from browse › Welcome.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func welcomeKey(_ keys: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(keys)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash.opacity(0.75), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.75)
        )
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Meet graff, built right in.", "Ask about the active page, @-mention any open tab or history, use /summarize or /write, and keep agent tabs neatly grouped.")
            WelcomeAgentSetup(
                browser: browser,
                prefs: prefs,
                installedBinding: $graffInstalled,
                leaveSetup: { finish() }
            )
        }
    }

    /// True when the currently selected browser has at least one applicable
    /// data kind toggled on (ignores `wantsSignIns` on non-Chromium browsers).
    private func hasApplicableSelection(for selected: ImportSource) -> Bool {
        wantsPasswords || wantsBookmarks || wantsHistory || (wantsSignIns && selected.chromium != nil)
    }

    private var bring: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Bring your web over.", "Passwords go straight into your macOS Keychain, bookmarks into the menu, and history into the address bar. Nothing in your old browser changes.")

            if scanningSources && !scannedSources {
                Card {
                    HStack(spacing: 10) {
                        Ring(size: 12)
                        Text("Looking for browsers on this Mac…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
            } else if sources.isEmpty {
                Card {
                    Nothing(unreadableNotes.isEmpty
                        ? "No Chrome, Arc, Brave, Firefox or other browser found on this Mac."
                        : unreadableNotes.joined(separator: "\n"))
                }
            } else {
                let selected = source ?? sources[0]
                let isLocked = lockedSources.contains(selected.id)

                DataFlow(from: selected.name)

                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        if sources.count > 1 {
                            Line("Browser") {
                                Segmented(
                                    options: sources.map { ($0, $0.name) },
                                    selection: Binding(
                                        get: { selected },
                                        set: { next in
                                            source = next
                                            done = false
                                            hadFailure = false
                                            brought = nil
                                        }
                                    )
                                )
                            }
                            Rule()
                        } else {
                            Line("From \(selected.name)", "Detected on this Mac") { EmptyView() }
                            Rule()
                        }
                        if isLocked {
                            Line(
                                "Full Disk Access needed",
                                "macOS protects \(selected.name)'s data folder. Grant browse Full Disk Access in System Settings and this step refreshes automatically."
                            ) {
                                Pill("Full Disk Access…", filled: true) {
                                    _ = browser.unlock(selected) { scanSources() }
                                }
                            }
                        } else {
                            Line("Passwords", "macOS asks once for that browser's keychain key") { Switch(on: $wantsPasswords) }
                            Rule()
                            Line("Bookmarks", "Folders and all, behind the bookmark button") { Switch(on: $wantsBookmarks) }
                            Rule()
                            Line("History", "Up to ten thousand most-visited places") { Switch(on: $wantsHistory) }
                            if selected.chromium != nil {
                                Rule()
                                Line("Sign-ins", "Stay signed in where you were; each profile becomes a space") { Switch(on: $wantsSignIns) }
                            }
                        }
                    }
                }

                if !isLocked {
                    HStack(spacing: 12) {
                        if done {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.safe)
                                Text("Imported")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Palette.wash, in: Capsule())
                        } else {
                            let label = bringing ? "Bringing…" : (hadFailure ? "Try again" : "Bring them in")
                            Big(label, filled: true) { bringAll(from: selected) }
                                .disabled(bringing || !hasApplicableSelection(for: selected))
                            if bringing { Ring(size: 10) }
                        }
                        if let brought {
                            Text(brought)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                    .animation(Motion.settle, value: brought)
                    .animation(Motion.settle, value: done)
                }
            }

            Card {
                Line("From Safari or an exported file", "Safari › File › Export Browsing Data to File… (.zip), or any bookmarks HTML / passwords CSV") {
                    Pill("Choose file…", filled: sources.isEmpty) {
                        browser.importExport { fromFile = $0 }
                    }
                }
                if let fromFile {
                    Rule()
                    Text(fromFile)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var hold: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Make it feel like yours.", "Pick your look, search engine, and where tabs live. Switch layouts any time with ⇧⌘S, or search every option in Settings with ⌘F.")
            HStack(spacing: 12) {
                Way(title: "Sidebar (Arc / Dia)", sidebar: true, chosen: prefs.sidebar, glyph: prefs.glyph, tinted: prefs.sideTint) {
                    withAnimation(Motion.glide) { prefs.sidebar = true }
                }
                Way(title: "Top tab strip", sidebar: false, chosen: !prefs.sidebar, glyph: prefs.glyph, tinted: false) {
                    withAnimation(Motion.glide) { prefs.sidebar = false }
                }
            }
            Card {
                Line("Appearance", "Light, dark, or match macOS — pages follow too") {
                    Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
                }
                Rule()
                Line("Tabs show", "Favicons or single letters on tabs and pins") {
                    Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
                }
                if prefs.sidebar {
                    Rule()
                    Line("Colour the sidebar like the page", "Softly tints the frosted glass frame with the active page") {
                        Switch(on: $prefs.sideTint)
                    }
                }
                Rule()
                Line("Search engine", "Where words typed in the address bar go") {
                    Picker("", selection: $prefs.engine) {
                        ForEach(Engine.allCases.filter { $0 != .custom }) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if prefs.engine == .google {
                    Rule()
                    Line("Google search suggestions", "Optional · autocomplete as you type (never sent in private tabs)") {
                        Switch(on: $prefs.googleSuggestions)
                    }
                }
            }
        }
    }

    private var links: some View {
        let activeStarter = Self.starterPrompts[min(Self.starterPrompts.count - 1, max(0, chosenStarter))]
        return VStack(alignment: .leading, spacing: 18) {
            heading("You're all set.", prefs.usesAgent && graffInstalled
                    ? "Open any site with ⌘L, jump between tabs with ⌘K or ⇧⌘\\, and press ⌘; whenever you want graff beside a page."
                    : "Open any site with ⌘L, jump between tabs with ⌘K or ⇧⌘\\. You can set up graff any time in Settings › Agent.")

            if prefs.usesAgent && graffInstalled {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 7) {
                        GraffMark(size: 16, color: Palette.ink)
                        Text("Try your first prompt in graff")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.starterPrompts.indices, id: \.self) { i in
                            let selected = chosenStarter == i
                            Button {
                                chosenStarter = i
                            } label: {
                                Text(Self.starterPrompts[i].label)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(selected ? Palette.ground : Color.clear, in: Capsule())
                                    .overlay(
                                        Capsule().strokeBorder(selected ? Palette.hairline : Color.clear, lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("“\(activeStarter.prompt)”")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Big("Open draft in graff", filled: true) { finish(openAgent: true, prompt: activeStarter.prompt) }
                        Text("Editable before sending — never sent automatically")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 0.75)
                )
            }

            Card {
                Line(
                    isDefault ? "browse is your default browser" : "Open links in browse",
                    isDefault
                        ? "Links from Mail, Slack, and other apps open right here."
                        : (asked ? "Finish confirming in the macOS prompt, or keep going." : "Make browse your default Mac browser for external links.")
                ) {
                    if isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.safe)
                    } else {
                        Pill("Make default", filled: true) {
                            asked = true
                            Links.becomeDefault { _ in isDefault = Links.isDefault }
                        }
                    }
                }
                Rule()
                Line("Remind me of shortcuts later", "Shown once after you open a page · full guide in Help (⌘/)") {
                    Switch(on: $remindShortcuts)
                }
            }

            HStack(spacing: 10) {
                welcomeKey("⌘T", "New tab")
                welcomeKey("⌃Tab", "Recent tabs")
                welcomeKey("⌘S", "Toggle sidebar")
                welcomeKey("⌘,", "Settings + ⌘F")
            }
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 16) {
            Button("Set up later") { finish() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .help("Finish setup now; reopen it from browse › Welcome")
            Spacer(minLength: 8)
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Big(page < pages - 1 ? "Continue" : "Start browsing", filled: true) {
                if page < pages - 1 { forward = true; page += 1 } else { finish() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .disabled(bringing)
    }

    // MARK: - doing

    /// Scan installed browsers off the main thread so Step 3 opens at 120 FPS
    /// and surfaces macOS 27 Full Disk Access locks immediately.
    private func scanSources() {
        scanningSources = true
        DispatchQueue.global(qos: .userInitiated).async {
            let present = ImportSource.present()
            let shut = Set(present.filter(\.locked).map(\.id))
            if !shut.isEmpty { Browser.registerForFullDiskAccessList() }
            let missing = Chromium.unreadable().map {
                "\($0.source.name) is on this Mac, but nothing of it was found in \($0.looked)."
            }
            DispatchQueue.main.async {
                sources = present
                lockedSources = shut
                unreadableNotes = missing
                if let current = source, !present.contains(current) {
                    source = nil
                }
                if source == nil {
                    source = present.first { !shut.contains($0.id) } ?? present.first
                }
                scanningSources = false
                scannedSources = true
            }
        }
    }

    private func bringAll(from selected: ImportSource) {
        if !browser.unlock(selected, then: { bring(from: selected) }) {
            lockedSources.insert(selected.id)
            brought = "\(selected.name)'s folder needs Full Disk Access for browse. Turned on from here, bringing starts by itself."
        }
    }

    private func bring(from source: ImportSource) {
        bringing = true
        hadFailure = false
        var lines: [String] = []
        var anyFailure = false
        let group = DispatchGroup()
        if wantsPasswords {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try source.read() }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let found):
                        lines.append("\(browser.keep(found)) passwords")
                    case .failure(Chromium.Trouble.noPassphrase):
                        anyFailure = true
                        lines.append("passwords: macOS didn't hand over the key — allow it and try again")
                    case .failure(Mozilla.Trouble.primaryPassword):
                        anyFailure = true
                        lines.append("passwords: \(source.name) has a primary password — export them from it and bring in the CSV")
                    case .failure:
                        anyFailure = true
                        lines.append("passwords: nothing readable")
                    }
                    group.leave()
                }
            }
        }
        if wantsBookmarks {
            lines.append("\(browser.takeBookmarks(from: source).added) bookmarks")
        }
        if wantsSignIns, let chromium = source.chromium {
            group.enter()
            Task {
                lines.append(await browser.takeSignIns(from: chromium))
                group.leave()
            }
        }
        if wantsHistory {
            group.enter()
            browser.takePlaces(from: source) { count in
                lines.append("\(count) places")
                group.leave()
            }
        }
        group.notify(queue: .main) {
            bringing = false
            hadFailure = anyFailure
            done = !anyFailure
            brought = lines.joined(separator: " · ")
            browser.relist()
        }
    }

    private func finish(openAgent: Bool = false, prompt: String? = nil) {
        if remindShortcuts { browser.requestShortcutReminder() }
        prefs.welcomed = true
        withAnimation(Motion.settle) { browser.welcoming = false }
        if openAgent {
            if browser.agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browser.agent.draft = prompt ?? Self.starterPrompts[0].prompt
            }
            if browser.talkOnStage { browser.focusAgent() } else { browser.takeStage() }
        }
    }

    private func heading(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - pieces

    private struct Big: View {
        let title: String
        var filled = false
        let act: () -> Void
        @State private var hovering = false

        init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.filled = filled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(filled ? Palette.onAccent : Palette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(filled ? Palette.accent : (hovering ? Palette.hover : Palette.wash), in: Capsule())
                    .contentShape(Capsule())
            }
            .fixedSize()
            .buttonStyle(TactilePress())
            .onHover { hovering = $0 }
        }
    }

    /// One of the two ways, as a small drawing of the window.
    private struct Way: View {
        let title: String
        let sidebar: Bool
        let chosen: Bool
        let glyph: Glyph
        let tinted: Bool
        let pick: () -> Void
        @State private var hovering = false

        private static let letters = ["G", "W", "Y"]
        private static let icons: [NSImage?] = ["github", "webkit", "youtube"].map { name in
            Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "PreviewFavicons")
                .flatMap { NSImage(contentsOf: $0) }
        }

        private func mark(_ index: Int) -> some View {
            Mark(icon: glyph == .icons ? Way.icons[index] : nil, letter: Way.letters[index], size: 16)
                .frame(width: 20, height: 20)
                // The sample sites' marks include black on transparency; a
                // small white tile lets them read in both looks.
                .background(glyph == .icons ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 5))
        }

        var body: some View {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(sidebar ? (tinted ? Palette.accent.opacity(0.10) : Palette.wash.opacity(0.8)) : Palette.ground)
                        if sidebar {
                            HStack(spacing: 4) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                        .padding(.bottom, 2)
                                    ForEach(0..<3, id: \.self) { i in
                                        HStack(spacing: 5) {
                                            mark(i)
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Palette.faint.opacity(0.7))
                                                .frame(width: 23, height: 4)
                                        }
                                        .padding(.horizontal, 3)
                                        .frame(height: 20)
                                        .background(i == 0 ? Palette.ground.opacity(0.92) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .padding(.leading, 8)
                                .padding(.vertical, 8)
                                .frame(width: 72)

                                // Floating rounded webpage card inside the frosted frame.
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.ground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Palette.hairline, lineWidth: 0.75)
                                    )
                                    .padding(.vertical, 5)
                                    .padding(.trailing, 5)
                            }
                        } else {
                            HStack(spacing: 3) {
                                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                    .padding(.trailing, 6)
                                ForEach(0..<3, id: \.self) { i in
                                    mark(i)
                                        .frame(width: 36, height: 24)
                                        .background(i == 0 ? Palette.wash : Palette.hover, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(8)
                        }
                    }
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    Text(title)
                        .font(.system(size: 13, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chosen ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chosen ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.settle, value: chosen)
            .animation(Motion.quick, value: glyph)
            .animation(Motion.quick, value: tinted)
        }
    }

}
