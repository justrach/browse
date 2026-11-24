import AppKit
import SwiftUI

// Customizable keyboard shortcuts across menus, the window key monitor,
// Settings › Shortcuts, and the Help › Keyboard Shortcuts sheet.

struct KeyCombo: Codable, Hashable, Equatable {
    let key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        // ⌘+ arrives as "=" or "+" depending on keyboard layout; normalize to "+".
        // ⇧⌘; can arrive as ":" under some IMEs or synthetic events; normalize to ";".
        let plus = key == "=" || key == "+"
        let colon = key == ":" && shift
        self.key = plus ? "+" : (colon ? ";" : key.lowercased())
        self.shift = plus ? false : shift
        self.command = command
        self.option = option
        self.control = control
    }

    /// The physical/unmodified key an NSEvent pressed, so ⌥⌘P reads as "p"
    /// rather than "π" and ⇧⌘] reads as "]" rather than "}".
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let named = KeyCombo.names[event.keyCode] ?? KeyCombo.digits[event.keyCode].map(String.init)
        let raw = named ?? KeyCombo.unmodifiedKey(for: event)
        guard !raw.isEmpty else { return nil }
        self.init(
            raw,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }

    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private static let names: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return",
        51: "delete", 117: "delete", 49: "space", 48: "tab", 53: "escape",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩",
        "delete": "⌫", "space": "Space", "tab": "⇥", "escape": "⎋",
    ]

    private static func unmodifiedKey(for event: NSEvent) -> String {
        let base = event.shortcutKey
        if !base.isEmpty {
            return base
        }
        return event.charactersIgnoringModifiers?.lowercased() ?? ""
    }

    /// As macOS menus show it: ⌃⌥⇧⌘ then the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (KeyCombo.symbols[key] ?? key.uppercased())
    }

    private var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// A key alone, or with only ⇧, is typing — never a shortcut.
    var isUsable: Bool { command || option || control || isFunctionKey }

    /// Caret movement/selection keys stand aside while typing in a text field.
    var movesCaret: Bool {
        let arrow = key == "left" || key == "right" || key == "up" || key == "down"
        guard arrow, !control else { return false }
        return (command && !option) || (option && !command)
    }

    var swiftUI: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "return": equivalent = .return
        case "delete": equivalent = .delete
        case "space": equivalent = .space
        case "tab": equivalent = .tab
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                equivalent = KeyEquivalent(Character(scalar))
            } else if key.count == 1, let character = key.first {
                equivalent = KeyEquivalent(character)
            } else {
                return nil
            }
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// macOS's own and the browser's fixed number/navigation keys.
    static func isReserved(_ combo: KeyCombo) -> Bool {
        let system: Set<KeyCombo> = [
            KeyCombo("q", command: true),
            KeyCombo("h", command: true),
            KeyCombo("h", command: true, option: true),
            KeyCombo("m", command: true),
            KeyCombo("c", command: true),
            KeyCombo("v", command: true),
            KeyCombo("x", command: true),
            KeyCombo("a", command: true),
            KeyCombo("z", command: true),
            KeyCombo("z", command: true, shift: true),
            KeyCombo("space", command: true),
            KeyCombo("tab", command: true),
            KeyCombo("tab", command: true, shift: true),
        ]
        if system.contains(combo) { return true }
        if combo.key == "escape" { return true }
        if combo.key == "tab", !combo.control, !combo.option { return true }
        if combo.command, !combo.shift, !combo.option, !combo.control,
           let n = Int(combo.key), (1...9).contains(n) {
            return true
        }
        return false
    }
}

