import AppKit
import WebKit

// Opt-in in-window video full screen: Settings › General › Full-screen video
// fills this window. Off by default.
//
// WebKit's native element full screen opens a separate `WKFullScreenWindowController`
// in its own macOS Space, leaving the browser window behind. When enabled, this
// intercepts `requestFullscreen` / `webkitRequestFullscreen` / `webkitEnterFullscreen`
// in the page world, expands the element over the viewport with `#000` behind it,
// hides browser chrome (`Tab.immersed = true`), and toggles macOS full screen on
// the existing window when not already full screen — returning cleanly on Esc,
// tab switch, or page exit without leaving a dangling WebKit Space.

@MainActor
final class WindowFullScreen {
    static let shared = WindowFullScreen()

    /// Driven by `Preferences.fullScreenInWindow` so new tabs arm the script only
    /// when the setting is turned on.
    static var on = false

    nonisolated static let ask = "__browseFillsWindow"
    nonisolated static let leave = "__browseLeavesWindow"
    nonisolated static let off = "__browseFillsWindowOff"

    private struct Entry {
        weak var tab: Tab?
        weak var window: NSWindow?
        var took: Bool
    }

    private var filling: [ObjectIdentifier: Entry] = [:]
    private var leaveOnArrival: Set<ObjectIdentifier> = []
    private var watchers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        watchers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.arrived(window) }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.windowLeaving(window) }
            },
        ]
    }

    func fills(_ web: WKWebView?) -> Bool {
        guard let web else { return false }
        return filling[ObjectIdentifier(web)] != nil
    }

    func setting(_ enabled: Bool, for tabs: [Tab]) {
        WindowFullScreen.on = enabled
        for tab in tabs {
            guard let web = tab.built else { continue }
            if enabled {
                web.evaluateInSearch(Self.bridge)
                web.evaluateJavaScript(Self.page, in: nil, in: .page) { _ in }
            } else {
                end(web)
                web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(Self.off)')); void 0", in: nil, in: .page) { _ in }
            }
        }
    }

    func page(_ tab: Tab, fills on: Bool) {
        guard let web = tab.built else { return }
        let key = ObjectIdentifier(web)
        if !on {
            finish(key)
            return
        }
        guard filling[key] == nil, let window = web.window else { return }
        let alreadyFull = window.styleMask.contains(.fullScreen)
        let took = !alreadyFull
        filling[key] = Entry(tab: tab, window: window, took: took)
        if !tab.immersed { tab.immersed = true }
        if took {
            window.toggleFullScreen(nil)
        } else if let host = web.url?.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") {
            refreshPlayerLayout(web)
        }
    }

    private func refreshPlayerLayout(_ web: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak web] in
            guard let web, self.fills(web), web.frame.height > 1 else { return }
            let size = web.frame.size
            let reduced = NSSize(width: size.width, height: size.height - 1)
            web.setFrameSize(reduced)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak web] in
                guard let web, web.frame.size == reduced else { return }
                web.setFrameSize(size)
            }
        }
    }

    func end(_ web: WKWebView) {
        let key = ObjectIdentifier(web)
        guard filling[key] != nil else { return }
        Self.endPage(web)
        finish(key)
    }

    private func finish(_ key: ObjectIdentifier) {
        guard let entry = filling.removeValue(forKey: key) else { return }
        if let tab = entry.tab, tab.immersed { tab.immersed = false }
        guard entry.took, let window = entry.window else { return }
        guard !filling.values.contains(where: { $0.window === window }) else { return }
        if window.styleMask.contains(.fullScreen), !leaveOnArrival.contains(ObjectIdentifier(window)) {
            window.toggleFullScreen(nil)
        } else {
            leaveOnArrival.insert(ObjectIdentifier(window))
        }
    }

    private func arrived(_ window: NSWindow) {
        guard leaveOnArrival.remove(ObjectIdentifier(window)) != nil else { return }
        window.toggleFullScreen(nil)
    }

    private func windowLeaving(_ window: NSWindow) {
        leaveOnArrival.remove(ObjectIdentifier(window))
        for (key, entry) in filling where entry.window === window {
            filling[key]?.took = false
            if let web = entry.tab?.built { Self.endPage(web) }
            finish(key)
        }
    }

    static func endPage(_ web: WKWebView) {
        web.evaluateInSearch("""
            if (document.fullscreenElement) document.exitFullscreen();
            window.dispatchEvent(new CustomEvent('\(leave)'));
            void 0
            """)
        web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(leave)')); void 0", in: nil, in: .page) { _ in }
    }

    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(FormRelay.name);
      if (!handler || window.__browseFillsBridge) return;
      window.__browseFillsBridge = true;
      window.addEventListener('\(ask)', function (event) {
        var on = event.detail === 'on';
        if (on && navigator.userActivation && !navigator.userActivation.isActive) return;
        handler.postMessage({ kind: 'fillsWindow', on: on });
      });
    })();
    """

    nonisolated static let page = """
    (function () {
      if (window.__browseFills) return;
      Object.defineProperty(window, '__browseFills', { value: true, configurable: true });
      var ASK = '\(ask)', LEAVE = '\(leave)', OFF = '\(off)', NOTE = '__browseFullScreen';
      var FILLS = 'data-browse-fullscreen', ABOVE = 'data-browse-fullscreen-ancestor',
          ROOT = 'data-browse-fullscreen-document';
      var isTop = window === window.top;
      var EP = Element.prototype, DP = Document.prototype;
      var current = null, lifted = [], kept = new Map(), sheet = null, timer = null, undo = [];

      var mine = {
        position: 'fixed', inset: '0', margin: '0', 'box-sizing': 'border-box',
        'min-width': '0', 'max-width': 'none', 'min-height': '0', 'max-height': 'none',
        width: '100%', height: '100%', transform: 'none', 'object-fit': 'contain',
        'z-index': '2147483647', visibility: 'visible'
      };
      var framed = { border: '0', padding: '0' };
      var ancestor = {
        'z-index': 'auto', position: 'static', opacity: '1', transform: 'none', mask: 'none',
        clip: 'none', filter: 'none', transition: 'none', overflow: 'visible', contain: 'none',
        'will-change': 'auto', 'clip-path': 'none', 'backdrop-filter': 'none', visibility: 'visible'
      };

      function set(el, styles) {
        var before = kept.get(el) || { '': el.hasAttribute('style') };
        for (var name in styles) {
          if (!(name in before)) {
            before[name] = [el.style.getPropertyValue(name), el.style.getPropertyPriority(name)];
          }
          el.style.setProperty(name, styles[name], 'important');
        }
        kept.set(el, before);
      }

      function restore() {
        kept.forEach(function (before, el) {
          for (var name in before) {
            if (!name) continue;
            if (before[name][0]) el.style.setProperty(name, before[name][0], before[name][1]);
            else el.style.removeProperty(name);
          }
          if (!before[''] && !el.getAttribute('style')) el.removeAttribute('style');
          el.removeAttribute(FILLS);
          el.removeAttribute(ABOVE);
        });
        kept.clear();
        lifted = [];
        if (document.documentElement) document.documentElement.removeAttribute(ROOT);
      }

      function applySheet() {
        if (sheet && sheet.isConnected) return;
        sheet = document.createElement('style');
        sheet.textContent =
          'html[' + ROOT + '] { background: #000 !important; overflow: hidden !important; }' +
          'html[' + ROOT + '] body *:not([' + FILLS + ']):not([' + ABOVE + ']):not([' + FILLS + '] *)' +
          ' { visibility: hidden !important; }' +
          'video[' + FILLS + '] { background-color: #000 !important; }';
        if (location.hostname === 'youtube.com' || location.hostname.endsWith('.youtube.com')) {
          sheet.textContent += 'html[' + ROOT + '] #movie_player.ytp-fullscreen .ytp-chrome-bottom' +
            '[style*="width: 100px;"][style*="left: 12px;"] { width: auto !important; right: 12px !important; }';
        }
        (document.head || document.documentElement).appendChild(sheet);
      }

      function up(el) {
        if (el.parentElement) return el.parentElement;
        var root = el.getRootNode && el.getRootNode();
        return root && root.host ? root.host : null;
      }

      function lift(el) {
        applySheet();
        if (document.documentElement) document.documentElement.setAttribute(ROOT, '');
        el.setAttribute(FILLS, '');
        set(el, mine);
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') set(el, framed);
        var p = up(el);
        while (p && p !== document.documentElement) {
          p.setAttribute(ABOVE, '');
          if (p !== document.body) set(p, ancestor);
          lifted.push(p);
          p = up(p);
        }
      }

      function fireChange(target) {
        var doc = (target && target.ownerDocument) || document;
        doc.dispatchEvent(new Event('fullscreenchange', { bubbles: true }));
        doc.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: true }));
      }

      function askNative(on) {
        window.dispatchEvent(new CustomEvent(ASK, { detail: on ? 'on' : 'off' }));
      }

      function leave(notifyParent) {
        var was = current;
        if (!was) return;
        current = null;
        if (timer) { clearInterval(timer); timer = null; }
        restore();
        if (sheet && sheet.isConnected) sheet.remove();
        sheet = null;
        if (was.tagName === 'IFRAME' || was.tagName === 'FRAME') {
          try { if (was.contentWindow) was.contentWindow.postMessage({ [NOTE]: 'leave' }, '*'); } catch (e) {}
        }
        fireChange(was);
        if (notifyParent) {
          if (isTop) askNative(false);
          else if (window.parent) window.parent.postMessage({ [NOTE]: 'down' }, '*');
        }
      }

      function enter(el) {
        if (!el || !el.isConnected) return Promise.resolve();
        if (navigator.userActivation && !navigator.userActivation.isActive && window === window.top) {
          return Promise.resolve();
        }
        if (current && current !== el) leave(false);
        current = el;
        lift(el);
        if (!timer) {
          timer = setInterval(function () {
            if (current && !current.isConnected) leave(true);
          }, 500);
        }
        if (isTop) askNative(true);
        else if (window.parent) window.parent.postMessage({ [NOTE]: 'up' }, '*');
        fireChange(el);
        return Promise.resolve();
      }

      function getter(obj, prop, fn) {
        var desc = Object.getOwnPropertyDescriptor(obj, prop);
        undo.push([obj, prop, desc]);
        Object.defineProperty(obj, prop, { configurable: true, get: fn });
      }
      function method(obj, prop, fn) {
        var desc = Object.getOwnPropertyDescriptor(obj, prop);
        undo.push([obj, prop, desc]);
        Object.defineProperty(obj, prop, { configurable: true, writable: true, value: fn });
      }

      getter(DP, 'fullscreenElement', function () { return current; });
      getter(DP, 'webkitFullscreenElement', function () { return current; });
      getter(DP, 'webkitCurrentFullScreenElement', function () { return current; });
      getter(DP, 'fullscreenEnabled', function () { return true; });
      getter(DP, 'webkitFullscreenEnabled', function () { return true; });

      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (name) {
        if (name in EP) method(EP, name, function () { return enter(this); });
      });
      ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'].forEach(function (name) {
        if (name in DP) method(DP, name, function () {
          if (current) leave(true);
          return Promise.resolve();
        });
      });

      var VP = typeof HTMLVideoElement !== 'undefined' && HTMLVideoElement.prototype;
      if (VP) {
        if ('webkitEnterFullscreen' in VP) {
          method(VP, 'webkitEnterFullscreen', function () { enter(this); });
        }
        if ('webkitExitFullscreen' in VP) {
          method(VP, 'webkitExitFullscreen', function () { if (current === this) leave(true); });
        }
        var modeDesc = Object.getOwnPropertyDescriptor(VP, 'webkitPresentationMode');
        var setModeDesc = Object.getOwnPropertyDescriptor(VP, 'webkitSetPresentationMode');
        if (modeDesc && modeDesc.get && setModeDesc && setModeDesc.value) {
          getter(VP, 'webkitPresentationMode', function () {
            return current === this ? 'fullscreen' : modeDesc.get.call(this);
          });
          method(VP, 'webkitSetPresentationMode', function (to) {
            if (to === 'fullscreen') return enter(this);
            if (current === this) leave(true);
            if (to !== 'inline') return setModeDesc.value.call(this, to);
          });
        }
      }

      function heard(event) {
        var data = event.data, note = data && typeof data === 'object' ? data[NOTE] : null;
        if (!note) return;
        event.stopImmediatePropagation();
        if (note === 'off') {
          if (event.source === window.parent) off();
          return;
        }
        if (note === 'leave') {
          if (event.source === window.parent && current) leave(false);
          return;
        }
        var frame = Array.prototype.find.call(document.querySelectorAll('iframe, frame'), function (f) {
          return f.contentWindow === event.source;
        });
        if (!frame) return;
        if (note === 'up') {
          if (navigator.userActivation && !navigator.userActivation.isActive) {
            event.source.postMessage({ [NOTE]: 'leave' }, '*');
            return;
          }
          enter(frame);
        } else if (note === 'down' && current === frame) {
          leave(true);
        }
      }
      window.addEventListener('message', heard, true);

      function ended() { leave(false); }
      function hidden() { if (current) leave(true); }
      if (isTop) window.addEventListener(LEAVE, ended);
      window.addEventListener('pagehide', hidden);

      function off() {
        if (current) leave(false);
        undo.reverse().forEach(function (entry) {
          if (entry[2]) Object.defineProperty(entry[0], entry[1], entry[2]);
          else delete entry[0][entry[1]];
        });
        undo = [];
        window.removeEventListener('message', heard, true);
        window.removeEventListener(LEAVE, ended);
        window.removeEventListener(OFF, off);
        window.removeEventListener('pagehide', hidden);
        Array.prototype.forEach.call(document.querySelectorAll('iframe, frame'), function (f) {
          if (f.contentWindow) f.contentWindow.postMessage({ [NOTE]: 'off' }, '*');
        });
        delete window.__browseFills;
      }
      if (isTop) window.addEventListener(OFF, off);
    })();
    """
}
