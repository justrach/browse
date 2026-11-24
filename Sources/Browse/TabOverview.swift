import SwiftUI
import AppKit
import Combine

/// Lightweight in-memory snapshot cache for open tabs, shared between the
/// `⌘K` Command Switcher sneak-peek pane, `⌃Tab` HUD, and `⇧⌘\` Visual Tab Overview grid.
/// Captures on demand via `Tab.capturePreview` so idle browsing uses zero extra RAM.
@MainActor
final class TabPreviewCache: ObservableObject {
    static let shared = TabPreviewCache()

    /// Per-tab observable slot so landing a captured thumbnail invalidates
    /// ONLY that tab's thumbnail view instead of every open card/HUD item.
    @MainActor
    final class Slot: ObservableObject {
        @Published fileprivate(set) var image: NSImage?
        @Published fileprivate(set) var revision = 0
        fileprivate var url: URL?
        fileprivate var capturedAt: Date?
    }

    private let cache: NSCache<NSUUID, Slot> = {
        let c = NSCache<NSUUID, Slot>()
        c.countLimit = 48
        return c
    }()
    private let slots = NSMapTable<NSUUID, Slot>.strongToWeakObjects()
    private var inFlight: Set<Tab.ID> = []
    private var pending: [(tab: Tab, width: CGFloat)] = []
    private static let maxConcurrentCaptures = 4

    func slot(for tab: Tab) -> Slot {
        let key = tab.id as NSUUID
        if let existing = cache.object(forKey: key) {
            return existing
        }
        if let existing = slots.object(forKey: key) {
            cache.setObject(existing, forKey: key)
            return existing
        }
        let created = Slot()
        slots.setObject(created, forKey: key)
        cache.setObject(created, forKey: key)
        return created
    }

    func displayImage(for tab: Tab, slot: Slot) -> NSImage? {
        if slot.url == tab.address, let img = slot.image {
            return img
        }
        return tab.cover
    }

    func image(for tab: Tab) -> NSImage? {
        let key = tab.id as NSUUID
        if let entry = cache.object(forKey: key) ?? slots.object(forKey: key),
           entry.url == tab.address,
           let img = entry.image {
            return img
        }
        return tab.cover
    }

    func request(_ tab: Tab, width: CGFloat = 560) {
        guard !tab.isBlank else { return }
        let key = tab.id as NSUUID
        if let entry = cache.object(forKey: key) ?? slots.object(forKey: key),
           entry.url == tab.address,
           entry.image != nil,
           let capturedAt = entry.capturedAt,
           Date().timeIntervalSince(capturedAt) < 120 {
            return
        }
        enqueueCapture(tab, width: width)
    }

    func refresh(_ tab: Tab, width: CGFloat = 640) {
        guard !tab.isBlank else { return }
        enqueueCapture(tab, width: width)
    }

    func trim() {
        pending.removeAll()
        if let enumerator = slots.objectEnumerator() {
            while let obj = enumerator.nextObject() as? Slot {
                obj.image = nil
                obj.url = nil
                obj.capturedAt = nil
                obj.revision &+= 1
            }
        }
        cache.removeAllObjects()
    }

    private func enqueueCapture(_ tab: Tab, width: CGFloat) {
        guard !inFlight.contains(tab.id) else { return }
        if let index = pending.firstIndex(where: { $0.tab.id == tab.id }) {
            if width > pending[index].width { pending[index].width = width }
            return
        }
        if inFlight.count >= Self.maxConcurrentCaptures {
            pending.append((tab: tab, width: width))
            return
        }
        startCapture(tab, width: width)
    }

    private func startCapture(_ tab: Tab, width: CGFloat) {
        inFlight.insert(tab.id)
        let tabID = tab.id
        let url = tab.address
        tab.capturePreview(width: width) { [weak self, weak tab] image in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(tabID)
                if let image, let tab {
                    let target = self.slot(for: tab)
                    target.url = url
                    target.capturedAt = Date()
                    target.image = image
                    target.revision &+= 1
                }
                self.drainPending()
            }
        }
    }

    private func drainPending() {
        while inFlight.count < Self.maxConcurrentCaptures, !pending.isEmpty {
            let next = pending.removeFirst()
            guard !next.tab.isBlank, !inFlight.contains(next.tab.id) else { continue }
            startCapture(next.tab, width: next.width)
        }
    }
}

