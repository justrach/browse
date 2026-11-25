import SwiftUI
import AppKit

/// Native `NSTextField` wrapper for inline group renaming so both focus transfer
/// and outside clicks (e.g. clicking non-focusable chrome or `DragStrip`) commit
/// the rename consistently.
private struct GroupRenameField: NSViewRepresentable {
    let placeholder: String
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = initialText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        context.coordinator.watch(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCommit = onCommit
        coordinator.onCancel = onCancel
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let h = ceil(nsView.intrinsicContentSize.height)
        if let w = proposal.width {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: max(56, nsView.intrinsicContentSize.width + 6), height: h)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        var claimed = false
        private var finished = false
        private var watcher: Any?

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func commit(_ field: NSTextField) {
            guard !finished else { return }
            finished = true
            unwatch()
            onCommit(field.stringValue)
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            unwatch()
            onCancel()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                if let field = control as? NSTextField { commit(field) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard !finished, let field = note.object as? NSTextField else { return }
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                self.commit(field)
            }
        }

        func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, !self.finished, event.window === field.window else { return event }
                let local = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(local) {
                    DispatchQueue.main.async { [weak self, weak field] in
                        guard let self, let field else { return }
                        self.commit(field)
                    }
                }
                return event
            }
        }

        func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// Collapsible user-created tab group section for `SideBar`.
struct UserGroupSection<Row: View>: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let members: [Tab]
    @ViewBuilder let row: (Tab) -> Row

    @Environment(\.colorScheme) private var scheme
    @State private var headerHover = false

    private var editing: Bool { browser.editingGroupID == group.id }
    private var tintColor: Color {
        let idx = group.colour ?? 0
        return Spaces.toned(idx, dark: scheme == .dark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !group.collapsed {
                VStack(spacing: SideBar.gap) {
                    ForEach(members) { tab in
                        row(tab)
                    }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(tintColor.opacity(0.45))
                        .frame(width: 2)
                        .padding(.leading, 3)
                        .padding(.vertical, 4)
                }
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.quick, value: group.collapsed)
    }

    private var header: some View {
        HStack(spacing: 5) {
            headerLabel
                .padding(.leading, 8)

            Rectangle()
                .fill(tintColor.opacity(0.28))
                .frame(height: 0.75)
                .frame(maxWidth: .infinity)

            if headerHover && !editing {
                Button { browser.newTab(inGroup: group.id) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 19, height: 19)
                        .background(Capsule().fill(Palette.ink.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("New Tab in Group")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.trailing, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { headerHover = $0 }
        .contextMenu {
            GroupContextMenu(browser: browser, group: group)
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var headerLabel: some View {
        if editing {
            HStack(spacing: 5) {
                Circle()
                    .fill(tintColor)
                    .frame(width: 7, height: 7)
                GroupRenameField(
                    placeholder: "Group name",
                    initialText: group.name,
                    onCommit: { name in
                        browser.renameTabGroup(group.id, to: name)
                        browser.editingGroupID = nil
                    },
                    onCancel: {
                        browser.editingGroupID = nil
                    }
                )
            }
        } else {
            Button {
                withAnimation(Motion.quick) { browser.toggleTabGroup(group.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(tintColor.opacity(0.88))
                        .frame(width: 9)
                    Circle()
                        .fill(tintColor)
                        .frame(width: 7, height: 7)
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.88))
                        .lineLimit(1)
                    Text("\(members.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(tintColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tintColor.opacity(0.14)))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.collapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
        }
    }
}

/// Compact pill for a user-created tab group in `TabBar`.
struct UserGroupChip: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let count: Int

    @Environment(\.colorScheme) private var scheme

    static let chipWidth: CGFloat = 92

    private var editing: Bool { browser.editingGroupID == group.id }
    private var tintColor: Color {
        let idx = group.colour ?? 0
        return Spaces.toned(idx, dark: scheme == .dark)
    }

    var body: some View {
        Group {
            if editing {
                GroupRenameField(
                    placeholder: "Group",
                    initialText: group.name,
                    onCommit: { name in
                        browser.renameTabGroup(group.id, to: name)
                        browser.editingGroupID = nil
                    },
                    onCancel: {
                        browser.editingGroupID = nil
                    }
                )
                .frame(width: 80)
                .padding(.horizontal, 8)
                .frame(height: 24)
            } else {
                Button {
                    withAnimation(Motion.quick) { browser.toggleTabGroup(group.id) }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tintColor)
                            .frame(width: 6.5, height: 6.5)
                        Text(group.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 64, alignment: .leading)
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .opacity(0.82)
                    }
                    .foregroundStyle(tintColor)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Capsule().fill(tintColor.opacity(group.collapsed ? 0.18 : 0.11)))
        .overlay(Capsule().strokeBorder(tintColor.opacity(group.collapsed ? 0.45 : 0.25), lineWidth: 0.75))
        .help(group.collapsed ? "Expand “\(group.name)” (\(count))" : "Collapse “\(group.name)” (\(count))")
        .contextMenu {
            GroupContextMenu(browser: browser, group: group)
        }
    }
}

struct GroupContextMenu: View {
    @ObservedObject var browser: Browser
    let group: TabGroup

    var body: some View {
        let openMembers = browser.tabs.filter { $0.userGroupID == group.id && !$0.isBlank }
        Button("New Tab in Group") { browser.newTab(inGroup: group.id) }
        if browser.prefs.usesAgent, !openMembers.isEmpty {
            Button("Ask Codegraff about Group") { browser.askAgentAboutGroup(group.id) }
        }
        Divider()
        Button("Rename Group") { browser.editingGroupID = group.id }
        Button(group.collapsed ? "Expand Group" : "Collapse Group") {
            browser.toggleTabGroup(group.id)
        }
        Menu("Colour") {
            ForEach(0..<Spaces.colours.count, id: \.self) { index in
                Button {
                    browser.setTabGroupColour(group.id, to: index)
                } label: {
                    HStack {
                        Text(Spaces.colourNames[index])
                        if (group.colour ?? 0) == index {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        if browser.prefs.usesSpaces, browser.spaces.count > 1 {
            Menu("Move Group to Space") {
                ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                    Button {
                        browser.move(group: group.id, toSpace: space.id)
                    } label: {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
            }
        }
        Divider()
        Button("Ungroup Tabs") { browser.removeTabGroup(group.id) }
        Button("Close Group") { browser.closeTabGroup(group.id) }
    }
}
