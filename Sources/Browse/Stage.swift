import SwiftUI
import WebKit

/// Everything below the strip: the page, the line that says it is coming, and
/// the sentence that says it never did.
///
/// The tab is watched from here rather than from the window. A tab is a class,
/// so going from blank to loaded changes nothing about the value the window
/// hands down — SwiftUI sees the same reference, re-runs nothing, and the page
/// arrives in WebKit without ever being put on screen. Watching it here is
/// what turns that into a redraw.
struct Page: View {
    @ObservedObject var tab: Tab
    /// Rounded, as a card in a split (Split.swift); square on its own.
    var corner: CGFloat = 0
    /// False while transitioning out in favor of `SplitStage` so an exiting
    /// single-pane stage never reclaims a `WKWebView` mid-animation.
    var active: Bool = true

    var body: some View {
        ZStack {
            // A tab put down with ⌘W has no view, and asking for one here
            // would build an empty one a frame before the stage moves on.
            //
            // Nor is a floating page asked for. Handing the same view over
            // before and after the float changes nothing SwiftUI can see, so
            // the stage was never told to take it back when it landed, and
            // the tab stayed empty. Nothing, then the page, is a change.
            WebStage(
                page: tab.isBlank || tab.asleep || tab.floating ? nil : tab.web,
                corner: corner,
                active: active
            )
            if corner > 0 {
                PageOverlays(tab: tab)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                PageOverlays(tab: tab)
            }
        }
    }
}

/// Shadow-casting card backdrop behind the framed page stage (`App.swift`).
///
/// Observes `tab` directly so transitions between blank and live pages update
/// without re-evaluating the whole window. When a live `WKWebView` is on screen,
/// the backdrop is inset by 1pt and matched to `darkCanvas` so SwiftUI's
/// `RoundedRectangle` and `StageView`'s `CALayer` continuous corner curve can
/// never misalign and bleed a bright/dark fringe around the 4 corners.
struct FramedPageBackdrop: View {
    @ObservedObject var tab: Tab
    let darkCanvas: Bool

    var body: some View {
        let livePage = !tab.isBlank && !tab.asleep && !tab.floating
        let corner = livePage ? max(0, Split.corner - 1) : Split.corner
        let fill = livePage
            ? Themes.color(\.ground, dark: darkCanvas)
            : Palette.NS.ground
        // Uses an explicit CALayer.shadowPath instead of SwiftUI .shadow so
        // CoreAnimation renders the backdrop shadow in O(1) on the GPU without
        // recomputing an offscreen alpha-mask blur during 120 Hz WKWebView scrolls.
        BackdropShadowView(
            corner: corner,
            fill: fill,
            shadowOpacity: darkCanvas ? 0.26 : 0.06,
            shadowRadius: darkCanvas ? 8 : 5
        )
        .padding(livePage ? 1 : 0)
        .allowsHitTesting(false)
    }
}

struct BackdropShadowView: NSViewRepresentable {
    let corner: CGFloat
    let fill: NSColor
    let shadowOpacity: Swift.Float
    let shadowRadius: CGFloat
    var shadowOffset: CGSize = CGSize(width: 0, height: -1.5)

    final class LayerView: NSView {
        var corner: CGFloat = 0
        var dynamicFill: NSColor?
        private var lastBounds: CGRect = .zero
        private var lastCorner: CGFloat = -1
        private var lastFillCG: CGColor?
        private var lastOpacity: Swift.Float = -1
        private var lastRadius: CGFloat = -1
        private var lastOffset: CGSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        /// Opaque inner CALayer inset by the corner radius so macOS WindowServer
        /// can cull behind-window `NSVisualEffectView` Gaussian blur for ~98% of
        /// the WKWebView viewport pixels during 120 Hz scrolling.
        let opaqueOcclusion = CALayer()

        override func layout() {
            super.layout()
            updateShadowPath()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyResolvedFill()
        }