/// Every menu and browser action whose shortcut can be viewed or customized.
enum CommandID: String, CaseIterable, Codable, Identifiable {
    // File
    case newTab
    case newPrivateTab
    case reopenTab
    case openAddress
    case closeTab
    case share
    case printPage
    // Edit
    case findOnPage
    case findNext
    case findPrevious
    // View
    case toggleSidebarLayout
    case toggleFold
    case reloadPage
    case reloadFromOrigin
    case readingMode
    case floatVideo
    case toggleSplit
    case swapSplit
    case fullScreen
    case hideElements
    case hiddenOnSite
    case tidyPage
    case zoomIn
    case zoomOut
    case actualSize
    case webInspector
    case jsConsole
    case inspectElement
    // Codegraff
    case toggleAgent
    case expandAgent
    case fillFormWithAgent
    // Tabs
    case back
    case forward
    case nextTab
    case previousTab
    case searchTabs
    case tabOverview
    case pinTab
    case renameTab
    case duplicateTab
    case copyAddress
    case copyMarkdownLink
    case pasteAndGo
    case closeOtherTabs
    case stopMedia
    // Bookmarks
    case bookmarkPage
    case showBookmarks
    case toggleBookmarksBar
    // History
    case showHistory
    case showDownloads
    case clearData
    case clearHistory
    // App
    case settings
    case passwords
    case showShortcuts
    case welcome

    var id: String { rawValue }
}

struct BrowserCommand: Identifiable {
    enum Section: String, CaseIterable {
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case agent = "Codegraff"
        case tabs = "Tabs"
        case bookmarks = "Bookmarks"
        case history = "History"
        case app = "App"
    }

    let id: CommandID
    let section: Section
    let title: String
    let defaultKey: KeyCombo?
    /// True for commands the browser keeps ahead of web pages (tab creation/closing,
    /// tab switching, search tabs, Codegraff toggle, clear data).
    let alwaysOurs: Bool

    init(_ id: CommandID, _ section: Section, _ title: String, _ defaultKey: KeyCombo?, alwaysOurs: Bool = false) {
        self.id = id
        self.section = section
        self.title = title
        self.defaultKey = defaultKey
        self.alwaysOurs = alwaysOurs
    }

