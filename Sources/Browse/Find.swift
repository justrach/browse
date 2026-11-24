import AppKit
import SwiftUI

/// Looking for a word on the page: frosted floating pill in the top-right
/// corner with live match counter (`3 / 12`), `Return` / `⇧Return` stepping,
/// and instant clear/dismiss.
struct FindBar: View {
    @ObservedObject var browser: Browser
    @Environment(\.colorScheme) private var scheme
    @State private var clearFocusTick = 0

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(browser.missed ? Color.red.opacity(0.8) : Palette.muted)

            ZStack(alignment: .leading) {
                if browser.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.34))
                        .allowsHitTesting(false)
                }
                FindField(
                    text: $browser.needle,
                    focusTick: browser.findFocus &+ clearFocusTick,
                    onSubmit: { forward in browser.look(forward: forward) },
                    onClose: { browser.closeFind() }
                )
            }
            .font(.system(size: 12.5))
            .frame(width: 164, height: 18)

            if !browser.needle.isEmpty {
                let countText: String = {
                    if browser.missed { return "0 / 0" }
                    if browser.findMatches > 0 {
                        let total = browser.findMatches >= 1000 ? "999+" : "\(browser.findMatches)"
                        return "\(max(1, browser.findIndex)) / \(total)"
                    }
                    return ""
                }()
                if !countText.isEmpty {
                    Text(countText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(browser.missed ? Color.red.opacity(0.85) : Palette.muted)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
                Button {
                    browser.needle = ""
                    clearFocusTick &+= 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1, height: 14)

            let cantStep = browser.needle.isEmpty || browser.missed
            step("chevron.up", help: "Previous match   ⇧↩", disabled: cantStep) { browser.look(forward: false) }
            step("chevron.down", help: "Next match   ↩", disabled: cantStep) { browser.look(forward: true) }
            step("xmark", help: "Close   esc") { browser.closeFind() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 6.5)
        .background {
            ZStack {
                Capsule().fill(.regularMaterial)
                Capsule().fill(Palette.ground.opacity(dark ? 0.84 : 0.90))
            }
        }
        .overlay(
            Capsule().strokeBorder(
                browser.missed
                    ? Color.red.opacity(0.45)
                    : (dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09)),
                lineWidth: 0.75
            )
        )
        .shadow(color: .black.opacity(dark ? 0.34 : 0.12), radius: 20, y: 6)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: browser.missed)
        .animation(Motion.quick, value: browser.findMatches)
    }

    private struct FindField: NSViewRepresentable {
        @Binding var text: String
        let focusTick: Int
        let onSubmit: (Bool) -> Void
        let onClose: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 12.5)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.delegate = context.coordinator
            field.stringValue = text
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            context.coordinator.parent = self
            if field.stringValue != text {
                field.stringValue = text
            }
            context.coordinator.focusIfNeeded(field)
        }

        @MainActor
        final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: FindField
            private var didInitialFocus = false
            private var lastFocusTick: Int

            init(parent: FindField) {
                self.parent = parent
                self.lastFocusTick = parent.focusTick
            }

            func focusIfNeeded(_ field: NSTextField) {
                guard !didInitialFocus || lastFocusTick != parent.focusTick else { return }
                didInitialFocus = true
                lastFocusTick = parent.focusTick
                DispatchQueue.main.async { [weak field] in
                    guard let field, let window = field.window else { return }
                    window.makeFirstResponder(field)
                    (field.currentEditor() as? NSTextView)?.selectAll(nil)
                }
            }

            func controlTextDidChange(_ obj: Notification) {
                guard let field = obj.object as? NSTextField else { return }
                if parent.text != field.stringValue {
                    parent.text = field.stringValue
                }
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                if selector == #selector(NSResponder.insertNewline(_:)) {
                    let forward = !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                    parent.onSubmit(forward)
                    return true
                }
                if selector == #selector(NSResponder.cancelOperation(_:)) {
                    parent.onClose()
                    return true
                }
                return false
            }
        }
    }

    private func step(_ icon: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        StepButton(icon: icon, help: help, disabled: disabled, action: action)
    }

    private struct StepButton: View {
        let icon: String
        let help: String
        var disabled: Bool = false
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(disabled ? Palette.faint : (hovering ? Palette.ink : Palette.muted))
                    .frame(width: 24, height: 24)
                    .background(hovering && !disabled ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(help)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
