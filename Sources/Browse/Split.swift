import SwiftUI
import AppKit

/// Hook for `./bench split-drag` to drive the live split divider directly
/// through whichever path the active SplitStage uses.
@MainActor
enum SplitDragBench {
    static var onBegin: (() -> Void)?
    static var onMove: ((CGFloat) -> Void)?
    static var onEnd: (() -> Void)?
    static var mode: String { onMove != nil ? "appkit-direct" : "swiftui-published" }

    static func begin() { onBegin?() }
    static func move(to fraction: CGFloat) -> Bool {
        guard let onMove else { return false }
        onMove(fraction)
        return true
    }
    static func end() { onEnd?() }
}

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
    /// When true, scrolling either pane scrolls its partner by the same delta.
    var syncsScroll: Bool = false

    enum Side { case left, right }

    func has(_ id: Tab.ID?) -> Bool { id == left || id == right }
    func other(than id: Tab.ID) -> Tab.ID? {
        if id == left { return right }
        if id == right { return left }
        return nil
    }

    /// The frame around and between the two pages, their corners, and the
    /// strip over each that names it.
    static let gap: CGFloat = 6
    static let corner: CGFloat = 10
    static let header: CGFloat = 28

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
    /// front is split with the tab looked at before it. With no other page
    /// to put beside it — one page open, or an empty tab in front — the
    /// other side is an empty tab with the address field open, as a new tab
    /// is: ⌘D used to only beep there, and read as broken.
    func toggleSplit() {
        if shownSplit != nil { unsplit(); return }
        guard let active else { NSSound.beep(); return }
        let others = tabs.filter { $0.id != active.id && !$0.isBlank && !$0.shy }
        let last = others.max(by: { $0.touched < $1.touched })
        if !active.isBlank, let last {
            split(with: last)
            return
        }
        guard let page = active.isBlank ? last : active else { NSSound.beep(); return }
        if talkOnStage { leaveStage() }
        if !active.isBlank { newTab(immediate: true) }
        guard let empty = self.active, empty.id != page.id else { return }
        let pair = Split(left: page.id, right: empty.id)
        withAnimation(Motion.glide) {
            split = pair
            keepTogether(pair)
        }
        wakePair()
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
        applySyncScroll(previous: nil)
    }

    func evenSplit() {
        guard split != nil else { return }
        split?.fraction = 0.5
    }

    func closeSplit() {
        guard let pair = shownSplit else { return }
        split = nil
        close(pair.right)
        close(pair.left)
    }

    func toggleSyncScroll() {
        guard split != nil else { return }
        split?.syncsScroll.toggle()
    }

    func applySyncScroll(previous: Split?) {
        let on = split?.syncsScroll == true
        if let prev = previous {
            for id in [prev.left, prev.right] where !(split?.has(id) == true && on) {
                tabs.first(where: { $0.id == id })?.setSplitScrollSync(false)
            }
        }
        guard let cur = split else { return }
        for id in [cur.left, cur.right] {
            tabs.first(where: { $0.id == id })?.setSplitScrollSync(on)
        }
    }

    func syncScroll(from tab: Tab, by dy: Double) {
        guard let pair = split, pair.syncsScroll,
              pair.has(tab.id), let partnerID = pair.other(than: tab.id),
              dy.isFinite, dy != 0,
              let web = tabs.first(where: { $0.id == partnerID })?.built
        else { return }
        let js = "window.scrollBy({ top: \(dy), left: 0, behavior: 'instant' }); window.__browseSynced = window.scrollY; 0"
        web.evaluateJavaScript(js, in: nil, in: Web.world) { _ in }
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
///
/// Resizing runs directly in AppKit (`SplitDeck` / `SplitContainerView`) with
/// cached `CALayer.shadowPath` and zero `@Published` mutations during drag,
/// committing the final fraction to `Browser` once on release so ProMotion
/// displays stay locked at 120 Hz.
struct SplitStage<Overlay: View>: View {
    @ObservedObject var browser: Browser
    @ObservedObject var left: Tab
    @ObservedObject var right: Tab
    var inUnifiedCanvas: Bool = false
    let overlay: (Tab) -> Overlay

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SplitDeck(
            browser: browser,
            left: left,
            right: right,
            fraction: min(0.82, max(0.18, browser.split?.fraction ?? 0.5)),
            activeID: browser.activeID,
            darkChrome: darkChrome,
            overlay: overlay,
            onCommit: { final in
                if browser.split?.fraction != final {
                    browser.split?.fraction = final
                }
            }
        )
        .background {
            if !inUnifiedCanvas { ground }
        }
        .environment(\.colorScheme, browser.fullScreen ? .dark : (tint.map { $0.dark ? .dark : .light } ?? scheme))
    }

    private var tint: PageTint? {
        browser.prefs.sideTint ? PageTint(browser.activeHue, over: scheme) : nil
    }

    private var darkChrome: Bool {
        browser.fullScreen || (tint?.dark ?? (scheme == .dark))
    }

    /// The same surface as the sidebar's (SideBar's background): pure black in
    /// Full Screen to blend into the bezel, or the desktop through glass under
    /// the page's colour when windowed.
    private var ground: some View {
        Group {
            if browser.fullScreen {
                Color.black
            } else {
                ZStack {
                    SideGlass(dark: tint?.dark)
                    if let tint { tint.wash } else { Palette.ground.opacity(0.45) }
                }
                .animation(Motion.glide, value: tint)
            }
        }
    }
}

