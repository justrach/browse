import SwiftUI
import AppKit

// Lifted from Office Inspiration, with the ground turned white: there the work
// floats on an off-white canvas, here the page *is* the ground and everything
// the browser draws has to get out of its way.
//
// Every colour is a pair — one for a light window, one for a dark — and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings › Appearance:
// light, dark, or whatever the Mac is doing. Nothing else in the code knows
// which it is. The pairs themselves come from the theme in use (Theme.swift);
// the default one is the white and greys this always was.
enum Palette {
    static let ground = Color(nsColor: NS.ground)
    static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    static let muted = Color(nsColor: NS.muted)         // neutral-500
    static let faint = Color(nsColor: NS.faint)         // neutral-300 · neutral-700
    static let hairline = Color(nsColor: NS.hairline)   // neutral-200 · neutral-800
    static let wash = Color(nsColor: NS.wash)           // the live tab
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// What should stand out: a switch that's on, the button that matters.
    /// The ink, in a theme that has no colour of its own.
    static let accent = Color(nsColor: NS.accent)
    /// Words on the accent.
    static let onAccent = Color(nsColor: NS.onAccent)
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can (see SiteCard.swift).
    static let safe = Color(nsColor: NS.safe)           // green-700 · green-400
    static let unsafe = Color(nsColor: NS.unsafe)       // amber-700 · amber-400

    /// The same colours for the AppKit corners of the app — a text field's
    /// ink, a window's background — which want an NSColor and keep it.
    enum NS {
        static let ground = role(\.ground)
        static let ink = role(\.ink)
        static let muted = role(\.muted)
        static let faint = role(\.faint)
        static let hairline = role(\.hairline)
        static let wash = role(\.wash)
        static let hover = role(\.hover)
        static let accent = NSColor(name: nil) { appearance in
            let colors = Themes.current.colors(dark: dim(appearance))
            return Themes.color(colors.accent ?? colors.ink)
        }
        static let onAccent = NSColor(name: nil) { appearance in
            let colors = Themes.current.colors(dark: dim(appearance))
            return Themes.color(colors.onAccent ?? colors.ground)
        }
        /// The resting traffic lights, drawn by hand when the app is behind.
        static let resting = role(\.faint)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        private static func role(_ role: KeyPath<Theme.Colors, String>) -> NSColor {
            NSColor(name: nil) { appearance in Themes.color(role, dark: dim(appearance)) }
        }

        private static func dim(_ appearance: NSAppearance) -> Bool {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}

/// Light, dark, or the Mac's own — the one choice that colours everything.
enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// What the app is told to be. Nothing, for "system": the app then
    /// follows the Mac, and changes with it.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// Set on the app rather than on the window, so every panel, alert and
    /// sheet — and every page, which follows the window it is in — agrees.
    ///
    /// Never from inside whatever is happening when it is asked for: the
    /// switch in Settings changes it from within an animation, over a panel
    /// in transition, and re-skinning every window in the middle of that is
    /// how a window ends up with a layer that takes clicks and shows
    /// nothing. The next turn of the run loop is soon enough.
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

enum Metrics {
    /// The tab strip. The window's title bar is grown to match it so the
    /// traffic lights come down with the tabs — otherwise giving the row room
    /// to breathe just leaves it sitting below three buttons it used to line
    /// up with.
    static let strip: CGFloat = 52
    /// Where the first tab starts. The traffic lights run from 19 to 79 —
    /// measured, not guessed — so this leaves them the same air on their right
    /// that the window gives them on their left.
    static let lights: CGFloat = 100
    /// Back, forward and reload, at the far end of the row beside the
    /// bookmarks: three doors and the air before the next one.
    static let helm: CGFloat = 3 * 26 + 2 * 2 + 8
    /// The same three doors again, in the sidebar, where they sit right of
    /// the lights instead. The column already has 10 of horizontal padding
    /// of its own before this even starts, so this is the lights' own edge
    /// (79) less that padding, plus a sliver of air — not the full breathing
    /// room a tab row gets, because the sidebar's minimum width doesn't have
    /// it to give.
    static let sideLights: CGFloat = 72
    /// The band left at the top when there is no strip: just enough for the
    /// traffic lights to sit in, and nothing else.
    static let bare: CGFloat = 34
    /// Tabs are a fixed width rather than the width of their titles, so the
    /// cross always lands in the same place and the row never rearranges
    /// itself while you read it. They give way when there are too many:
    /// narrower than tabTitled they show their site's mark alone, and they
    /// stop at tabMinWidth, the mark and its air. Past that the row scrolls,
    /// inside its own edges.
    static let tabWidth: CGFloat = 186
    static let tabTitled: CGFloat = 80
    static let tabMinWidth: CGFloat = 36
    static let tabGap: CGFloat = 2
    /// A pinned tab is a square the height of the row, holding one letter.
    static let pinWidth: CGFloat = 30
    /// The square at the end of the row that opens a new page.
    static let plusWidth: CGFloat = 30
    /// The address field, in both the places it shows up.
    static let fieldWidth: CGFloat = 560
    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 176
    static let sideMax: CGFloat = 440
    /// The agent's column down the right, when it is on (see Agent.swift).
    static let agent: CGFloat = 360
    static let agentMin: CGFloat = 280
    static let agentMax: CGFloat = 640
    /// The measure its talk is held to when it fills the stage (see
    /// AgentColumn.swift).
    static let chat: CGFloat = 680
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
// When macOS Reduce Motion is on in System Settings, transitions become
// immediate so the interface does not jump or slide.
enum Motion {
    /// Whether interface transitions should be immediate, following the
    /// Mac's own accessibility setting.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var glide: Animation? {
        reduced ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }

