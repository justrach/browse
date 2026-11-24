import SwiftUI

/// Collapsible user-created tab group section for `SideBar`.
struct UserGroupSection<Row: View>: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let members: [Tab]
    @ViewBuilder let row: (Tab) -> Row

    @Environment(\.colorScheme) private var scheme
    @State private var headerHover = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

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
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { browser.editingGroupID = nil }
                    .onAppear {
                        draft = group.name
                        DispatchQueue.main.async { renameFocused = true }
                    }
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

    private func commitRename() {
        browser.renameTabGroup(group.id, to: draft)
        browser.editingGroupID = nil
    }
}

/// Compact pill for a user-created tab group in `TabBar`.
struct UserGroupChip: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let count: Int

    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    static let chipWidth: CGFloat = 92

    private var editing: Bool { browser.editingGroupID == group.id }
    private var tintColor: Color {
        let idx = group.colour ?? 0
        return Spaces.toned(idx, dark: scheme == .dark)
    }

    var body: some View {
        Group {
            if editing {
                TextField("Group", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 80)
                    .focused($renameFocused)
                    .onSubmit {
                        browser.renameTabGroup(group.id, to: draft)
                        browser.editingGroupID = nil
                    }
                    .onExitCommand { browser.editingGroupID = nil }
                    .onAppear {
                        draft = group.name
                        DispatchQueue.main.async { renameFocused = true }
                    }
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
        Button("New Tab in Group") { browser.newTab(inGroup: group.id) }
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
