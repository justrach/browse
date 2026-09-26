import AppKit
import SwiftUI

/// Settings › Sync: the switch, where it stands, and the code that brings
/// another Mac in.
struct SyncPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var sync = Sync.shared
    @State private var typed = ""
    @State private var said: String?
    @State private var shown = false
    @State private var sure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AccountCard(browser: browser)
            Card {
                Line(
                    "Sync history and bookmarks",
                    "Between the Macs you sign in to Codegraff on. Sealed on this Mac first, with a key only your Macs have: Codegraff keeps them without being able to read them, addresses included"
                ) {
                    Switch(on: Binding(
                        get: { prefs.sync },
                        set: { $0 ? sync.switchOn() : sync.switchOff() }
                    ))
                }
                if prefs.sync {
                    Rule()
                    Line(
                        "Passwords too",
                        "Sealed the same way, so Codegraff can't read them. Anyone with the sync code and your Codegraff sign-in could — keep the code as you would a password"
                    ) {
                        Switch(on: Binding(
                            get: { prefs.syncPasswords },
                            set: { on in
                                prefs.syncPasswords = on
                                if on { sync.nudge(after: 1) } else { sync.stopPasswords() }
                            }
                        ))
                    }
                    Rule()
                    Line(status.0, status.1) {
                        if case .syncing = sync.phase {
                            Ring(size: 12)
                        } else if sync.phase != .signedOut, sync.phase != .needsCode {
                            Pill("Sync now") { sync.now() }
                        }
                    }
                }
            }

            if prefs.sync, sync.phase == .needsCode || sync.phase == .wrongCode {
                Card {
                    Line(
                        "Enter the sync code",
                        "Another Mac already syncs to this Codegraff account. Its code is in Settings › Sync on that Mac"
                    ) { EmptyView() }
                    HStack(spacing: 8) {
                        TextField("ABCD-EFGH-…", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(join)
                        Pill("Join", filled: true, action: join)
                    }
                    .padding(.bottom, 10)
                    if let said {
                        Text(said)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .padding(.bottom, 10)
                    }
                }
            }

            if prefs.sync, let code = sync.code {
                Card {
                    Line("Add another Mac", "Switch sync on there, then enter this code. Anyone with it and your Codegraff sign-in can read what's synced") {
                        HStack(spacing: 6) {
                            Pill(shown ? "Hide" : "Show") { shown.toggle() }
                            Pill("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                browser.announce("Sync code copied")
                            }
                        }
                    }
                    if shown {
                        Text(code)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(Palette.ink)
                            .padding(.bottom, 10)
                    }
                    Rule()
                    Line(
                        "Delete what's synced",
                        sure ? "Gone from Codegraff for good. Every Mac keeps its own history and bookmarks" : "From Codegraff's server, for every Mac. Each Mac keeps its own copy"
                    ) {
                        if sure {
                            HStack(spacing: 6) {
                                Pill("Cancel") { sure = false }
                                Pill("Delete", filled: true) {
                                    sure = false
                                    Task {
                                        let problem = await sync.deleteEverywhere()
                                        browser.announce(problem ?? "Synced data deleted from Codegraff")
                                    }
                                }
                            }
                        } else {
                            Pill("Delete…") { sure = true }
                        }
                    }
                }
            }
        }
    }

    private var status: (String, String) {
        switch sync.phase {
        case .off: return ("Starting", "In a moment")
        case .signedOut: return ("Not signed in", "Sync goes through your Codegraff account — sign in above")
        case .needsCode: return ("Waiting for the code", "Below")
        case .wrongCode: return ("That code doesn't fit", "This Mac's key isn't the one the other Macs use — enter theirs below")
        case .syncing: return ("Syncing…", "History, then bookmarks")
        case .synced(let at): return ("Synced \(at.formatted(.relative(presentation: .named)))", "Every ten minutes, and soon after anything changes")
        case .failed(let why): return ("Didn't sync", why)
        }
    }

    private func join() {
        let code = typed
        said = nil
        Task {
            said = await sync.join(code)
            if said == nil { typed = "" }
        }
    }
}
