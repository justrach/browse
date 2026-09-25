import WebKit

// Frames that belong to another site, set right on the page they sit in.
//
// WebKit, like every browser, paints an opaque backdrop behind a frame
// whose document's colour scheme differs from the frame element's: a dark
// page (color-scheme: dark) holding a document that says nothing about its
// scheme gets a white rectangle behind it. Google's "Sign in with Google"
// card is exactly that — a rounded dark card in a white box on ChatGPT and
// every other dark site. The fix is to give the frame element the scheme of
// what's in it — `color-scheme: light` in WebKit; `normal`, which Chrome takes
// for the same, leaves WebKit's box where it is (tried side by side). Here it's
// made for Google's sign-in frames only: those never declare a dark scheme, so
// matching them can only take the box away, where doing it to every frame
// could put one behind a frame that is dark on purpose.

enum Frames {
    static let script = """
    (() => {
      const signIn = /^https:\\/\\/accounts\\.google\\.com\\/gsi\\//;
      const fix = (frame) => {
        if (frame.tagName === 'IFRAME' && signIn.test(frame.src || '')) {
          frame.style.setProperty('color-scheme', 'light', 'important');
        }
      };
      const sweep = (node) => {
        if (node.nodeType !== 1) return;
        fix(node);
        if (node.querySelectorAll) node.querySelectorAll('iframe').forEach(fix);
      };
      new MutationObserver((changes) => {
        for (const change of changes) {
          if (change.type === 'attributes') fix(change.target);
          else change.addedNodes.forEach(sweep);
        }
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    })();
    """

    /// At the start of every document, in the browser's own world, so a page
    /// can't see it or undo it by replacing the observer.
    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
    }
}
