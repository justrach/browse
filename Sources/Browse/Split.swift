import SwiftUI
import AppKit

/// Two tabs side by side, as Arc's Split View has them.
///
/// The pair is kept, not the view: pick either tab and both come up, the one
/// you picked in front; pick any other and it has the stage to itself, the
/// pair waiting for you to come back. The tab in front is the one the
/// address field, Codegraff and the sidebar's colour belong to, and a click
/// in the other page puts that one in front.
struct Split: Equatable {
    var left: Tab.ID
    var right: Tab.ID
    /// How much of the stage the left page has.
    var fraction: CGFloat = 0.5

    func has(_ id: Tab.ID?) -> Bool { id == left || id == right }

    /// The frame around and between the two pages, and their corners.
    static let gap: CGFloat = 8
    static let corner: CGFloat = 10
}

extension Browser {
    /// The pair on screen: both still open, and one of them in front.
    var shownSplit: (left: Tab, right: Tab)? {
        guard let split, split.has(activeID), !talkOnStage,
              let left = tabs.first(where: { $0.id == split.left }),
              let right = tabs.first(where: { $0.id == split.right }) else { return nil }
        return (left, right)
    }

    /// Whether the tab is one of the pair on screen.
    func showing(inSplit tab: Tab) -> Bool {
        guard let pair = shownSplit else { return false }
        return pair.left === tab || pair.right === tab
    }

    /// The tab in front beside `tab`: the one in front on the left, `tab` on
    /// the right, as a link opened beside a page would sit.
    func split(with tab: Tab) {
        guard let active, active.id != tab.id, !active.isBlank || !tab.isBlank else { return }
        if talkOnStage { leaveStage() }
        withAnimation(Motion.glide) { split = Split(left: active.id, right: tab.id) }
        // What was on screen stays in front.
        wakePair()
    }

    /// ⌃⌘S: the pair on screen goes back to one page; otherwise the tab in
    /// front is split with the tab looked at before it.
    func toggleSplit() {
        if shownSplit != nil { unsplit(); return }
        guard let active else { return }
        let others = tabs.filter { $0.id != active.id && !$0.isBlank && !$0.shy }
        guard let partner = others.max(by: { $0.touched < $1.touched }) else { return }
        split(with: partner)
    }

    func unsplit() {
        withAnimation(Motion.glide) { split = nil }
    }

    /// Left and right change places.
    func swapSplit() {
        guard var pair = split else { return }
        swap(&pair.left, &pair.right)
        pair.fraction = 1 - pair.fraction
        withAnimation(Motion.glide) { split = pair }
    }

    /// Both pages of the pair on screen are woken, not just the one picked.
    func wakePair() {
        guard let pair = shownSplit else { return }
        for tab in [pair.left, pair.right] where tab.id != activeID {
            if !tab.wake() { tab.revive() }
        }
    }
}

/// The pair on the stage: each page on a card of its own, the gap between
/// and around them the same glass and colour as the sidebar, so the column
/// and the frame read as one surface the pages sit in.
struct SplitStage<Pane: View>: View {
    @ObservedObject var browser: Browser
    let left: Tab
    let right: Tab
    let pane: (Tab) -> Pane

    @Environment(\.colorScheme) private var scheme
    /// The share the left page had when the gap was picked up.
    @State private var grabbed: CGFloat?
    @State private var onHandle = false

    var body: some View {
        GeometryReader { geo in
            let gap = Split.gap
            let usable = max(1, geo.size.width - gap * 3)
            let fraction = min(0.8, max(0.2, browser.split?.fraction ?? 0.5))
            HStack(spacing: 0) {
                card(left).frame(width: usable * fraction)
                handle(usable: usable, fraction: fraction).frame(width: gap)
                card(right)
            }
            .padding(gap)
        }
        .background { ground }
    }

    private var tint: PageTint? {
        browser.prefs.sideTint ? PageTint(browser.activeHue, over: scheme) : nil
    }

    /// Lines drawn on the frame: light on a dark page's colour, dark on
    /// any other.
    private var ink: Color {
        (tint?.dark ?? (scheme == .dark)) ? .white : .black
    }

    /// The same surface as the sidebar's (SideBar's background): the
    /// desktop through glass, under the page's colour when there is one.
    private var ground: some View {
        ZStack {
            SideGlass(dark: tint?.dark)
            if let tint { tint.wash } else { Palette.ground.opacity(0.45) }
        }
        .animation(Motion.glide, value: tint)
    }

    private func card(_ tab: Tab) -> some View {
        let front = tab.id == browser.activeID
        let shape = RoundedRectangle(cornerRadius: Split.corner, style: .continuous)
        return pane(tab)
            .clipShape(shape)
            // A click anywhere in the page puts it in front; the click still
            // goes on to the page.
            .overlay { PaneClick { if tab.id != browser.activeID { browser.select(tab) } } }
            // The page in front, ringed; the other only edged.
            .overlay {
                shape.strokeBorder(ink.opacity(front ? 0.28 : 0.08), lineWidth: front ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(front ? 0.16 : 0.06), radius: front ? 10 : 4, y: 2)
            .animation(Motion.quick, value: front)
    }

    /// The gap between the two: pulled to give one page more room,
    /// double-clicked to share it evenly again.
    private func handle(usable: CGFloat, fraction: CGFloat) -> some View {
        Capsule()
            .fill(ink.opacity(onHandle || grabbed != nil ? 0.35 : 0))
            .frame(width: 3, height: 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { over in
                onHandle = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = fraction }
                        let wanted = (grabbed ?? fraction) + value.translation.width / usable
                        browser.split?.fraction = min(0.8, max(0.2, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { browser.split?.fraction = 0.5 }
            })
            .animation(Motion.quick, value: onHandle)
    }
}

/// Hears a click inside its bounds without taking it: the page underneath
/// still gets every click, and this only learns there was one.
private struct PaneClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) { view.act = act }

    final class Watcher: NSView {
        var act: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.act() }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
