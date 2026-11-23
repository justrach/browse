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
    static let agentMin: CGFloat = 300
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
    /// Whether interface transitions should avoid spatial movement, following
    /// the Mac's own Reduce Motion accessibility setting.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Fast, interruptible spring under 300 ms for layout/drawer movement.
    static var glide: Animation? {
        reduced ? .easeOut(duration: 0.14) : .spring(response: 0.24, dampingFraction: 0.88)
    }

    /// Smooth, zero-overshoot deceleration curve for ⌘; Agent & ⌘S Sidebar
    /// slides (0.36 s ≈ 43 frames at 120 Hz) — gives WebKit generous time for
    /// its single reflow and matches `animateWindowFrame`'s exact CoreAnimation
    /// cubic-bezier `(0.22, 1.0, 0.36, 1.0)` with zero bounce.
    static let panelSlideDuration: TimeInterval = 0.36
    static var panelSlide: Animation? {
        reduced ? .easeOut(duration: 0.16) : .timingCurve(0.22, 1.0, 0.36, 1.0, duration: panelSlideDuration)
    }

    /// Snappy spring for list rows and arriving/departing cards.
    static var settle: Animation? {
        reduced ? .easeOut(duration: 0.14) : .spring(response: 0.24, dampingFraction: 0.88)
    }

    /// Crisp tactile spring for button presses and sliders.
    static var snappy: Animation? {
        reduced ? .easeOut(duration: 0.12) : .spring(response: 0.18, dampingFraction: 0.86)
    }

    /// Slightly softer spring for full-stage transitions, still under 300 ms.
    static var gentle: Animation? {
        reduced ? .easeOut(duration: 0.16) : .spring(response: 0.28, dampingFraction: 0.90)
    }

    /// Fast ease-out for hover states and micro-feedback.
    static var quick: Animation? {
        .easeOut(duration: 0.14)
    }

    /// Opacity-only crossfade that stays smooth even under Reduce Motion.
    static var fade: Animation {
        .easeOut(duration: reduced ? 0.14 : 0.18)
    }
}

/// Live breathing status dot for active agent runs and connected MCP sessions.
/// Animates GPU-composited scale + opacity only (zero per-frame layout work)
/// and stays static under macOS Reduce Motion.
struct PulseDot: View {
    var color: Color = Palette.accent
    var size: CGFloat = 6
    var active: Bool = true
    @State private var breathing = false

    var body: some View {
        ZStack {
            if active && !Motion.reduced {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(breathing ? 2.3 : 1.05)
                    .opacity(breathing ? 0.0 : 0.42)
                    .animation(.easeOut(duration: 1.35).repeatForever(autoreverses: false), value: breathing)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .onAppear { if active { breathing = true } }
        .onChange(of: active) { _, on in breathing = on }
    }
}

/// Subtle spring press feedback for interactive pills and buttons.
struct TactilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!Motion.reduced && configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
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

/// What's picked, raised off the column: a crisp, tactile elevated pill with
/// clean contrast in both Light and Dark appearances — never a hollow wireframe.
struct Raised: View {
    let corner: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.92))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: dark
                            ? [.white.opacity(0.18), .white.opacity(0.05)]
                            : [.black.opacity(0.06), .black.opacity(0.09)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
            .shadow(
                color: .black.opacity(dark ? 0.22 : 0.06),
                radius: dark ? 4 : 3,
                y: 1
            )
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
        // Never flip a Dark Mode window frame into bright white chrome (e.g. dark SPAs
        // whose unpainted WebKit underPageBackgroundColor defaults to #FFFFFF, or sites
        // that hardcode a light theme-color without dark-mode support).
        if scheme == .dark, seen >= 0.5 { return nil }
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

/// A crisp, high-contrast keyboard keycap badge — legible in light mode, dark
/// mode, and over page-tinted sidebars alike.
struct ShortcutBadge: View {
    let keys: String
    var active: Bool = false

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? Palette.ink : Palette.ink.opacity(0.84))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .frame(minWidth: 20, minHeight: 19)
            .background(
                Palette.ink.opacity(active ? 0.13 : 0.085),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(active ? 0.26 : 0.18), lineWidth: 0.75)
            )
            .fixedSize()
    }
}

