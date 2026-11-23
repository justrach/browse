import SwiftUI
import AppKit

/// Lightweight in-memory snapshot cache for open tabs, shared between the
/// `⌘K` Command Switcher sneak-peek pane and the `⇧⌘\` Visual Tab Overview grid.
/// Captures on demand via `Tab.capturePreview` so idle browsing uses zero extra RAM.
@MainActor
final class TabPreviewCache: ObservableObject {
    static let shared = TabPreviewCache()

    private final class Entry: NSObject {
        let url: URL?
        let image: NSImage
        let capturedAt: Date
        init(url: URL?, image: NSImage, capturedAt: Date) {
            self.url = url
            self.image = image
            self.capturedAt = capturedAt
        }
    }

    private let cache: NSCache<NSUUID, Entry> = {
        let c = NSCache<NSUUID, Entry>()
        c.countLimit = 48
        return c
    }()
    private var inFlight: Set<Tab.ID> = []
    /// Bumped when a newly captured snapshot lands so observing preview cards refresh.
    @Published private(set) var revision = 0

    func image(for tab: Tab) -> NSImage? {
        if let entry = cache.object(forKey: tab.id as NSUUID), entry.url == tab.address {
            return entry.image
        }
        return tab.cover
    }

    func request(_ tab: Tab, width: CGFloat = 560) {
        guard !tab.isBlank else { return }
        if let entry = cache.object(forKey: tab.id as NSUUID),
           entry.url == tab.address,
           Date().timeIntervalSince(entry.capturedAt) < 120 {
            return
        }
        capture(tab, width: width)
    }

    func refresh(_ tab: Tab, width: CGFloat = 640) {
        guard !tab.isBlank else { return }
        capture(tab, width: width)
    }

    private func capture(_ tab: Tab, width: CGFloat) {
        guard !inFlight.contains(tab.id) else { return }
        inFlight.insert(tab.id)
        let tabID = tab.id
        let url = tab.address
        tab.capturePreview(width: width) { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(tabID)
                guard let image else { return }
                self.cache.setObject(Entry(url: url, image: image, capturedAt: Date()), forKey: tabID as NSUUID)
                self.revision &+= 1
            }
        }
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
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
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
    @ObservedObject private var previews = TabPreviewCache.shared
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var items: [SwitcherItem] {
        browser.switcherItems(matching: state.query, mode: .palette)
    }

    private var fallbackActions: [SwitcherAction] {
        browser.switcherFallbackActions(
            for: state.query,
            excluding: items,
            limit: items.isEmpty ? 7 : 4
        )
    }

    private var selectedAction: SwitcherAction? {
        if let actionID = state.selectedActionID,
           let match = fallbackActions.first(where: { $0.id == actionID }) {
            return match
        }
        return items.isEmpty ? fallbackActions.first : nil
    }

    private var selectedItem: SwitcherItem? {
        guard selectedAction == nil else { return nil }
        return items.first { $0.id == state.selectedID } ?? items.first
    }

    private var selectedTab: Tab? { selectedItem?.tab }

