import Foundation

// Reading mode: the article, and nothing that was arranged around it.
//
// Mounted as a cloned non-destructive full-viewport overlay on `documentElement`
// rather than overwriting `document.body.innerHTML`: toggling Reading Mode off
// removes `#office-reader-root` and restores the exact live page immediately
// with scroll position, forms, and event listeners intact — no reload needed.

enum Reader {
    static let script = enterScript(theme: .auto, font: .serif, size: 18)

    static func enterScript(theme: Preferences.ReaderTheme, font: Preferences.ReaderFont, size: Int) -> String {
        let clampedSize = min(26, max(14, size))
        return """
        (function () {
          function prose(el) {
            var paragraphs = el.querySelectorAll('p');
            if (paragraphs.length < 2) return 0;
            var letters = 0;
            for (var i = 0; i < paragraphs.length; i++) {
              letters += (paragraphs[i].innerText || '').length;
            }
            if (letters < 400) return 0;
            // A rail of related links has plenty of text and nothing to read.
            var links = el.querySelectorAll('a').length;
            return letters / (1 + links * 14);
          }

          function best() {
            var candidates = document.querySelectorAll(
              'article, main, [role="main"], .post, .entry, .article, .content, #content, div, section'
            );
            var top = null, mark = 0;
            for (var i = 0; i < candidates.length; i++) {
              if (candidates[i].id === 'office-reader-root') continue;
              var score = prose(candidates[i]);
              if (score > mark) { mark = score; top = candidates[i]; }
            }
            return top;
          }

          var article = best();
          if (!article) return 'none';

          var oldRoot = document.getElementById('office-reader-root');
          if (oldRoot) oldRoot.remove();
          var oldStyle = document.getElementById('office-reader-style');
          if (oldStyle) oldStyle.remove();

          // Resolve live image URLs against the still-mounted article without mutating it.
          var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
                      'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
          var livePics = article.querySelectorAll('img');
          var resolvedSrcs = [];
          var resolvedSets = [];
          for (var i = 0; i < livePics.length; i++) {
            var picture = livePics[i];
            var real = picture.currentSrc || picture.getAttribute('src') || '';
            if (!real || real.indexOf('data:image') === 0 || picture.naturalWidth <= 2) {
              for (var k = 0; k < late.length; k++) {
                var kept = picture.getAttribute(late[k]);
                if (kept) { real = kept; break; }
              }
            }
            resolvedSrcs.push(real);
            resolvedSets.push(picture.getAttribute('data-srcset') || picture.getAttribute('srcset') || '');
          }

          var clone = article.cloneNode(true);
          var clonePics = clone.querySelectorAll('img');
          for (var i = 0; i < clonePics.length; i++) {
            clonePics[i].setAttribute('loading', 'eager');
            if (resolvedSrcs[i]) clonePics[i].setAttribute('src', resolvedSrcs[i]);
            if (resolvedSets[i]) clonePics[i].setAttribute('srcset', resolvedSets[i]);
          }

          var clutter = clone.querySelectorAll(
            'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
            '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
          );
          for (var c = 0; c < clutter.length; c++) clutter[c].remove();

          var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
          var frames = clone.querySelectorAll('iframe');
          for (var f = 0; f < frames.length; f++) {
            var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
            if (players.test(where)) {
              frames[f].setAttribute('src', where);
              frames[f].removeAttribute('height');
              frames[f].removeAttribute('width');
            } else {
              frames[f].remove();
            }
          }

          var keptImgs = clone.querySelectorAll('img');
          for (var g = 0; g < keptImgs.length; g++) {
            var src = keptImgs[g].getAttribute('src') || '';
            if (!src || src.indexOf('data:image') === 0) keptImgs[g].remove();
          }

          var heading = document.querySelector('h1');
          var title = (heading && heading.innerText.trim()) || document.title;
          var rawWords = (clone.textContent || '').trim().split(/\\s+/).filter(Boolean).length;
          var mins = Math.max(1, Math.round(rawWords / 225));

          var sheet = document.createElement('style');
          sheet.id = 'office-reader-style';
          sheet.textContent = [
            'html.office-reading,html.office-reading body{overflow:hidden !important}',
            '#office-reader-root{position:fixed;inset:0;z-index:2147483647;overflow-y:auto;-webkit-overflow-scrolling:touch;',
            '--r-bg:#fff;--r-fg:#171717;--r-muted:#737373;--r-code:#f5f5f5;--r-border:#e5e5e5;--r-link:#171717;',
            '--r-font:ui-serif,Georgia,"Times New Roman",serif;--r-size:\(clampedSize)px;',
            'background:var(--r-bg);color:var(--r-fg);margin:0;padding:0}',
            '@media (prefers-color-scheme:dark){#office-reader-root[data-theme="auto"]{',
            '--r-bg:#161618;--r-fg:#e8e8ea;--r-muted:#98989f;--r-code:#232327;--r-border:#303036;--r-link:#f4f4f6}}',
            '#office-reader-root[data-theme="light"]{--r-bg:#fff;--r-fg:#171717;--r-muted:#737373;--r-code:#f5f5f5;--r-border:#e5e5e5;--r-link:#171717}',
            '#office-reader-root[data-theme="sepia"]{--r-bg:#f7f1e3;--r-fg:#2c241b;--r-muted:#7a6c59;--r-code:#ede4d0;--r-border:#dfd3ba;--r-link:#3e2f1c}',
            '#office-reader-root[data-theme="dark"]{--r-bg:#161618;--r-fg:#e8e8ea;--r-muted:#98989f;--r-code:#232327;--r-border:#303036;--r-link:#f4f4f6}',
            '#office-reader-root[data-font="sans"]{--r-font:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}',
            '#office-reader-root[data-font="mono"]{--r-font:ui-monospace,"SF Mono",Menlo,monospace}',
            '#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;',
            'font:400 var(--r-size)/1.72 var(--r-font);color:var(--r-fg)}',
            '#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
            'margin:0 0 8px;letter-spacing:-0.01em;color:var(--r-fg)}',
            '#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:var(--r-muted);',
            'margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
            '#office-reader p{margin:0 0 1.35em}',
            '#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;',
            'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
            '#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
            '#office-reader figure{margin:1.8em 0}',
            '#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;color:var(--r-muted);margin-top:.6em}',
            '#office-reader a{color:var(--r-link);text-underline-offset:3px}',
            '#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;margin:2em 0 .6em;color:var(--r-fg)}',
            '#office-reader pre,#office-reader code{font-family:ui-monospace,monospace;font-size:0.86em}',
            '#office-reader pre{background:var(--r-code);padding:14px;border-radius:8px;overflow:auto}',
            '#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;border-left:2px solid var(--r-border);color:var(--r-muted)}'
          ].join('');

          var root = document.createElement('div');
          root.id = 'office-reader-root';
          root.setAttribute('data-theme', '\(theme.rawValue)');
          root.setAttribute('data-font', '\(font.rawValue)');

          var wrap = document.createElement('div');
          wrap.id = 'office-reader';
          wrap.appendChild(clone);

          var top = document.createElement('h1');
          top.textContent = title;
          var from = document.createElement('p');
          from.className = 'office-from';
          from.textContent = location.host.replace(/^www\\./, '') + ' · ' + mins + ' min read';

          wrap.insertBefore(from, wrap.firstChild);
          wrap.insertBefore(top, wrap.firstChild);
          root.appendChild(wrap);

          (document.head || document.documentElement).appendChild(sheet);
          document.documentElement.classList.add('office-reading');
          document.documentElement.appendChild(root);
          root.scrollTop = 0;
          return 'read';
        })();
        """
    }

    static func updateStyleScript(theme: Preferences.ReaderTheme, font: Preferences.ReaderFont, size: Int) -> String {
        let clampedSize = min(26, max(14, size))
        return """
        (function () {
          var root = document.getElementById('office-reader-root');
          if (!root) return false;
          root.setAttribute('data-theme', '\(theme.rawValue)');
          root.setAttribute('data-font', '\(font.rawValue)');
          root.style.setProperty('--r-size', '\(clampedSize)px');
          return true;
        })();
        """
    }

    static let exitScript = """
    (function () {
      document.documentElement.classList.remove('office-reading');
      var root = document.getElementById('office-reader-root');
      if (root) root.remove();
      var sheet = document.getElementById('office-reader-style');
      if (sheet) sheet.remove();
      return 'exited';
    })();
    """
}
