import AppKit
import SwiftUI

// Themes: the browser's own colours, chosen.
//
// Everything the browser draws is a handful of colours — the ground, the ink,
// the greys between, the lines, the live tab's wash — each a pair for light
// and for dark (see Palette). A theme is those, plus an accent for the few
// things that should stand out: a switch that's on, the button that matters.
// The default theme's accent is its ink, so the browser looks as it always
// has until someone picks another.
//
// A theme is a small JSON file, and that's all it is: the built-in ones live
// here, the rest in Themes/ in the profile — made by hand, added from a
// file, or made by Codegraff with its `theme` tool from a sentence. The ones
// that aren't built in sync between Macs with the bookmarks (Sync.swift).
// Which one is in use is each Mac's own choice.

struct Theme: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var author: String?
    var light: Colors
    var dark: Colors

    struct Colors: Codable, Equatable {
        var ground: String
        var ink: String
        var muted: String
        var faint: String
        var hairline: String
        var wash: String
        var hover: String
        /// Switches that are on, the button that matters. The ink, if none.
        var accent: String?
        /// Words on the accent. The ground, if none.
        var onAccent: String?
    }

    var builtIn: Bool { Themes.builtIn.contains { $0.id == id } }

    func colors(dark: Bool) -> Colors { dark ? self.dark : light }
}

enum Themes {
    // MARK: - the built-in ones

    /// browse's own: white and near-black, greys between, no colour of its own.
    static let plain = Theme(
        id: "browse", name: "browse", author: nil,
        light: .init(ground: "#ffffff", ink: "#171717", muted: "#8c8c8c", faint: "#d4d4d4", hairline: "#e8e8e8", wash: "#efefef", hover: "#f6f6f6"),
        dark: .init(ground: "#1c1c1c", ink: "#ededed", muted: "#949494", faint: "#525252", hairline: "#333333", wash: "#2d2d2d", hover: "#262626")
    )

    static let builtIn: [Theme] = [
        plain,
        // The Codegraff app's default, Warm Graphite: cream and graphite,
        // with amber.
        Theme(
            id: "codegraff", name: "Codegraff", author: "Codegraff",
            light: .init(ground: "#faf8f3", ink: "#1a1813", muted: "#6b6557", faint: "#cbc3b4", hairline: "#dad3c5", wash: "#e7e1d5", hover: "#f0ece3", accent: "#c77d20", onAccent: "#faf8f3"),
            dark: .init(ground: "#16140f", ink: "#edeae2", muted: "#9a9384", faint: "#4a4336", hairline: "#332e25", wash: "#2a261e", hover: "#1f1c16", accent: "#e8a33d", onAccent: "#16140f")
        ),
        // codegraff.com: warm paper, ink, and coral.
        Theme(
            id: "codegraff-paper", name: "Codegraff Paper", author: "Codegraff",
            light: .init(ground: "#f7f1e7", ink: "#171717", muted: "#655e55", faint: "#d8c3a5", hairline: "#e7dac6", wash: "#ede3d3", hover: "#f2eadc", accent: "#d75a42", onAccent: "#fffdf8"),
            dark: .init(ground: "#100f0d", ink: "#f3ecdf", muted: "#aaa4a0", faint: "#4a4540", hairline: "#2b2823", wash: "#221f1b", hover: "#191714", accent: "#ef8069", onAccent: "#100f0d")
        ),
        Theme(
            id: "nord", name: "Nord", author: nil,
            light: .init(ground: "#eceff4", ink: "#2e3440", muted: "#6b7385", faint: "#c3c9d4", hairline: "#d8dee9", wash: "#dfe4ec", hover: "#e5e9f0", accent: "#5e81ac", onAccent: "#eceff4"),
            dark: .init(ground: "#2e3440", ink: "#eceff4", muted: "#9aa3b5", faint: "#4c566a", hairline: "#3b4252", wash: "#434c5e", hover: "#3b4252", accent: "#88c0d0", onAccent: "#2e3440")
        ),
        Theme(
            id: "forest", name: "Forest", author: nil,
            light: .init(ground: "#f4f6f1", ink: "#1c2419", muted: "#5f6b59", faint: "#c6cfbf", hairline: "#dde3d7", wash: "#e4e9de", hover: "#ecf0e7", accent: "#3f7d4e", onAccent: "#f4f6f1"),
            dark: .init(ground: "#121712", ink: "#e6ece3", muted: "#93a08d", faint: "#3d4a3b", hairline: "#263024", wash: "#1f281d", hover: "#192118", accent: "#7fa86b", onAccent: "#121712")
        ),
    ]

