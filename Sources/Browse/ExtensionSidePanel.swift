import SwiftUI
import WebKit

/// What lives in the docked right-hand side panel beside the active page.
enum SidePanelContent: Equatable {
    case page(extensionID: String, url: URL, tab: Tab.ID?)
}

enum SidePanelAnswer: Equatable {
    case taken
    case noPanel
    case notHere
}

extension Preferences {
    static let sidePanelWidths: ClosedRange<CGFloat> = 300...640
    static let sidePanelStart: CGFloat = 380
}

// MARK: - Browser coordination

extension Browser {
    @available(macOS 15.4, *)
    @discardableResult
    func showSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> SidePanelAnswer {
        if holdsPanel(for: tab, context: context) { return .notHere }
        let content = SidePanelContent.page(extensionID: context.uniqueIdentifier, url: url, tab: tab)
        guard SidePanelPages.shared.load(url, from: context, in: self, for: tab) else { return .noPanel }
        if let tab { SidePanelPages.shared.bind(content, to: tab, in: self) }
        sidePanel = content
        sidePanelShown = true
        return .taken
    }

    @available(macOS 15.4, *)
    @discardableResult
    func toggleSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> SidePanelAnswer {
        if sidePanelShown, case .page(let id, _, _) = sidePanel, id == context.uniqueIdentifier {
            closeSidePanel()
            return .taken
        }
        return showSidePanel(context, url: url, for: tab)
    }

    func sidePanelFailed(_ url: URL) {
        guard case .page(_, let shown, _) = sidePanel, shown == url else { return }
        closeSidePanel()
        guard #available(macOS 15.4, *), (try? Extensions.mayOpen(url)) != nil else { return }
        open(url, foreground: true)
    }

    func closeSidePanel() {
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.drop(in: self)
        sidePanelShown = false
        sidePanel = nil
    }

    func sidePanelFollows(_ tab: Tab) {
        if case .page(_, _, let bound?) = sidePanel, bound != tab.id {
            SidePanelPages.shared.park(bound, in: self)
            sidePanelShown = false
            sidePanel = nil
        }
        sidePanelReturns(to: tab)
    }

    private func sidePanelReturns(to tab: Tab) {
        guard #available(macOS 15.4, *), sidePanel == nil,
              case .page(let id, let url, _)? = SidePanelPages.shared.bound(to: tab.id, in: self),
              let context = Extensions.shared.contexts[id]
        else { return }
        _ = showSidePanel(context, url: url, for: tab.id)
    }

    var sidePanelHeld: Bool {
        guard #available(macOS 15.4, *),
              case .page(let id, _, _) = sidePanel,
              panelPanes().contains(where: { $0.shy })
        else { return false }
        guard let context = Extensions.shared.contexts[id] else { return true }
        return !prefs.extensionsInPrivate
            && !context.hasAccessToPrivateData
    }

    @available(macOS 15.4, *)
    private func holdsPanel(for tab: Tab.ID?, context: WKWebExtensionContext) -> Bool {
        let shy = panelPanes(tab).contains(where: { $0.shy })
        guard shy else { return false }
        return !prefs.extensionsInPrivate && !context.hasAccessToPrivateData
    }

    private func panelPanes(_ tab: Tab.ID? = nil) -> [Tab] {
        guard let here = tabs.first(where: { $0.id == (tab ?? activeID) }) else { return [] }
        guard let split, split.has(here.id) else { return [here] }
        let otherID = split.left == here.id ? split.right : split.left
        if let other = tabs.first(where: { $0.id == otherID }) {
            return [here, other]
        }
        return [here]
    }
}

// MARK: - Live WKWebView storage

@MainActor
final class SidePanelPages: NSObject {
    static let shared = SidePanelPages()

    private final class Page {
        let web: WKWebView
        let delegate: NSObject
        let owner: String
        let first: URL
        init(web: WKWebView, delegate: NSObject, owner: String, first: URL) {
            self.web = web
            self.delegate = delegate
            self.owner = owner
            self.first = first
        }
    }

    private var pages: [ObjectIdentifier: Page] = [:]
    private var bound: [ObjectIdentifier: [Tab.ID: SidePanelContent]] = [:]
    private var parked: [ObjectIdentifier: [(tab: Tab.ID, page: Page)]] = [:]
    static let keeps = 4