/// AppKit bridge hosting both split panes directly (`StageView` + pure AppKit
/// headers, divider and ratio pill) so 120 Hz drags run with zero SwiftUI
/// layout passes.
private struct SplitDeck<Overlay: View>: NSViewRepresentable {
    let browser: Browser
    let left: Tab
    let right: Tab
    let fraction: CGFloat
    let activeID: Tab.ID?
    let darkChrome: Bool
    let overlay: (Tab) -> Overlay
    let onCommit: (CGFloat) -> Void

    func makeNSView(context: Context) -> SplitContainerView<Overlay> {
        SplitContainerView(
            leftOverlay: overlay(left),
            rightOverlay: overlay(right),
            fraction: fraction
        )
    }

    func updateNSView(_ view: SplitContainerView<Overlay>, context: Context) {
        view.onCommit = onCommit
        view.update(
            browser: browser,
            left: left,
            leftOverlay: overlay(left),
            leftFront: left.id == activeID,
            right: right,
            rightOverlay: overlay(right),
            rightFront: right.id == activeID,
            fraction: fraction,
            darkChrome: darkChrome
        )
    }
}

@MainActor
private final class SplitContainerView<Overlay: View>: NSView {
    private let leftSlot: SplitPaneSlot<Overlay>
    private let rightSlot: SplitPaneSlot<Overlay>
    private let divider = SplitDividerView()
    private let ratioPill = SplitRatioPill()

    private var liveFraction: CGFloat
    private var dragStartFraction: CGFloat = 0.5
    private var isDragging = false
    private var snappedStop: CGFloat?

    // 120 Hz display-link animation for double-click snap back to 50 : 50.
    private var snapLink: CADisplayLink?
    private var snapFrom: CGFloat = 0.5
    private var snapTarget: CGFloat = 0.5
    private var snapStarted: CFTimeInterval = 0
    private let snapDuration: CFTimeInterval = 0.24

    var onCommit: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    init(
        leftOverlay: Overlay,
        rightOverlay: Overlay,
        fraction: CGFloat
    ) {
        self.liveFraction = fraction
        self.leftSlot = SplitPaneSlot(overlay: leftOverlay, isLeft: true)
        self.rightSlot = SplitPaneSlot(overlay: rightOverlay, isLeft: false)
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(leftSlot)
        addSubview(rightSlot)
        addSubview(divider)
        addSubview(ratioPill)

        divider.onDragBegin = { [weak self] in self?.beginDrag() }
        divider.onDragDelta = { [weak self] dx in self?.dragBy(dx) }
        divider.onDragEnd = { [weak self] in self?.endDrag() }
        divider.onDoubleClick = { [weak self] in self?.animateSnap(to: 0.5) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            SplitDragBench.onBegin = { [weak self] in self?.beginDrag() }
            SplitDragBench.onMove = { [weak self] fraction in self?.applyLiveFraction(fraction, showPill: true) }
            SplitDragBench.onEnd = { [weak self] in self?.endDrag() }
        } else {
            stopSnap()
            SplitDragBench.onBegin = nil
            SplitDragBench.onMove = nil
            SplitDragBench.onEnd = nil
        }
    }