/// Vector mark from NanoHarness (`apps/nano/assets/icons/harness-logo.svg`):
/// the open ink C-ring, `</>` code brackets, and six pixel fragments.
struct GraffMark: View {
    var size: CGFloat = 16
    var color: Color = Palette.ink

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height) / 1000.0
            let ox = (sz.width - 1000.0 * s) * 0.5
            let oy = (sz.height - 1000.0 * s) * 0.5
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: ox + x * s, y: oy + y * s)
            }

            // Open outer C-ring.
            var ring = Path()
            ring.move(to: pt(778, 275))
            ring.addCurve(to: pt(418, 205), control1: pt(678, 180), control2: pt(545, 160))
            ring.addCurve(to: pt(222, 526), control1: pt(272, 255), control2: pt(212, 389))
            ring.addCurve(to: pt(531, 814), control1: pt(234, 700), control2: pt(371, 812))
            ring.addCurve(to: pt(794, 722), control1: pt(650, 817), control2: pt(733, 772))
            ctx.stroke(
                ring,
                with: .color(color),
                style: StrokeStyle(lineWidth: max(1.2, 108 * s), lineCap: .round, lineJoin: .round)
            )

            // Center `</>` code brackets.
            var code = Path()
            code.move(to: pt(456, 457))
            code.addLine(to: pt(383, 500))
            code.addLine(to: pt(456, 543))
            code.move(to: pt(536, 437))
            code.addLine(to: pt(493, 563))
            code.move(to: pt(578, 457))
            code.addLine(to: pt(651, 500))
            code.addLine(to: pt(578, 543))
            ctx.stroke(
                code,
                with: .color(color),
                style: StrokeStyle(lineWidth: max(0.9, 36 * s), lineCap: .round, lineJoin: .round)
            )

            // Six pixel fragments along the open trailing edge.
            let pixels: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (802, 455, 27, 4),
                (849, 495, 38, 5),
                (790, 552, 48, 6),
                (860, 574, 23, 4),
                (823, 630, 34, 5),
                (893, 662, 18, 3),
            ]
            for (x, y, w, r) in pixels {
                let rect = CGRect(x: ox + x * s, y: oy + y * s, width: max(1.0, w * s), height: max(1.0, w * s))
                ctx.fill(Path(roundedRect: rect, cornerRadius: max(0.3, r * s)), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Subtle, GPU-composited Dia / Apple Liquid Glass ambient shimmer rim for a
/// floating card:
/// - `working`: softly glides a diffused luminous edge highlight around the
///   10pt squircle rim while graff is actively working with the page.
/// - `settling`: sweeps a brief frosted sheen across the trailing edge during
///   sidebar/panel layout transitions so one-shot WebKit reflows feel fluid.
struct PageShimmerRim: View {
    let corner: CGFloat
    let dark: Bool
    let working: Bool
    let settling: Bool

    @State private var spin: Double = 0
    @State private var sweep: CGFloat = -0.35

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            if working {
                let colors: [Color] = dark
                    ? [
                        Color.white.opacity(0.03),
                        Palette.accent.opacity(0.50),
                        Color(red: 0.56, green: 0.78, blue: 1.0).opacity(0.42),
                        Color.white.opacity(0.03),
                    ]
                    : [
                        Color.black.opacity(0.02),
                        Palette.accent.opacity(0.42),
                        Color(red: 0.36, green: 0.62, blue: 0.98).opacity(0.34),
                        Color.black.opacity(0.02),
                    ]
                let gradient = AngularGradient(
                    gradient: Gradient(colors: colors),
                    center: .center,
                    angle: .degrees(Motion.reduced ? 45 : spin)
                )
                // Lightweight dual-stroke luminous rim without a full-window
                // Gaussian `.blur()` pass so scrolling heavy SPAs (like X.com)
                // stays locked at 120 FPS even while the agent is working.
                ZStack {
                    shape
                        .strokeBorder(gradient, lineWidth: 2.5)
                        .opacity(dark ? 0.28 : 0.22)
                    shape
                        .strokeBorder(gradient, lineWidth: 1.25)
                }
                .drawingGroup()
                .clipShape(shape)
                .transition(.opacity)
                .onAppear {
                    guard !Motion.reduced else { return }
                    spin = 0
                    withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) {
                        spin = 360
                    }
                }
                .onDisappear { spin = 0 }
            }

            if settling {
                // Soft trailing-edge frosted shimmer that smooths over the
                // single-pass WebKit reflow when panels slide open or shut.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, sweep - 0.35)),
                        .init(color: (dark ? Color.white : Color.white).opacity(dark ? 0.08 : 0.42), location: max(0, min(1, sweep))),
                        .init(color: .clear, location: min(1, sweep + 0.35)),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(shape)
                .transition(.opacity)
                .onAppear {
                    guard !Motion.reduced else { return }
                    sweep = 0.25
                    withAnimation(.easeOut(duration: 0.32)) {
                        sweep = 1.25
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.24), value: working)
        .animation(.easeOut(duration: 0.18), value: settling)
    }
}