    static var settle: Animation? {
        reduced ? nil : .spring(response: 0.30, dampingFraction: 0.86)
    }

    static var quick: Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }
}

/// browse's mark, the same as the Dock icon and the website's. The bundle copy is
/// used in packaged builds; a source-tree build can load the original file.
struct BrandMark: View {
    private static let artwork: NSImage? = {
        if let path = Bundle.main.path(forResource: "BrandMark", ofType: "png"),
           let image = NSImage(contentsOfFile: path) { return image }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Icon/browse.png")
            .standardizedFileURL
        return NSImage(contentsOf: source)
    }()

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                Image(nsImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: "globe").resizable().scaledToFit()
            }
        }
        .accessibilityLabel("browse logo")
    }
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !Motion.reduced else { return ProjectionTransform(.identity) }
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}

/// What's picked, raised off the column: a lens of Liquid Glass where the Mac
/// has it (macOS 26 on), the theme's wash where it doesn't. A thin light
/// edge along the top and a soft shadow beneath are what make it read as
/// lifted rather than as a grey patch.
struct Raised: View {
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            // Glass is in the macOS 26 SDK (Swift 6.2); an older Xcode builds
            // the wash alone.
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular.interactive(), in: shape)
            } else {
                shape.fill(Palette.wash)
            }
            #else
            shape.fill(Palette.wash)
            #endif
        }
        // Light catching the top edge and fading down it, as on a pane of
        // glass lit from above.
        .overlay(shape.strokeBorder(
            LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
            lineWidth: 0.75
        ))
        .shadow(color: .black.opacity(0.10), radius: 4, y: 1.5)
    }
}

/// The page's colour, made into the sidebar's: laid over the glass, so the
/// column reads as the page carried on under frosted glass rather than a
/// panel painted beside it. A quiet colour — a cream, a white, a near-black —
/// goes on nearly solid; a loud one (a brand's red, a saturated blue) lets
/// more of the glass through, so it colours the column without shouting.
/// `dark` is whether what's seen ends up dark enough to want light words.
struct PageTint: Equatable {
    let color: NSColor
    let strength: Double
    let dark: Bool

    init?(_ hue: NSColor?, over scheme: ColorScheme) {
        guard let c = hue?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { return nil }
        let (r, g, b) = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        let top = max(r, g, b), bottom = min(r, g, b)
        let saturation = top == 0 ? 0 : (top - bottom) / top
        strength = 0.86 - 0.36 * saturation
        // What shows through the rest: the glass, about as light as the
        // window it's in.
        let glass = scheme == .dark ? 0.12 : 0.94
        let seen = (0.299 * r + 0.587 * g + 0.114 * b) * strength + glass * (1 - strength)
        dark = seen < 0.5
        color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// Laid over the glass: the colour, and a sheen of light down from the
    /// top, as on the rest of the app's glass (Raised).
    var wash: some View {
        ZStack {
            Color(nsColor: color).opacity(strength)
            LinearGradient(
                colors: [.white.opacity(dark ? 0.05 : 0.18), .clear],
                startPoint: .top, endPoint: .center
            )
        }
    }
}

/// Behind the sidebar: the desktop, blurred, as a Mac's own sidebars show
/// it, with the theme's ground laid over so every theme still reads as
/// itself — only lighter. `dark`, when a page's colour asks for it, is the
/// blur's own appearance, so a dark page's column isn't frosted white.
struct SideGlass: NSViewRepresentable {
    var dark: Bool?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
    }
}
