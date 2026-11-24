import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions — but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate, WKScriptMessageHandler {
    static let shared = ExtensionPopup()
    private static let handlerName = "searchPopupSize"

    private var popover: NSPopover?
    private var web: WKWebView?
    private weak var messageController: WKUserContentController?
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window — Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private(set) var extensionID: String?
    /// The extension's own button, when the popup hangs from it.
    private weak var button: NSView?
    /// The popup a click on its own button just closed: the popover can go
    /// on mouse-down or mouse-up, before the button's press arrives — which
    /// would open it again.
    private var closedByButton: (id: String, at: Date)?

    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    /// On screen now.
    var isUp: Bool { popover?.isShown == true }

    /// The popup as its extension's worker finds it in clients.matchAll().
    func client(of id: String) -> [String: Any]? {
        guard extensionID == id, let url = web?.url else { return nil }
        return ["id": "popup", "url": url.absoluteString, "visible": isUp, "focused": isUp && web?.window?.isKeyWindow == true]
    }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        // Sized the way Chrome sizes a popup (see preferred), unseen, while
        // the popover already stands at the size this popup had last time;
        // then shown. It has to be in the window meanwhile: WebKit suspends
        // a page that is in none.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        configuration.userContentController.add(self, contentWorld: Self.world, name: Self.handlerName)
        messageController = configuration.userContentController
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over the popover's dark
        // material would vanish.
        web.alphaValue = 0
        web.load(URLRequest(url: url))

        let stage = NSView(frame: NSRect(origin: .zero, size: ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)))
        stage.addSubview(web)
        let host = NSViewController()
        host.view = stage
        // The popover takes its size from its view controller: left at zero,
        // it comes in as a sliver and grows to the size it was given,
        // instead of standing at that size from the start.
        host.preferredContentSize = stage.frame.size
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        button = anchor != nil && anchor === Extensions.shared.anchors[context.uniqueIdentifier]?.view ? anchor : nil
        let page = PopupPage(web: web)
        self.page = page
        Extensions.shared.controller.didOpenTab(page)

        shown = false
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            // No button to hang from — the column or the strip folded away:
            // where the buttons would be, the column's foot or the strip's
            // far end. The window's content is SwiftUI's, a flipped view,
            // whose top is at minY: measured from maxY, "the top right" was
            // the bottom right, across the window from the column's buttons.
            let bounds = content.bounds, flipped = content.isFlipped
            let column = Extensions.shared.browser?.prefs.sidebar == true
            let spot = column
                ? NSRect(x: bounds.minX + 24, y: flipped ? bounds.maxY - 24 : bounds.minY + 24, width: 1, height: 1)
                : NSRect(x: bounds.maxX - 60, y: flipped ? bounds.minY + 40 : bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: column ? .maxX : (flipped ? .maxY : .minY))
        }
        // Sized once loaded — or after a moment regardless, for a page that
        // never finishes loading.
        // Measured when the document is built (see below) or has loaded;
        // a page slow to do either is measured anyway after a moment, and
        // shown regardless a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.measure()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.measure(force: true)
            self.reveal()
        }
    }

    private static var cachedSizes: [String: NSSize]?

    /// Each extension's popup size, cached in memory and persisted across
    /// launches within valid bounds (25×25 to 800×600).
    static var lastSize: [String: NSSize] {
        get {
            if let cachedSizes { return cachedSizes }
            let kept = Store.settings.dictionary(forKey: "extensionPopupSizes") as? [String: [Double]] ?? [:]
            let loaded = kept.compactMapValues { $0.count == 2 ? bounded(NSSize(width: $0[0], height: $0[1])) : nil }
            cachedSizes = loaded
            return loaded
        }
        set {
            cachedSizes = newValue
            Store.settings.set(newValue.mapValues { [Double($0.width), Double($0.height)] }, forKey: "extensionPopupSizes")
        }
    }
    private var shown = false

    /// Clamps a finite size within `[25...800, 25...600]`, returning `nil` for NaN/infinity.
    static func bounded(_ size: NSSize) -> NSSize? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        return NSSize(
            width: min(800, max(25, size.width.rounded(.up))),
            height: min(600, max(25, size.height.rounded(.up)))
        )
    }

    /// Removes stored popup dimensions when an extension is uninstalled.
    static func forget(_ id: String) {
        var sizes = lastSize
        guard sizes.removeValue(forKey: id) != nil else { return }
        lastSize = sizes
    }

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popover?.contentViewController?.view else { return }
        shown = true
        web.frame = NSRect(origin: .zero, size: popover?.contentSize ?? stage.bounds.size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    func close() {
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        messageController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        messageController = nil
        if let page { Extensions.shared.controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
    }

    /// A press on the button of an extension whose popup is up closes it,
    /// as in Chrome — whether the popover is still there (a click on the
    /// view it hangs from doesn't close it) or went on this click's
    /// mouse-down or mouse-up. Closed, it is not opened again.
    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if popover != nil, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }

    /// Chrome auto-size (25×25 to 800×600), measuring explicit widths/heights,
    /// min-content narrowest width, and overflowing elements hanging beneath `body`.
    static let preferred = """
    () => {
      const d = document.documentElement;
      if (!d) return null;
      const v = document.compatMode === 'BackCompat' && document.body ? document.body : d;
      const m = window.__searchSizing || (window.__searchSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      const gutter = Math.max(0, innerWidth - v.clientWidth);
      let w;
      if (Math.abs(box.width - innerWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - innerWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      const below = (root) => {
        let bottom = 0, n = 0;
        const walk = (el) => {
          for (const c of el.children) {
            if (++n > 3000) return;
            const s = getComputedStyle(c);
            if (s.display === "none") continue;
            const r = c.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) bottom = Math.max(bottom, r.bottom);
            if (s.overflowY === "visible" && s.overflowX === "visible") walk(c);
          }
        };
        walk(root);
        return bottom + scrollY;
      };
      w = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
      d.style.setProperty("width", Math.max(1, w - gutter) + "px", "important");
      let h = d.getBoundingClientRect().height;
      d.style.setProperty("height", "auto", "important");
      d.style.setProperty("min-height", "0", "important");
      const content = d.getBoundingClientRect().height;
      if (Math.abs(h - content) <= 1) { m.h = 0; h = content; }
      else if (Math.abs(h - innerHeight) > 1) m.h = h;
      else h = m.h && Math.abs(m.h - innerHeight) <= 1 ? m.h : content;
      if (document.body && v === d) h = Math.max(h, below(document.body));
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h)))];
    }
    """

    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        measure()
    }

    private static let world = WKContentWorld.world(name: "search-popup-size")

    private static func watch(force: Bool) -> String {
        """
        (() => {
          const d = document.documentElement;
          if (!d) return null;
          const w = window.__searchWatch || (window.__searchWatch = { raf: 0, posted: null });
          const measure = \(preferred);
          const push = (forceSend) => {
            const size = measure();
            if (!size) return null;
            if (!forceSend && w.posted && Math.abs(size[0] - w.posted[0]) <= 1 && Math.abs(size[1] - w.posted[1]) <= 1) {
              return null;
            }
            w.posted = size;
            return size;
          };
          const notify = () => {
            if (w.raf) return;
            w.raf = requestAnimationFrame(() => {
              w.raf = 0;
              const size = push(false);
              if (!size) return;
              try {
                const mh = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(handlerName);
                if (mh) mh.postMessage(size);
              } catch (e) {}
            });
          };
          if (!w.ro) {
            try {
              w.ro = new ResizeObserver(notify);
              w.ro.observe(d);
              if (document.body) { w.body = document.body; w.ro.observe(document.body); }
            } catch (e) {}
            addEventListener("load", notify, true);
            addEventListener("transitionend", notify, true);
            try { document.fonts.addEventListener("loadingdone", notify); } catch (e) {}
          }
          if (w.ro && document.body && w.body !== document.body) {
            w.body = document.body;
            try { w.ro.observe(document.body); } catch (e) {}
          }
          return push(\(force));
        })()
        """
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web,
              let pair = message.body as? [Double], pair.count == 2
        else { return }
        handleMeasuredSize(NSSize(width: pair[0], height: pair[1]), force: false)
    }

    /// Measures while hidden (delaying reveal until content renders) and while open.
    private func measure(force: Bool = false) {
        guard let web else { return }
        web.evaluateJavaScript(Self.watch(force: force), in: nil, in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, web === self.web,
                      case .success(let value) = result, let pair = value as? [Double], pair.count == 2
                else { return }
                self.handleMeasuredSize(NSSize(width: pair[0], height: pair[1]), force: force)
            }
        }
    }

    private func handleMeasuredSize(_ wanted: NSSize, force: Bool) {
        guard let popover else { return }
        if !shown, !force, max(wanted.width, wanted.height) <= 25 { return }
        let now = popover.contentSize
        if !shown || abs(wanted.width - now.width) > 1 || abs(wanted.height - now.height) > 1 {
            apply(wanted)
        }
    }

    private func apply(_ measured: NSSize) {
        guard let popover, let size = ExtensionPopup.bounded(measured) else { return }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID, ExtensionPopup.lastSize[id] != size {
            ExtensionPopup.lastSize[id] = size
        }
        reveal()
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        measure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
            guard let self, let webView, webView === self.web, !self.shown else { return }
            self.measure(force: true)
        }
    }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The same rule as tabs.create: never a file on this Mac, never javascript:.
        if let url = action.request.url, (try? Extensions.mayOpen(url)) != nil {
            Extensions.shared.browser?.open(url, foreground: true)
        }
        close()
        return nil
    }

    /// The click being handled, not the live mouse state: AppKit can close
    /// the popover on mouse-up, when no button is pressed any more. The
    /// event also keeps its location if the pointer has since moved.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, let event = NSApp.currentEvent,
              event.window === window, event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        let spot = button.convert(event.locationInWindow, from: nil)
        if button.bounds.contains(spot) { closedByButton = (id, Date()) }
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        forget()
    }
}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs — which is where Chrome puts a popup too.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?

    init(web: WKWebView) { self.web = web }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