        func apply(
            corner: CGFloat,
            fill: NSColor,
            shadowOpacity: Swift.Float,
            shadowRadius: CGFloat,
            shadowOffset: CGSize
        ) {
            self.dynamicFill = fill
            let resolved = resolveFillColor(fill)
            let cornerChanged = self.corner != corner
            let fillChanged = lastFillCG != resolved
            let shadowChanged = lastOpacity != shadowOpacity
                || lastRadius != shadowRadius
                || lastOffset != shadowOffset

            guard cornerChanged || fillChanged || shadowChanged || bounds != lastBounds || corner != lastCorner else {
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if cornerChanged {
                self.corner = corner
                layer?.cornerRadius = corner
            }
            if fillChanged {
                lastFillCG = resolved
                layer?.backgroundColor = resolved
                opaqueOcclusion.backgroundColor = resolved
            }
            if shadowChanged {
                lastOpacity = shadowOpacity
                lastRadius = shadowRadius
                lastOffset = shadowOffset
                layer?.shadowOpacity = shadowOpacity
                layer?.shadowRadius = shadowRadius
                layer?.shadowOffset = shadowOffset
            }

            CATransaction.commit()
            updateShadowPath()
        }

        private func applyResolvedFill() {
            guard let dynamicFill else { return }
            let resolved = resolveFillColor(dynamicFill)
            guard lastFillCG != resolved else { return }
            lastFillCG = resolved
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = resolved
            opaqueOcclusion.backgroundColor = resolved
            CATransaction.commit()
        }

        private func resolveFillColor(_ color: NSColor) -> CGColor {
            var cg: CGColor?
            effectiveAppearance.performAsCurrentDrawingAppearance {
                cg = color.cgColor
            }
            return cg ?? color.cgColor
        }

        func updateShadowPath() {
            guard bounds != lastBounds || corner != lastCorner else { return }
            lastBounds = bounds
            lastCorner = corner

            guard bounds.width > 0, bounds.height > 0 else {
                layer?.shadowPath = nil
                opaqueOcclusion.frame = .zero
                return
            }
            let r = min(corner, min(bounds.width, bounds.height) / 2)
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
            let inset = ceil(r)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if bounds.width > inset * 2, bounds.height > inset * 2 {
                opaqueOcclusion.frame = bounds.insetBy(dx: inset, dy: inset)
            } else {
                opaqueOcclusion.frame = .zero
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let noAnim: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "shadowPath": NSNull(),
            "cornerRadius": NSNull(),
            "backgroundColor": NSNull(),
            "shadowOpacity": NSNull(),
            "shadowRadius": NSNull(),
            "shadowOffset": NSNull(),
        ]
        let view = LayerView()
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.actions = noAnim
        view.opaqueOcclusion.isOpaque = true
        view.opaqueOcclusion.actions = noAnim
        view.layer?.addSublayer(view.opaqueOcclusion)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.apply(
            corner: corner,
            fill: fill,
            shadowOpacity: shadowOpacity,
            shadowRadius: shadowRadius,
            shadowOffset: shadowOffset
        )
    }
}

/// Everything layered over a tab's WKWebView: wake cover, floating notice,
/// load failure and swipe-back disc. Split View mounts StageView directly in
/// AppKit and layers these overlays separately so resizing never runs SwiftUI.
struct PageOverlays: View {
    @ObservedObject var tab: Tab