    var body: some View {
        let dark = scheme == .dark
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        ZStack {
            // Subtle dim scrim — tap anywhere outside the palette to dismiss.
            Color.black.opacity(dark ? 0.42 : 0.18)
                .contentShape(Rectangle())
                .onTapGesture { browser.closeTabSwitcher() }

            VStack(spacing: 0) {
                searchHeader(dark: dark)
                Divider().overlay(Palette.hairline)

                if items.isEmpty {
                    if !fallbackActions.isEmpty {
                        webFallback(dark: dark)
                    } else {
                        emptyState
                    }
                } else {
                    HStack(spacing: 0) {
                        tabList(dark: dark)
                            .frame(width: 336)
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(width: 1)
                        sneakPeek(dark: dark)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                }

                Divider().overlay(Palette.hairline)
                footerBar(dark: dark)
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
            syncSelection()
            DispatchQueue.main.async { searchFocused = true }
            if let tab = selectedTab { previews.request(tab, width: 640) }
        }
        .onChange(of: state.focusTick) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: state.query) { _, _ in
            syncSelection()
        }
        .onChange(of: state.selectedID) { _, _ in
            if let tab = selectedTab { previews.request(tab, width: 640) }
        }
    }

    private func syncSelection() {
        let list = items
        let actions = fallbackActions
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

    private func searchHeader(dark: Bool) -> some View {
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

            Text("\(items.count) open")
                .font(.system(size: 11, weight: .medium))
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

    private func tabList(dark: Bool) -> some View {
        let actions = fallbackActions
        return ScrollViewReader { proxy in
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
                        HStack {
                            Text("Sites & Web")
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
            .onChange(of: state.selectedID) { _, id in
                guard let id else { return }
                withAnimation(Motion.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: state.selectedActionID) { _, id in
                guard let id else { return }
                withAnimation(Motion.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func sneakPeek(dark: Bool) -> some View {
        if let item = selectedItem {
            let tab = item.tab
            let _ = previews.revision
            let preview = previews.image(for: tab)
            let isActive = item.space == nil && tab.id == browser.activeID
            let prettyURL = tab.address.map { Address.pretty($0) } ?? "New Tab"

            VStack(alignment: .leading, spacing: 12) {
                // Visual 16:10 sneak-peek browser card (bounded height so header
                // and footer never overflow the 472pt palette).
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
                .id(tab.id)

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
                            Text(isActive ? "Focus Tab" : "Switch to Tab")
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
        case .search: "magnifyingglass"
        case .ask: "sparkles"
        }
        let kindLabel: String = switch action.kind {
        case .url: "Website"
        case .bookmark: "Bookmark"
        case .history: "Visited Site"
        case .search: "Web Search"
        case .ask: "Ask \(browser.agent.backend.shortName)"
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
                        Text(action.kind == .search ? "Search Web" : "Open Website")
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

                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }

    private func webFallback(dark: Bool) -> some View {
        let actions = fallbackActions
        return ScrollViewReader { proxy in
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
            .onChange(of: state.selectedActionID) { _, id in
                guard let id else { return }
                withAnimation(Motion.quick) {
                    proxy.scrollTo(id, anchor: .center)
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

    private func footerBar(dark: Bool) -> some View {
        let onAction = selectedAction != nil
        return HStack(spacing: 14) {
            KeyHint(keys: "↑↓", label: items.isEmpty ? "Select" : "Preview")
            KeyHint(keys: "↩", label: onAction ? (selectedAction?.kind == .search ? "Search" : "Open") : "Switch")
            KeyHint(keys: "⌘D", label: "Split")
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
        case .search: return "magnifyingglass"
        case .ask: return "sparkles"
        }
    }

    private var badgeText: String {
        switch action.kind {
        case .url: return "Website"
        case .bookmark: return "Bookmark"
        case .history: return "Visited"
        case .search: return "Search"
        case .ask: return "Ask"
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
                        Text(action.kind == .search ? "Search" : "Open")
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
                if hovering || selected {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 18, height: 18)
                            .background(Palette.ink.opacity(dark ? 0.11 : 0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
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
    @ObservedObject private var previews = TabPreviewCache.shared
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var items: [SwitcherItem] {
        browser.switcherItems(matching: state.query, mode: .grid)
    }

    private var selectedItem: SwitcherItem? {
        items.first { $0.id == state.selectedID } ?? items.first
    }

    private let columns = [
        GridItem(.adaptive(minimum: 256, maximum: 320), spacing: 18),
    ]

    var body: some View {
        let dark = scheme == .dark

        ZStack {
            // Full-window frosted glass canvas; click empty space to dismiss.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Palette.ground.opacity(dark ? 0.72 : 0.78)
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.closeTabSwitcher() }

            VStack(spacing: 0) {
                topBar(dark: dark)
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
                                        selected: item.id == selectedItem?.id,
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
                        .onChange(of: state.selectedID) { _, id in
                            guard let id else { return }
                            withAnimation(Motion.quick) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if state.selectedID == nil || !items.contains(where: { $0.id == state.selectedID }) {
                state.selectedID = browser.activeID ?? items.first?.id
            }
            DispatchQueue.main.async { searchFocused = true }
            // Prime previews for the visible set smoothly.
            for item in items.prefix(12) {
                previews.request(item.tab, width: 520)
            }
        }
        .onChange(of: state.focusTick) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: state.query) { _, _ in
            if let current = state.selectedID, items.contains(where: { $0.id == current }) { return }
            state.selectedID = items.first?.id
        }
    }

    private func topBar(dark: Bool) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Text("Open Tabs")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("\(items.count)")
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
    @ObservedObject private var previews = TabPreviewCache.shared
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
        let _ = previews.revision
        let preview = previews.image(for: tab)
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
                if hovering {
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
                    .transition(.opacity)
                } else {
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
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Palette.ground)

            Rectangle()
                .fill(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06))
                .frame(height: 1)

            // 16:10 visual snapshot surface.
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
        .shadow(
            color: .black.opacity(dark ? (hovering || selected ? 0.42 : 0.24) : (hovering || selected ? 0.14 : 0.06)),
            radius: hovering || selected ? 16 : 8,
            y: hovering || selected ? 6 : 2
        )
        .scaleEffect(!Motion.reduced && hovering ? 1.014 : 1.0)
        .animation(Motion.snappy, value: hovering)
        .animation(Motion.quick, value: selected)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
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
