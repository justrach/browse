import Foundation
import SwiftUI

/// A named section of ordinary tabs in one space's tab layout.
/// Tabs remain ordinary `Tab` instances whose `userGroupID` records membership.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
    var colour: Int? = nil

    init(id: UUID = UUID(), name: String, collapsed: Bool = false, colour: Int? = nil) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.colour = colour
    }

    private enum Keys: String, CodingKey { case id, name, collapsed, colour }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        colour = try? c.decodeIfPresent(Int.self, forKey: .colour)
    }

    /// Stable positive integer ID exposed to Chrome extensions (`chrome.tabGroups`).
    static func number(_ id: UUID) -> Int {
        let u = id.uuid
        let n = Int(u.0 & 0x7F) << 24 | Int(u.1) << 16 | Int(u.2) << 8 | Int(u.3)
        return n == 0 ? 1 : n
    }
}

@MainActor
extension Browser {
    /// Non-pinned, non-Agent tabs assigned to `groupID`.
    func tabs(inGroup groupID: UUID) -> [Tab] {
        tabs.filter { $0.pin == nil && !$0.isAgentTab && $0.userGroupID == groupID }
    }

    /// The user-created tab group containing `tab`, if any.
    func group(for tab: Tab) -> TabGroup? {
        guard tab.pin == nil, !tab.isAgentTab, let gid = tab.userGroupID else { return nil }
        return tabGroups.first { $0.id == gid }
    }

    /// Creates a new user tab group (optionally seeding it with `tab`) and begins inline rename.
    @discardableResult
    func createTabGroup(from tab: Tab? = nil, name: String = "New Group") -> TabGroup {
        let nextColour = (tabGroups.last?.colour.map { ($0 + 1) % Spaces.colours.count })
            ?? (tabGroups.count % Spaces.colours.count)
        let group = TabGroup(id: UUID(), name: name, collapsed: false, colour: nextColour)
        tabGroups.append(group)
        if let tab {
            addTab(tab, toGroup: group.id)
        } else {
            writeSession(now: true)
        }
        editingGroupID = group.id
        return group
    }

    /// Moves `tab` into `groupID`, preserving the four-way partition invariant
    /// (Pinned / Agent / UserGroup / Ungrouped are mutually exclusive).
    func addTab(_ tab: Tab, toGroup groupID: UUID) {
        guard let gIndex = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        if editingPin == tab.id { editingPin = nil }
        tab.pin = nil
        tab.agentGroup = nil
        tab.userGroupID = groupID
        tabGroups[gIndex].collapsed = false

        // Keep grouped tabs together directly after pins and Agent tabs.
        let membersBefore = tabs.filter { $0.id != tab.id && $0.pin == nil && !$0.isAgentTab && $0.userGroupID == groupID }
        let floor = pinnedCount + agentTabs.count
        if let current = tabs.firstIndex(where: { $0.id == tab.id }) {
            let desiredIndex: Int
            if let last = membersBefore.last, let idx = tabs.firstIndex(where: { $0.id == last.id }) {
                desiredIndex = current < idx ? idx : min(idx + 1, tabs.count - 1)
            } else {
                desiredIndex = min(floor, max(0, tabs.count - 1))
            }
            if current != desiredIndex {
                move(tab, to: desiredIndex)
            }
        }
        writeSession(now: true)
    }

    /// Moves `tab` out of its user group back into loose personal tabs.
    func removeTabFromGroup(_ tab: Tab) {
        guard tab.userGroupID != nil else { return }
        tab.userGroupID = nil
        if let current = tabs.firstIndex(where: { $0.id == tab.id }) {
            let floor = pinnedCount + agentTabs.count
            let lastGrouped = tabs.lastIndex { $0.pin != nil || $0.isAgentTab || $0.userGroupID != nil }
            let raw = lastGrouped.map { current < $0 ? $0 : $0 + 1 } ?? floor
            let target = min(max(floor, raw), max(0, tabs.count - 1))
            if current != target {
                move(tab, to: target)
            }
        }
        writeSession(now: true)
    }

    func toggleTabGroup(_ groupID: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        tabGroups[index].collapsed.toggle()
        writeSession(now: true)
    }

    func renameTabGroup(_ groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        tabGroups[index].name = trimmed
        writeSession(now: true)
    }

    func setTabGroupColour(_ groupID: UUID, to colour: Int) {
        guard let index = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        tabGroups[index].colour = ((colour % Spaces.colours.count) + Spaces.colours.count) % Spaces.colours.count
        writeSession(now: true)
    }

