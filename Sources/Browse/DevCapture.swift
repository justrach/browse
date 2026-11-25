import Foundation

/// On-demand passive ring-buffer capture of page console messages, runtime
/// errors, and fetch/XHR network requests for Codegraff / MCP inspection.
///
/// Runs purely in the page world with zero `MutationObserver`s, zero scroll or
/// input listeners, zero native IPC during page execution, and never records
/// cookies, `Authorization` headers, or request/response bodies.
@MainActor
enum DevCapture {
    static var on = false

    static let script = """
    (function () {
      if (window.__browseDevLog) return;
      var MAX = 200;
      var store = { console: [], network: [] };
      var xhrMeta = typeof WeakMap === 'function' ? new WeakMap() : null;
      var xhrHooked = typeof WeakMap === 'function' ? new WeakMap() : null;
      function push(arr, item) {
        if (arr.length >= MAX) arr.shift();
        arr.push(item);
      }
      function formatVal(v) {
        try {
          if (typeof v === 'string') return v;
          if (v instanceof Error) return (v.name ? v.name + ': ' : '') + (v.message || String(v));
          if (v === null) return 'null';
          if (v === undefined) return 'undefined';
          if (typeof Node !== 'undefined' && v instanceof Node) {
            return '<' + String(v.nodeName || 'node').toLowerCase() + '>';
          }
          if (typeof v === 'object') {
            if (Array.isArray(v) || Object.prototype.toString.call(v) === '[object Object]') {
              return JSON.stringify(v).slice(0, 400);
            }
            return Object.prototype.toString.call(v);
          }
          return String(v);
        } catch (_) {
          try { return String(v); } catch (__) { return '[unserializable]'; }
        }
      }
      function formatArgs(args) {
        var out = [];
        for (var i = 0; i < args.length; i++) out.push(formatVal(args[i]));
        return out.join(' ').slice(0, 800);
      }
      function normalizeURL(u) {
        try {
          var s = String(u || '');
          if (s.length > 500) s = s.slice(0, 500);
          return s;
        } catch (_) { return ''; }
      }

      ['log', 'info', 'warn', 'error'].forEach(function (level) {
        var orig = console[level];
        if (typeof orig !== 'function') return;
        console[level] = function () {
          try {
            push(store.console, {
              level: level,
              text: formatArgs(arguments),
              ts: Date.now()
            });
          } catch (_) {}
          return orig.apply(console, arguments);
        };
      });

      window.addEventListener('error', function (e) {
        try {
          var msg = (e && e.message) ? String(e.message) : 'Uncaught error';
          if (e && e.filename) msg += ' (' + normalizeURL(e.filename) + ':' + (e.lineno || 0) + ')';
          push(store.console, { level: 'error', text: msg.slice(0, 800), ts: Date.now() });
        } catch (_) {}
      });

      window.addEventListener('unhandledrejection', function (e) {
        try {
          var reason = e && 'reason' in e ? formatVal(e.reason) : 'Unhandled rejection';
          push(store.console, { level: 'error', text: ('Unhandled rejection: ' + reason).slice(0, 800), ts: Date.now() });
        } catch (_) {}
      });

      if (typeof window.fetch === 'function') {
        var origFetch = window.fetch;
        window.fetch = function (input, init) {
          var method = 'GET';
          var url = '';
          try {
            if (init && init.method) method = String(init.method).toUpperCase();
            else if (input && typeof input === 'object' && input.method) method = String(input.method).toUpperCase();
            url = (input && typeof input === 'object' && typeof input.url === 'string') ? normalizeURL(input.url) : normalizeURL(input);
          } catch (_) {}
          var t0 = performance.now();
          var ts = Date.now();
          var p = origFetch.apply(this, arguments);
          try {
            if (p && typeof p.then === 'function') {
              p.then(function (res) {
                try {
                  push(store.network, {
                    type: 'fetch',
                    method: method,
                    url: url,
                    status: res ? res.status : 0,
                    ok: !!(res && res.ok),
                    durationMs: Math.round(performance.now() - t0),
                    ts: ts
                  });
                } catch (_) {}
              }, function (err) {
                try {
                  push(store.network, {
                    type: 'fetch',
                    method: method,
                    url: url,
                    status: 0,
                    ok: false,
                    durationMs: Math.round(performance.now() - t0),
                    error: formatVal(err).slice(0, 200),
                    ts: ts
                  });
                } catch (_) {}
              });
            }
          } catch (_) {}
          return p;
        };
      }

      if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype) {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          try {
            if (xhrMeta) {
              xhrMeta.set(this, {
                method: String(method || 'GET').toUpperCase(),
                url: normalizeURL(url)
              });
            }
          } catch (_) {}
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          try {
            var meta = (xhrMeta && xhrMeta.get(this)) || { method: 'GET', url: '' };
            if (!xhrHooked || !xhrHooked.has(this)) {
              if (xhrHooked) xhrHooked.set(this, true);
              var xhr = this;
              var t0 = performance.now();
              var ts = Date.now();
              xhr.addEventListener('loadend', function () {
                try {
                  var status = xhr.status || 0;
                  push(store.network, {
                    type: 'xhr',
                    method: meta.method,
                    url: meta.url,
                    status: status,
                    ok: status >= 200 && status < 400,
                    durationMs: Math.round(performance.now() - t0),
                    error: status === 0 ? 'network-error' : '',
                    ts: ts
                  });
                } catch (_) {}
              }, { once: true });
            }
          } catch (_) {}
          return origSend.apply(this, arguments);
        };
      }

      Object.defineProperty(window, '__browseDevLog', { value: store, enumerable: false, configurable: true });
    })();
    """

    static func readConsoleScript(level: String, limit: Int, clear: Bool) -> String {
        let levelLit = jsonLiteral(level.lowercased())
        let clampedLimit = max(1, min(limit, 200))
        return """
        (function () {
          var s = window.__browseDevLog;
          if (!s) return { active: false, total: 0, entries: [] };
          var list = s.console || [];
          var want = \(levelLit);
          var out = [];
          for (var i = 0; i < list.length; i++) {
            var e = list[i];
            if (!e) continue;
            if (want === 'all' || want === '' || e.level === want) out.push(e);
          }
          var total = out.length;
          if (out.length > \(clampedLimit)) out = out.slice(out.length - \(clampedLimit));
          if (\(clear ? "true" : "false")) s.console = [];
          return { active: true, total: total, entries: out };
        })()
        """
    }

    static func readNetworkScript(failedOnly: Bool, filter: String?, limit: Int, clear: Bool) -> String {
        let filterLit = jsonLiteral((filter ?? "").lowercased())
        let clampedLimit = max(1, min(limit, 200))
        return """
        (function () {
          var s = window.__browseDevLog;
          if (!s) return { active: false, total: 0, entries: [] };
          var list = s.network || [];
          var failedOnly = \(failedOnly ? "true" : "false");
          var needle = \(filterLit);
          var out = [];
          for (var i = 0; i < list.length; i++) {
            var e = list[i];
            if (!e) continue;
            if (failedOnly && e.ok && e.status >= 200 && e.status < 400) continue;
            if (needle && (!e.url || e.url.toLowerCase().indexOf(needle) === -1)) continue;
            out.push(e);
          }
          var total = out.length;
          if (out.length > \(clampedLimit)) out = out.slice(out.length - \(clampedLimit));
          if (\(clear ? "true" : "false")) s.network = [];
          return { active: true, total: total, entries: out };
        })()
        """
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