    func update(
        browser: Browser,
        left: Tab,
        leftOverlay: Overlay,
        leftFront: Bool,
        right: Tab,
        rightOverlay: Overlay,
        rightFront: Bool,
        fraction: CGFloat,
        darkChrome: Bool
    ) {
        leftSlot.update(browser: browser, tab: left, overlay: leftOverlay, front: leftFront, darkChrome: darkChrome)
        rightSlot.update(browser: browser, tab: right, overlay: rightOverlay, front: rightFront, darkChrome: darkChrome)
        divider.update(browser: browser)
        divider.setChrome(dark: darkChrome)
        ratioPill.setChrome(dark: darkChrome)
        if !isDragging && snapLink == nil && abs(liveFraction - fraction) > 0.0005 {
            liveFraction = fraction
            layoutPanes(fraction: liveFraction, live: false)
        }
    }

    override func layout() {
        super.layout()
        layoutPanes(fraction: liveFraction, live: isDragging || snapLink != nil)
    }

    private func beginDrag() {
        stopSnap()
        isDragging = true
        dragStartFraction = liveFraction
        snappedStop = nil
        divider.setDragging(true)
        leftSlot.startLiveResize()
        rightSlot.startLiveResize()
        ratioPill.setVisible(true)
        layoutPanes(fraction: liveFraction, live: true)
    }

