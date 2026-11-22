import AppKit
import SwiftUI

/// NanoHarness ↑/↓ prompt recall state (1:1 with `prompt_history.zig`):
/// steps through the open chat's earlier human prompts, newest first, and
/// restores the unsent draft when ↓ passes the newest prompt.
struct PromptRecallState {
    private var back = 0
    private var savedDraft = ""
    private var prompts: [String] = []
    private(set) var shown: String?

    mutating func reset() {
        back = 0
        savedDraft = ""
        prompts = []
        shown = nil
    }

    func isShowingUnchanged(_ text: String) -> Bool {
        guard let shown else { return false }
        return shown == text
    }

    /// One step: `-1` for an older prompt, `+1` for a newer one (or restoring
    /// the original draft). Returns the replacement text, or `nil` if there is
    /// nowhere to step.
    mutating func step(delta: Int, currentText: String, history: [String]) -> String? {
        if let shown, shown != currentText { reset() }
        if shown == nil {
            guard delta < 0, !history.isEmpty else { return nil }
            savedDraft = currentText
            prompts = history
            back = 0
        } else if delta < 0 {
            guard back + 1 < prompts.count else { return nil }
            back += 1
        } else if back > 0 {
            back -= 1
        } else {
            let restored = savedDraft
            reset()
            return restored
        }
        let next = prompts[prompts.count - 1 - back]
        shown = next
        return next
    }
}

/// Built-in and agent-advertised slash commands (matching NanoHarness
/// `composer_completion.zig`).
struct NanoSlashCommand: Identifiable, Equatable {
    enum Action: Equatable {
        case newChat
        case model
        case stop
        case expand
        case writeMode
        case feedback
        case reconnect
        case guide
        case insert(String)
    }

    let id: String
    let name: String
    let description: String
    let icon: String
    let action: Action

    static func catalog(agentCommands: [String], working: Bool, full: Bool) -> [NanoSlashCommand] {
        var list: [NanoSlashCommand] = [
            NanoSlashCommand(id: "new", name: "new", description: "Start a new conversation", icon: "square.and.pencil", action: .newChat),
            NanoSlashCommand(id: "model", name: "model", description: "Switch model or reasoning effort", icon: "cpu", action: .model),
            NanoSlashCommand(id: "write", name: "write", description: "Open full-page editor (⌘⇧E)", icon: "doc.text", action: .writeMode),
            NanoSlashCommand(id: "expand", name: "expand", description: full ? "Move sidebar beside page (⇧⌘;)" : "Expand conversation full screen (⇧⌘;)", icon: full ? "sidebar.right" : "arrow.up.left.and.arrow.down.right", action: .expand),
        ]
        if working {
            list.insert(
                NanoSlashCommand(id: "stop", name: "stop", description: "Stop the current run", icon: "stop.circle", action: .stop),
                at: 0
            )
        }
        list.append(contentsOf: [
            NanoSlashCommand(id: "feedback", name: "feedback", description: "Report an agent problem", icon: "flag", action: .feedback),
            NanoSlashCommand(id: "reconnect", name: "reconnect", description: "Reconnect Codegraff", icon: "arrow.triangle.2.circlepath", action: .reconnect),
            NanoSlashCommand(id: "help", name: "help", description: "How to use Codegraff", icon: "questionmark.circle", action: .guide),
        ])
        let builtIn = Set(list.map(\.name))
        for raw in agentCommands {
            let clean = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            guard !clean.isEmpty, !builtIn.contains(clean) else { continue }
            list.append(NanoSlashCommand(
                id: "graff-\(clean)",
                name: clean,
                description: "Codegraff command",
                icon: "terminal",
                action: .insert("/\(clean) ")
            ))
        }
        return list
    }

    /// Word count matching NanoHarness `view_write.zig:wordCount`.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { token in token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0.value >= 0x80 } }
            .count
    }
}

/// Native 120 FPS AppKit text editor for Codegraff's composer and Write page.
/// Avoids SwiftUI `TextField(..., axis: .vertical)` per-keystroke layout thrash,
/// paints NanoHarness's crisp rounded accent caret, and handles Return,
/// Shift+Return, ⌘Return, ⌘⇧E, ↑/↓ prompt recall, and slash-menu keys natively.
struct NanoComposerField: NSViewRepresentable {
    let text: String
    let revision: Int
    let fontSize: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let newlinesOnReturn: Bool
    let slashMenuOpen: Bool
    let recallingUnchanged: Bool
    let focusRequest: Int

    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool

    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onCommandReturn: () -> Void
    let onSlashMove: (Int) -> Void
    let onSlashAccept: () -> Void
    let onSlashDismiss: () -> Void
    let onRecall: (Int) -> Void
    let onEscape: () -> Void
    let onToggleWriteMode: () -> Void
    var onTab: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let textView = NanoTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Message Codegraff")
        textView.applyTypography(size: fontSize)

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll

        if !text.isEmpty {
            textView.string = text
            context.coordinator.lastRevision = revision
        }
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        textView.applyTypography(size: fontSize)

