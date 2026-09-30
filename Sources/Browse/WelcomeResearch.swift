import SwiftUI

/// A labelled example, using the same surface as the page and side chat.
struct WelcomeResearchPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A page you're reading", systemImage: "doc.text")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                    Text("A little garden.\nA good place to start.")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Choose a sunny spot, water regularly, and grow what suits your space.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Codegraff")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("What's the main idea?")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .padding(10)
                        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))
                    Text("Start small. Pick plants that fit your space and give them consistent care.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Label("This page is included", systemImage: "doc.text")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash)
            }
            .frame(height: 230)
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.hairline, lineWidth: 1))
            Text("Example · choose the context, ask a question, follow the answer")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Setup checks the local installation without starting a conversation.
struct WelcomeAgentSetup: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let leaveSetup: () -> Void
    @State private var looked = false
    @State private var installed = false
    @State private var explaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codegraff in Browse")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("Open or close with ⌘; · press . beside a page")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("Codegraff in Browse", isOn: $prefs.usesAgent)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Enable Codegraff in Browse")
            }
            if prefs.usesAgent {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: installed ? "checkmark.circle" : "arrow.down.circle")
                        .foregroundStyle(installed ? Palette.safe : Palette.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(!looked ? "Checking this Mac…" : installed ? "Codegraff is installed" : "Install Codegraff to start chatting")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text(!looked ? "Looking for the Codegraff installed on this Mac."
                             : installed
                             ? "Browse uses the Codegraff already on your Mac. Provider accounts you have connected there are available in the model picker."
                             : "Browse connects to Codegraff on your Mac. Get it now, or choose its location later in Settings › Agent.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if looked, !installed {
                            Button("Get Codegraff") {
                                leaveSetup()
                                browser.open(Agent.download, foreground: true)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        }
                    }
                }
                Divider()
                Text("Sign in here with a code and web approval, or connect later in Settings. Sync is a separate choice there.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                AccountCard(browser: browser, inline: true)
                DisclosureGroup("How to use Codegraff", isExpanded: $explaining) {
                  VStack(alignment: .leading, spacing: 12) {
                    tip("doc.text", "Review the context", "The title above your question shows the page included. Exclude it, or pin it while changing tabs.")
                    tip("list.bullet", "See what's happening", "Reported activity and results show the work. Open agent pages when you want to inspect them.")
                    tip("text.cursor", "Send when you're ready", "Draft a follow-up while it works. Nothing is sent until you choose Send.")
                    tip("square.stack", "Make it yours", "Settings › Agent can enable reusable tasks and a draft per tab. The question-mark button in chat explains the controls whenever you need it.")
                  }
                  .padding(.top, 12)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .tint(Palette.ink)
                Text("When you ask, Codegraff can use browser tools and work on your Mac. Describe the actions you want it to take.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Start with the browser. You can enable Codegraff later in Settings › Agent.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .task(id: "\(prefs.usesAgent)-\(prefs.agentPath)") {
            looked = false
            guard prefs.usesAgent else { return }
            let found = await Agent.locate(custom: prefs.agentPath)
            guard !Task.isCancelled else { return }
            installed = found != nil
            looked = true
        }
    }

    private func tip(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