/// Memoizes `Browser.switcherItems` and `switcherFallbackActions` across hover/keyboard
/// selection moves while the query and browser tab list remain unchanged.
@MainActor
private final class SwitcherResultsCache {
    struct Snapshot {
        let items: [SwitcherItem]
        let totalOpenCount: Int
        let fallbackActions: [SwitcherAction]
    }

    private var cancellable: AnyCancellable?
    private weak var subscribedBrowser: Browser?
    private var generation = 0
    private var cachedGen = -1
    private var cachedQuery = ""
    private var cachedMode: TabSwitcherMode = .palette
    private var cachedSnapshot = Snapshot(items: [], totalOpenCount: 0, fallbackActions: [])

    func invalidate() {
        cachedGen = -1
    }

    func snapshot(browser: Browser, query: String, mode: TabSwitcherMode) -> Snapshot {
        if subscribedBrowser !== browser {
            subscribedBrowser = browser
            generation &+= 1
            cachedGen = -1
            cancellable = browser.objectWillChange.sink { [weak self] _ in
                self?.generation &+= 1
            }
        }
        if cachedGen == generation && cachedQuery == query && cachedMode == mode {
            return cachedSnapshot
        }
        cachedGen = generation
        cachedQuery = query
        cachedMode = mode

        let items = browser.switcherItems(matching: query, mode: mode)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = trimmed.isEmpty ? items.count : browser.switcherItems(matching: "", mode: mode).count
        let actions = mode == .palette
            ? browser.switcherFallbackActions(for: query, excluding: items, limit: items.isEmpty ? 7 : 4)
            : []
        let snap = Snapshot(items: items, totalOpenCount: total, fallbackActions: actions)
        cachedSnapshot = snap
        return snap
    }
}

/// Top-level overlay hosting both the `⌘K` Command Switcher + Live Sneak-Peek
/// and the `⇧⌘\` Visual Tab Overview Grid.
struct TabSwitcherLayer: View {
    @ObservedObject var browser: Browser
    @ObservedObject var state: TabSwitcherState
    let mode: TabSwitcherMode

    init(browser: Browser, mode: TabSwitcherMode) {
        self.browser = browser
        self._state = ObservedObject(wrappedValue: browser.tabSwitcherState)
        self.mode = mode
    }

