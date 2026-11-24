import AppKit

/// A mouse wheel's notched steps, glided smoothly over display frames.
/// WebKit on macOS jumps a whole notch per frame (40 pt per line) whereas
/// Chromium eases across ~1/6 s; trackpads and smooth mice (`hasPreciseScrollingDeltas`)
/// are left untouched.
///
/// Opt-in via Settings › General › Smooth scrolling with a mouse wheel.
@MainActor
final class WheelGlide: NSObject {
    /// Settings › General › Smooth scrolling with a mouse wheel.
    static var on = false

    /// WebKit pixels per notched wheel line (`Scrollbar::pixelsPerLineStep`).
    static let line: CGFloat = 40
    /// Decay time constant (~160 ms ease-out).
    static let tau: CFTimeInterval = 0.045

    private weak var view: PageView?
    private var template: CGEvent?
    private var target = CGVector.zero
    private var done = CGVector.zero
    private var moved = CGVector.zero
    private var link: CADisplayLink?
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    /// Number of interpolated steps emitted since the latest notch.
    private(set) var steps = 0

    init(_ view: PageView) {
        self.view = view
    }

    /// Consumes a notched wheel event for smooth stepping, or returns `false`
    /// to pass the original event straight to the page.
    func take(_ event: NSEvent) -> Bool {
        guard Self.on, !event.hasPreciseScrollingDeltas, event.phase == [], event.momentumPhase == [],
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let view, let cg = event.cgEvent?.copy()
        else { return false }

        let add = CGVector(dx: event.scrollingDeltaX * Self.line, dy: event.scrollingDeltaY * Self.line)
        guard add.dx != 0 || add.dy != 0 else { return false }

        template = cg
        guard let check = make(0, 3), check.hasPreciseScrollingDeltas, check.scrollingDeltaY == 3,
              check.window === event.window, check.locationInWindow == event.locationInWindow
        else {
            template = nil
            return false
        }

        let left = CGVector(dx: target.dx - moved.dx, dy: target.dy - moved.dy)
        if left.dx * add.dx < 0 || left.dy * add.dy < 0 {
            target = moved
        }
        target.dx += add.dx
        target.dy += add.dy
        steps = 0

        if link == nil, timer == nil {
            last = CACurrentMediaTime()
            if view.window?.occlusionState.contains(.visible) == true {
                let displayLink = view.displayLink(target: self, selector: #selector(frame))
                displayLink.add(to: .main, forMode: .common)
                self.link = displayLink
            } else {
                let fallbackTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.frame() }
                }
                RunLoop.main.add(fallbackTimer, forMode: .common)
                self.timer = fallbackTimer
            }
            frame()
        }
        return true
    }

    /// Halts any in-flight glide (called when the page closes or sleeps).
    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        template = nil
        target = .zero
        done = .zero
        moved = .zero
    }

    @objc private func frame() {
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240, now - last)
        last = now
        let k = 1 - exp(-dt / Self.tau)
        moved.dx += (target.dx - moved.dx) * k
        moved.dy += (target.dy - moved.dy) * k
        let close = abs(target.dx - moved.dx) < 0.5 && abs(target.dy - moved.dy) < 0.5
        if close { moved = target }
        let step = CGVector(dx: moved.dx.rounded() - done.dx, dy: moved.dy.rounded() - done.dy)
        if step.dx != 0 || step.dy != 0, let event = make(step.dx, step.dy), let view {
            done.dx += step.dx
            done.dy += step.dy
            steps += 1
            view.glide(event)
        }
        if close || view == nil {
            stop()
        }
    }

    /// Synthesizes a pixel-delta wheel event from the original notch event.
    private func make(_ dx: CGFloat, _ dy: CGFloat) -> NSEvent? {
        guard let cg = template?.copy() else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy.sign == .minus ? -1 : dy == 0 ? 0 : 1))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx.sign == .minus ? -1 : dx == 0 ? 0 : 1))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy) / 10)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx) / 10)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        return NSEvent(cgEvent: cg)
    }
}