    static let all: [BrowserCommand] = [
        // File
        BrowserCommand(.newTab, .file, "New Tab", KeyCombo("t", command: true), alwaysOurs: true),
        BrowserCommand(.newPrivateTab, .file, "New Private Tab", KeyCombo("n", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.reopenTab, .file, "Reopen Closed Tab", KeyCombo("t", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.openAddress, .file, "Open Address…", KeyCombo("l", command: true), alwaysOurs: true),
        BrowserCommand(.closeTab, .file, "Close Tab", KeyCombo("w", command: true), alwaysOurs: true),
        BrowserCommand(.share, .file, "Share…", nil),
        BrowserCommand(.printPage, .file, "Print…", KeyCombo("p", command: true)),
        // Edit
        BrowserCommand(.findOnPage, .edit, "Find on Page…", KeyCombo("f", command: true)),
        BrowserCommand(.findNext, .edit, "Find Next", KeyCombo("g", command: true)),
        BrowserCommand(.findPrevious, .edit, "Find Previous", KeyCombo("g", command: true, shift: true)),
        // View
        BrowserCommand(.toggleSidebarLayout, .view, "Move Tabs to Side / Top", KeyCombo("s", command: true, shift: true)),
        BrowserCommand(.toggleFold, .view, "Hide / Show Tabs", KeyCombo("s", command: true)),
        BrowserCommand(.reloadPage, .view, "Reload Page", KeyCombo("r", command: true)),
        BrowserCommand(.reloadFromOrigin, .view, "Reload Page From Origin", KeyCombo("r", command: true, option: true)),
        BrowserCommand(.readingMode, .view, "Reading Mode", KeyCombo("r", command: true, shift: true)),
        BrowserCommand(.floatVideo, .view, "Float Video", KeyCombo("p", command: true, shift: true)),
        BrowserCommand(.toggleSplit, .view, "Split View", KeyCombo("d", command: true)),
        BrowserCommand(.swapSplit, .view, "Swap Split Sides", KeyCombo("d", command: true, option: true)),
        BrowserCommand(.fullScreen, .view, "Enter / Exit Full Screen", KeyCombo("f", command: true, control: true), alwaysOurs: true),
        BrowserCommand(.hideElements, .view, "Hide Elements…", KeyCombo("h", command: true, shift: true)),
        BrowserCommand(.hiddenOnSite, .view, "Hidden on This Site…", KeyCombo("u", command: true, shift: true)),
        BrowserCommand(.tidyPage, .view, "Tidy This Page", KeyCombo("t", command: true, option: true)),
        BrowserCommand(.zoomIn, .view, "Zoom In", KeyCombo("+", command: true)),
        BrowserCommand(.zoomOut, .view, "Zoom Out", KeyCombo("-", command: true)),
        BrowserCommand(.actualSize, .view, "Actual Size", KeyCombo("0", command: true)),
        BrowserCommand(.webInspector, .view, "Web Inspector", KeyCombo("i", command: true, option: true)),
        BrowserCommand(.jsConsole, .view, "JavaScript Console", KeyCombo("j", command: true, option: true)),
        BrowserCommand(.inspectElement, .view, "Inspect Element", KeyCombo("c", command: true, option: true)),
        // Codegraff
        BrowserCommand(.toggleAgent, .agent, "Toggle Agent Sidebar", KeyCombo(";", command: true), alwaysOurs: true),
        BrowserCommand(.expandAgent, .agent, "Expand / Collapse Full-Screen Agent", KeyCombo(";", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.fillFormWithAgent, .agent, "Fill In This Form with Codegraff", KeyCombo("f", command: true, option: true)),
        // Tabs
        BrowserCommand(.back, .tabs, "Back", KeyCombo("[", command: true)),
        BrowserCommand(.forward, .tabs, "Forward", KeyCombo("]", command: true)),
        BrowserCommand(.nextTab, .tabs, "Next Tab", KeyCombo("]", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.previousTab, .tabs, "Previous Tab", KeyCombo("[", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.searchTabs, .tabs, "Search Open Tabs…", KeyCombo("k", command: true), alwaysOurs: true),
        BrowserCommand(.tabOverview, .tabs, "Tab Overview", KeyCombo("\\", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.pinTab, .tabs, "Pin / Unpin Tab", KeyCombo("p", command: true, option: true)),
        BrowserCommand(.renameTab, .tabs, "Rename Tab", KeyCombo("e", command: true, option: true)),
        BrowserCommand(.duplicateTab, .tabs, "Duplicate Tab", KeyCombo("d", command: true, shift: true)),
        BrowserCommand(.copyAddress, .tabs, "Copy Address", KeyCombo("c", command: true, shift: true)),
        BrowserCommand(.copyMarkdownLink, .tabs, "Copy as Markdown Link", KeyCombo("m", command: true, option: true)),
        BrowserCommand(.pasteAndGo, .tabs, "Paste and Go", KeyCombo("v", command: true, shift: true)),
        BrowserCommand(.closeOtherTabs, .tabs, "Close Other Tabs", nil),
        BrowserCommand(.stopMedia, .tabs, "Stop Sound in Tab", KeyCombo("m", command: true, shift: true)),
        // Bookmarks
        BrowserCommand(.bookmarkPage, .bookmarks, "Add This Page", KeyCombo("b", command: true, shift: true)),
        BrowserCommand(.showBookmarks, .bookmarks, "Show Bookmarks…", KeyCombo("b", command: true, option: true)),
        BrowserCommand(.toggleBookmarksBar, .bookmarks, "Show / Hide Bookmarks Bar", KeyCombo("o", command: true, shift: true)),
        // History
        BrowserCommand(.showHistory, .history, "Show History…", KeyCombo("y", command: true)),
        BrowserCommand(.showDownloads, .history, "Downloads…", KeyCombo("j", command: true, shift: true)),
        BrowserCommand(.clearData, .history, "Clear Browsing Data…", KeyCombo("delete", command: true, shift: true), alwaysOurs: true),
        BrowserCommand(.clearHistory, .history, "Clear History", nil),
        // App
        BrowserCommand(.settings, .app, "Settings…", KeyCombo(",", command: true), alwaysOurs: true),
        BrowserCommand(.passwords, .app, "Passwords…", KeyCombo("l", command: true, option: true)),
        BrowserCommand(.showShortcuts, .app, "Keyboard Shortcuts…", KeyCombo("/", command: true)),
        BrowserCommand(.welcome, .app, "Welcome…", nil),
    ]

    static let byID: [CommandID: BrowserCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

struct GlobalHotKeyBinding: Codable, Equatable {
    let combo: KeyCombo
    let keyCode: UInt16
}

@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    private static let storageKey = "shortcuts.custom.v1"
    private static let globalKey = "shortcuts.global.v1"

    /// Custom overrides: nil value means explicitly cleared (no shortcut).
    private struct Override: Codable, Equatable {
        let combo: KeyCombo?
    }

    @Published private var overrides: [CommandID: Override] = [:]
    @Published var globalHotKey: GlobalHotKeyBinding? {
        didSet {
            saveGlobal()
            applyGlobalHotKey()
        }
    }
    /// True while a recorder box in Settings › Shortcuts is capturing a key.
    @Published var recording = false
    /// Last status note for global hotkey registration.
    @Published var globalNote: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = Store.settings) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CommandID: Override].self, from: data) {
            overrides = decoded
        }
        if let data = defaults.data(forKey: Self.globalKey),
           let decoded = try? JSONDecoder().decode(GlobalHotKeyBinding.self, from: data) {
            globalHotKey = decoded
        }
    }

    func key(for id: CommandID) -> KeyCombo? {
        if let override = overrides[id] { return override.combo }
        return BrowserCommand.byID[id]?.defaultKey
    }

    func isChanged(_ id: CommandID) -> Bool {
        guard let override = overrides[id] else { return false }
        return override.combo != BrowserCommand.byID[id]?.defaultKey
    }

    var hasAnyCustom: Bool {
        BrowserCommand.all.contains { isChanged($0.id) }
    }

    func command(for combo: KeyCombo) -> BrowserCommand? {
        BrowserCommand.all.first { key(for: $0.id) == combo }
    }

    /// True when `event` matches the agent toggle (`⌘;`) or full-screen expand (`⇧⌘;`).
    func isAgentToggle(_ event: NSEvent) -> Bool {
        guard !recording, let combo = KeyCombo(event: event), combo.isUsable,
              let cmd = command(for: combo) else { return false }
        return cmd.id == .toggleAgent || cmd.id == .expandAgent
    }

    /// Assigns `combo` to `id`. If another command currently holds `combo`,
    /// that command is cleared so there are never duplicate bindings.
    @discardableResult
    func set(_ combo: KeyCombo, for id: CommandID) -> CommandID? {
        guard combo.isUsable, !KeyCombo.isReserved(combo) else { return nil }
        var displaced: CommandID?
        for other in BrowserCommand.all where other.id != id && key(for: other.id) == combo {
            overrides[other.id] = Override(combo: nil)
            displaced = other.id
        }
        if combo == BrowserCommand.byID[id]?.defaultKey {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = Override(combo: combo)
        }
        save()
        return displaced
    }

    func clear(_ id: CommandID) {
        if BrowserCommand.byID[id]?.defaultKey == nil {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = Override(combo: nil)
        }
        save()
    }

    func reset(_ id: CommandID) {
        overrides.removeValue(forKey: id)
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    func setGlobal(combo: KeyCombo, keyCode: UInt16) -> String? {
        guard combo.isUsable else { return "Include ⌘, ⌥, ⌃, or a function key" }
        let mods = HotKey.modifiers(of: combo)
        if HotKey.usedByMacOS(code: keyCode, modifiers: mods) {
            return "\(combo.display) is used by macOS"
        }
        let status = HotKey.set(code: keyCode, modifiers: mods)
        guard status == noErr else {
            return "macOS wouldn't register \(combo.display)"
        }
        globalNote = nil
        globalHotKey = GlobalHotKeyBinding(combo: combo, keyCode: keyCode)
        return nil
    }

    func clearGlobal() {
        HotKey.clear()
        globalNote = nil
        globalHotKey = nil
    }

    func applyGlobalHotKey() {
        guard !Store.testing else { return }
        guard let binding = globalHotKey else {
            HotKey.clear()
            return
        }
        let status = HotKey.set(code: binding.keyCode, modifiers: HotKey.modifiers(of: binding.combo))
        if status != noErr {
            globalNote = "Couldn't register \(binding.combo.display) — another app may hold it"
        } else {
            globalNote = nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.storageKey)
        }
        MenuKeySanitizer.shared.sanitize()
    }

    private func saveGlobal() {
        if let globalHotKey, let data = try? JSONEncoder().encode(globalHotKey) {
            defaults.set(data, forKey: Self.globalKey)
        } else {
            defaults.removeObject(forKey: Self.globalKey)
        }
    }
}

/// Strips conflicting macOS Edit › Spelling and Grammar key equivalents (`⌘;`
/// Check Document Now and `⌘:` / `⇧⌘;` Show Spelling and Grammar) from the
/// standard SwiftUI Edit menu so `browse`'s agent shortcuts always supersede
/// macOS spellcheck across every view, sheet, text field, and `WKWebView`.
@MainActor
final class MenuKeySanitizer {
    static let shared = MenuKeySanitizer()
    private var observers: [NSObjectProtocol] = []
    private weak var sanitizedEditMenu: NSMenu?
    private var lastEditItemCount = -1
    private var trackedItems: [WeakMenuItem] = []

    private struct WeakMenuItem {
        weak var item: NSMenuItem?
    }

    func start() {
        guard observers.isEmpty else { sanitize(force: true); return }
        let centre = NotificationCenter.default
        observers = [
            centre.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sanitize(force: false) }
            },
            centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sanitize(force: true) }
            },
        ]
        sanitize(force: true)
    }

    func sanitize(force: Bool = true) {
        guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else { return }
        // O(1) zero-allocation fast path for 120–240 Hz didUpdateNotification events:
        // only re-walk the Edit menu if SwiftUI rebuilt it or re-bound a tracked spelling item.
        if !force,
           sanitizedEditMenu === editMenu,
           editMenu.numberOfItems == lastEditItemCount,
           trackedItems.allSatisfy({ $0.item?.keyEquivalent.isEmpty ?? true }) {
            return
        }
        sanitizedEditMenu = editMenu
        lastEditItemCount = editMenu.numberOfItems
        trackedItems.removeAll(keepingCapacity: true)
        let agentCombos: [KeyCombo] = [.toggleAgent, .expandAgent].compactMap { ShortcutStore.shared.key(for: $0) }
        stripConflicts(in: editMenu, agentCombos: agentCombos)
    }

    private func stripConflicts(in menu: NSMenu, agentCombos: [KeyCombo]) {
        for item in menu.items {
            if let sub = item.submenu {
                stripConflicts(in: sub, agentCombos: agentCombos)
            }
            let actionName = item.action.map(NSStringFromSelector) ?? ""
            let isSpellingShortcut = actionName == "checkSpelling:" || actionName == "showGuessPanel:"
            if isSpellingShortcut {
                trackedItems.append(WeakMenuItem(item: item))
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            let flags = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let eq = item.keyEquivalent
            // macOS encodes ⇧⌘; as keyEquivalent ":" with [.command] (or ";" with [.command, .shift]).
            let shiftedColon = eq == ":" && flags == .command
            let combo = KeyCombo(
                shiftedColon ? ";" : eq,
                command: flags.contains(.command),
                shift: flags.contains(.shift) || shiftedColon,
                option: flags.contains(.option),
                control: flags.contains(.control)
            )
            if isSpellingShortcut || agentCombos.contains(combo) {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                if !isSpellingShortcut { trackedItems.append(WeakMenuItem(item: item)) }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func shortcut(_ combo: KeyCombo?) -> some View {
        if let sc = combo?.swiftUI {
            self.keyboardShortcut(sc)
        } else {
            self
        }
    }
}

// MARK: - Help › Keyboard Shortcuts & onboarding

struct Shortcut: Identifiable {
    let keys: String
    let what: String
    var id: String { keys + "|" + what }
}

enum Shortcuts {
    static let first: [Shortcut] = [
        Shortcut(keys: "⌘T", what: "New tab"),
        Shortcut(keys: "⌘L", what: "Open address"),
        Shortcut(keys: "⌘K", what: "Search open tabs"),
        Shortcut(keys: "⌘;", what: "Toggle agent sidebar"),
        Shortcut(keys: "⇧⌘;", what: "Expand full-screen agent"),
        Shortcut(keys: "⌘/", what: "All keyboard shortcuts"),
    ]
}

struct ShortcutLine: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 9) {
            Text(shortcut.keys)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.16), lineWidth: 0.75)
                )
                .frame(minWidth: 68)
            Text(shortcut.what)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
    }
}