    // MARK: - the one in use

    /// Read from inside the colours themselves, whichever thread draws.
    nonisolated(unsafe) private(set) static var current: Theme = plain

    /// At launch, before there's a window: only which theme it is.
    nonisolated static func start(_ id: String) {
        current = all().first { $0.id == id } ?? plain
    }

    /// The theme by its id, in place now: every window's colours drawn again.
    @MainActor
    static func use(_ id: String) {
        let chosen = all().first { $0.id == id } ?? plain
        current = chosen
        cache.removeAll()
        redraw()
    }

    /// Dynamic colours are worked out again when the app's appearance
    /// changes, and not otherwise. So for one turn of the run loop the app
    /// wears the vibrant twin of what it wears now — the same light or dark,
    /// so nothing flashes — and then its own again, and every window draws
    /// itself in the new colours on the way.
    @MainActor
    private static func redraw() {
        let app = NSApplication.shared
        let kept = app.appearance
        let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        app.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
        DispatchQueue.main.async {
            app.appearance = kept
            for window in app.windows { window.backgroundColor = Palette.NS.ground }
        }
    }

    // MARK: - the files

    nonisolated static var folder: URL { Store.folder.appendingPathComponent("Themes", isDirectory: true) }

    /// Every theme there is: the built-in ones, then the folder's by name.
    nonisolated static func all() -> [Theme] { builtIn + installed() }

