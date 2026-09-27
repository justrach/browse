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

    enum Side { case left, right }

    func has(_ id: Tab.ID?) -> Bool { id == left || id == right }

    /// The frame around and between the two pages, their corners, and the
    /// strip over each that names it.
    static let gap: CGFloat = 8
    static let corner: CGFloat = 10
    static let header: CGFloat = 30

    /// Shares the gap settles on when let go near one: thirds and halves.
    static let stops: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3]
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

    /// `tab` on one side of the stage. Beside the tab in front when there's
    /// one page; in place of whatever is on that side when there are two.
    /// `tab` is put in front either way.
    func open(_ tab: Tab, on side: Split.Side = .right) {
        guard let active else { return }
        if talkOnStage { leaveStage() }
        var pair: Split
        if let shown = shownSplit {
            // Already one of the two: to the side asked for.
            if shown.left === tab || shown.right === tab {
                if (side == .left) != (shown.left === tab) { swapSplit() }
                select(tab)
                return
            }
            let other = side == .left ? shown.right : shown.left
            pair = Split(left: side == .left ? tab.id : other.id, right: side == .left ? other.id : tab.id,
                         fraction: split?.fraction ?? 0.5)
        } else {
            guard active.id != tab.id else { return }
            // An empty tab has nothing to put beside: the page just takes it.
            guard !active.isBlank else { select(tab); return }
            pair = Split(left: side == .left ? tab.id : active.id, right: side == .left ? active.id : tab.id)
        }
        withAnimation(Motion.glide) {
            split = pair
            keepTogether(pair)
        }
        select(tab)
        wakePair()
    }

    /// The tab in front beside the tab looked at before it — the other way
    /// round from `open`, since what you were reading stays in front.
    func split(with tab: Tab) {
        guard let active, active.id != tab.id, !active.isBlank, !tab.isBlank else { return }
        if talkOnStage { leaveStage() }
        let pair = Split(left: active.id, right: tab.id)
        withAnimation(Motion.glide) {
            split = pair
            keepTogether(pair)
        }
        wakePair()
    }

    /// ⌘D: the pair on screen goes back to one page; otherwise the tab in
    /// front is split with the tab looked at before it.
    func toggleSplit() {
        if shownSplit != nil { unsplit(); return }
        guard let active, !active.isBlank else { NSSound.beep(); return }
        let others = tabs.filter { $0.id != active.id && !$0.isBlank && !$0.shy }
        guard let partner = others.max(by: { $0.touched < $1.touched }) else { NSSound.beep(); return }
        split(with: partner)
    }

    func unsplit() {
        withAnimation(Motion.glide) { split = nil }
    }

    /// One of the two, on its own: the pair is let go and it stays in front.
    func alone(_ tab: Tab) {
        select(tab)
        unsplit()
    }

    /// One of the two taken off the stage: the other has it, the tab stays
    /// open in the list.
    func dropSide(_ tab: Tab) {
        guard let pair = shownSplit else { return }
        alone(pair.left === tab ? pair.right : pair.left)
    }

    /// Left and right change places.
    func swapSplit() {
        guard var pair = split else { return }
        swap(&pair.left, &pair.right)
        pair.fraction = 1 - pair.fraction
        withAnimation(Motion.glide) {
            split = pair
            keepTogether(pair)
        }
    }

    /// Both pages of the pair on screen are woken, not just the one picked.
    func wakePair() {
        guard let pair = shownSplit else { return }
        for tab in [pair.left, pair.right] where tab.id != activeID {
            if !tab.wake() { tab.revive() }
        }
    }

    /// The two next to each other in the list, left above right, so the
    /// sidebar can hold them as one (SideBar's pair frame). Pinned tabs keep
    /// their places.
    private func keepTogether(_ pair: Split) {
        guard let left = tabs.first(where: { $0.id == pair.left }),
              let right = tabs.first(where: { $0.id == pair.right }),
              left.pin == nil, right.pin == nil,
              let l = tabs.firstIndex(where: { $0 === left }),
              let r = tabs.firstIndex(where: { $0 === right }) else { return }
        // Where the right one lands once it's taken out and put back just
        // after the left.
        let wanted = r < l ? l : l + 1
        if wanted != r { move(right, to: wanted) }
    }

    // MARK: - a tab pulled out of the sidebar onto the page

    /// Where a tab being carried out of the sidebar is, in the window;
    /// nil while it's still among the others.
    func dragOut(_ tab: Tab, at point: CGPoint?) {
        guard splitDrag != point else { return }
        splitDrag = point
    }

    /// The side of the stage a point is over.
    func splitSide(at point: CGPoint) -> Split.Side {
        point.x < stageFrame.midX ? .left : .right
    }

    /// Let go of over the page: opened on the half it was let go over.
    func dropOut(_ tab: Tab) {
        defer { splitDrag = nil }
        guard let point = splitDrag, stageFrame.contains(point) else { return }
        // The page in front, dropped on itself, has nothing to go beside.
        if shownSplit == nil, tab.id == activeID { return }
        open(tab, on: splitSide(at: point))
    }
}

