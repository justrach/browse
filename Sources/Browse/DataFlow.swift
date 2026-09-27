import SwiftUI

/// Where things brought over go, drawn for the welcome's Bring page — the
/// same picture as docs/your-data.md: read once out of the other browser's
/// folder, kept on this Mac, and only if sync is on, sealed before it goes
/// anywhere, with a key only your Macs hold.
struct DataFlow: View {
    /// The browser things come from.
    let from: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                Stop(title: from, detail: "its folder on this Mac") {
                    Image(systemName: "folder")
                }
                Carry(word: "read once", sealed: false)
                Stop(title: "browse", detail: "keychain, history,\nbookmarks, sign-ins", lit: true) {
                    BrandMark().frame(width: 24, height: 24)
                }
                Carry(word: "sealed", sealed: true)
                Stop(title: "Your other Macs", detail: "only with sync on") {
                    Image(systemName: "lock.laptopcomputer")
                }
            }
            Text("Bringing things over never leaves this Mac. Sync, if you switch it on, seals each thing with a key only your Macs hold, so Codegraff's server keeps what it can't read.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    /// One place the things are.
    private struct Stop<Mark: View>: View {
        let title: String
        let detail: String
        var lit = false
        @ViewBuilder let mark: () -> Mark

        var body: some View {
            VStack(spacing: 6) {
                mark()
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 40, height: 40)
                    .background {
                        if lit {
                            Raised(corner: 11)
                        } else {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.ink.opacity(0.05))
                        }
                    }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 118)
        }
    }

    /// The way between two places, a dot travelling it: solid for a copy
    /// on this Mac, dashed and locked for what's sealed on its way out.
    private struct Carry: View {
        let word: String
        let sealed: Bool

        @Environment(\.accessibilityReduceMotion) private var still

        var body: some View {
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    if sealed { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    Text(word)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Path { line in
                            line.move(to: CGPoint(x: 0, y: 3))
                            line.addLine(to: CGPoint(x: geo.size.width, y: 3))
                        }
                        .stroke(Palette.faint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: sealed ? [3, 4] : []))
                        TimelineView(.animation(paused: still)) { time in
                            let phase = still ? 0.5 : (time.date.timeIntervalSinceReferenceDate / 1.8).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .fill(Palette.ink.opacity(0.75))
                                .frame(width: 6, height: 6)
                                .offset(x: phase * (geo.size.width - 6))
                        }
                    }
                }
                .frame(height: 6)
            }
            .padding(.top, 13)
            .frame(minWidth: 40, maxWidth: .infinity)
        }
    }
}
