import SwiftUI

/// Live miniature preview of browse's unified frosted glass frame:
/// left tab sidebar with Dia-style active-tab badge, floating webpage card,
/// spotless 6pt gutter, and floating `graff` companion card.
struct WelcomeResearchPreview: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let cardRim = dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
        let outerShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                // Unified frosted window frame.
                LinearGradient(
                    colors: dark
                        ? [Color(white: 0.14), Color(white: 0.11)]
                        : [Color(white: 0.945), Color(white: 0.925)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 0) {
                    // Compact unified top bar.
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 7, height: 7)
                            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 7, height: 7)
                            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 7, height: 7)
                        }
                        Spacer().frame(width: 44)
                        HStack(spacing: 5) {
                            Circle().fill(Palette.accent.opacity(0.75)).frame(width: 6, height: 6)
                            Text("notes.garden")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            Text("A little garden")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.78))
                        )
                        Spacer()
                        HStack(spacing: 4) {
                            GraffMark(size: 10, color: Palette.accent)
                            Text("graff")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.accent)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(Palette.accent.opacity(dark ? 0.16 : 0.11)))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)

                    // Sidebar + floating page card + spotless 6pt gutter + floating graff card.
                    HStack(spacing: 6) {
                        // Mini left sidebar.
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Today")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Palette.muted.opacity(0.7))
                                .padding(.leading, 6)
                                .padding(.top, 2)

                            HStack(spacing: 5) {
                                Circle().fill(Palette.accent.opacity(0.7)).frame(width: 6, height: 6)
                                Text("A little garden")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                GraffMark(size: 8.5, color: Palette.muted.opacity(0.75))
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.92))
                            )

                            ForEach(["Field notes", "Sunlight map"], id: \.self) { label in
                                HStack(spacing: 5) {
                                    Circle().fill(Palette.muted.opacity(0.35)).frame(width: 6, height: 6)
                                    Text(label)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 112)
                        .padding(.leading, 6)

                        // Floating webpage card.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("A little garden.\nA good place to start.")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Choose a sunny spot, water regularly, and grow what fits your space.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.muted)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 3).fill(Palette.wash).frame(width: 48, height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(Palette.wash).frame(width: 34, height: 6)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cardRim, lineWidth: 0.75))

                        // Floating graff card.
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                GraffMark(size: 12, color: Palette.ink.opacity(0.9))
                                Text("graff")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Palette.ink)
                                Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                                Spacer()
                            }
                            Text("What's the main idea?")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text("Start small. Pick plants that match your light and give them steady care.")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                Text("@Field notes")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(Palette.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Palette.accent.opacity(dark ? 0.18 : 0.11)))
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink.opacity(0.85))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
                            )
                        }
                        .padding(11)
                        .frame(width: 178)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cardRim, lineWidth: 0.75))
                    }
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
                }
            }
            .frame(height: 224)
            .clipShape(outerShape)
            .overlay(outerShape.strokeBorder(cardRim, lineWidth: 0.75))
            .shadow(color: .black.opacity(dark ? 0.34 : 0.09), radius: 18, y: 6)

            Text("120 FPS ProMotion browsing · mention any open tab with @ · switch tabs live with ⌘K or ⇧⌘\\")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Setup checks the local `graff` installation and Harness MCP bridge without
/// starting a conversation until you choose to.
struct WelcomeAgentSetup: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @Binding var installedBinding: Bool
    let leaveSetup: () -> Void
    @State private var looked = false
    @State private var installed = false
    @State private var explaining = false
    @State private var checkTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                Line(
                    "graff beside your pages",
                    "Open or close with ⌘; · press . while reading · mention tabs or @history"
                ) {
                    Switch(on: $prefs.usesAgent)
                }
                if prefs.usesAgent {
                    Rule()
                    HStack(alignment: .top, spacing: 10) {
                        GraffMark(size: 18, color: installed ? Palette.ink : Palette.muted)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(!looked ? "Checking this Mac…" : installed ? "graff is ready on this Mac" : "Install graff to start chatting")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                if installed && AgentTools.harnessAvailable {
                                    Text("Harness MCP")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .foregroundStyle(Palette.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Palette.accent.opacity(0.12)))
                                }
                            }
                            Text(!looked
                                 ? "Looking for the local graff binary."
                                 : installed
                                 ? "browse uses your local graff installation and connects its browser tools automatically. Any provider accounts you signed into appear in the model picker."
                                 : "browse runs the local graff CLI. Install it now and click Check again, or point browse to it later in Settings › Agent.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if looked, !installed {
                                HStack(spacing: 8) {
                                    Pill("Get graff", filled: true) {
                                        if Links.isDefault {
                                            leaveSetup()
                                            browser.open(Agent.download, foreground: true)
                                        } else {
                                            NSWorkspace.shared.open(Agent.download)
                                        }
                                    }
                                    Pill("Check again") {
                                        checkTick += 1
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            if prefs.usesAgent {
                AccountCard(browser: browser, inline: true)

                Card {
                    DisclosureGroup("Tips for working with graff", isExpanded: $explaining) {
                        VStack(alignment: .leading, spacing: 10) {
                            tip("at", "Mention tabs or @history", "Type @ in the composer to pull any open tab or your recent browsing history into context.")
                            tip("slash.circle", "Inline skills & commands", "Type / for /summarize, /explain, /compare, /factcheck, /write (⌘⇧E), /model, or /new.")
                            tip("sparkles.rectangle.stack", "Dedicated Agent tab group", "Tabs graff opens stay in their own collapsible Agent group so your personal tabs stay clean.")
                        }
                        .padding(.top, 10)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .tint(Palette.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
        }
        .task(id: "\(prefs.usesAgent)-\(prefs.agentPath)-\(checkTick)") {
            looked = false
            guard prefs.usesAgent else {
                installed = false
                installedBinding = false
                return
            }
            let found = await Agent.locate(custom: prefs.agentPath)
            guard !Task.isCancelled else { return }
            installed = found != nil
            installedBinding = installed
            looked = true
        }
    }

    private func tip(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