    func moveTabGroup(_ groupID: UUID, to targetIndex: Int) {
        guard let current = tabGroups.firstIndex(where: { $0.id == groupID }),
              tabGroups.indices.contains(targetIndex),
              current != targetIndex else { return }
        tabGroups.move(fromOffsets: IndexSet(integer: current), toOffset: targetIndex > current ? targetIndex + 1 : targetIndex)
        writeSession(now: true)
    }

    func newTab(inGroup groupID: UUID) {
        guard let gIndex = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            newTab(immediate: true)
            return
        }
        leaveStage()
        tabGroups[gIndex].collapsed = false
        let tab = Tab()
        prepare(tab)
        tab.userGroupID = groupID
        let lastMember = tabs.lastIndex(where: { $0.userGroupID == groupID })
        let insertAt = lastMember.map { $0 + 1 } ?? min(tabs.count, pinnedCount + agentTabs.count)
        insert(tab, at: insertAt)
        select(tab)
        editing = true
        typed = ""
        focusRequest += 1
        writeSession(now: true)
    }

    /// Ungroups every tab in `groupID` and removes the group heading.
    func removeTabGroup(_ groupID: UUID) {
        for tab in tabs where tab.userGroupID == groupID {
            tab.userGroupID = nil
        }
        tabGroups.removeAll { $0.id == groupID }
        if editingGroupID == groupID { editingGroupID = nil }
        writeSession(now: true)
    }

    /// Closes all non-bench tabs inside `groupID` and removes the group.
    func closeTabGroup(_ groupID: UUID) {
        let members = tabs(inGroup: groupID).filter { !$0.bench }
        tabGroups.removeAll { $0.id == groupID }
        if editingGroupID == groupID { editingGroupID = nil }
        if members.isEmpty {
            writeSession(now: true)
            return
        }
        if tabs.count == members.count {
            newTab(immediate: true)
        }
        for tab in members {
            tab.userGroupID = nil
            close(tab)
        }
        announce(members.count == 1 ? "Closed 1 grouped tab — ⌘⇧T brings it back" : "Closed \(members.count) grouped tabs — ⌘⇧T brings them back")
        writeSession(now: true)
    }

    /// Strips dangling `userGroupID` values referencing unknown groups.
    func pruneOrphanGroups() {
        let valid = Set(tabGroups.map(\.id))
        for tab in tabs {
            if tab.pin != nil || tab.isAgentTab || (tab.userGroupID.map { !valid.contains($0) } ?? false) {
                tab.userGroupID = nil
            }
        }
    }

    /// Moves a whole user group and its tabs to another Space.
    func move(group groupID: UUID, toSpace targetID: UUID) {
        guard targetID != spaceID,
              let gIndex = tabGroups.firstIndex(where: { $0.id == groupID }),
              let targetSpace = spaces.first(where: { $0.id == targetID })
        else { return }

        let group = tabGroups.remove(at: gIndex)
        if editingGroupID == groupID { editingGroupID = nil }
        let members = tabs(inGroup: groupID)
        let sharedStore = Spaces.store(for: spaceID) === Spaces.store(for: targetID)

        if parked[targetID] == nil {
            parked[targetID] = loadRow(targetID)
        }
        var destination = parked[targetID] ?? Parked(tabs: [], active: nil)
        destination.groups.append(group)

        for tab in members {
            if split?.has(tab.id) == true { unsplit() }
            if floating == tab.id { land() }
            let moved: Tab
            if sharedStore {
                moved = tab
                moved.agentGroup = nil
            } else {
                moved = Tab(configuration: Web.configuration(space: targetID))
                prepare(moved)
                moved.name = tab.name
                moved.userGroupID = groupID
                if let url = tab.pending ?? tab.address {
                    moved.restore(url: url, title: tab.title, name: tab.name)
                }
                tab.close()
            }
            destination.tabs.append(moved)
            if destination.active == nil { destination.active = moved.id }
        }
        parked[targetID] = destination

        let memberIDs = Set(members.map(\.id))
        let remaining = tabs.filter { !memberIDs.contains($0.id) }
        if remaining.isEmpty {
            let blank = Tab()
            prepare(blank)
            showRow([blank], active: blank.id)
            editing = true
        } else {
            let nextActive = (activeID.map { memberIDs.contains($0) } ?? false) ? remaining.first?.id : activeID
            showRow(remaining, active: nextActive)
        }

        writeSession(now: true)
        writeParkedSession(space: targetID, row: destination)
        announce("Moved “\(group.name)” to \(targetSpace.name)")
    }
}
