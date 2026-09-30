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

    // Bringing things over. Nil until one is picked, which means the first:
    // finding them looks through each browser's folders, and as an initial
    // value that ran every time the panel was made, the first window's
    // included, for a page that isn't showing yet.
    @State private var source: ImportSource?
    @State private var wantsPasswords = true
    @State private var wantsHistory = true
    @State private var wantsBookmarks = true
    @State private var wantsSignIns = true
    @State private var bringing = false
    @State private var brought: String?
    /// Brought in, not merely tried: a folder macOS kept shut is tried again.
    @State private var done = false
    /// What came in from an export file: Safari's zip, or bookmarks.
    @State private var fromFile: String?

    // The default browser.
    @State private var isDefault = Links.isDefault
    @State private var asked = false
    @State private var remindShortcuts = false

    private static let steps = ["Welcome", "Codegraff", "Import", "Your browser", "Ready"]
    private let pages = Self.steps.count

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 24) {
                progress
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 24)
                            Group {
                                switch page {
                                case 0: welcome
                                case 1: account
                                case 2: bring
                                case 3: hold
                                default: links
                                }
                            }
                            .frame(maxWidth: 560)
                            .padding(.vertical, 12)
                            Spacer(minLength: 24)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollIndicators(.automatic)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .offset(x: forward ? 20 : -20).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                foot
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .animation(Motion.glide, value: page)
        .transition(.opacity)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 26, height: 26)
                Text("Make yourself at home")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text("\(page + 1) of \(pages)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.muted)
                    .accessibilityLabel("Step \(page + 1) of \(pages): \(Self.steps[page])")
            }
            HStack(spacing: 8) {
                ForEach(Self.steps.indices, id: \.self) { index in
                    Button {
                        forward = index > page
                        page = index
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule()
                                .fill(index <= page ? Palette.accent : Palette.wash)
                                .frame(height: 3)
                            Text(Self.steps[index])
                                .font(.system(size: 11.5, weight: index == page ? .medium : .regular))
                                .foregroundStyle(index == page ? Palette.ink : Palette.muted)
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
        VStack(alignment: .leading, spacing: 24) {
            heading("More room for the web.", "A quiet Mac browser with Codegraff beside your pages. Read, ask a question, and follow the evidence without losing your place.")
            WelcomeResearchPreview()
            HStack(alignment: .top, spacing: 24) {
                welcomeKey("⌘L", "Go somewhere")
                welcomeKey("⌘;", "Open Codegraff")
                welcomeKey(".", "Ask beside a page")
            }
            Text("Set up what matters to you. Every step is optional, and you can revisit this tour from the Browse menu › Welcome.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func welcomeKey(_ keys: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(keys)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("A research companion, when you want one.", "Ask about a page, compare sources, or work through a bigger question. You choose the model and reasoning effort in the chat.")
            WelcomeAgentSetup(browser: browser, prefs: prefs, leaveSetup: { finish() })
        }
    }

    private var bring: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Bring things over.", "Passwords go into your keychain, bookmarks into the menu, and history means the address field already knows where you go. Nothing in the other browser changes.")

            // Found by their folders, not by looking inside them: macOS asks
            // before letting another app read in there, and the question
            // belongs to "Bring them in", not to this page appearing.
            let sources = ImportSource.present()
            if !sources.isEmpty {
                DataFlow(from: (source ?? sources[0]).name)
            }
            if sources.isEmpty {
                let unreadable = Chromium.unreadable()
                Text(unreadable.isEmpty
                     ? "No Chrome, Arc, Brave, Firefox or other browser on this Mac."
                     : unreadable.map { "\($0.source.name) is on this Mac, but nothing of it was found in \($0.looked)." }.joined(separator: "\n"))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if sources.count > 1 {
                        Segmented(
                            options: sources.map { ($0, $0.name) },
                            selection: Binding(get: { source ?? sources[0] }, set: { source = $0; done = false; brought = nil })
                        )
                    } else {
                        Text("From \(sources[0].name)")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    Choice("Passwords", "macOS will ask once for that browser's keychain key", on: $wantsPasswords)
                    Choice("Bookmarks", "Folders and all, behind the bookmark button", on: $wantsBookmarks)
                    Choice("History", "Up to ten thousand places, the ones you go to most first", on: $wantsHistory)
                    if (source ?? sources[0]).chromium != nil {
                        Choice("Sign-ins", "Stay signed in where you were; each profile becomes a space", on: $wantsSignIns)
                    }
                    Text("On macOS 27, Chrome, Brave, Edge and Firefox keep their folders to themselves: browse needs Full Disk Access to bring them in, and says how when you try.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.faint)
                }

                HStack(spacing: 12) {
                    Big(bringing ? "Bringing…" : "Bring them in", filled: true) { bringAll() }
                        .disabled(bringing || done || !(wantsPasswords || wantsHistory || wantsBookmarks || wantsSignIns))
                    if bringing { Ring(size: 10) }
                    if let brought {
                        Text(brought)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.settle, value: brought)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("From Safari: in Safari, File › Export Browsing Data to File…, then choose the zip it makes. A bookmarks file from any browser works too.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Big("Choose an export…", filled: sources.isEmpty) {
                        browser.importExport { fromFile = $0 }
                    }
                    if let fromFile {
                        Text(fromFile)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.settle, value: fromFile)
            }
        }
    }

    private var hold: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Make it feel like yours.", "Choose where your tabs live. Change the layout any time with ⇧⌘S, and find these choices again in Settings.")
            HStack(spacing: 12) {
                Way(title: "Tab strip", sidebar: false, chosen: !prefs.sidebar, glyph: prefs.glyph) {
                    withAnimation(Motion.glide) { prefs.sidebar = false }
                }
                Way(title: "Sidebar", sidebar: true, chosen: prefs.sidebar, glyph: prefs.glyph) {
                    withAnimation(Motion.glide) { prefs.sidebar = true }
                }
            }
            HStack(spacing: 12) {
                Text("Tabs wear")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Divider()
            Choice("Google search suggestions", "Optional · sends search words to Google as you type", on: $prefs.googleSuggestions)
            Text(prefs.engine == .google
                 ? "When enabled, search words go to Google before you press Return. Addresses and searches in private tabs are never sent for suggestions."
                 : "Suggestions work only with Google. Your search engine is \(prefs.engine.name(custom: prefs.customEngine)). Addresses and private searches are never sent for suggestions.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("You're ready.", prefs.usesAgent
                    ? "Open a page with ⌘L. Press . while reading to ask about it, or use ⌘; for a conversation with more room."
                    : "Open a page with ⌘L. Your browser is ready; Codegraff is available whenever you want to enable it in Settings › Agent.")
            if prefs.usesAgent {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try your first research question")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("“Help me research a topic. Ask me what I want to learn, then help me compare reliable sources.”")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Big("Open a draft in Codegraff", filled: true) { finish(openAgent: true) }
                    Text("You can edit the question, choose a model, and send when you're ready. An existing draft is kept.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isDefault ? "checkmark.circle" : "link")
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(isDefault ? "Browse is your default browser" : "Open links here, too")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if !isDefault {
                        Text("Choose Browse for links from Mail, messages and other apps. macOS will ask you to confirm.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Big("Make Browse the default") {
                            asked = true
                            Links.becomeDefault { _ in isDefault = Links.isDefault }
                        }
                        if asked {
                            Text("Finish in the macOS dialog, or carry on without changing it.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 24) {
                welcomeKey("⌘T", "New tab")
                welcomeKey("⌘K", "Find an open tab")
                welcomeKey("⌘,", "Settings")
            }
            Choice("Remind me of shortcuts later", "Once, after you open a page · full guide in Help", on: $remindShortcuts)
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 16) {
            Button("Set up later") { finish() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .help("Finish setup now; reopen it from Browse › Welcome")
            Spacer(minLength: 8)
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            if page > 0, page < pages - 1 {
                Button("Skip this step") { forward = true; page += 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
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

    private func bringAll() {
        guard let source = source ?? ImportSource.present().first else { return }
        if !browser.unlock(source, then: { bring(from: source) }) {
            brought = "\(source.name)'s folder needs Full Disk Access for browse. Turned on from here, bringing starts by itself; if not, reopen browse and try again."
        }
    }

    private func bring(from source: ImportSource) {
        bringing = true
        var lines: [String] = []
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
                        lines.append("passwords: macOS didn't hand over the key — allow it and try again")
                    case .failure(Mozilla.Trouble.primaryPassword):
                        lines.append("passwords: \(source.name) has a primary password — export them from it and bring in the CSV")
                    case .failure:
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
            done = true
            brought = lines.joined(separator: " · ")
            browser.relist()
        }
    }

    private func finish(openAgent: Bool = false) {
        if remindShortcuts { browser.requestShortcutReminder() }
        prefs.welcomed = true
        withAnimation(Motion.settle) { browser.welcoming = false }
        if openAgent {
            if browser.agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browser.agent.draft = "Help me research a topic. Ask me what I want to learn, then help me compare reliable sources."
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
                    .foregroundStyle(filled ? Palette.onAccent : Palette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(filled ? Palette.accent : (hovering ? Palette.hover : Palette.wash), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private struct Choice: View {
        let title: String
        let detail: String
        @Binding var on: Bool

        init(_ title: String, _ detail: String, on: Binding<Bool>) {
            self.title = title
            self.detail = detail
            _on = on
        }

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                }
                Spacer()
                Toggle(title, isOn: $on)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(title)
            }
        }
    }

    /// One of the two ways, as a small drawing of the window.
    private struct Way: View {
        let title: String
        let sidebar: Bool
        let chosen: Bool
        let glyph: Glyph
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
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground)
                        if sidebar {
                            HStack(spacing: 0) {
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
                                        .background(i == 0 ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .padding(8)
                                .frame(width: 72)
                                Rectangle().fill(Palette.hairline).frame(width: 1)
                                Spacer()
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
        }
    }

}
