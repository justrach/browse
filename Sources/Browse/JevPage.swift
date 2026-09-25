import Foundation
import WebKit

// The page side of Jev.swift: what a page offers, read in one go, and the
// one step Jev chose, done the way a person's hand would do it.
//
// Every script here runs in a content world of the browser's own, so a page
// can't see the table of nodes, stand in for it, or tell these steps from
// its own visitors' by looking for them. The events they fire are the page's
// to hear, as any click is.
//
// The snapshot, the action space and the step checks are adapted from
// jev-ultrafast (https://github.com/browser-use/jev-ultrafast), under its
// MIT License:
//
//   Copyright (c) 2026 Browser Use
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

extension Jev {
    /// One thing on the page that can be done: an element and what to do to it,
    /// or a scroll, or a wait.
    struct Control {
        /// This read's id for it: `e1`…, or `scroll_down`, `scroll_up`, `wait`.
        let id: String
        /// The node, as the browser's own table knows it; stable between reads.
        let node: Int
        /// click, fill, select, scroll or wait.
        let kind: String
        let role: String
        let label: String
        let value: String
        /// For a select: what's chosen now.
        let current: String
        let states: [String: String]
        let delta: Int

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String, let kind = raw["kind"] as? String else { return nil }
            self.id = id
            self.kind = kind
            node = raw["node"] as? Int ?? 0
            role = raw["role"] as? String ?? ""
            label = raw["label"] as? String ?? id
            value = raw["value"] as? String ?? ""
            current = raw["current_value"] as? String ?? ""
            var states: [String: String] = [:]
            for key in ["checked", "selected", "expanded"] { if let state = raw[key] as? String { states[key] = state } }
            self.states = states
            delta = raw["delta"] as? Int ?? 0
        }

        /// A box's state in words, for the table and the history: Jev reads
    /// " — checked" far more surely than a separate field, and without it
    /// flips a box it has already set.
    var state: String {
        guard let checked = states["checked"] else { return "" }
        return checked == "true" ? " — checked" : " — not checked"
    }

    /// What the script that does it is handed.
        var action: [String: Any] { ["node": node, "kind": kind, "value": value, "delta": delta] }
    }

    /// A page as read for one decision.
    struct Page {
        let url: String
        let title: String
        let text: String
        /// Changes when anything Jev would see changes.
        let mark: String
        let controls: [Control]
    }

    /// A step taken, as Jev hears about it next time and graff reads it after.
    struct Step {
        let label: String
        let kind: String
        let text: String?
        let changed: Bool
    }

    /// The page's controls as Jev is asked about them: one index per element,
    /// and for each operation the elements it could act on.
    struct Space {
        struct Choice {
            let control: Control
            let criterion: [String: Any]
        }

        var elements: [[String: Any]] = []
        var targets: [String: [String: Choice]] = [:]
        var others: [String: Control] = [:]

        init(_ controls: [Control]) {
            let operations = ["click": "CLICK", "fill": "TYPE_TEXT", "select": "SELECT"]
            var indices: [Int: Int] = [:]
            for control in controls {
                guard let operation = operations[control.kind] else {
                    others[control.id.uppercased()] = control
                    continue
                }
                if indices[control.node] == nil {
                    indices[control.node] = elements.count
                    var element: [String: Any] = [
                        "index": String(elements.count + 1),
                        "role": control.role,
                        "label": control.label.components(separatedBy: " → ").first ?? control.label,
                        "value": control.kind == "select" ? control.current : control.value,
                        "operations": [String](),
                    ]
                    for (key, state) in control.states { element[key] = state }
                    if control.kind == "select" { element["options"] = [[String: Any]]() }
                    elements.append(element)
                }
                let at = indices[control.node]!
                let index = String(at + 1)
                var operationsHere = elements[at]["operations"] as? [String] ?? []
                if !operationsHere.contains(operation) { operationsHere.append(operation) }
                elements[at]["operations"] = operationsHere
                var target = index
                if control.kind == "select" {
                    var options = elements[at]["options"] as? [[String: Any]] ?? []
                    target = "\(index):\(options.count + 1)"
                    options.append(["index": target, "label": control.label, "value": control.value])
                    elements[at]["options"] = options
                }
                var criterion: [String: Any] = [
                    "element": "[\(index)] \(control.label)\(control.state)",
                    "current_value": control.kind == "select" ? control.current : control.value,
                    "role": control.role,
                ]
                for (key, state) in control.states { criterion[key] = state }
                targets[operation, default: [:]][target] = Choice(control: control, criterion: criterion)
            }
        }
    }
}