    var body: some View {
        Group {
            switch mode {
            case .palette:
                TabPaletteView(browser: browser, state: state)
                    .transition(.opacity)
            case .grid:
                TabOverviewGridView(browser: browser, state: state)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(Motion.quick, value: mode)
    }
}

// MARK: - ⌘K Command Switcher + Live Sneak-Peek

private struct TabPaletteView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var state: TabSwitcherState
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var resultsCache = SwitcherResultsCache()

    private let previews = TabPreviewCache.shared

    private func resolvedSelection(in snapshot: SwitcherResultsCache.Snapshot) -> (item: SwitcherItem?, action: SwitcherAction?) {
        let items = snapshot.items
        let actions = snapshot.fallbackActions
        if let actionID = state.selectedActionID,
           let match = actions.first(where: { $0.id == actionID }) {
            return (nil, match)
        }
        if items.isEmpty {
            return (nil, actions.first)
        }
        return (items.first { $0.id == state.selectedID } ?? items.first, nil)
    }

    var body: some View {
        let dark = scheme == .dark
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let snapshot = resultsCache.snapshot(browser: browser, query: state.query, mode: .palette)
        let items = snapshot.items
        let fallbackActions = snapshot.fallbackActions
        let selection = resolvedSelection(in: snapshot)
        let selectedItem = selection.item
        let selectedAction = selection.action

        ZStack {
            // Subtle dim scrim — tap anywhere outside the palette to dismiss.
            Color.black.opacity(dark ? 0.42 : 0.18)
                .contentShape(Rectangle())
                .onTapGesture { browser.closeTabSwitcher() }

            VStack(spacing: 0) {
                searchHeader(dark: dark, itemCount: items.count, totalCount: snapshot.totalOpenCount)
                Divider().overlay(Palette.hairline)

                if items.isEmpty {
                    if !fallbackActions.isEmpty {
                        webFallback(dark: dark, actions: fallbackActions, selectedAction: selectedAction)
                    } else {
                        emptyState
                    }
                } else {
                    HStack(spacing: 0) {
                        tabList(
                            dark: dark,
                            items: items,
                            actions: fallbackActions,
                            selectedItem: selectedItem,
                            selectedAction: selectedAction
                        )
                        .frame(width: 336)
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(width: 1)
                        sneakPeek(dark: dark, selectedItem: selectedItem, selectedAction: selectedAction)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                }

                Divider().overlay(Palette.hairline)
                footerBar(dark: dark, itemsEmpty: items.isEmpty, selectedAction: selectedAction)
            }
            .frame(width: 780, height: 472)
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Palette.ground.opacity(dark ? 0.86 : 0.92)
                }
            }
            .clipShape(cardShape)
            .overlay(
                cardShape.strokeBorder(
                    dark ? Color.white.opacity(0.13) : Color.black.opacity(0.10),
                    lineWidth: 0.75
                )
            )
            .shadow(color: .black.opacity(dark ? 0.50 : 0.18), radius: 34, y: 14)
            .padding(.bottom, 24)
        }
        .onAppear {
            resultsCache.invalidate()
            let current = resultsCache.snapshot(browser: browser, query: state.query, mode: .palette)
            syncSelection(snapshot: current)
            DispatchQueue.main.async { searchFocused = true }
            if let tab = resolvedSelection(in: current).item?.tab {
                previews.request(tab, width: 640)
            }
        }
        .onChange(of: state.focusTick) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: state.query) { _, _ in
            let current = resultsCache.snapshot(browser: browser, query: state.query, mode: .palette)
            syncSelection(snapshot: current)
        }
        .onChange(of: state.selectedID) { _, _ in
            let current = resultsCache.snapshot(browser: browser, query: state.query, mode: .palette)
            if let tab = resolvedSelection(in: current).item?.tab {
                previews.request(tab, width: 640)
            }
        }
    }

    private func syncSelection(snapshot: SwitcherResultsCache.Snapshot) {
        let list = snapshot.items
        let actions = snapshot.fallbackActions
        if let currentAction = state.selectedActionID,
           actions.contains(where: { $0.id == currentAction }) {
            state.selectedID = nil
            return
        }
        if !list.isEmpty {
            state.selectedActionID = nil
            if let current = state.selectedID, list.contains(where: { $0.id == current }) {
                return
            }
            state.selectedID = list.first?.id
            return
        }
        state.selectedID = nil
        state.selectedActionID = actions.first?.id
    }

    private func filteringBadgeText(itemCount: Int, totalCount: Int) -> String {
        let filtering = !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return filtering ? "\(itemCount) of \(totalCount)" : "\(itemCount) open"
    }

    private func searchHeader(dark: Bool, itemCount: Int, totalCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.muted)

            TextField("Search tabs, sites, or the web…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Palette.ink)
                .focused($searchFocused)
                .onSubmit { browser.confirmTabSwitcher() }

            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Text(filteringBadgeText(itemCount: itemCount, totalCount: totalCount))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Palette.ink.opacity(dark ? 0.08 : 0.055))
                )

            Button {
                browser.openTabSwitcher(.grid)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                    Text("Overview")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Palette.ink.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.ink.opacity(dark ? 0.09 : 0.06))
                )
            }
            .buttonStyle(TactilePress())
            .help("Switch to Visual Tab Overview (⇧⌘\\)")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func tabList(
        dark: Bool,
        items: [SwitcherItem],
        actions: [SwitcherAction],
        selectedItem: SwitcherItem?,
        selectedAction: SwitcherAction?
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !actions.isEmpty {
                        HStack {
                            Text("Open Tabs")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 3)
                    }

                    ForEach(items) { item in
                        let tab = item.tab
                        let isSelected = item.id == selectedItem?.id
                        let isActive = item.space == nil && tab.id == browser.activeID
                        TabPaletteRow(
                            tab: tab,
                            space: item.space,
                            selected: isSelected,
                            active: isActive,
                            inSplit: item.space == nil && browser.split?.has(tab.id) == true,
                            dark: dark,
                            onHover: { over in
                                if over && !browser.cycling {
                                    state.selectedActionID = nil
                                    state.selectedID = item.id
                                }
                            },
                            onSelect: {
                                browser.selectFromSwitcher(item)
                            },
                            onClose: {
                                browser.closeTabFromSwitcher(item)
                            }
                        )
                        .id(item.id)
                    }

                    if !actions.isEmpty {
                        let onlyClosed = actions.allSatisfy { $0.kind == .closed }
                        HStack {
                            Text(onlyClosed ? "Recently Closed" : "Sites & Web")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 3)

                        ForEach(actions) { action in
                            let isSelected = action.id == selectedAction?.id
                            SwitcherActionRow(
                                action: action,
                                selected: isSelected,
                                dark: dark,
                                compact: true,
                                onHover: { over in
                                    if over && !browser.cycling {
                                        state.selectedID = nil
                                        state.selectedActionID = action.id
                                    }
                                },
                                onSelect: {
                                    browser.openActionFromSwitcher(action)
                                }
                            )
                            .id(action.id)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: state.keyboardScrollTick) { _, _ in
                if let id = state.selectedID {
                    proxy.scrollTo(id)
                } else if let id = state.selectedActionID {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder
    private func sneakPeek(dark: Bool, selectedItem: SwitcherItem?, selectedAction: SwitcherAction?) -> some View {
        if let item = selectedItem {
            let tab = item.tab
            let isActive = item.space == nil && tab.id == browser.activeID
            let prettyURL = tab.address.map { Address.pretty($0) } ?? "New Tab"

            VStack(alignment: .leading, spacing: 12) {
                // Visual 16:10 sneak-peek browser card (bounded height so header
                // and footer never overflow the 472pt palette).
                TabPreviewSurface(tab: tab, slot: previews.slot(for: tab), dark: dark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 234)
                    .background(dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(color: .black.opacity(dark ? 0.30 : 0.08), radius: 12, y: 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        browser.selectFromSwitcher(item)
                    }
                    .onAppear { previews.request(tab, width: 640) }

                // Metadata & quick actions.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 16)
                        Text(tab.label)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if tab.asleep {
                            HStack(spacing: 3) {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 9, weight: .medium))
                                Text("Asleep")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.ink.opacity(dark ? 0.09 : 0.06)))
                        }
                        if let space = item.space {
                            SpaceChip(space: space, dark: dark)
                        } else if isActive {
                            Text("Current")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Palette.accent.opacity(dark ? 0.18 : 0.12)))
                        }
                    }

                    Text(prettyURL)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        browser.selectFromSwitcher(item)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.asleep ? "Wake Tab" : (isActive ? "Focus Tab" : "Switch to Tab"))
                                .font(.system(size: 12, weight: .medium))
                            Text("↩")
                                .font(.system(size: 11, weight: .medium))
                                .opacity(0.72)
                        }
                        .foregroundStyle(dark ? Color.black : Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.ink))
                    }
                    .buttonStyle(TactilePress())

                    if item.space == nil && !isActive && !tab.isBlank {
                        Button {
                            browser.splitSelectedTabFromSwitcher()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text("Split")
                                    .font(.system(size: 12, weight: .medium))
                                Text("⌘D")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.muted)
                            }
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Palette.ink.opacity(dark ? 0.10 : 0.065))
                            )
                        }
                        .buttonStyle(TactilePress())
                    }

                    Spacer(minLength: 0)

                    Button {
                        browser.closeTabFromSwitcher(item)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Palette.ink.opacity(dark ? 0.07 : 0.05)))
                    }
                    .buttonStyle(TactilePress())
                    .help("Close tab (⌘⌫)")
                }
            }
            .padding(16)
        } else if let action = selectedAction {
            actionPreview(action, dark: dark)
        }
    }

    private func actionPreview(_ action: SwitcherAction, dark: Bool) -> some View {
        let iconName: String = switch action.kind {
        case .url: "globe"
        case .bookmark: "star.fill"
        case .history: "clock"
        case .closed: "arrow.uturn.backward.circle"
        case .search: "magnifyingglass"
        case .ask: "sparkles"
        }
        let kindLabel: String = switch action.kind {
        case .url: "Website"
        case .bookmark: "Bookmark"
        case .history: "Visited Site"
        case .closed: "Recently Closed"
        case .search: "Web Search"
        case .ask: "Ask \(browser.agent.backend.shortName)"
        }
        let primaryLabel: String = switch action.kind {
        case .ask: "Ask \(browser.agent.backend.shortName)"
        case .search: "Search Web"
        case .closed: "Reopen Tab"
        default: "Open Website"
        }

        return VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08),
                                lineWidth: 0.75
                            )
                    )
                VStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(action.kind == .bookmark ? Palette.accent : Palette.ink.opacity(0.75))
                        .frame(width: 58, height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Palette.ink.opacity(dark ? 0.08 : 0.05))
                        )
                    Text(kindLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 234)
            .contentShape(Rectangle())
            .onTapGesture { browser.openActionFromSwitcher(action) }

            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(action.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    browser.openActionFromSwitcher(action)
                } label: {
                    HStack(spacing: 5) {
                        Text(primaryLabel)
                            .font(.system(size: 12, weight: .medium))
                        Text("↩")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.72)
                    }
                    .foregroundStyle(dark ? Color.black : Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.ink))
                }
                .buttonStyle(TactilePress())

                if action.kind != .ask {
                    Button {
                        browser.openActionFromSwitcher(action, split: true)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("Split")
                                .font(.system(size: 12, weight: .medium))
                            Text("⌘D")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.muted)
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Palette.ink.opacity(dark ? 0.10 : 0.065))
                        )
                    }
                    .buttonStyle(TactilePress())
                }

                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }

    private func webFallback(dark: Bool, actions: [SwitcherAction], selectedAction: SwitcherAction?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    HStack {
                        Text("Open or Search")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                        Spacer()
                        Text("No open tabs match")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted.opacity(0.75))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                    ForEach(actions) { action in
                        let isSelected = action.id == selectedAction?.id
                        SwitcherActionRow(
                            action: action,
                            selected: isSelected,
                            dark: dark,
                            onHover: { over in
                                if over { state.selectedActionID = action.id }
                            },
                            onSelect: {
                                browser.openActionFromSwitcher(action)
                            }
                        )
                        .id(action.id)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
            .onChange(of: state.keyboardScrollTick) { _, _ in
                if let id = state.selectedActionID {
                    proxy.scrollTo(id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.muted.opacity(0.7))
            Text("No open tabs yet")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.85))
            Text("Type any website or search term above and press Return.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footerBar(dark: Bool, itemsEmpty: Bool, selectedAction: SwitcherAction?) -> some View {
        let onAction = selectedAction != nil
        let actionVerb: String = switch selectedAction?.kind {
        case .ask: "Ask"
        case .search: "Search"
        case .closed: "Reopen"
        default: "Open"
        }
        return HStack(spacing: 14) {
            KeyHint(keys: "↑↓", label: itemsEmpty ? "Select" : "Preview")
            KeyHint(keys: "↩", label: onAction ? actionVerb : "Switch")
            if selectedAction?.kind != .ask {
                KeyHint(keys: "⌘D", label: "Split")
            }
            if !onAction {
                KeyHint(keys: "⌘⌫", label: "Close")
            }
            Spacer(minLength: 0)
            KeyHint(keys: "⇧⌘\\", label: "Overview Grid")
            KeyHint(keys: "⎋", label: "Dismiss")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Palette.ink.opacity(dark ? 0.035 : 0.025))
    }
}

private struct SwitcherActionRow: View {
    let action: SwitcherAction
    let selected: Bool
    let dark: Bool
    var compact: Bool = false
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    private var iconName: String {
        switch action.kind {
        case .url: return "globe"
        case .bookmark: return "star.fill"
        case .history: return "clock"
        case .closed: return "arrow.uturn.backward.circle"
        case .search: return "magnifyingglass"
        case .ask: return "sparkles"
        }
    }

    private var badgeText: String {
        switch action.kind {
        case .url: return "Website"
        case .bookmark: return "Bookmark"
        case .history: return "Visited"
        case .closed: return "Closed"
        case .search: return "Search"
        case .ask: return "Ask"
        }
    }

    private var actionButtonLabel: String {
        switch action.kind {
        case .ask: return "Ask"
        case .search: return "Search"
        case .closed: return "Reopen"
        default: return "Open"
        }
    }

    var body: some View {
        HStack(spacing: compact ? 9 : 11) {
            Image(systemName: iconName)
                .font(.system(size: compact ? 11.5 : 13, weight: .medium))
                .foregroundStyle((action.kind == .bookmark || action.kind == .ask) ? Palette.accent : (selected ? Palette.ink : Palette.muted))
                .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                        .fill(Palette.ink.opacity(selected ? (dark ? 0.14 : 0.08) : (dark ? 0.07 : 0.045)))
                )

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(action.title)
                    .font(.system(size: compact ? 12.5 : 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(action.subtitle)
                    .font(.system(size: compact ? 11 : 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if !compact {
                if selected {
                    HStack(spacing: 4) {
                        Text(actionButtonLabel)
                            .font(.system(size: 11, weight: .medium))
                        Text("↩")
                            .font(.system(size: 10.5, weight: .medium))
                            .opacity(0.75)
                    }
                    .foregroundStyle(dark ? Color.black : Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.ink))
                } else {
                    Text(badgeText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.ink.opacity(dark ? 0.07 : 0.045)))
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(selected ? Palette.ink.opacity(dark ? 0.11 : 0.065) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onSelect)
    }
}

private struct TabPaletteRow: View {
    @ObservedObject var tab: Tab
    let space: Space?
    let selected: Bool
    let active: Bool
    let inSplit: Bool
    let dark: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        let host = tab.address.map { Address.pretty($0) } ?? "New Tab"
        HStack(spacing: 10) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 16)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if active {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 5, height: 5)
                    }
                    if tab.isAgentTab {
                        Text("Agent")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Palette.accent.opacity(0.14)))
                    }
                }
                HStack(spacing: 5) {
                    if let space {
                        SpaceChip(space: space, dark: dark, compact: true)
                    }
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                if tab.noisy || tab.muted {
                    Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                }
                if tab.pin != nil {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
                if inSplit {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                }
                if tab.asleep {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted.opacity(0.75))
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18)
                        .background(Palette.ink.opacity(dark ? 0.11 : 0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
                .opacity(hovering || selected ? 1 : 0)
                .allowsHitTesting(hovering || selected)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.11) : Color.black.opacity(0.07))
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.hover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { over in
            hovering = over
            onHover(over)
        }
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - ⇧⌘\ Visual Tab Overview Grid

private struct TabOverviewGridView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var state: TabSwitcherState
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var resultsCache = SwitcherResultsCache()

    private let previews = TabPreviewCache.shared

    private let columns = [
        GridItem(.adaptive(minimum: 256, maximum: 320), spacing: 18),
    ]

    var body: some View {
        let dark = scheme == .dark
        let snapshot = resultsCache.snapshot(browser: browser, query: state.query, mode: .grid)
        let items = snapshot.items
        let selectedID = items.first { $0.id == state.selectedID }?.id ?? items.first?.id

        ZStack {
            // Full-window frosted glass canvas; click empty space to dismiss.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Palette.ground.opacity(dark ? 0.72 : 0.78)
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.closeTabSwitcher() }

            VStack(spacing: 0) {
                topBar(dark: dark, count: items.count)
                    .padding(.top, 46)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)

                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Palette.muted.opacity(0.65))
                        Text("No open tabs match “\(state.query)”")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.ink.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.closeTabSwitcher() }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(items) { item in
                                    let tab = item.tab
                                    TabOverviewCard(
                                        tab: tab,
                                        space: item.space,
                                        selected: item.id == selectedID,
                                        active: item.space == nil && tab.id == browser.activeID,
                                        inSplit: item.space == nil && browser.split?.has(tab.id) == true,
                                        dark: dark,
                                        onSelect: {
                                            browser.selectFromSwitcher(item)
                                        },
                                        onSplit: {
                                            if item.space != nil {
                                                browser.selectFromSwitcher(item)
                                            } else {
                                                browser.closeTabSwitcher()
                                                if tab.id == browser.activeID {
                                                    browser.select(tab)
                                                } else {
                                                    browser.open(tab, on: .right)
                                                }
                                            }
                                        },
                                        onClose: {
                                            browser.closeTabFromSwitcher(item)
                                        }
                                    )
                                    .id(item.id)
                                    .onAppear {
                                        previews.request(tab, width: 520)
                                    }
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.top, 4)
                            .padding(.bottom, 32)
                        }
                        .onChange(of: state.keyboardScrollTick) { _, _ in
                            if let id = state.selectedID {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            resultsCache.invalidate()
            let current = resultsCache.snapshot(browser: browser, query: state.query, mode: .grid).items
            if state.selectedID == nil || !current.contains(where: { $0.id == state.selectedID }) {
                state.selectedID = browser.activeID ?? current.first?.id
            }
            DispatchQueue.main.async { searchFocused = true }
            // Prime previews for the visible set smoothly.
            for item in current.prefix(12) {
                previews.request(item.tab, width: 520)
            }
        }
        .onChange(of: state.focusTick) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: state.query) { _, _ in
            let current = resultsCache.snapshot(browser: browser, query: state.query, mode: .grid).items
            if let id = state.selectedID, current.contains(where: { $0.id == id }) { return }
            state.selectedID = current.first?.id
        }
    }

    private func topBar(dark: Bool, count: Int) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Text("Open Tabs")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Palette.ink.opacity(dark ? 0.10 : 0.07)))

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    Button {
                        browser.openTabSwitcher(.palette)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                            Text("Quick Switch")
                                .font(.system(size: 12, weight: .medium))
                            Text("⌘K")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.muted)
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Palette.ground.opacity(dark ? 0.72 : 0.90))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08),
                                lineWidth: 0.75
                            )
                        )
                    }
                    .buttonStyle(TactilePress())

                    Button {
                        browser.closeTabSwitcher()
                        browser.newTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Palette.ground.opacity(dark ? 0.72 : 0.90)))
                            .overlay(
                                Circle().strokeBorder(
                                    dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08),
                                    lineWidth: 0.75
                                )
                            )
                    }
                    .buttonStyle(TactilePress())
                    .help("New Tab (⌘T)")

                    Button {
                        browser.closeTabSwitcher()
                    } label: {
                        Text("Done")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(dark ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Palette.ink))
                    }
                    .buttonStyle(TactilePress())
                }
            }

            // Centered floating search pill.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("Filter open tabs…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .focused($searchFocused)
                    .onSubmit { browser.confirmTabSwitcher() }
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 300, height: 34)
            .background(
                Capsule().fill(Palette.ground.opacity(dark ? 0.85 : 0.96))
            )
            .overlay(
                Capsule().strokeBorder(
                    dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09),
                    lineWidth: 0.75
                )
            )
            .shadow(color: .black.opacity(dark ? 0.24 : 0.06), radius: 10, y: 3)
        }
    }
}

