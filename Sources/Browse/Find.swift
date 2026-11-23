import SwiftUI

/// Looking for a word on the page: frosted floating pill in the top-right
/// corner with live match counter (`3 / 12`), `Return` / `⇧Return` stepping,
/// and instant clear/dismiss.
struct FindBar: View {
    @ObservedObject var browser: Browser
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

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
                }
                TextField("", text: $browser.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { browser.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: 164)

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
                Button { browser.needle = "" } label: {
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
        .onAppear { focused = true }
        .onChange(of: browser.findFocus) { _, _ in focused = true }
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
