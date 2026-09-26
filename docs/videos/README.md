# browse demo

The narrated walkthrough shows keyboard shortcuts and reading progress in the real macOS app. The README's animated preview links to the full MP4.

| Shortcut | Action |
| --- | --- |
| ⌘S | Hide or show the tabs |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌘] / ⌘[ | Forward / back within a tab's page history |

Scrolling fills the active tab to indicate reading progress. The enlarged strip in the video is a crop of the same live recording.

## Recording notes

- Recorded from the development build at `110bd9d`, merged in PR #6; not a claim that all development changes are in the published 1.0.3 release.
- An isolated demo profile was used. No personal browsing history or account was recorded.
- Native ScreenCaptureKit window capture, up to 60 frames per second. The export is 1920 × 1080 at 60 fps, with H.264 video, AAC narration, and optional English subtitles.
- Shortcuts ran through browse's keyboard handler. Page scrolling used WebKit's native smooth scrolling; the progress animation and sliding tab highlight are the app's own rendering.
- Animated keycaps and the enlarged tab strip are editorial overlays. The browser UI was not generated or recreated.
- Narration: Gemini 3.8 Flash TTS, Sulafat voice. [Transcript](transcript.txt) and [subtitles](browse-demo.srt).
- Public pages: [WebKit](https://en.wikipedia.org/wiki/WebKit), [Japan](https://en.wikipedia.org/wiki/Japan), and [Safari](https://en.wikipedia.org/wiki/Safari_(web_browser)). Wikipedia text is available under CC BY-SA 4.0; individual media licenses are on the linked Wikimedia Commons file pages.
- Raw footage, intermediate renders, and audio source files are kept out of Git. No API key is included.