private struct TabOverviewCard: View {
    @ObservedObject var tab: Tab
    let space: Space?
    let selected: Bool
    let active: Bool
    let inSplit: Bool
    let dark: Bool
    let onSelect: () -> Void
    let onSplit: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        let host = tab.address.map { Address.pretty($0) } ?? "New Tab"
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(spacing: 0) {
            // Card chrome header.
            HStack(spacing: 7) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                Text(tab.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if active {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5.5, height: 5.5)
                        .help("Current tab")
                }
                if tab.isAgentTab {
                    Text("Agent")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accent.opacity(0.14)))
                }
                Spacer(minLength: 4)
                ZStack(alignment: .trailing) {
                    HStack(spacing: 4) {
                        if space == nil && !active && !tab.isBlank {
                            Button(action: onSplit) {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 20, height: 20)
                                    .background(Palette.ink.opacity(dark ? 0.10 : 0.07), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Open in Split View")
                        }
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 20, height: 20)
                                .background(Palette.ink.opacity(dark ? 0.10 : 0.07), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Close tab")
                    }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)

                    HStack(spacing: 4) {
                        if tab.noisy || tab.muted {
                            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Palette.muted)
                        }
                        if tab.pin != nil {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Palette.muted)
                        }
                        if inSplit {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted)
                        }
                        if tab.asleep {
                            Image(systemName: "moon.zzz")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted.opacity(0.75))
                        }
                    }
                    .opacity(hovering ? 0 : 1)
                    .allowsHitTesting(false)
                }
                .frame(height: 20)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Palette.ground)

            Rectangle()
                .fill(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06))
                .frame(height: 1)

            // 16:10 visual snapshot surface.
            TabPreviewSurface(tab: tab, slot: TabPreviewCache.shared.slot(for: tab), dark: dark)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 10, contentMode: .fit)
                .background(dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025))
                .clipped()

            // Compact bottom domain footer.
            HStack(spacing: 6) {
                Text(host)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let space {
                    SpaceChip(space: space, dark: dark, compact: true)
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Palette.ground)
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                selected ? Palette.accent : (dark ? Color.white.opacity(hovering ? 0.22 : 0.11) : Color.black.opacity(hovering ? 0.18 : 0.085)),
                lineWidth: selected ? 2 : 0.75
            )
        )
        .background {
            shape
                .fill(Palette.ground)
                .shadow(
                    color: .black.opacity(dark ? (hovering || selected ? 0.42 : 0.24) : (hovering || selected ? 0.14 : 0.06)),
                    radius: 12,
                    y: 4
                )
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

/// Isolated thumbnail renderer so async snapshot completions refresh ONLY the
/// owning tab's image slot instead of cascading across the palette or overview grid.
private struct TabPreviewSurface: View {
    @ObservedObject var tab: Tab
    @ObservedObject var slot: TabPreviewCache.Slot
    let dark: Bool

    var body: some View {
        let _ = slot.revision
        let preview = TabPreviewCache.shared.displayImage(for: tab, slot: slot)

        ZStack(alignment: .top) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                TabPlaceholderSurface(tab: tab, dark: dark)
            }
        }
    }
}

// MARK: - Shared Helpers

private struct TabPlaceholderSurface: View {
    @ObservedObject var tab: Tab
    let dark: Bool

    var body: some View {
        VStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 32)
            Text(tab.label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.78))
                .lineLimit(1)
                .padding(.horizontal, 16)
            if let url = tab.address {
                Text(Address.pretty(url))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: dark
                    ? [Color.white.opacity(0.05), Color.white.opacity(0.02)]
                    : [Color.black.opacity(0.03), Color.black.opacity(0.01)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct SpaceChip: View {
    let space: Space
    let dark: Bool
    var compact = false

    var body: some View {
        let tint = Spaces.colours[space.colour % Spaces.colours.count]
        HStack(spacing: 3) {
            Image(systemName: space.symbol)
                .font(.system(size: compact ? 8 : 9, weight: .medium))
            Text(space.name)
                .font(.system(size: compact ? 9.5 : 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1.5 : 2)
        .background(Capsule().fill(tint.opacity(dark ? 0.18 : 0.12)))
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.72))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.ink.opacity(0.07))
                )
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
        }
    }
}
