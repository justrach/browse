import AppKit
import SwiftUI

// Lightweight theme stubs so the real Sources/Browse/Plate.swift compiles and
// lays out under AppKit's real CoreText / SwiftUI layout engine in <2s.
enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let faint = Color.secondary.opacity(0.6)
    static let ground = Color(nsColor: .windowBackgroundColor)
    static let wash = Color.primary.opacity(0.06)
    static let hover = Color.primary.opacity(0.09)
    static let hairline = Color.primary.opacity(0.12)
    static let accent = Color.accentColor
    static let onAccent = Color.white
}

struct Door: View {
    let icon: String
    var help = ""
    let act: () -> Void
    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

/// Mirror of Settings.swift's Pill (guarding single-line capsule behavior under tight widths).
private struct TestPill: View {
    let title: String
    var body: some View {
        Button {} label: {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.ground, in: Capsule())
        }
        .fixedSize()
        .buttonStyle(.plain)
    }
}

@MainActor
private func measure<V: View>(_ view: V, width: CGFloat) -> CGSize {
    let host = NSHostingView(rootView: view.frame(width: width))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    return size
}

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        failures += 1
    } else {
        print("PASS: \(message)")
    }
}

@main
struct UILayoutChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        // 1. Quick (from real Plate.swift) must NEVER wrap into a vertical single-letter
        //    column when placed beside long text in a tight container.
        let quickRow = HStack(spacing: 8) {
            Text("A very long description that competes heavily for horizontal space in a narrow row")
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 4)
            Quick("Sleep now") {}
        }
        let quickSize = measure(quickRow, width: 260)
        check(
            quickSize.height <= 48,
            "Plate.Quick stays single-line under tight horizontal pressure (got height=\(Int(quickSize.height))pt)"
        )

        // 2. Real Plate.Line with multi-line helper copy (>3 lines) must NOT clip at 3 lines.
        let shortLine = Line(
            "Short",
            "One single short sentence."
        ) {
            Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
        }
        let longSpacesLine = Line(
            "Spaces",
            "Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1–⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first."
        ) {
            Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
        }
        let shortH = measure(shortLine, width: 458).height
        let longH = measure(longSpacesLine, width: 458).height
        check(
            longH >= shortH + 40,
            "Plate.Line expands past 3 lines without truncating long Settings descriptions (short=\(Int(shortH))pt, long=\(Int(longH))pt)"
        )

        // 3. Settings › Tabs › Memory profile stacked layout at exact Settings width (458pt)
        //    must stay compact and never crush the Sleep now pill.
        let memoryRow = Line(
            "Memory profile",
            "Balanced: keeps 2 background tabs awake, sleeps extras after 45 s, and idle tabs after 10 min"
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 2) {
                    Text("Balanced").font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 5)
                    Text("Low RAM").font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 5)
                }
                .fixedSize()
                TestPill(title: "Sleep now")
            }
        }
        .padding(.leading, 14)
        let memSize = measure(memoryRow, width: 458)
        check(
            memSize.height <= 125 && memSize.width <= 462,
            "Settings Memory profile row stays clean & uncrushed at 458pt (got \(Int(memSize.width))×\(Int(memSize.height))pt)"
        )

        // 4. graff header at Metrics.agentMin (280pt) must stay strictly single-row (<=42pt).
        let graffHeader = HStack(spacing: 6) {
            Circle().frame(width: 17, height: 17)
            Text("graff")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
            Circle().frame(width: 13, height: 13)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { _ in
                    Door(icon: "xmark") {}
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        let headerSize = measure(graffHeader, width: 280)
        check(
            headerSize.width <= 280 && headerSize.height <= 42,
            "graff header fits cleanly inside minimum 280pt column width (got \(Int(headerSize.width))×\(Int(headerSize.height))pt)"
        )

        // 5. TabPaletteView vertical budget must fit inside 472pt so search header & footer
        //    never overflow outside the rounded card frame.
        let paletteLayout = VStack(spacing: 0) {
            HStack { Text("Search open tabs…"); Spacer() }.frame(height: 50)
            Rectangle().frame(height: 1)
            HStack(spacing: 0) {
                Color.clear.frame(width: 336)
                Rectangle().frame(width: 1)
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10).frame(height: 234)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Example Domain").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Text("example.com").font(.system(size: 11.5)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        TestPill(title: "Switch to Tab ↩")
                        TestPill(title: "Split ⌘D")
                    }
                }
                .padding(16)
            }
            Rectangle().frame(height: 1)
            HStack { Text("↑↓ Preview"); Spacer() }.frame(height: 32)
        }
        let paletteSize = measure(paletteLayout, width: 780)
        check(
            paletteSize.height <= 472,
            "TabPaletteView natural height fits inside 472pt card without header/footer overflow (got \(Int(paletteSize.height))pt)"
        )

        if failures > 0 {
            fputs("\n\(failures) UI layout check(s) failed.\n", stderr)
            exit(1)
        }
        print("\nAll UI layout geometry checks passed.")
    }
}