    var body: some View {
        ZStack {
            if let cover = tab.cover {
                // The page as it was left, while it is rebuilt underneath —
                // anchored where the page itself starts, and never in the
                // way of a click meant for the page.
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if tab.floating {
                // The tab is not empty, its page is simply elsewhere. Saying so
                // is kinder than a white rectangle.
                Text("This page is playing in the floating window.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.ground)
                    .transition(.opacity)
            }

            if let failure = tab.failure {
                Trouble(message: failure, url: tab.address) { tab.reload() }
                    .transition(.opacity)
            }

            if tab.loading && !tab.isBlank {
                PageProgressBar(progress: tab.progress)
                    .transition(.opacity)
            }

            if let pull = tab.pull {
                Disc(pull: pull)
                    // A disc for each edge, never one that changes edges: a
                    // view whose alignment flips is a view that glides the
                    // whole way across the window to get there.
                    .id(pull.back)
                    // A short fade and a little growth, both ways. Anything
                    // longer is still arriving when a quick flick has already
                    // let go.
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(Motion.quick, value: tab.failure)
        .animation(Motion.quick, value: tab.floating)
        .animation(.easeOut(duration: 0.2), value: tab.cover == nil)
        .animation(.easeOut(duration: 0.16), value: tab.pull == nil)
        .animation(.easeOut(duration: 0.18), value: tab.loading)
    }
}

/// Hairline top progress bar shown while a page is loading.
private struct PageProgressBar: View {
    let progress: Double

    var body: some View {
        let fraction = CGFloat(max(0.08, min(1.0, progress)))
        Rectangle()
            .fill(Palette.accent.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .scaleEffect(x: fraction, y: 1, anchor: .leading)
            .animation(.easeOut(duration: 0.16), value: fraction)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

/// The disc a sideways swipe brings in from the edge.
///
/// White, with a hairline, like everything else that floats over a page. A
/// line of ink winds round it as the fingers go and closes at the point where
/// letting go would mean it. Turn back and it unwinds. Let go while it is
/// closed and the disc leaves with the page.
///
/// It follows the fingers directly, with no spring between: a spring reads
/// as lag on a quick flick, and a quick flick is how most people swipe.
private struct Disc: View {
    let pull: Pull

    var body: some View {
        // The fingers can travel as far as they like; the disc stops short.
        let reach = 150 * (1 - exp(-pull.travel / 110))
        let grown = min(1, pull.travel / 110)
        let scale: CGFloat = pull.going ? 1.08 : 0.86 + 0.14 * grown

        ZStack {
            Circle()
                .fill(Palette.ground)
            Circle()
                .strokeBorder(Palette.hairline, lineWidth: 1)
            // How far there is to go, wound round the edge, closed when it
            // is armed.
            Circle()
                .trim(from: 0, to: grown)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(0.75)
            Image(systemName: pull.back ? "arrow.left" : "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(0.4 + 0.6 * grown))
        }
        .frame(width: 52, height: 52)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .scaleEffect(scale)
        .opacity(pull.going ? 0 : 1)
        // Whole from the first point, a little way in from the edge, drawn
        // further in as the fingers go — and a step further on its way out
        // with the page.
        .offset(x: (pull.back ? 1 : -1) * (10 + reach * 0.2 + (pull.going ? 12 : 0)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pull.back ? .leading : .trailing)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.22), value: pull.going)
    }
}

/// The one place a page is allowed to be. Tabs hand their web view over when
/// they become the live one and get it back untouched when they don't — no
/// reload, no lost scroll position, no forgotten form.
struct WebStage: NSViewRepresentable {
    let page: NSView?
    var corner: CGFloat = 0
    var active: Bool = true

    final class Coordinator {
        weak var lastPage: NSView?
        var lastCorner: CGFloat = -1
        var hasUpdated = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> StageView { StageView() }

    func updateNSView(_ view: StageView, context: Context) {
        guard active else { return }
        let coord = context.coordinator
        let cornerChanged = !coord.hasUpdated || coord.lastCorner != corner
        let pageChanged = !coord.hasUpdated || coord.lastPage !== page || (page != nil && page?.superview !== view)
        guard cornerChanged || pageChanged else { return }
        coord.hasUpdated = true
        if cornerChanged {
            coord.lastCorner = corner
            view.round(corner)
        }
        coord.lastPage = page
        view.show(page)
    }

    static func dismantleNSView(_ view: StageView, coordinator: Coordinator) {
        coordinator.lastPage = nil
        view.relinquishIfMoved()
    }
}

final class StageView: NSView {
    /// A page is an AppKit view, which SwiftUI's clipping doesn't reach:
    /// the corners are cut here, on the layer that holds it.
    func round(_ corner: CGFloat) {
        let now = layer?.cornerRadius ?? 0
        guard now != corner else { return }
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = corner > 0
    }

    /// What this stage has been told to show, and the only thing it keeps.
    ///
    /// It used to track that *and* what it was holding, and reconcile the two.
    /// One divergence between them — a page taken by the floating window, a tab
    /// closed at the wrong moment, an update that arrived out of order — and
    /// the stage would sit there holding nothing while believing it held
    /// something. That is the white page, and it came back every time from a
    /// different direction because the bookkeeping had many ways to slip.
    ///
    /// Now there is one fact and one rule: show `wanted`, and put that right on
    /// every layout. Nothing to fall out of step with.
    private weak var wanted: NSView?
    private weak var backedWeb: WKWebView?
    private weak var liveResizingWeb: WKWebView?
    /// While a 240 ms sidebar / Agent spring slide is in flight, pin the inner
    /// WKWebView width to its exact final target width once at `t = 0` so heavy
    /// pages (X/Twitter, GitHub, videos) reflow at most ONCE instead of 30×
    /// while `StageView.bounds` glides at pure 120 FPS GPU lockstep.
    private var pinnedSlideWidth: CGFloat?
    private var unback: DispatchWorkItem?
    private var lastSize: CGSize = .zero

    /// The Web Inspector each page off show had docked beside it. WebKit
    /// docks it once, on show; a page coming back without it was laid out
    /// short, beside an empty space. Weak both ways: a closed tab's page
    /// takes its entry with it, and an inspector is kept by WebKit while it
    /// is open, never by this.
    private static let docks = NSMapTable<NSView, NSView>.weakToWeakObjects()

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            endLiveResize()
            unbackPage()
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        if size != lastSize {
            if lastSize.width > 0, lastSize.height > 0, size.width > 0, size.height > 0,
               backedWeb !== (wanted as? WKWebView) {
                backPage()
            }
            lastSize = size
        }
        settle()
    }

    func show(_ page: NSView?) {
        if let leaving = wanted, leaving !== page {
            endLiveResize()
            unbackPage()
            if let web = leaving as? WKWebView { WindowFullScreen.shared.end(web) }
            if let dock = subviews.first(where: Self.isInspector) {
                Self.docks.setObject(dock, forKey: leaving)
                dock.removeFromSuperview()
            }
        }
        let unchanged = (wanted === page)
        wanted = page
        if unchanged {
            if let page {
                if page.superview === self, window != nil, subviews.count == 1 {
                    if let web = page as? WKWebView, web.fullscreenState != .notInFullscreen { return }
                    let target = pinnedSlideWidth.map {
                        CGRect(x: 0, y: 0, width: $0, height: bounds.height)
                    } ?? bounds
                    if page.frame != target { page.frame = target }
                    return
                }
            } else if subviews.isEmpty {
                return
            }
        }
        settle()
    }

    /// Tell WebKit a live split drag has started so it switches its drawing
    /// area to async live-resize instead of blocking the main thread on
    /// synchronous WebContent presentation updates at every 120 Hz step.
    func startLiveResize() {
        pinnedSlideWidth = nil
        backPage()
        guard let web = wanted as? WKWebView, liveResizingWeb !== web else { return }
        endLiveResize()
        (web as? PageView)?.splitLiveResizing = true
        web.viewWillStartLiveResize()
        liveResizingWeb = web
    }

    /// Pin the inner `WKWebView` ONCE to its final post-slide width at `t = 0`
    /// while `StageView` smoothly animates its GPU clip bounds across the
    /// 240 ms spring — turning 30 consecutive DOM/ResizeObserver reflows on
    /// heavy feeds like X/Twitter into a single reflow with zero post-slide jump.
    func beginSlide(deltaWidth: CGFloat) {
        let baseWidth = pinnedSlideWidth ?? bounds.width
        startLiveResize()
        guard let wanted, baseWidth > 0, bounds.height > 0 else { return }
        let targetWidth = max(200, baseWidth + deltaWidth)
        pinnedSlideWidth = targetWidth
        let targetFrame = CGRect(x: 0, y: 0, width: targetWidth, height: bounds.height)
        if wanted.frame != targetFrame {
            wanted.frame = targetFrame
        }
    }

    func endSlide() {
        pinnedSlideWidth = nil
        if let wanted, window != nil, wanted.superview === self, subviews.count == 1,
           wanted.frame != bounds {
            wanted.frame = bounds
        }
        endLiveResize()
    }

    /// Drops `wanted` when this stage is dismantled after the page moved to
    /// another container (such as `SplitPaneSlot`), leaving the live container intact.
    func relinquishIfMoved() {
        if let page = wanted, page.superview !== self {
            endLiveResize()
            unbackPage()
            wanted = nil
        }
    }

    func endLiveResize() {
        guard let web = liveResizingWeb else { return }
        liveResizingWeb = nil
        (web as? PageView)?.splitLiveResizing = false
        web.viewDidEndLiveResize()
        // Schedule a single unback once live-resize finishes instead of
        // cancelling/reallocating timers on every intermediate 120 Hz frame.
        if backedWeb != nil {
            unback?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.unbackPage() }
            unback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// Keep the page's own background colour behind WebKit during live resize
    /// so newly exposed strips never flash grey or black while the web process
    /// catches up, then hand drawing back to WebKit half a second after resize
    /// settles.
    func backPage() {
        guard let web = wanted as? WKWebView else { return }
        wantsLayer = true
        layer?.backgroundColor = web.underPageBackgroundColor.cgColor
        if backedWeb !== web {
            if let prev = backedWeb { Self.setDrawsBackground(prev, true) }
            Self.setDrawsBackground(web, false)
            backedWeb = web
        }
        unback?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unbackPage() }
        unback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func unbackPage() {
        unback?.cancel()
        unback = nil
        if let web = backedWeb {
            Self.setDrawsBackground(web, true)
            backedWeb = nil
        }
        layer?.backgroundColor = nil
    }

    private static func setDrawsBackground(_ web: WKWebView, _ on: Bool) {
        let sel = NSSelectorFromString("_setDrawsBackground:")
        guard web.responds(to: sel) else { return }
        web.setValue(on, forKey: "drawsBackground")
    }

    private func settle() {
        // A video filling the screen has its page lent to WebKit's own
        // window, with a placeholder left here in its place. The chrome
        // stepping aside lays this stage out again in that same moment, and
        // taking the page back then left the screen black with the sound
        // still playing. WebKit puts it back itself on the way out.
        if let web = wanted as? WKWebView, web.fullscreenState != .notInFullscreen { return }

        // Fast path during live 120 Hz resize or GPU-clipped slide: the wanted
        // page is already the sole subview, so skip inspector reflection and
        // subview scans (and keep width pinned during a single-reflow slide).
        if let wanted, window != nil, wanted.superview === self, subviews.count == 1 {
            let target = pinnedSlideWidth.map {
                CGRect(x: 0, y: 0, width: $0, height: bounds.height)
            } ?? bounds
            if wanted.frame != target { wanted.frame = target }
            return
        }

        // Anything here that isn't wanted, out. Only ever what is actually
        // ours: a page may be somewhere else on purpose. Except the Web
        // Inspector docked beside the page: WebKit puts it here, next to the
        // web view, and shrinks the page to make room. Taken out on the next
        // resize, it left the page shrunk beside nothing (#91).
        let docked = inspecting
        for view in subviews where view !== wanted && !(docked && Self.isInspector(view)) {
            view.removeFromSuperview()
        }

        guard let wanted, window != nil else { return }
        if wanted.superview !== self {
            // A web view can have only one superview, so taking it back is how
            // it is taken back.
            wanted.removeFromSuperview()
            // Seen — unless it has yet to draw, and would be seen white.
            wanted.alphaValue = (wanted as? PageView)?.unpainted == true ? 0 : 1
            addSubview(wanted)
            if docked, let dock = Self.docks.object(forKey: wanted) {
                addSubview(dock, positioned: .below, relativeTo: wanted)
            }
            Self.docks.removeObject(forKey: wanted)
            // Full size, which WebKit, with its inspector back, cuts down to
            // make room for it again at the stage's size now.
            wanted.frame = bounds
            // A web view coming back into a window sometimes keeps the last
            // picture it had — which, after a while out of one, is nothing.
            // Asking it to draw again is cheap and is what brings it back.
            wanted.needsLayout = true
            wanted.needsDisplay = true
            wanted.layer?.setNeedsDisplay()
        }
        // With the inspector docked, WebKit lays the page and it out side by
        // side as this view changes size; setting the page's frame here would
        // cover the inspector.
        if !(docked && subviews.contains(where: Self.isInspector)) {
            if wanted.frame != bounds { wanted.frame = bounds }
        }
    }

    /// Whether the page on show has its Web Inspector up. WebKit answers only
    /// through names outside its public framework, asked for before use (see
    /// Inspector.swift).
    private var inspecting: Bool {
        guard let web = wanted as? WKWebView else { return false }
        let get = NSSelectorFromString("_inspector")
        guard web.responds(to: get), let inspector = web.perform(get)?.takeUnretainedValue() as? NSObject else { return false }
        let visible = NSSelectorFromString("isVisible")
        guard inspector.responds(to: visible) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(inspector.method(for: visible), to: Getter.self)(inspector, visible)
    }

    private static func isInspector(_ view: NSView) -> Bool {
        String(describing: type(of: view)).hasPrefix("WKInspector")
    }
}

/// What there is to say when the page never came. Quiet surface with host
/// context and a single action to try again.
private struct Trouble: View {
    let message: String
    var url: URL? = nil
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.faint)
            VStack(spacing: 4) {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                if let url {
                    Text(Address.pretty(url))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Pill("Try again", action: retry)
                .help("Reload Page   ⌘R")
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}

/// Hands back the NSWindow once there is one. SwiftUI has no opinion about
/// traffic lights or title bars, and both need settling by hand here.
struct WindowSetup: NSViewRepresentable {
    let ready: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(ready: ready) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let ready: (NSWindow) -> Void

        init(ready: @escaping (NSWindow) -> Void) {
            self.ready = ready
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Here only to learn the window, never to be clicked: set behind or
        /// over something that spans the whole window — Fold's layer does,
        /// since its band runs along the top — a view that answered would
        /// take every click meant for the page and the tabs.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // The window is still being put together at this point; anything
            // set now gets overwritten a moment later.
            DispatchQueue.main.async { self.ready(window) }
        }
    }
}

/// Drag to move, double-click to fill the screen. Lifted from the canvas app —
/// with the title bar hidden the interface swallows the clicks a title bar
/// would have handled, and they have to be put back.
struct DragStrip: NSViewRepresentable {
    /// How much of the leading edge belongs to the tabs. A representable is a
    /// real view sitting under everything SwiftUI draws on top of it, and a
    /// real view takes the click first — so the run the tabs occupy is refused
    /// here and falls through to them.
    var reserved: CGFloat = 0
    /// How much of the top belongs to whatever is drawn there, measured from
    /// the top edge. The column of tabs uses this the way the strip uses the
    /// leading run.
    var below: CGFloat = 0
    /// The run at the trailing end that belongs to a button.
    var trailing: CGFloat = 0
    /// Stands in for the title bar's own double-click, in a strip that is
    /// empty tab-row rather than title bar: the empty space below or after
    /// the tabs, where a double-click opens a new tab instead of zooming the
    /// window.
    var onDoubleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView { Strip() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Strip)?.reserved = reserved
        (view as? Strip)?.below = below
        (view as? Strip)?.trailing = trailing
        (view as? Strip)?.onDoubleClick = onDoubleClick
    }

    private final class Strip: NSView {
        var reserved: CGFloat = 0
        var below: CGFloat = 0
        var trailing: CGFloat = 0
        var onDoubleClick: (() -> Void)?

        private var pressed: NSEvent?
        private var moved = false

        /// The strip moves the window and answers the double-click itself.
        /// Left to say yes, AppKit takes both on too in the title bar the
        /// strip sits in, and a double-click answered twice — by AppKit on
        /// the press, here on the release — ends where it started.
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            guard inside.x >= reserved, inside.x <= bounds.width - trailing else { return nil }
            // AppKit measures up from the bottom; the reservation is from the top.
            guard bounds.height - inside.y >= below else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = event
            moved = false
        }

        /// The window is not movable on its own (see dress in App.swift): a tab
        /// picked up in the strip would carry the window off with it. Here
        /// it is let go for the one drag, handed to the system's own window
        /// drag so it snaps and tiles as any window does.
        override func mouseDragged(with event: NSEvent) {
            guard let window, let pressed, !moved else { return }
            let dx = event.locationInWindow.x - pressed.locationInWindow.x
            let dy = event.locationInWindow.y - pressed.locationInWindow.y
            // A little slack, so a shaky click is still a click.
            if abs(dx) < 3 && abs(dy) < 3 { return }
            moved = true
            window.isMovable = true
            window.performDrag(with: pressed)
            window.isMovable = false
        }

        /// A double-click does what a title bar's does, unless this strip
        /// stands for empty tab row instead, in which case it opens a new
        /// tab, the same as the button it is standing in for. It answered
        /// every click before, so a double-click filled the screen on the
        /// first click and put the window back on the second, and looked
        /// like nothing at all.
        override func mouseUp(with event: NSEvent) {
            guard let window, !moved, event.clickCount == 2 else { return }
            if let onDoubleClick {
                onDoubleClick()
                return
            }
            // System Settings › Desktop & Dock: what double-clicking a title
            // bar should do. Unset means the default, which fills the screen.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}


/// The three buttons as they look when the app is not the one you are using.
///
/// macOS does draw its own in that state, but in a light window they come out
/// nearly white on white — Apple's own choice, and the reason a pale window
/// looks like it has lost its controls while a dark one does not. So the
/// system's are put away and these are drawn in exactly their place, read from
/// the real buttons rather than guessed at.
///
/// It lives inside the title bar rather than in the window's content, because
/// the title bar draws above everything the app puts on screen.
final class RestingLights: NSView {
    /// Set again each time the title bar is laid out — every change of
    /// screen, key window or size — and redrawn only when they moved.
    var spots: [CGRect] = [] {
        didSet { if spots != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirty: NSRect) {
        Palette.NS.resting.setFill()
        for spot in spots { NSBezierPath(ovalIn: spot).fill() }
    }

    /// Never in the way of a click: the real buttons are underneath, and they
    /// come back the moment the app does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