struct ShortcutGuide: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var store = ShortcutStore.shared
    @State private var hunt = ""
    @FocusState private var hunting: Bool

    private func matches(_ cmd: BrowserCommand) -> Bool {
        let q = hunt.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let key = store.key(for: cmd.id)?.display ?? ""
        return cmd.title.localizedCaseInsensitiveContains(q)
            || key.localizedCaseInsensitiveContains(q.replacingOccurrences(of: " ", with: ""))
    }

    var body: some View {
        Plate("Keyboard Shortcuts", close: { browser.showingShortcuts = false }) {
            VStack(alignment: .leading, spacing: 12) {
                Hunt(text: $hunt, prompt: "Search commands or keys", focus: $hunting)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if hunt.trimmingCharacters(in: .whitespaces).isEmpty {
                            group("Always available", [
                                Shortcut(keys: "⌘1–⌘9", what: "Jump to a tab (9 is the last)"),
                                Shortcut(keys: "⌃Tab / ⌃⇧Tab", what: "Next / previous tab"),
                                Shortcut(keys: "⌘← / ⌘→", what: "Back / forward"),
                                Shortcut(keys: ".", what: "Ask beside the page while reading"),
                            ])
                        }
                        ForEach(BrowserCommand.Section.allCases, id: \.self) { section in
                            let items = BrowserCommand.all.filter { $0.section == section && matches($0) }
                                .compactMap { cmd -> Shortcut? in
                                    guard let combo = store.key(for: cmd.id) else { return nil }
                                    return Shortcut(keys: combo.display, what: cmd.title)
                                }
                            if !items.isEmpty {
                                group(section.rawValue, items)
                            }
                        }
                        HStack {
                            Text("Customize any shortcut in Settings › Shortcuts.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.faint)
                            Spacer()
                            Button("Customize…") {
                                Store.settings.set(SettingsPanel.Page.shortcuts.rawValue, forKey: "settings.page")
                                browser.showingShortcuts = false
                                browser.tuning = true
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.accent)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(height: 340)
            }
        }
    }

    private func group(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .textCase(.uppercase)
                .tracking(0.6)
            ForEach(shortcuts) { ShortcutLine(shortcut: $0) }
        }
    }
}

