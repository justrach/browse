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
    /// Pure CSS rule instead of a subtree MutationObserver: zero JavaScript
    /// execution on DOM mutations across iframes (important for Speedometer
    /// and heavy React/SPA apps), while still eliminating the white backdrop
    /// behind Google's Sign-In card on dark pages.
    static let script = """
    (() => {
      if (document.getElementById('__browse_gsi_fix')) return;
      const s = document.createElement('style');
      s.id = '__browse_gsi_fix';
      s.textContent = 'iframe[src^="https://accounts.google.com/gsi/"]{color-scheme:light!important;}';
      (document.head || document.documentElement).appendChild(s);
    })();
    """

    /// At the start of every document, in the browser's own world.
    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
    }
}