    func web(in browser: Browser) -> WKWebView? {
        pages[ObjectIdentifier(browser)]?.web
    }

    func activeURL(for extensionID: String) -> URL? {
        pages.values.first(where: { $0.owner == extensionID })?.web.url
    }

    @available(macOS 15.4, *)
    func load(_ url: URL, from context: WKWebExtensionContext, in browser: Browser, for tab: Tab.ID? = nil) -> Bool {
        let key = ObjectIdentifier(browser)
        if let current = pages[key], current.owner == context.uniqueIdentifier, current.web.url == url {
            return true
        }
        if let tab, let index = parked[key]?.firstIndex(where: { $0.tab == tab }) {
            let kept = parked[key]!.remove(at: index).page
            if kept.owner == context.uniqueIdentifier, kept.first == url {
                drop(in: browser)
                pages[key] = kept
                return true
            }
            close(kept)
        }
        drop(in: browser)
        guard let configuration = context.webViewConfiguration else { return false }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: configuration)
        let delegate = PanelDelegate(browser: browser, base: context.baseURL, first: url)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsMagnification = true
        web.isInspectable = true
        Self.holdForFirstFrame(web)
        web.load(URLRequest(url: url))
        pages[key] = Page(web: web, delegate: delegate, owner: context.uniqueIdentifier, first: url)
        return true
    }

    func park(_ tab: Tab.ID, in browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard let page = pages.removeValue(forKey: key) else { return }
        page.web.removeFromSuperview()
        var kept = (parked[key] ?? []).filter { old in
            guard old.tab == tab else { return true }
            close(old.page)
            return false
        }
        kept.append((tab, page))
        while kept.count > Self.keeps { close(kept.removeFirst().page) }
        parked[key] = kept
    }

    func drop(in browser: Browser) {
        guard let page = pages.removeValue(forKey: ObjectIdentifier(browser)) else { return }
        close(page)
    }

    func bind(_ content: SidePanelContent, to tab: Tab.ID, in browser: Browser) {
        bound[ObjectIdentifier(browser), default: [:]][tab] = content
    }

    func unbind(_ tab: Tab.ID, in browser: Browser) {
        let key = ObjectIdentifier(browser)
        bound[key]?[tab] = nil
        parked[key] = parked[key]?.filter { kept in
            guard kept.tab == tab else { return true }
            close(kept.page)
            return false
        }
    }

    func bound(to tab: Tab.ID, in browser: Browser) -> SidePanelContent? {
        bound[ObjectIdentifier(browser)]?[tab]
    }

    func forget(_ id: String) {
        guard #available(macOS 15.4, *), let browser = Extensions.shared.browser else { return }
        if case .page(let shown, _, _) = browser.sidePanel, shown == id {
            browser.closeSidePanel()
        }
        let key = ObjectIdentifier(browser)
        bound[key] = bound[key]?.filter {
            if case .page(let owner, _, _) = $0.value { return owner != id }
            return true
        }
        parked[key] = parked[key]?.filter { kept in
            guard kept.page.owner == id else { return true }
            close(kept.page)
            return false
        }
    }

    private func close(_ page: Page) {
        page.web.stopLoading()
        page.web.navigationDelegate = nil
        page.web.uiDelegate = nil
        page.web.removeFromSuperview()
    }

    static func holdForFirstFrame(_ web: WKWebView) {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard web.responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(web.method(for: observe), to: Setter.self)(web, observe, PageView.firstFrame)
        web.alphaValue = 0
    }

    static func showFirstFrame(_ web: WKWebView) {
        guard web.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            web.animator().alphaValue = 1
        }
    }
}