struct ShortcutReminder: View {
    let show: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("A few keys make browsing quicker.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button("See shortcuts", action: show)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.accent)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Dismiss shortcut reminder")
            .accessibilityLabel("Dismiss shortcut reminder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }
}

// MARK: - Settings › Shortcuts

struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var store = ShortcutStore.shared

    @State private var hunt = ""
    @FocusState private var hunting: Bool
    @State private var notice: String?

    private func shown(_ cmd: BrowserCommand) -> Bool {
        let q = hunt.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let key = store.key(for: cmd.id)?.display ?? ""
        return cmd.title.localizedCaseInsensitiveContains(q)
            || key.localizedCaseInsensitiveContains(q.replacingOccurrences(of: " ", with: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Caption("From any app")
                Card {
                    Line(
                        "Summon browse",
                        store.globalNote ?? "Bring browse forward and open the address bar from any app"
                    ) {
                        GlobalKeyRecorder(store: store, notice: $notice)
                    }
                }
            }

            Hunt(text: $hunt, prompt: "Search commands or keys (e.g. tab, ⌘K)", focus: $hunting)

            if let notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.accent)
                    .padding(.leading, 2)
            }

            let found = BrowserCommand.all.filter(shown)
            if found.isEmpty {
                Nothing("No command called that, or on that key")
            }

