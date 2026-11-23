import AppKit
import SwiftUI
import WebKit

/// Dia-style floating selection action pill that appears quietly above
/// highlighted webpage text (Ask, Explain, Rewrite when inside an editable
/// field, Copy). Runs passively in `Web.world` on `mouseup`/`keyup` only —
/// zero `MutationObserver` and zero work during 120 Hz scrolling.
struct PageSelection: Equatable {
    let tabID: Tab.ID
    let text: String
    /// Selection bounding box in web view points (top-left origin).
    let rect: CGRect
    /// True when the selection lives inside an editable field (`textarea`,
    /// `input`, or `contenteditable`), unlocking the one-click Rewrite action.
    let editable: Bool
}

final class SelectionRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeSelect"
    @MainActor static var on = true

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            guard SelectionRelay.on else {
                tab.onSelection?(tab, nil)
                return
            }
            guard let text = body["text"] as? String,
                  !text.isEmpty,
                  let r = body["rect"] as? [String: Any],
                  let x = r["x"] as? Double, let y = r["y"] as? Double,
                  let w = r["w"] as? Double, let h = r["h"] as? Double
            else {
                tab.onSelection?(tab, nil)
                return
            }
            let zoom = tab.built?.pageZoom ?? 1
            let rect = CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
            let editable = body["editable"] as? Bool ?? false
            tab.onSelection?(tab, PageSelection(tabID: tab.id, text: text, rect: rect, editable: editable))
        }
    }

    static let script = """
    (function () {
      if (window.__officeSelect) return;
      window.__officeSelect = true;
      var shown = false;
      var timer = null;

      function hide() {
        if (!shown) return;
        shown = false;
        window.webkit.messageHandlers.\(name).postMessage({ clear: true });
      }

      function isEditable(node) {
        var el = node && node.nodeType === 1 ? node : (node && node.parentElement);
        while (el) {
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'input') {
            var t = (el.type || 'text').toLowerCase();
            if (t === 'password') return 'password';
            return true;
          }
          if (tag === 'textarea' || el.isContentEditable === true) return true;
          el = el.parentElement;
        }
        return false;
      }

      function measure() {
        timer = null;
        var active = document.activeElement;
        if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA')) {
          if ((active.type || '').toLowerCase() === 'password') { hide(); return; }
          var start = active.selectionStart, end = active.selectionEnd;
          if (typeof start === 'number' && typeof end === 'number' && end > start) {
            var val = (active.value || '').slice(start, end).trim();
            if (val.length >= 12) {
              var ar = active.getBoundingClientRect();
              if (ar.width > 0 && ar.height > 0) {
                shown = true;
                window.webkit.messageHandlers.\(name).postMessage({
                  text: val.slice(0, 3500),
                  rect: { x: ar.left, y: ar.top, w: ar.width, h: Math.min(ar.height, 44) },
                  editable: true
                });
                return;
              }
            }
          }
          hide();
          return;
        }

        var sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0) { hide(); return; }
        var text = (sel.toString() || '').trim();
        if (text.length < 12) { hide(); return; }
        var ed = isEditable(sel.anchorNode);
        if (ed === 'password') { hide(); return; }
        var range = sel.getRangeAt(0);
        var rect = range.getBoundingClientRect();
        if (!rect || (rect.width === 0 && rect.height === 0)) { hide(); return; }
        if (rect.bottom < 0 || rect.top > window.innerHeight) { hide(); return; }
        shown = true;
        window.webkit.messageHandlers.\(name).postMessage({
          text: text.slice(0, 3500),
          rect: { x: rect.left, y: rect.top, w: rect.width, h: rect.height },
          editable: ed === true
        });
      }

      function schedule() {
        if (timer) clearTimeout(timer);
        timer = setTimeout(measure, 140);
      }

      document.addEventListener('mouseup', schedule, { passive: true, capture: true });
      document.addEventListener('keyup', function (e) {
        if (e.shiftKey || e.key === 'a' || e.key === 'A') schedule();
      }, { passive: true, capture: true });
      document.addEventListener('mousedown', hide, { passive: true, capture: true });
      window.addEventListener('scroll', hide, { passive: true, capture: true });
      window.addEventListener('pagehide', hide, { passive: true });
    })();
    """
}

/// Floating frosted pill anchored cleanly above the current text selection.
struct SelectionBar: View {
    let selection: PageSelection
    let viewport: CGSize
    let onAsk: () -> Void
    let onExplain: () -> Void
    let onRewrite: () -> Void
    let onCopy: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pillWidth: CGFloat = selection.editable ? 268 : 200
        let pillHeight: CGFloat = 32
        let viewW = viewport.width > 0 ? viewport.width : 900
        let viewH = viewport.height > 0 ? viewport.height : 600
        let leftX = selection.rect.midX - pillWidth / 2
        let clampedX = min(max(12, leftX), max(12, viewW - pillWidth - 12))
        let aboveY = selection.rect.minY - pillHeight - 10
        let belowY = selection.rect.maxY + 10
        let chosenY = aboveY >= 8 ? aboveY : min(max(8, viewH - pillHeight - 8), belowY)

        HStack(spacing: 2) {
            pillButton(icon: "sparkles", label: "Ask", accent: true, action: onAsk)
            pillDivider
            pillButton(icon: "lightbulb", label: "Explain", action: onExplain)
            if selection.editable {
                pillDivider
                pillButton(icon: "wand.and.stars", label: "Rewrite", action: onRewrite)
            }
            pillDivider
            pillButton(icon: "doc.on.doc", label: nil, help: "Copy selection", action: onCopy)
        }
        .padding(.horizontal, 5)
        .frame(height: pillHeight)
        .background(
            Capsule()
                .fill(scheme == .dark ? Color(white: 0.14).opacity(0.95) : Color.white.opacity(0.96))
        )
        .overlay(
            Capsule()
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.14), radius: 14, y: 5)
        .offset(x: clampedX, y: chosenY)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 1, height: 14)
    }

    private func pillButton(icon: String, label: String?, help: String? = nil, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent ? Palette.accent : Palette.ink.opacity(0.82))
                if let label {
                    Text(label)
                        .font(.system(size: 11.5, weight: accent ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, label == nil ? 7 : 8)
            .frame(height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(TactilePress())
        .help(help ?? label ?? "")
    }
}
