import SwiftUI

/// The first time. Six short pages over the window, in the app's own
/// language: what this is, signing in to Codegraff, what to bring over, how
/// to hold it, what Codegraff does on a page, and whether links from other
/// apps should come here. Nothing is asked twice, and every
/// page can be skipped.
struct WelcomePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// A test run can open on another page (the welcome.start setting), for
    /// pictures of it.
    @State private var page = Store.testing ? Store.settings.integer(forKey: "welcome.start") : 0
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

    private let pages = 6

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    switch page {
                    case 0: welcome
                    case 1: account
                    case 2: bring
                    case 3: hold
                    case 4: codegraff
                    default: links
                    }
                }
                .frame(maxWidth: 520)
                .id(page)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                    removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                ))
                Spacer(minLength: 0)
                foot
            }
            .padding(40)
        }
        .animation(Motion.glide, value: page)
        .transition(.opacity)
    }

    // MARK: - the pages

    private var welcome: some View {
        VStack(spacing: 22) {
            Plate(size: 72)
            VStack(spacing: 10) {
                Text("browse")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("A browser with nothing in the way. Four megabytes, the engine already in your Mac, and as little around the page as we could manage.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Sign in with Codegraff.", "One account keeps your bookmarks, history and themes the same on every Mac, sealed so only your Macs can read them — and lets Codegraff work beside the page. Skip it if you like; it's in Settings whenever you want it.")
            AccountCard(browser: browser, inline: true)
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
            heading("Two ways to hold it.", "Titles across the top, or down the side. The grey slides to the tab you pick either way, and you can change your mind with ⇧⌘S.")
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
        }
    }

    /// Codegraff at work on the page you're on, shown once so it's known:
    /// the form pill as it looks on a page, and a line each for the rest.
    private var codegraff: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Codegraff, on the page you're on.", "Beside the page when you want it, out of the way when you don't. On a page it doesn't submit, pay or send anything unless you ask it to.")
            // The pill as a page with a form shows it, drawn, not pressable.
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Fill in with Codegraff")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(Capsule().fill(Palette.accent))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                Text("appears on a page with a form")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(icon: "sparkle", title: "Fills in forms",
                        line: "One click and it fills what it knows, asks for the rest in one question, and leaves submitting to you. ⌥⌘F does the same for the page in front.")
                Feature(icon: "pin", title: "One tab, one agent",
                        line: "Right-click a tab › Ask Codegraff About This Tab: a chat pinned to it, working there and nowhere else.")
                Feature(icon: "text.line.first.and.arrowtriangle.forward", title: "Keep typing while it works",
                        line: "What you send meanwhile waits in a queue above the box and goes in turn; any of it can go now instead.")
                Feature(icon: "wand.and.stars", title: "Tidy a page",
                        line: "View › Tidy This Page takes off the cookie bars and pop-ups the ad blocker let through.")
            }
            if CodegraffAccount.key() == nil {
                Text("These need a Codegraff sign-in, a page back.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
            }
        }
    }

    private struct Feature: View {
        let icon: String
        let title: String
        let line: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28)
                    .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(line)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Links from other apps.", "A click in Mail, in Slack, in a PDF — macOS sends it to whichever browser is the default. It can be this one.")
            HStack(spacing: 12) {
                if isDefault {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                        Text("browse is the default browser")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                } else {
                    Big("Make browse the default", filled: true) {
                        asked = true
                        Links.becomeDefault { _ in isDefault = Links.isDefault }
                    }
                    if asked, !isDefault {
                        Text("macOS asks in its own dialog")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.faint)
                    }
                }
            }
            .animation(Motion.settle, value: isDefault)

            VStack(alignment: .leading, spacing: 9) {
                Text("A few useful keys")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 9) {
                    ForEach(Shortcuts.first) { ShortcutLine(shortcut: $0) }
                }
                Text("The full guide is in Help › Keyboard Shortcuts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.faint)
            }
            Choice("Remind me of shortcuts later", "Once, after you open a page", on: $remindShortcuts)
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Palette.ink : Palette.faint.opacity(0.6))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            if page < pages - 1 {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Big(page < pages - 1 ? "Continue" : "Start browsing", filled: true) {
                if page < pages - 1 { forward = true; page += 1 } else { finish() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520)
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

    private func finish() {
        if remindShortcuts { browser.requestShortcutReminder() }
        prefs.welcomed = true
        withAnimation(Motion.settle) { browser.welcoming = false }
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

    /// The Codegraff artwork at the size the page wants.
    private struct Plate: View {
        let size: CGFloat
        var body: some View {
            BrandMark().frame(width: size, height: size)
        }
    }

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
                Switch(on: $on)
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