            ForEach(BrowserCommand.Section.allCases, id: \.self) { section in
                let commands = found.filter { $0.section == section }
                if !commands.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Caption(section.rawValue)
                        Card {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, cmd in
                                if index > 0 { Rule() }
                                Line(cmd.title) {
                                    KeyRecorderBox(store: store, id: cmd.id, notice: $notice)
                                }
                                .contextMenu {
                                    Button("Clear Shortcut") {
                                        store.clear(cmd.id)
                                        notice = "Cleared \(cmd.title)"
                                    }
                                    .disabled(store.key(for: cmd.id) == nil)
                                    Button("Reset to Default") {
                                        store.reset(cmd.id)
                                        notice = nil
                                    }
                                    .disabled(!store.isChanged(cmd.id))
                                }
                            }
                        }
                    }
                }
            }

            if store.hasAnyCustom {
                HStack {
                    Spacer()
                    Pill("Reset All Defaults") {
                        store.resetAll()
                        notice = "Shortcuts reset to defaults"
                    }
                }
            }
        }
    }
}

private struct KeyRecorderBox: View {
    @ObservedObject var store: ShortcutStore
    let id: CommandID
    @Binding var notice: String?

    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            listening ? stop() : start()
        } label: {
            Text(listening ? "Press keys…" : (store.key(for: id)?.display ?? "Add…"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(listening ? Palette.onAccent : (store.key(for: id) != nil ? Palette.ink : Palette.faint))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(minWidth: 74)
                .background(
                    listening ? Palette.accent : Palette.wash,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        store.recording = true
        notice = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if event.keyCode == 51 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                store.clear(id)
                stop()
                return nil
            }
            guard let combo = KeyCombo(event: event) else { return nil }
            if !combo.isUsable {
                notice = "Include ⌘, ⌥, ⌃, or a function key"
                return nil
            }
            if KeyCombo.isReserved(combo) {
                notice = "\(combo.display) is reserved by macOS or tabs"
                return nil
            }
            if let displaced = store.set(combo, for: id), let title = BrowserCommand.byID[displaced]?.title {
                notice = "Moved \(combo.display) from \(title)"
            } else {
                notice = nil
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        store.recording = false
    }
}

private struct GlobalKeyRecorder: View {
    @ObservedObject var store: ShortcutStore
    @Binding var notice: String?

    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                listening ? stop() : start()
            } label: {
                Text(listening ? "Press keys…" : (store.globalHotKey?.combo.display ?? "Off"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(listening ? Palette.onAccent : (store.globalHotKey != nil ? Palette.ink : Palette.faint))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 74)
                    .background(
                        listening ? Palette.accent : Palette.wash,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            if store.globalHotKey != nil && !listening {
                Button {
                    store.clearGlobal()
                    notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                }
                .buttonStyle(.plain)
                .help("Turn off global shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        store.recording = true
        notice = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard let combo = KeyCombo(event: event) else { return nil }
            if let problem = store.setGlobal(combo: combo, keyCode: event.keyCode) {
                notice = problem
            } else {
                notice = nil
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        store.recording = false
    }
}