    nonisolated static func installed() -> [Theme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Theme.self, from: $0) } }
            .filter { theme in !builtIn.contains { $0.id == theme.id } && check(theme) == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Kept in the folder, under its id. Nil, or why not.
    @MainActor
    @discardableResult
    static func save(_ theme: Theme) -> String? {
        if let trouble = check(theme) { return trouble }
        guard !theme.builtIn else { return "That's the name of a built-in theme" }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(theme).write(to: file(theme.id), options: .atomic)
        } catch {
            return "Couldn't save it: \(error.localizedDescription)"
        }
        if theme.id == current.id { use(theme.id) }
        Sync.shared.nudge()
        return nil
    }

    @MainActor
    static func remove(_ id: String, prefs: Preferences) {
        try? FileManager.default.removeItem(at: file(id))
        if prefs.theme == id { prefs.theme = plain.id }
        Sync.shared.nudge()
    }

    /// A theme file from somewhere else, taken in under an id of its own.
    @MainActor
    static func add(from url: URL) -> Result<Theme, Failure> {
        guard let data = try? Data(contentsOf: url), var theme = try? JSONDecoder().decode(Theme.self, from: data) else {
            return .failure(Failure(why: "That isn't a theme file"))
        }
        if theme.builtIn || all().contains(where: { $0.id == theme.id }) || !validID(theme.id) { theme.id = UUID().uuidString }
        if let trouble = save(theme) { return .failure(Failure(why: trouble)) }
        return .success(theme)
    }

    struct Failure: Error { let why: String }

    nonisolated static func file(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    nonisolated static func validID(_ id: String) -> Bool {
        id.count >= 8 && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: - checking

    /// Nil when every colour reads and the words can be read on what they
    /// sit on — or what's wrong, in words someone can fix it from.
    nonisolated static func check(_ theme: Theme) -> String? {
        guard !theme.name.trimmingCharacters(in: .whitespaces).isEmpty, theme.name.count <= 60 else { return "A theme needs a short name" }
        for (mode, colors) in [("light", theme.light), ("dark", theme.dark)] {
            let named: [(String, String?)] = [
                ("ground", colors.ground), ("ink", colors.ink), ("muted", colors.muted), ("faint", colors.faint),
                ("hairline", colors.hairline), ("wash", colors.wash), ("hover", colors.hover),
                ("accent", colors.accent), ("onAccent", colors.onAccent),
            ]
            for (role, value) in named {
                guard let value else { continue }
                if rgb(value) == nil { return "\(mode) \(role) isn't a colour like #1a2b3c" }
            }
            if contrast(colors.ink, colors.ground) < 4.5 { return "In \(mode), the ink doesn't read on the ground (contrast under 4.5)" }
            if contrast(colors.ink, colors.wash) < 4.5 { return "In \(mode), the ink doesn't read on the live tab's wash (contrast under 4.5)" }
            if contrast(colors.muted, colors.ground) < 2.5 { return "In \(mode), muted words barely show on the ground (contrast under 2.5)" }
            if let accent = colors.accent, contrast(colors.onAccent ?? colors.ground, accent) < 3 {
                return "In \(mode), words on the accent don't read (contrast under 3)"
            }
        }
        return nil
    }

    nonisolated static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (CGFloat((value >> 16) & 0xff) / 255, CGFloat((value >> 8) & 0xff) / 255, CGFloat(value & 0xff) / 255)
    }

    /// WCAG's contrast ratio, 1 to 21.
    nonisolated static func contrast(_ a: String, _ b: String) -> Double {
        guard let one = rgb(a), let two = rgb(b) else { return 0 }
        func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> Double {
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        let (x, y) = (luminance(one), luminance(two))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: - as colours

    nonisolated(unsafe) private static var cache: [String: NSColor] = [:]

    /// A role of the theme in use, light or dark as the drawing asks.
    nonisolated static func color(_ role: KeyPath<Theme.Colors, String>, dark: Bool) -> NSColor {
        color(current.colors(dark: dark)[keyPath: role])
    }

    nonisolated static func color(_ hex: String) -> NSColor {
        if let made = cache[hex] { return made }
        let (r, g, b) = rgb(hex) ?? (0.5, 0.5, 0.5)
        let made = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        cache[hex] = made
        return made
    }
}

/// Settings › Themes: every theme as a card, the folder, and Codegraff to
/// make one from a sentence.
struct ThemesPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @State private var themes = Themes.all()
    @State private var wish = ""
    @State private var said: String?

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, chosen: prefs.theme == theme.id) {
                        prefs.theme = theme.id
                    } remove: {
                        Themes.remove(theme.id, prefs: prefs)
                        themes = Themes.all()
                    }
                }
            }

            Card {
                Line("Make one with Codegraff", "Say what it should feel like — Codegraff picks the colours for light and dark, checks they read, and switches to it") { EmptyView() }
                HStack(spacing: 8) {
                    TextField("A calm, foggy harbour at dawn…", text: $wish)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .onSubmit(make)
                    Pill("Make it", filled: true, action: make)
                        .disabled(wish.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Card {
                Line("Theme files", said ?? "Themes are small JSON files. Ones you add or make sync between your Macs with sync on") {
                    HStack(spacing: 6) {
                        Pill("Add…") { add() }
                        Pill("Show folder") {
                            try? FileManager.default.createDirectory(at: Themes.folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(Themes.folder)
                        }
                    }
                }
            }
        }
        .onAppear { themes = Themes.all() }
        .onReceive(NotificationCenter.default.publisher(for: Themes.changed)) { _ in themes = Themes.all() }
    }

    private func make() {
        let words = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        wish = ""
        browser.tuning = false
        browser.ask("Make a colour theme for this browser: \(words). Use the `theme` tool once, with colours for both light and dark, then say in a sentence what you made.")
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Add theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch Themes.add(from: url) {
        case .success(let theme):
            themes = Themes.all()
            prefs.theme = theme.id
            said = "Added “\(theme.name)”"
        case .failure(let failure):
            said = failure.why
        }
    }
}

extension Themes {
    /// Posted when the set of themes changes from outside Settings — sync,
    /// or Codegraff making one.
    static let changed = Notification.Name("browse.themes.changed")
}

/// One theme: its light and dark halves side by side, as the browser would
/// wear them.
private struct ThemeCard: View {
    let theme: Theme
    let chosen: Bool
    let pick: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    half(theme.light)
                    half(theme.dark)
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                HStack {
                    Text(theme.name)
                        .font(.system(size: 12.5, weight: chosen ? .medium : .regular))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !theme.builtIn, hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .onTapGesture(perform: remove)
                            .help("Remove this theme")
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(chosen ? Palette.wash : (hovering ? Palette.hover : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(chosen ? Palette.accent.opacity(0.7) : Palette.hairline, lineWidth: chosen ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// A small window: the ground, a live tab in its wash, a line of ink, a
    /// line of muted words, and the accent.
    private func half(_ colors: Theme.Colors) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: Themes.color(colors.ground))
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: Themes.color(colors.wash))).frame(width: 34, height: 9)
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Themes.color(colors.ink))).frame(width: 40, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Themes.color(colors.muted))).frame(width: 28, height: 4)
                Capsule().fill(Color(nsColor: Themes.color(colors.accent ?? colors.ink))).frame(width: 18, height: 9)
            }
            .padding(8)
        }
    }
}
