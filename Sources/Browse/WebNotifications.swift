import AppKit
import UserNotifications
import WebKit

/// Bridges `window.Notification` from secure pages to macOS Notification Center
/// with per-site permission persistence shared with Settings › Privacy.
enum WebNotifications {
    nonisolated static let name = "browseNotifications"
    nonisolated static let askEvent = "__browseNotifAsk"
    nonisolated static let replyEvent = "__browseNotifReply"

    /// Normalized secure origin (`https` or loopback `http`), or `nil` for insecure origins.
    static func secureOrigin(scheme: String, host: String, port: Int) -> String? {
        let s = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return nil }
        let unbracketed = h.hasPrefix("[") && h.hasSuffix("]") ? String(h.dropFirst().dropLast()) : h
        let isLocal = unbracketed == "localhost"
            || unbracketed == "127.0.0.1"
            || unbracketed == "::1"
            || unbracketed.hasSuffix(".localhost")
        guard s == "https" || (s == "http" && isLocal) else { return nil }
        let formattedHost = unbracketed.contains(":") ? "[\(unbracketed)]" : unbracketed
        let defaultPort = (s == "https" && port == 443) || (s == "http" && port == 80)
        let portSuffix = (port > 0 && !defaultPort) ? ":\(port)" : ""
        return "\(s)://\(formattedHost)\(portSuffix)"
    }

    /// `Store.settings` key read by `Browser.savedCaptureChoices()`.
    static func permissionKey(for origin: String) -> String {
        "capture.\(origin)|notifications"
    }

    static var hasAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    nonisolated static let page = """
    (function () {
      if (window.__browseNotifInstalled) return;
      if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
      Object.defineProperty(window, '__browseNotifInstalled', { value: true, configurable: true });

      var ASK = '\(askEvent)', REPLY = '\(replyEvent)';
      var currentPermission = 'default';
      var pending = new Map();
      var instances = new Map();
      var deliveredIds = new Map();
      var nextReq = 1;
      var nextInst = 1;

      function send(payload) {
        window.dispatchEvent(new CustomEvent(ASK, { detail: JSON.stringify(payload) }));
      }

      window.addEventListener(REPLY, function (event) {
        var msg;
        try {
          msg = typeof event.detail === 'string' ? JSON.parse(event.detail) : event.detail;
        } catch (_) { return; }
        if (!msg || typeof msg !== 'object') return;
        if (msg.op === 'permission') {
          if (msg.permission === 'granted' || msg.permission === 'denied' || msg.permission === 'default') {
            currentPermission = msg.permission;
          }
          if (msg.reqId != null && pending.has(msg.reqId)) {
            var resolver = pending.get(msg.reqId);
            pending.delete(msg.reqId);
            resolver(currentPermission);
          }
        } else if (msg.op === 'event' && msg.notifId) {
          var inst = instances.get(msg.notifId);
          if (!inst) return;
          inst._emit(msg.type);
          if (msg.type === 'close' || msg.type === 'error') {
            instances.delete(msg.notifId);
          }
        }
      });

      function BrowseNotification(title, options) {
        if (arguments.length < 1) {
          throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
        }
        var opts = options && typeof options === 'object' ? options : {};
        this._id = String(nextInst++);
        this._listeners = { show: [], click: [], close: [], error: [] };
        this.title = String(title);
        this.body = opts.body != null ? String(opts.body) : '';
        this.tag = opts.tag != null ? String(opts.tag) : '';
        this.silent = Boolean(opts.silent);
        this.icon = opts.icon != null ? String(opts.icon) : '';
        this.data = opts.data !== undefined ? opts.data : null;
        this.dir = opts.dir != null ? String(opts.dir) : 'auto';
        this.lang = opts.lang != null ? String(opts.lang) : '';
        this.onclick = null;
        this.onshow = null;
        this.onclose = null;
        this.onerror = null;

        if (this.tag && deliveredIds.has(this.tag)) {
          var prevId = deliveredIds.get(this.tag);
          instances.delete(prevId);
        }
        if (this.tag) deliveredIds.set(this.tag, this._id);
        instances.set(this._id, this);

        send({
          op: 'show',
          notifId: this._id,
          title: this.title,
          body: this.body,
          tag: this.tag,
          silent: this.silent
        });
      }

      Object.defineProperty(BrowseNotification, 'permission', {
        configurable: true,
        get: function () { return currentPermission; }
      });
      Object.defineProperty(BrowseNotification, 'maxActions', {
        configurable: true,
        get: function () { return 0; }
      });

      BrowseNotification.requestPermission = function (cb) {
        var reqId = nextReq++;
        var p = new Promise(function (resolve) {
          pending.set(reqId, function (perm) {
            if (typeof cb === 'function') {
              try { cb(perm); } catch (_) {}
            }
            resolve(perm);
          });
        });
        send({ op: 'request', reqId: reqId });
        return p;
      };

      BrowseNotification.prototype.close = function () {
        send({ op: 'close', notifId: this._id, tag: this.tag });
        this._emit('close');
        instances.delete(this._id);
        if (this.tag && deliveredIds.get(this.tag) === this._id) deliveredIds.delete(this.tag);
      };

      BrowseNotification.prototype.addEventListener = function (type, fn) {
        if (!fn || typeof fn !== 'function') return;
        var list = this._listeners[type];
        if (!list) list = this._listeners[type] = [];
        if (list.indexOf(fn) === -1) list.push(fn);
      };

      BrowseNotification.prototype.removeEventListener = function (type, fn) {
        var list = this._listeners[type];
        if (!list) return;
        var idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
      };

      BrowseNotification.prototype.dispatchEvent = function (evt) {
        if (!evt || !evt.type) return false;
        this._emit(evt.type, evt);
        return true;
      };

      BrowseNotification.prototype._emit = function (type, existingEvent) {
        var evt = existingEvent || new Event(type);
        var prop = this['on' + type];
        if (typeof prop === 'function') {
          try { prop.call(this, evt); } catch (_) {}
        }
        var list = this._listeners[type];
        if (list) {
          list.slice().forEach(function (fn) {
            try { fn.call(this, evt); } catch (_) {}
          }, this);
        }
      };

      Object.defineProperty(window, 'Notification', {
        value: BrowseNotification,
        writable: true,
        enumerable: false,
        configurable: true
      });

      send({ op: 'query' });
    })();
    """

    nonisolated static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__browseNotifBridge) return;
      window.__browseNotifBridge = true;
      window.addEventListener('\(askEvent)', function (event) {
        try {
          var payload = typeof event.detail === 'string' ? JSON.parse(event.detail) : event.detail;
          handler.postMessage(payload);
        } catch (_) {}
      });
      window.__browseNotif = function (payload) {
        var text = typeof payload === 'string' ? payload : JSON.stringify(payload);
        window.dispatchEvent(new CustomEvent('\(replyEvent)', { detail: text }));
      };
    })();
    """

    #if !WEB_NOTIFICATIONS_STANDALONE
    @MainActor private static var cachedAuthorized: Bool?

    @MainActor
    static func installCenterDelegate() {
        guard hasAppBundle else { return }
        UNUserNotificationCenter.current().delegate = WebNotificationDelegate.shared
    }

    @MainActor
    static func dispatchToPage(_ web: WKWebView?, payload: [String: Any]) {
        guard let web,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateInSearch("window.__browseNotif && window.__browseNotif(\(json))")
    }

    @MainActor
    fileprivate static func post(
        tab: Tab,
        origin: String,
        host: String,
        notifID: String,
        title: String,
        body: String,
        tag: String,
        silent: Bool
    ) {
        guard hasAppBundle else {
            dispatchToPage(tab.built, payload: ["op": "event", "notifId": notifID, "type": "error"])
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = host.isEmpty ? origin : host
        content.sound = silent ? nil : .default
        content.userInfo = [
            "tabID": tab.id.uuidString,
            "notifID": notifID,
            "silent": silent,
        ]
        let identifier = tag.isEmpty ? "web.\(origin).\(notifID)" : "web.\(origin).tag.\(tag)"
        let tabRef = tab
        let web = tab.built
        Task { @MainActor in
            let ok: Bool
            if cachedAuthorized == true {
                ok = true
            } else {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                cachedAuthorized = granted ? true : nil
                ok = granted
            }
            guard ok else {
                dispatchToPage(tabRef.built ?? web, payload: ["op": "event", "notifId": notifID, "type": "error"])
                return
            }
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                dispatchToPage(tabRef.built ?? web, payload: ["op": "event", "notifId": notifID, "type": "show"])
            } catch {
                cachedAuthorized = nil
                dispatchToPage(tabRef.built ?? web, payload: ["op": "event", "notifId": notifID, "type": "error"])
            }
        }
    }

    @MainActor
    fileprivate static func remove(origin: String, notifID: String, tag: String) {
        guard hasAppBundle else { return }
        let identifier = tag.isEmpty ? "web.\(origin).\(notifID)" : "web.\(origin).tag.\(tag)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    #endif
}

#if !WEB_NOTIFICATIONS_STANDALONE
/// Handles main-frame `window.Notification` messages from `Tab` pages.
@MainActor
final class WebNotificationRelay: NSObject, WKScriptMessageHandler {
    weak var tab: Tab?
    var onRequest: ((String, String, @escaping (Bool) -> Void) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let op = body["op"] as? String
        else { return }

        let sec = message.frameInfo.securityOrigin
        let host = sec.host
        let shy = tab?.shy ?? true
        let reqId = body["reqId"] as? Int
        let notifId = body["notifId"] as? String ?? ""

        guard !shy, let origin = WebNotifications.secureOrigin(scheme: sec.protocol, host: host, port: sec.port) else {
            switch op {
            case "query", "request":
                var reply: [String: Any] = ["op": "permission", "permission": "denied"]
                if let reqId { reply["reqId"] = reqId }
                WebNotifications.dispatchToPage(tab?.built, payload: reply)
            case "show":
                WebNotifications.dispatchToPage(tab?.built, payload: ["op": "event", "notifId": notifId, "type": "error"])
            default:
                break
            }
            return
        }

        let key = WebNotifications.permissionKey(for: origin)
        switch op {
        case "query":
            // Page script starts with `currentPermission = 'default'`, so skip
            // the round-trip evaluateInSearch when no site override is saved.
            guard let saved = Store.settings.object(forKey: key) as? Bool else { return }
            let perm = saved ? "granted" : "denied"
            WebNotifications.dispatchToPage(tab?.built, payload: ["op": "permission", "permission": perm])

        case "request":
            if let saved = Store.settings.object(forKey: key) as? Bool {
                var reply: [String: Any] = ["op": "permission", "permission": saved ? "granted" : "denied"]
                if let reqId { reply["reqId"] = reqId }
                WebNotifications.dispatchToPage(tab?.built, payload: reply)
                return
            }
            guard let onRequest else {
                var reply: [String: Any] = ["op": "permission", "permission": "denied"]
                if let reqId { reply["reqId"] = reqId }
                WebNotifications.dispatchToPage(tab?.built, payload: reply)
                return
            }
            let label = host.isEmpty ? origin : host
            onRequest(label, origin) { [weak self] granted in
                var reply: [String: Any] = ["op": "permission", "permission": granted ? "granted" : "denied"]
                if let reqId { reply["reqId"] = reqId }
                WebNotifications.dispatchToPage(self?.tab?.built, payload: reply)
            }

        case "show":
            guard Store.settings.object(forKey: key) as? Bool == true, let tab else {
                WebNotifications.dispatchToPage(tab?.built, payload: ["op": "event", "notifId": notifId, "type": "error"])
                return
            }
            let title = body["title"] as? String ?? ""
            let msgBody = body["body"] as? String ?? ""
            let tag = body["tag"] as? String ?? ""
            let silent = body["silent"] as? Bool ?? false
            WebNotifications.post(
                tab: tab,
                origin: origin,
                host: host,
                notifID: notifId,
                title: title,
                body: msgBody,
                tag: tag,
                silent: silent
            )

        case "close":
            let tag = body["tag"] as? String ?? ""
            WebNotifications.remove(origin: origin, notifID: notifId, tag: tag)

        default:
            break
        }
    }
}

/// Routes foreground web notification banners and click activation back to the source tab.
final class WebNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let silent = notification.request.content.userInfo["silent"] as? Bool ?? false
        completionHandler(silent ? [.banner] : [.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let tabIDText = userInfo["tabID"] as? String
        let notifID = userInfo["notifID"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabIDText,
                      let uuid = UUID(uuidString: tabIDText),
                      let browser = Links.browser,
                      let tab = browser.tabs.first(where: { $0.id == uuid })
                else {
                    completionHandler()
                    return
                }
                Links.activateBrowserWindow()
                browser.select(tab)
                if let notifID, !notifID.isEmpty {
                    WebNotifications.dispatchToPage(tab.built, payload: [
                        "op": "event",
                        "notifId": notifID,
                        "type": "click",
                    ])
                }
                completionHandler()
            }
        }
    }
}
#endif