/// The pair on the stage: each page on a card of its own under a strip
/// that names it, the gap between and around them the same glass and
/// colour as the sidebar, so the column and the frame read as one surface
/// the pages sit in.
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
                column(left, width: usable * fraction, usable: usable)
                handle(usable: usable, fraction: fraction).frame(width: gap)
                column(right, width: nil, usable: usable)
            }
            .padding(.horizontal, gap)
            .padding(.bottom, gap)
            // A share while the gap is held, where it'll be let go.
            .overlay(alignment: .top) {
                if grabbed != nil {
                    Text("\(Int((fraction * 100).rounded())) : \(Int(((1 - fraction) * 100).rounded()))")
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(ink.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: gap + usable * fraction + gap / 2 - geo.size.width / 2, y: Split.header + 12)
                        .transition(.opacity)
                }
            }
        }
        .background { ground }
        .environment(\.colorScheme, tint.map { $0.dark ? .dark : .light } ?? scheme)
    }

    private var tint: PageTint? {
        browser.prefs.sideTint ? PageTint(browser.activeHue, over: scheme) : nil
    }

    /// Lines and words drawn on the frame: light on a dark page's colour,
    /// dark on any other.
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

    private func column(_ tab: Tab, width: CGFloat?, usable: CGFloat) -> some View {
        VStack(spacing: 0) {
            PaneHeader(browser: browser, tab: tab, ink: ink, width: width ?? usable / 2)
                .frame(height: Split.header)
            card(tab)
        }
        .frame(width: width)
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

    /// The gap between the two: pulled to give one page more room — settling
    /// on a third, a half or two thirds when let go near one — and
    /// double-clicked to share it evenly again.
    private func handle(usable: CGFloat, fraction: CGFloat) -> some View {
        Capsule()
            .fill(ink.opacity(onHandle || grabbed != nil ? 0.4 : 0.12))
            .frame(width: onHandle || grabbed != nil ? 4 : 3, height: 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, Split.header)
            .contentShape(Rectangle())
            .onHover { over in
                onHandle = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { withAnimation(Motion.quick) { grabbed = fraction } }
                        var wanted = (grabbed ?? fraction) + value.translation.width / usable
                        // A little pull towards the stops, so they're easy to
                        // land on and easy to leave.
                        if let stop = Split.stops.first(where: { abs($0 - wanted) < 0.02 }) { wanted = stop }
                        browser.split?.fraction = min(0.8, max(0.2, wanted))
                    }
                    .onEnded { _ in withAnimation(Motion.quick) { grabbed = nil } }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { browser.split?.fraction = 0.5 }
            })
            .animation(Motion.quick, value: onHandle)
    }
}

/// The strip over a page in a split: what it is, and what can be done with
/// it. A click puts it in front; pulled to the other side, the two change
/// places.
private struct PaneHeader: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let ink: Color
    let width: CGFloat

    @State private var hovering = false
    @State private var travel: CGFloat = 0

    private var front: Bool { tab.id == browser.activeID }
    private var onLeft: Bool { browser.split?.left == tab.id }

    var body: some View {
        HStack(spacing: 7) {
            if !tab.isBlank {
                Mark(icon: tab.icon, letter: tab.monogram, size: 14)
            }
            Text(tab.label)
                .font(.system(size: 12, weight: front ? .semibold : .regular))
                .foregroundStyle(ink.opacity(front ? 0.9 : 0.6))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                act("arrow.left.arrow.right", "Swap Sides") { browser.swapSplit() }
                act("arrow.up.left.and.arrow.down.right", "Just This One") { browser.alone(tab) }
                act("xmark", "Close This Side — the tab stays open") { browser.dropSide(tab) }
            }
            .opacity(hovering || front ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .offset(x: travel)
        .onHover { hovering = $0 }
        .onTapGesture { if !front { browser.select(tab) } }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { travel = $0.translation.width }
                .onEnded { value in
                    // Past a third of the page towards the other side: they
                    // change places.
                    let across = onLeft ? value.translation.width : -value.translation.width
                    if across > width / 3 { browser.swapSplit() }
                    withAnimation(Motion.settle) { travel = 0 }
                }
        )
        .contextMenu {
            Button("Swap Sides") { browser.swapSplit() }
            Button("Just This One") { browser.alone(tab) }
            Button("Close This Side") { browser.dropSide(tab) }
            Divider()
            Button("Leave Split View") { browser.unsplit() }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: front)
    }

    private func act(_ icon: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ink.opacity(0.55))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Over the stage while a tab is carried out of the sidebar: the half it
/// would open on, lit, and what letting go does.
struct SplitDropZone: View {
    @ObservedObject var browser: Browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let side = browser.splitDrag.map { browser.splitSide(at: $0) }
            ZStack(alignment: side == .left ? .leading : .trailing) {
                Color.clear
                if let side {
                    let shape = RoundedRectangle(cornerRadius: Split.corner, style: .continuous)
                    shape
                        .fill(Palette.accent.opacity(0.10))
                        .overlay(shape.strokeBorder(Palette.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                        .overlay {
                            Label(side == .left ? "Open on the left" : "Open on the right", systemImage: "rectangle.split.2x1")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .frame(width: frame.width / 2 - Split.gap * 1.5)
                        .padding(Split.gap)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: side)
            .onAppear { browser.stageFrame = frame }
            .onChange(of: frame) { _, new in browser.stageFrame = new }
        }
        .allowsHitTesting(false)
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