    private func dragBy(_ dx: CGFloat) {
        let usable = max(1, bounds.width - Split.gap * 3)
        var wanted = dragStartFraction + dx / usable
        if let stop = Split.stops.first(where: { abs($0 - wanted) < 0.014 }) {
            wanted = stop
            if snappedStop != stop {
                snappedStop = stop
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else {
            snappedStop = nil
        }
        applyLiveFraction(wanted, showPill: true)
    }

    private func applyLiveFraction(_ wanted: CGFloat, showPill: Bool) {
        let clamped = min(0.82, max(0.18, wanted))
        guard clamped != liveFraction || showPill else { return }
        liveFraction = clamped
        layoutPanes(fraction: clamped, live: true)
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        snappedStop = nil
        divider.setDragging(false)
        ratioPill.setVisible(false)
        leftSlot.endLiveResize()
        rightSlot.endLiveResize()
        layoutPanes(fraction: liveFraction, live: false)
        onCommit?(liveFraction)
    }

    private func animateSnap(to target: CGFloat) {
        stopSnap()
        snapFrom = liveFraction
        snapTarget = target
        guard abs(snapFrom - snapTarget) > 0.001 else { return }
        snapStarted = CACurrentMediaTime()
        leftSlot.startLiveResize()
        rightSlot.startLiveResize()
        let link = displayLink(target: self, selector: #selector(stepSnap(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        snapLink = link
    }

    @objc private func stepSnap(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - snapStarted
        let t = min(1, max(0, elapsed / snapDuration))
        let eased = 1 - pow(1 - t, 3)
        let current = snapFrom + (snapTarget - snapFrom) * eased
        applyLiveFraction(current, showPill: false)
        if t >= 1 {
            stopSnap()
            layoutPanes(fraction: snapTarget, live: false)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            onCommit?(snapTarget)
        }
    }

    private func stopSnap() {
        guard snapLink != nil else { return }
        snapLink?.invalidate()
        snapLink = nil
        leftSlot.endLiveResize()
        rightSlot.endLiveResize()
    }

    private func layoutPanes(fraction: CGFloat, live: Bool) {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let gap = Split.gap
        let usable = max(1, width - gap * 3)
        let leftWidth = (usable * fraction).rounded()
        let rightWidth = max(1, usable - leftWidth)
        let paneHeight = max(0, height - gap)

        leftSlot.layoutSlot(frame: CGRect(x: gap, y: 0, width: leftWidth, height: paneHeight), live: live)
        rightSlot.layoutSlot(frame: CGRect(x: gap * 2 + leftWidth, y: 0, width: rightWidth, height: paneHeight), live: live)

        let hitWidth: CGFloat = 16
        let dividerX = gap + leftWidth + gap / 2 - hitWidth / 2
        divider.frame = CGRect(x: dividerX.rounded(), y: Split.header, width: hitWidth, height: max(0, paneHeight - Split.header))

        if isDragging {
            let leftPct = Int((fraction * 100).rounded())
            ratioPill.update(text: "\(leftPct) : \(100 - leftPct)")
            let pillSize = ratioPill.intrinsicContentSize
            let pillCenterX = gap + leftWidth + gap / 2
            let pillX = min(max(gap, pillCenterX - pillSize.width / 2), width - gap - pillSize.width)
            ratioPill.frame = CGRect(x: pillX.rounded(), y: Split.header + 12, width: pillSize.width, height: pillSize.height)
        }
    }
}

/// Hosting view for rare page overlays (FindBar, LinkBubble, FormPill, errors)
/// that passes clicks on empty regions straight through to the WKWebView below.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One half of a split: pure AppKit header above, hardware-shadowed rounded
/// card hosting `StageView` directly below (zero SwiftUI in the 120 Hz loop).
@MainActor
private final class SplitPaneSlot<Overlay: View>: NSView {
    private struct OverlayKey: Equatable {
        var browserID: ObjectIdentifier
        var tabID: Tab.ID
        var front: Bool
        var showsLinks: Bool
        var finding: Bool
        var suggesting: Browser.Suggesting?
        var pageSelection: PageSelection?
        var viewport: CGSize
        var usesAgent: Bool
    }

    private let headerView: SplitHeaderView
    private let shadowView = NSView()
    private let clipView = NSView()
    private let stageView = StageView()
    private let overlayHost: PassThroughHostingView<Overlay>
    private let borderLayer = CALayer()

    private var onFocus: (() -> Void)?
    private var clickMonitor: Any?
    private var lastCardSize: CGSize = .zero
    private var lastFront: Bool?
    private var lastDarkChrome: Bool?
    private var lastOverlayKey: OverlayKey?

    override var isFlipped: Bool { true }

    init(overlay: Overlay, isLeft: Bool) {
        self.headerView = SplitHeaderView(isLeft: isLeft)
        self.overlayHost = PassThroughHostingView(rootView: overlay)
        super.init(frame: .zero)

        overlayHost.sizingOptions = []
        stageView.round(0)

        let noAnim: [String: CAAction] = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "shadowPath": NSNull(),
            "cornerRadius": NSNull(),
        ]

        shadowView.wantsLayer = true
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        shadowView.layer?.actions = noAnim

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Split.corner
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.layer?.actions = noAnim

        borderLayer.cornerRadius = Split.corner
        borderLayer.cornerCurve = .continuous
        borderLayer.zPosition = 100
        borderLayer.actions = noAnim

        addSubview(headerView)
        addSubview(shadowView)
        shadowView.addSubview(clipView)
        clipView.addSubview(stageView)
        clipView.addSubview(overlayHost)
        clipView.layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let pt = self.shadowView.convert(event.locationInWindow, from: nil)
            if self.shadowView.bounds.contains(pt) { self.onFocus?() }
            return event
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    func update(browser: Browser, tab: Tab, overlay: Overlay, front: Bool, darkChrome: Bool) {
        self.onFocus = { [weak browser, weak tab] in
            guard let browser, let tab, tab.id != browser.activeID else { return }
            browser.select(tab)
        }
        stageView.show(tab.isBlank || tab.asleep || tab.floating ? nil : tab.web)

        let shownSuggesting = (browser.suggesting?.tab == tab.id) ? browser.suggesting : nil
        let shownSelection = (front && browser.pageSelection?.tabID == tab.id) ? browser.pageSelection : nil
        let overlayKey = OverlayKey(
            browserID: ObjectIdentifier(browser),
            tabID: tab.id,
            front: front,
            showsLinks: front && browser.prefs.showsLinks,
            finding: front && browser.finding,
            suggesting: shownSuggesting,
            pageSelection: shownSelection,
            viewport: shownSelection != nil ? (tab.built?.bounds.size ?? .zero) : .zero,
            usesAgent: shownSelection != nil && browser.prefs.usesAgent
        )
        if lastOverlayKey != overlayKey {
            lastOverlayKey = overlayKey
            overlayHost.rootView = overlay
        }

        headerView.update(browser: browser, tab: tab, front: front, darkChrome: darkChrome)

        if lastFront != front || lastDarkChrome != darkChrome {
            lastFront = front
            lastDarkChrome = darkChrome
            let inkColor: NSColor = darkChrome ? .white : .black
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            shadowView.layer?.shadowOpacity = front ? 0.055 : 0.015
            shadowView.layer?.shadowRadius = front ? 4 : 1.5
            borderLayer.borderWidth = 1.0
            borderLayer.borderColor = inkColor.withAlphaComponent(front ? 0.15 : 0.07).cgColor
            CATransaction.commit()
        }
    }

    func startLiveResize() {
        stageView.startLiveResize()
    }

    func endLiveResize() {
        stageView.endLiveResize()
    }

    func layoutSlot(frame newFrame: CGRect, live: Bool) {
        if frame != newFrame { frame = newFrame }
        let width = newFrame.width
        let cardHeight = max(0, newFrame.height - Split.header)

        let headerRect = CGRect(x: 0, y: 0, width: width, height: Split.header)
        if headerView.frame != headerRect { headerView.frame = headerRect }

        let cardRect = CGRect(x: 0, y: Split.header, width: width, height: cardHeight)
        if shadowView.frame != cardRect { shadowView.frame = cardRect }

        let localCard = CGRect(origin: .zero, size: cardRect.size)
        if clipView.frame != localCard { clipView.frame = localCard }
        if stageView.frame != localCard { stageView.frame = localCard }
        if !live, overlayHost.frame != localCard { overlayHost.frame = localCard }
        if borderLayer.frame != localCard { borderLayer.frame = localCard }

        if lastCardSize != cardRect.size {
            lastCardSize = cardRect.size
            if cardRect.width > 0, cardRect.height > 0 {
                let r = min(Split.corner, min(cardRect.width, cardRect.height) / 2)
                shadowView.layer?.shadowPath = CGPath(
                    roundedRect: localCard,
                    cornerWidth: r,
                    cornerHeight: r,
                    transform: nil
                )
            } else {
                shadowView.layer?.shadowPath = nil
            }
        }
    }
}

/// Pure AppKit header strip over each split card: favicon/monogram, title,
/// hover-revealed swap/expand/close buttons, drag-to-swap, and context menu.
@MainActor
private final class SplitHeaderView: NSView {
    private struct Snapshot: Equatable {
        let tabID: Tab.ID
        let label: String
        let isBlank: Bool
        let iconID: ObjectIdentifier?
        let monogram: String
        let front: Bool
        let darkChrome: Bool
        let buttonsVisible: Bool
        let accentCG: CGColor
    }

    private let isLeft: Bool
    private let activeDot = CALayer()
    private let iconView = NSImageView()
    private let monogramField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let swapBtn = SplitHeaderButton()
    private let aloneBtn = SplitHeaderButton()
    private let closeBtn = SplitHeaderButton()

    private weak var browser: Browser?
    private weak var tab: Tab?
    private weak var lastIcon: NSImage?
    private var lastSnapshot: Snapshot?
    private var front = false
    private var darkChrome = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var dragStartX: CGFloat?
    private var dragTravel: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(isLeft: Bool) {
        self.isLeft = isLeft
        super.init(frame: .zero)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown

        monogramField.alignment = .center
        monogramField.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        monogramField.drawsBackground = false
        monogramField.isBezeled = false
        monogramField.wantsLayer = true
        monogramField.layer?.cornerRadius = 3.5

        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.drawsBackground = false
        titleField.isBezeled = false

        configureButton(swapBtn, symbol: "arrow.left.arrow.right", help: "Swap Sides", action: #selector(swapSides))
        configureButton(aloneBtn, symbol: "arrow.up.left.and.arrow.down.right", help: "Just This One", action: #selector(justThisOne))
        configureButton(closeBtn, symbol: "xmark", help: "Close This Side — the tab stays open", action: #selector(closeSide))

        activeDot.cornerRadius = 2.5
        layer?.addSublayer(activeDot)
        addSubview(iconView)
        addSubview(monogramField)
        addSubview(titleField)
        addSubview(swapBtn)
        addSubview(aloneBtn)
        addSubview(closeBtn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureButton(_ btn: SplitHeaderButton, symbol: String, help: String, action: Selector) {
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.imagePosition = .imageOnly
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
        btn.toolTip = help
        btn.target = self
        btn.action = action
    }

    func update(browser: Browser, tab: Tab, front: Bool, darkChrome: Bool) {
        self.browser = browser
        self.tab = tab
        self.front = front
        self.darkChrome = darkChrome

        let label = tab.label
        let isBlank = tab.isBlank
        let icon = isBlank ? nil : tab.icon
        let monogram = (isBlank || icon != nil) ? "" : tab.monogram
        let buttonsVisible = hovering || front
        let accentCG = resolvedAccentCGColor()
        let snap = Snapshot(
            tabID: tab.id,
            label: label,
            isBlank: isBlank,
            iconID: icon.map { ObjectIdentifier($0) },
            monogram: monogram,
            front: front,
            darkChrome: darkChrome,
            buttonsVisible: buttonsVisible,
            accentCG: accentCG
        )
        if lastSnapshot == snap, lastIcon === icon { return }

        let prev = lastSnapshot
        let needsGeometryLayout = prev == nil || prev?.front != front || prev?.isBlank != isBlank
        lastSnapshot = snap
        lastIcon = icon

        let ink: NSColor = darkChrome ? .white : .black
        activeDot.backgroundColor = accentCG
        activeDot.opacity = front ? 0.9 : 0

        if prev?.label != label {
            titleField.stringValue = label
        }
        if prev?.front != front || prev?.darkChrome != darkChrome {
            titleField.font = NSFont.systemFont(ofSize: 11.5, weight: front ? .semibold : .regular)
            titleField.textColor = ink.withAlphaComponent(front ? 0.9 : 0.55)
        }

        if isBlank {
            iconView.image = nil
            iconView.isHidden = true
            monogramField.isHidden = true
        } else if let icon {
            if prev?.iconID != snap.iconID { iconView.image = icon }
            iconView.isHidden = false
            monogramField.isHidden = true
        } else {
            iconView.image = nil
            iconView.isHidden = true
            monogramField.isHidden = false
            monogramField.stringValue = monogram
            monogramField.textColor = ink.withAlphaComponent(0.75)
            monogramField.layer?.backgroundColor = ink.withAlphaComponent(0.08).cgColor
        }

        let btnTint = ink.withAlphaComponent(0.55)
        let btnHoverTint = ink.withAlphaComponent(0.08)
        let btnAlpha: CGFloat = buttonsVisible ? 1 : 0
        for btn in [swapBtn, aloneBtn, closeBtn] {
            if prev?.darkChrome != darkChrome {
                btn.contentTintColor = btnTint
                btn.setHoverTint(btnHoverTint)
            }
            btn.alphaValue = btnAlpha
        }
        if needsGeometryLayout { needsLayout = true }
    }

    private func resolvedAccentCGColor() -> CGColor {
        var cg: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = Palette.NS.accent.cgColor
        }
        return cg ?? Palette.NS.accent.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateButtonAlpha()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateButtonAlpha()
    }

    private func updateButtonAlpha() {
        let target: CGFloat = (hovering || front) ? 1 : 0
        for btn in [swapBtn, aloneBtn, closeBtn] { btn.alphaValue = target }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let btnW: CGFloat = 22
        let btnGap: CGFloat = 2
        let rightPad: CGFloat = 6
        let buttonsWidth = btnW * 3 + btnGap * 2
        let buttonsX = max(6, w - rightPad - buttonsWidth)

        let btnY = ((h - btnW) / 2).rounded()
        swapBtn.frame = CGRect(x: buttonsX, y: btnY, width: btnW, height: btnW)
        aloneBtn.frame = CGRect(x: buttonsX + btnW + btnGap, y: btnY, width: btnW, height: btnW)
        closeBtn.frame = CGRect(x: buttonsX + (btnW + btnGap) * 2, y: btnY, width: btnW, height: btnW)

        var x: CGFloat = 6 + dragTravel
        if front {
            activeDot.frame = CGRect(x: x, y: ((h - 5) / 2).rounded(), width: 5, height: 5)
            x += 11
        } else {
            activeDot.frame = .zero
        }
        if !iconView.isHidden || !monogramField.isHidden {
            let iconRect = CGRect(x: x, y: ((h - 13) / 2).rounded(), width: 13, height: 13)
            iconView.frame = iconRect
            monogramField.frame = iconRect
            x += 19
        }
        let titleH: CGFloat = 15
        let titleW = max(0, buttonsX - 4 - x)
        titleField.frame = CGRect(x: x, y: ((h - titleH) / 2).rounded(), width: titleW, height: titleH)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragTravel = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        let dx = event.locationInWindow.x - start
        if abs(dx) >= 6 {
            dragTravel = dx
            needsLayout = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartX = nil
            if dragTravel != 0 {
                dragTravel = 0
                needsLayout = true
            }
        }
        if abs(dragTravel) < 6 {
            if let browser, let tab, !front { browser.select(tab) }
            return
        }
        let across = isLeft ? dragTravel : -dragTravel
        if across > 120 { browser?.swapSplit() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Swap Sides", action: #selector(swapSides), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Just This One", action: #selector(justThisOne), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close This Side", action: #selector(closeSide), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let sync = NSMenuItem(title: "Sync Scrolling", action: #selector(toggleSync), keyEquivalent: "")
        sync.target = self
        sync.state = browser?.split?.syncsScroll == true ? .on : .off
        menu.addItem(sync)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Leave Split View", action: #selector(leaveSplit), keyEquivalent: "").target = self
        return menu
    }

    @objc private func swapSides() { browser?.swapSplit() }
    @objc private func justThisOne() { if let tab { browser?.alone(tab) } }
    @objc private func closeSide() { if let tab { browser?.dropSide(tab) } }
    @objc private func toggleSync() { browser?.toggleSyncScroll() }
    @objc private func leaveSplit() { browser?.unsplit() }
}

/// Subtle hoverable icon button for split headers.
@MainActor
private final class SplitHeaderButton: NSButton {
    private var hoverTint: NSColor = NSColor.black.withAlphaComponent(0.08)
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHoverTint(_ color: NSColor) {
        hoverTint = color
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverTint.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

/// Native AppKit split handle: generous 16pt hit area, full-height hover/drag
/// guide rail, tactile accent grab capsule, and double-click snap back to 50 : 50.
@MainActor
private final class SplitDividerView: NSView {
    weak var browser: Browser?
    var onDragBegin: (() -> Void)?
    var onDragDelta: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    func update(browser: Browser) {
        self.browser = browser
    }

    private let guideLine = CALayer()
    private let pill = CALayer()
    private var darkChrome = false
    private var hovering = false
    private var dragging = false
    private var dragStartX: CGFloat = 0
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guideLine.cornerRadius = 0.75
        layer?.addSublayer(guideLine)
        layer?.addSublayer(pill)
        stylePill(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setChrome(dark: Bool) {
        guard darkChrome != dark else { return }
        darkChrome = dark
        stylePill(animated: true)
    }

    func setDragging(_ on: Bool) {
        guard dragging != on else { return }
        dragging = on
        stylePill(animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        positionPill()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        stylePill(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        stylePill(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStartX = event.locationInWindow.x
        onDragBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDragDelta?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Swap Sides", action: #selector(swapSides), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Equal Widths", action: #selector(equalWidths), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let sync = NSMenuItem(title: "Sync Scrolling", action: #selector(toggleSync), keyEquivalent: "")
        sync.target = self
        sync.state = browser?.split?.syncsScroll == true ? .on : .off
        menu.addItem(sync)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Leave Split View", action: #selector(leaveSplit), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Both Sides", action: #selector(closeBoth), keyEquivalent: "").target = self
        return menu
    }

    @objc private func swapSides() { browser?.swapSplit() }
    @objc private func equalWidths() { browser?.evenSplit() }
    @objc private func toggleSync() { browser?.toggleSyncScroll() }
    @objc private func leaveSplit() { browser?.unsplit() }
    @objc private func closeBoth() { browser?.closeSplit() }

    private func positionPill() {
        let active = hovering || dragging
        let railW: CGFloat = dragging ? 2.0 : 1.5
        guideLine.frame = CGRect(
            x: ((bounds.width - railW) / 2).rounded(.toNearestOrAwayFromZero),
            y: 6,
            width: railW,
            height: max(0, bounds.height - 12)
        )
        let w: CGFloat = active ? 4.0 : 2.5
        let h: CGFloat = active ? 48 : 32
        pill.frame = CGRect(
            x: ((bounds.width - w) / 2).rounded(.toNearestOrAwayFromZero),
            y: ((bounds.height - h) / 2).rounded(),
            width: w,
            height: h
        )
        pill.cornerRadius = w / 2
    }

    private func stylePill(animated: Bool) {
        let base: NSColor = darkChrome ? .white : .black
        let accent = NSColor(Palette.accent)
        let pillColor: NSColor = dragging
            ? accent
            : base.withAlphaComponent(hovering ? 0.42 : 0.16)
        let railColor: NSColor = dragging
            ? accent.withAlphaComponent(0.55)
            : (hovering ? base.withAlphaComponent(0.14) : .clear)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.14 : 0)
        guideLine.backgroundColor = railColor.cgColor
        pill.backgroundColor = pillColor.cgColor
        positionPill()
        CATransaction.commit()
    }
}

/// Floating translucent ratio capsule (`50 : 50`) updated directly in AppKit
/// during live divider drags without withinWindow backdrop blur overhead.
@MainActor
private final class SplitRatioPill: NSView {
    private let label = NSTextField(labelWithString: "50 : 50")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        alphaValue = 0
        isHidden = true

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
        setChrome(dark: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 62, height: 22)
    }

    override func layout() {
        super.layout()
        let text = label.intrinsicContentSize
        label.frame = CGRect(
            x: 0,
            y: ((bounds.height - text.height) / 2).rounded(),
            width: bounds.width,
            height: text.height
        )
    }

    func setChrome(dark: Bool) {
        let base: NSColor = dark ? .white : .black
        let fill: NSColor = dark
            ? NSColor(calibratedWhite: 0.14, alpha: 0.92)
            : NSColor(calibratedWhite: 0.97, alpha: 0.92)
        layer?.backgroundColor = fill.cgColor
        label.textColor = base.withAlphaComponent(0.88)
        layer?.borderColor = base.withAlphaComponent(0.14).cgColor
    }

    func update(text: String) {
        if label.stringValue != text {
            label.stringValue = text
        }
    }

    func setVisible(_ visible: Bool) {
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.16
            self.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if !visible, self?.alphaValue == 0 { self?.isHidden = true }
            }
        }
    }
}

/// Non-observable frame cache for sidebar rows so layout updates never trigger SwiftUI redraws.
final class SplitRowFrames {
    var rects: [Tab.ID: CGRect] = [:]
    var resolver: (() -> [Tab.ID: CGRect])?

    func currentRects() -> [Tab.ID: CGRect] {
        resolver?() ?? rects
    }
}

@MainActor
final class SplitMergeState: ObservableObject {
    static let shared = SplitMergeState()

    struct Shown: Equatable {
        let browserID: ObjectIdentifier
        let targetID: Tab.ID
        let sourceID: Tab.ID
        let onLeft: Bool
    }

    @Published var shown: Shown?
    private init() {}
}

enum SplitMergeResolver {
    static func resolve(
        point: CGPoint,
        dragging sourceID: Tab.ID,
        in rects: [Tab.ID: CGRect],
        browserID: ObjectIdentifier,
        canSplit: Bool
    ) -> SplitMergeState.Shown? {
        guard canSplit else { return nil }
        for (targetID, rect) in rects where targetID != sourceID {
            guard rect.height > 0, rect.width > 0 else { continue }
            let bandMinY = rect.minY + rect.height * 0.28
            let bandMaxY = rect.maxY - rect.height * 0.28
            guard point.x >= rect.minX - 6, point.x <= rect.maxX + 6,
                  point.y >= bandMinY, point.y <= bandMaxY
            else { continue }
            return SplitMergeState.Shown(
                browserID: browserID,
                targetID: targetID,
                sourceID: sourceID,
                onLeft: point.x < rect.midX
            )
        }
        return nil
    }
}

/// Overlay on a sidebar row while another tab is held over its middle band,
/// previewing the left/right Split View pair created on release.
struct MergeHint: View {
    let browser: Browser
    let tab: Tab
    @ObservedObject private var merge = SplitMergeState.shared

    private var shown: SplitMergeState.Shown? {
        guard let shown = merge.shown, shown.targetID == tab.id,
              shown.browserID == ObjectIdentifier(browser)
        else { return nil }
        return shown
    }

    var body: some View {
        Group {
            if let shown, let source = browser.tabs.first(where: { $0.id == shown.sourceID }) {
                GeometryReader { geo in
                    let halfW = max(1, geo.size.width / 2)
                    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                    ZStack(alignment: .topLeading) {
                        HalfLabel(tab: tab, emphasized: false)
                            .frame(width: halfW, height: geo.size.height)
                            .offset(x: shown.onLeft ? halfW : 0)
                        HalfLabel(tab: source, emphasized: true)
                            .frame(width: halfW, height: geo.size.height)
                            .background(shape.fill(Palette.ink.opacity(0.08)))
                            .offset(x: shown.onLeft ? 0 : halfW)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .background(shape.fill(Palette.ground))
                    .overlay(shape.strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1))
                    .animation(Motion.quick, value: shown.onLeft)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct HalfLabel: View {
        @ObservedObject var tab: Tab
        let emphasized: Bool

        var body: some View {
            HStack(spacing: 6) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 13, dim: tab.asleep)
                Text(tab.label.isEmpty ? "New Tab" : tab.label)
                    .font(.system(size: 11.5, weight: emphasized ? .medium : .regular))
                    .foregroundStyle(emphasized ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
        }
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