@MainActor
private final class PanelDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var browser: Browser?
    let base: URL
    let first: URL
    private var loaded = false

    init(browser: Browser, base: URL, first: URL) {
        self.browser = browser
        self.base = base
        self.first = first
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        SidePanelPages.showFirstFrame(webView)
    }

    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        if events & PageView.firstFrame != 0 { SidePanelPages.showFirstFrame(webView) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fellThrough(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fellThrough(error)
    }

    private func fellThrough(_ error: Error) {
        guard !loaded, (error as NSError).code != NSURLErrorCancelled,
              (error as NSError).code != 102
        else { return }
        loaded = true
        let url = first
        DispatchQueue.main.async { [weak browser] in browser?.sidePanelFailed(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if loaded { webView.reload() } else { fellThrough(NSError(domain: "browse", code: 1)) }
    }

    private func own(_ url: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
    }

    private func openInTab(_ url: URL?) {
        guard #available(macOS 15.4, *), let url, (try? Extensions.mayOpen(url)) != nil, let browser else { return }
        browser.open(url, foreground: true)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openInTab(navigationAction.request.url)
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let browser else { return decisionHandler(.deny) }
        browser.webView(webView, requestMediaCapturePermissionFor: origin, initiatedByFrame: frame, type: type, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            return decisionHandler(.allow)
        }
        if own(url) { return decisionHandler(.allow) }
        if url.scheme?.lowercased() == "about",
           let from = navigationAction.sourceFrame.request.url, own(from) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if [.linkActivated, .formSubmitted].contains(navigationAction.navigationType) {
            openInTab(url)
        }
    }
}

// MARK: - SwiftUI Views

struct SidePanelView: View {
    @ObservedObject var browser: Browser

    var body: some View {
        switch browser.sidePanel {
        case .page(let id, _, _):
            VStack(spacing: 0) {
                header(id)
                Rectangle().fill(Palette.hairline).frame(height: 0.75)
                PanelPage(web: SidePanelPages.shared.web(in: browser))
            }
        case nil:
            Color.clear
        }
    }

    @ViewBuilder
    private func header(_ id: String) -> some View {
        HStack(spacing: 8) {
            if #available(macOS 15.4, *),
               let icon = Extensions.shared.contexts[id]?.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
            }
            Text(displayName(id))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Door(icon: "xmark", help: "Close side panel") { browser.closeSidePanel() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func displayName(_ id: String) -> String {
        if #available(macOS 15.4, *), let name = Extensions.shared.contexts[id]?.webExtension.displayName, !name.isEmpty {
            return name
        }
        return id
    }
}

private struct PanelPage: NSViewRepresentable {
    let web: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        place(in: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        place(in: holder)
    }

    private func place(in holder: NSView) {
        guard let web else {
            holder.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard web.superview !== holder else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.frame = holder.bounds
        web.autoresizingMask = [.width, .height]
        holder.addSubview(web)
    }
}

struct SidePanelBeside: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let card: Bool
    let width: CGFloat
    var darkCanvas: Bool = false

    @State private var start: CGFloat?
    @State private var live: CGFloat?
    @State private var over = false
    @State private var cursorPushed = false

    var body: some View {
        let shownWidth = live ?? width
        HStack(spacing: 0) {
            handle
                .frame(width: card ? Split.gap : 5)
            SidePanelView(browser: browser)
                .frame(width: shownWidth)
                .background(Palette.ground)
                .clipShape(RoundedRectangle(cornerRadius: card ? Split.corner : 0, style: .continuous))
                .overlay {
                    if card {
                        RoundedRectangle(cornerRadius: Split.corner, style: .continuous)
                            .strokeBorder(darkCanvas ? Color.white.opacity(0.095) : Color.black.opacity(0.075), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.trailing, card ? Split.gap : 0)
        .padding(.vertical, card ? Split.gap : 0)
    }

    private var handle: some View {
        ZStack {
            if !card {
                Rectangle().fill(Palette.hairline).frame(width: 0.75)
            }
            Capsule()
                .fill(Palette.ink.opacity(over || start != nil ? 0.35 : 0))
                .frame(width: 3, height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            over = inside
            setResizeCursor(inside)
        }
        .onDisappear {
            setResizeCursor(false)
            if live != nil {
                live = nil
                start = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let from = start ?? prefs.sidePanelWidth
                    if start == nil { start = from }
                    let wanted = from - drag.translation.width
                    let bounds = Preferences.sidePanelWidths
                    live = min(max(wanted, bounds.lowerBound), bounds.upperBound)
                }
                .onEnded { _ in
                    if let live { prefs.sidePanelWidth = live }
                    live = nil
                    start = nil
                }
        )
        .onTapGesture(count: 2) {
            prefs.sidePanelWidth = Preferences.sidePanelStart
        }
    }

    private func setResizeCursor(_ active: Bool) {
        guard active != cursorPushed else { return }
        cursorPushed = active
        if active {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }
}