@MainActor
extension Jev.Page {
    private static let world = WKContentWorld.world(name: "search.jev")

    /// Everything Jev sees: the visible text, and every control on screen a
    /// person could use, each tied to its node.
    static func read(_ web: WKWebView) async -> Jev.Page? {
        guard let json = await call(snapshot, [:], on: web) as? String,
              let raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        return Jev.Page(
            url: raw["url"] as? String ?? "",
            title: raw["title"] as? String ?? "",
            text: raw["text"] as? String ?? "",
            mark: raw["mark"] as? String ?? "",
            controls: (raw["actions"] as? [[String: Any]] ?? []).compactMap(Jev.Control.init)
        )
    }

    /// The step, if its node is still there, shown, enabled and not under
    /// something else. "ok", or why not.
    static func act(_ control: Jev.Control, text: String?, on web: WKWebView) async -> String {
        await call(step, ["action": control.action, "text": text ?? ""], on: web) as? String ?? "the page didn't answer"
    }

    /// A beat for the page to answer the step: two frames, or suggestions
    /// under a field just typed in — and a load to its end, if it went
    /// somewhere.
    static func settle(after control: Jev.Control, on web: WKWebView) async {
        _ = await call(pause, ["action": control.action], on: web)
        guard web.isLoading else { return }
        let limit = Date().addingTimeInterval(15)
        while web.isLoading, Date() < limit { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private static func call(_ body: String, _ arguments: [String: Any], on web: WKWebView) async -> Any? {
        await withCheckedContinuation { done in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                done.resume(returning: try? result.get())
            }
        }
    }

    // Shared by the three: a node's name as assistive technology would say
    // it, and whether it is really there to be seen.
    fileprivate static let kit = """
    const visible = e => {
      if (e.closest('[aria-hidden="true"],[inert]')) return false;
      if (e.checkVisibility) return e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true});
      const s = getComputedStyle(e);
      return s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
    };
    """

    private static let snapshot = """
    if (!document.body) return null;
    \(Jev.Page.kit)
    const cache = window.__jev || (window.__jev = {ids: new WeakMap(), nodes: new Map(), next: 1});
    const identity = e => {
      if (!cache.ids.has(e)) cache.ids.set(e, cache.next++);
      const id = cache.ids.get(e); cache.nodes.set(id, e); return id;
    };
    for (const [id, e] of cache.nodes) if (!e.isConnected) cache.nodes.delete(id);
    const safe = e => !['password', 'file', 'hidden'].includes(e.type);
    const name = (e, seen = new Set()) => {
      if (!e || seen.has(e)) return '';
      seen.add(e);
      const referenced = (e.getAttribute('aria-labelledby') || '').split(/\\s+/)
        .map(id => name(document.getElementById(id), seen)).filter(Boolean).join(' ');
      return referenced || e.getAttribute('aria-label') ||
        [...(e.labels || [])].map(l => name(l, seen)).filter(Boolean).join(' ') ||
        (['button', 'submit', 'reset'].includes(e.type) ? e.value : '') || e.getAttribute('alt') ||
        (e.tagName === 'INPUT' ? '' : [...e.childNodes].map(n => n.nodeType === 3 ? n.textContent :
          n.nodeType === 1 && n.getAttribute('aria-hidden') !== 'true' ? name(n, seen) : '').join(' ').trim()) ||
        e.getAttribute('title') || e.getAttribute('placeholder') || '';
    };
    const clean = t => String(t || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
    const roles = ['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemradio',
      'option', 'gridcell', 'combobox', 'textbox', 'searchbox', 'spinbutton'];
    const selector = 'a[href],button,input,textarea,select,summary,[contenteditable="true"],' +
      roles.map(role => '[role="' + role + '"]').join(',');
    const role = e => {
      const explicit = e.getAttribute('role');
      if (roles.includes(explicit)) return explicit;
      if (e.tagName === 'BUTTON' || e.tagName === 'SUMMARY') return 'button';
      if (e.tagName === 'A') return 'link';
      if (e.tagName === 'SELECT') return 'combobox';
      if (e.tagName === 'TEXTAREA' || e.isContentEditable) return 'textbox';
      if (e.tagName === 'INPUT') {
        if (['checkbox', 'radio'].includes(e.type)) return e.type;
        if (['button', 'submit', 'reset', 'image'].includes(e.type)) return 'button';
        if (e.type === 'search') return 'searchbox';
        if (e.type === 'number') return 'spinbutton';
        if (['text', 'email', 'url', 'tel'].includes(e.type)) return 'textbox';
      }
      return null;
    };
    const actions = [];
    for (const e of document.querySelectorAll(selector)) {
      if (actions.length >= 160) break;
      if (!safe(e) || !visible(e) || e.matches(':disabled') || e.closest('[aria-disabled="true"]')) continue;
      const r = e.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2, rname = role(e);
      if (!rname || r.width <= 0 || r.height <= 0 || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
      if (rname === 'gridcell' && e.querySelector('button,[role="button"]')) continue;
      const base = {node: identity(e), role: rname, label: clean(name(e)) || rname};
      for (const key of ['checked', 'selected', 'expanded']) {
        const value = e.getAttribute('aria-' + key);
        if (value !== null) base[key] = value;
      }
      if (['checkbox', 'radio'].includes(e.type)) base.checked = String(e.checked);
      if (e.tagName === 'SELECT') {
        const current = [...e.selectedOptions].map(o => o.label).join(', ');
        for (const o of e.options) if (!o.selected && !o.disabled && !o.closest('optgroup[disabled]'))
          actions.push({...base, kind: 'select', value: o.value, current_value: current, label: base.label + ' → ' + clean(o.label)});
      } else {
        const editable = !e.readOnly && e.getAttribute('aria-readonly') !== 'true' &&
          (['textbox', 'searchbox', 'spinbutton'].includes(rname) ||
            (rname === 'combobox' && ['INPUT', 'TEXTAREA'].includes(e.tagName)));
        const value = 'value' in e ? clean(e.value) : e.isContentEditable || rname === 'combobox' ? clean(e.innerText) : '';
        actions.push({...base, kind: editable ? 'fill' : 'click', value});
        if (editable) actions.push({...base, kind: 'click', value, label: 'Open ' + base.label});
      }
    }
    const words = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const range = document.createRange(); let node, length = 0;
    while ((node = walker.nextNode()) && length < 4000) {
      const value = node.textContent.trim(), parent = node.parentElement;
      if (!value || !parent || parent.closest('script,style,noscript,template') || !visible(parent)) continue;
      range.selectNodeContents(node); const r = range.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth) {
        words.push(value); length += value.length;
      }
    }
    const text = words.join('\\n').slice(0, 4000), height = document.documentElement.scrollHeight;
    actions.forEach((a, i) => a.id = 'e' + (i + 1));
    const seen = JSON.stringify([location.href, scrollX, scrollY, document.title, text,
      actions.map(a => [a.node, a.kind, a.label, a.value, a.checked, a.selected, a.expanded])]);
    let hash = 2166136261;
    for (let i = 0; i < seen.length; i++) { hash ^= seen.charCodeAt(i); hash = Math.imul(hash, 16777619) >>> 0; }
    if (scrollY + innerHeight < height - 2) actions.push({id: 'scroll_down', kind: 'scroll', label: 'Scroll down', delta: Math.round(innerHeight * 0.7)});
    if (scrollY > 0) actions.push({id: 'scroll_up', kind: 'scroll', label: 'Scroll up', delta: -Math.round(innerHeight * 0.7)});
    actions.push({id: 'wait', kind: 'wait', label: 'Wait for the page to update'});
    return JSON.stringify({url: location.href, title: document.title, text, mark: hash + ':' + seen.length, actions});
    """

    private static let step = """
    \(Jev.Page.kit)
    if (action.kind === 'scroll') { window.scrollBy(0, action.delta); return 'ok'; }
    if (action.kind === 'wait') { await new Promise(r => setTimeout(r, 300)); return 'ok'; }
    const e = window.__jev && window.__jev.nodes.get(action.node);
    if (!e || !e.isConnected) return 'gone';
    if (!visible(e) || e.matches(':disabled') || e.closest('[aria-disabled="true"],[inert]')) return 'hidden or disabled';
    if (action.kind === 'fill' && (e.readOnly || e.getAttribute('aria-readonly') === 'true')) return 'read-only';
    const r = e.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2;
    if (!r.width || !r.height || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return 'off screen';
    const set = (el, value) => {
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      const d = Object.getOwnPropertyDescriptor(proto, 'value');
      if (d && d.set) d.set.call(el, value); else el.value = value;
    };
    if (action.kind === 'select') {
      if (e.tagName !== 'SELECT' || ![...e.options].some(o => o.value === action.value && !o.disabled)) return 'no such option';
      e.focus({preventScroll: true});
      set(e, action.value);
      e.dispatchEvent(new Event('input', {bubbles: true}));
      e.dispatchEvent(new Event('change', {bubbles: true}));
      return 'ok';
    }
    const hit = document.elementFromPoint(x, y);
    if (!hit || !(hit === e || e.contains(hit))) return 'covered';
    const at = {bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view: window, button: 0, pointerType: 'mouse', isPrimary: true};
    hit.dispatchEvent(new PointerEvent('pointerover', at));
    hit.dispatchEvent(new PointerEvent('pointerdown', at));
    hit.dispatchEvent(new MouseEvent('mousedown', at));
    if (e.focus) e.focus({preventScroll: true});
    hit.dispatchEvent(new PointerEvent('pointerup', at));
    hit.dispatchEvent(new MouseEvent('mouseup', at));
    hit.click();
    if (action.kind === 'fill') {
      if (e.isContentEditable) document.execCommand('selectAll', false, null); else if (e.select) e.select();
      let typed = false;
      try { typed = document.execCommand('insertText', false, text); } catch (_) {}
      const now = e.isContentEditable ? e.innerText : e.value;
      if (!typed || now !== text) {
        if ('value' in e) set(e, text); else e.textContent = text;
        e.dispatchEvent(new Event('input', {bubbles: true}));
      }
    }
    return 'ok';
    """

    private static let pause = """
    return await new Promise(resolve => {
      const field = window.__jev && window.__jev.nodes.get(action.node);
      const suggests = action.kind === 'fill' && field &&
        (field.getAttribute('role') === 'combobox' || field.getAttribute('aria-autocomplete'));
      let frames = 0, stopped = false;
      const finish = () => { if (!stopped) { stopped = true; resolve(true); } };
      setTimeout(finish, suggests ? 250 : 60);
      const ready = () => {
        if (stopped) return;
        if (++frames >= 2 && (!suggests || document.querySelector('[role="option"]'))) finish();
        else requestAnimationFrame(ready);
      };
      requestAnimationFrame(ready);
    });
    """
}
