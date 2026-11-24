// Space and arrow keys on a clicked HTML media element showing the browser's
// own controls, matching Chrome and Firefox.
//
// Custom site players (YouTube, Vimeo) handle their own keys and are left
// untouched: only a focused `<video>` / `<audio>` showing native `controls`,
// outside fullscreen, where the page didn't already `preventDefault()` and no
// modifier keys are held.
//
// Off by default unless enabled in Settings › General.

enum VideoKeys {
    @MainActor static var on = false

    /// Disables the key listener immediately in pages already loaded.
    static let off = "window.__searchVideoKeysOff = true;"

    static let script = #"""
    (() => {
      window.__searchVideoKeysOff = false;
      if (window.__searchVideoKeys) return;
      window.__searchVideoKeys = true;
      window.addEventListener('keydown', (e) => {
        if (window.__searchVideoKeysOff || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
        const media = e.target;
        if (!(media instanceof HTMLMediaElement) || !media.controls) return;
        if (document.fullscreenElement || media.webkitDisplayingFullscreen) return;
        if (e.key === ' ' && !e.shiftKey) {
          if (media.paused || media.ended) media.play().catch(() => {}); else media.pause();
        } else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && !e.shiftKey && isFinite(media.duration)) {
          const to = media.currentTime + (e.key === 'ArrowRight' ? 5 : -5);
          media.currentTime = Math.max(0, Math.min(media.duration, to));
        } else return;
        e.preventDefault();
      });
    })();
    """#
}