        // Sync text ONLY when a programmatic mutation bumped `revision` (or on
        // first mount), so rapid typing / IME composition is never overwritten.
        if coordinator.lastRevision != revision {
            coordinator.lastRevision = revision
            if textView.string != text {
                coordinator.suppressingChange = true
                textView.string = text
                let end = (text as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                coordinator.suppressingChange = false
                coordinator.recalculateHeight()
            }
        }

        if coordinator.answeredFocus != focusRequest {
            coordinator.answeredFocus = focusRequest
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }

        // Keep height accurate when container width changes (e.g. sidebar resize).
        let width = scroll.contentSize.width
        if abs(width - coordinator.lastWidth) > 0.5, width > 1 {
            coordinator.lastWidth = width
            DispatchQueue.main.async { coordinator.recalculateHeight() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NanoComposerField
        weak var textView: NanoTextView?
        weak var scrollView: NSScrollView?
        var lastRevision = -1
        var answeredFocus = -1
        var lastWidth: CGFloat = 0
        var suppressingChange = false

        init(parent: NanoComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressingChange, let textView else { return }
            parent.onTextChange(textView.string)
            recalculateHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func recalculateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2 + 2
            let clamped = min(parent.maxHeight, max(parent.minHeight, ceil(used)))
            if abs(parent.measuredHeight - clamped) > 0.5 {
                parent.measuredHeight = clamped
            }
        }

        func handleKeyDown(_ event: NSEvent, in textView: NanoTextView) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasMarked = textView.hasMarkedText()

            // ⌘⇧E toggles NanoHarness full-page Write mode.
            if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "e" {
                parent.onToggleWriteMode()
                return true
            }

            // Slash-command completion popup owns ↑/↓/Tab/Return/Esc while open.
            if parent.slashMenuOpen, !hasMarked {
                switch event.keyCode {
                case 126: // Up
                    parent.onSlashMove(-1)
                    return true
                case 125: // Down
                    parent.onSlashMove(1)
                    return true
                case 48, 36, 76: // Tab, Return, Enter
                    if !flags.contains(.shift) {
                        parent.onSlashAccept()
                        return true
                    }
                case 53: // Escape
                    parent.onSlashDismiss()
                    return true
                default:
                    break
                }
            }

            // Return / Enter handling.
            if (event.keyCode == 36 || event.keyCode == 76), !hasMarked {
                if flags.contains(.command) {
                    parent.onCommandReturn()
                    return true
                }
                if parent.newlinesOnReturn || flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }

            // Escape: cancel queue edit or close Write mode.
            if event.keyCode == 53, !hasMarked {
                parent.onEscape()
                return true
            }

            // Tab: optional switch (e.g. AgentHome Search/Ask).
            if event.keyCode == 48, flags.isEmpty, !hasMarked, let onTab = parent.onTab {
                onTab()
                return true
            }

            // ↑/↓ prompt history recall when caret is at boundary (or stepping
            // through an unchanged recalled prompt), matching NanoHarness.
            if (event.keyCode == 126 || event.keyCode == 125), flags.isEmpty, !hasMarked {
                let sel = textView.selectedRange()
                if sel.length == 0 {
                    let delta = event.keyCode == 126 ? -1 : 1
                    let len = (textView.string as NSString).length
                    let atBoundary = (delta < 0 && sel.location == 0) || (delta > 0 && sel.location == len)
                    if parent.recallingUnchanged || atBoundary {
                        parent.onRecall(delta)
                        return true
                    }
                }
            }

            return false
        }
    }
}

/// Custom `NSTextView` with NanoHarness's crisp rounded accent caret and
/// zero-lag native key routing.
final class NanoTextView: NSTextView {
    weak var coordinator: NanoComposerField.Coordinator?
    private var appliedSize: CGFloat = 0

    func applyTypography(size: CGFloat) {
        let ink = Palette.NS.ink
        let accent = NSColor(Palette.accent)
        let font = NSFont.systemFont(ofSize: size)
        if abs(appliedSize - size) > 0.1 || self.font == nil {
            appliedSize = size
            self.font = font
        }
        self.textColor = ink
        self.insertionPointColor = accent
        self.selectedTextAttributes = [
            .backgroundColor: accent.withAlphaComponent(0.22),
            .foregroundColor: ink,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        self.defaultParagraphStyle = paragraph
        self.typingAttributes = [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTypography(size: appliedSize > 0 ? appliedSize : 13.5)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let c = coordinator, !c.parent.isFocused {
            c.parent.isFocused = true
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let c = coordinator, c.parent.isFocused {
            c.parent.isFocused = false
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if let coordinator, coordinator.handleKeyDown(event, in: self) {
            return
        }
        super.keyDown(with: event)
    }

    /// NanoHarness rounded accent caret (`1.75pt` wide, inset `1.5pt` top/bottom).
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var bar = rect
        bar.size.width = 1.75
        bar.origin.y += 1.5
        bar.size.height = max(8, bar.size.height - 3)
        if flag {
            NSGraphicsContext.saveGraphicsState()
            NSColor(Palette.accent).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 0.9, yRadius: 0.9).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -2, dy: -1), avoidAdditionalLayout: flag)
    }
}
