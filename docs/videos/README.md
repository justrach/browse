# browse demo

The 67-second walkthrough opens with the measured RAM comparison, then shows search, keyboard shortcuts, reading progress, and Codegraff in the real macOS app. The README's animated preview links to the full MP4.

| Shortcut | Action |
| --- | --- |
| ⌘L | Search, recent queries, and optional Google suggestions |
| ⌘K | Find an open tab |
| ⌘S | Hide or show the tabs |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌘] / ⌘[ | Forward / back within a tab's page history |

Scrolling fills the active tab to indicate reading progress. The enlarged strip in the video is a crop of the same live recording.

## Opening images and measurements

The opening compares **289 MiB for browse with 701 MiB for Chrome**, about **59% less RAM** with ten retained tabs in the [recorded synthetic workload](../performance.md). browse had four awake tabs and six asleep. This is one Mac and one workload, not a measured maximum tab capacity. The benchmark used build `8452b4d`; the footage uses the later build identified below.

The narration says lower memory pressure can *potentially* reduce energy spent swapping. Energy consumption and battery life have not been measured.

The two opening illustrations were made using the built-in ImageGen tool. They are concept art, not browser screenshots or quantitative charts:

- [RAM comparison image](ram-opening-v1.png) · [Exact prompt](ram-opening-prompt.txt)
- [Research image](research-opening-v1.png) · [Exact prompt](research-opening-prompt.txt)

## Chapters

| Time | Scene |
| --- | --- |
| 0:00 | Ten-tab RAM comparison |
| 0:08 | More room for research |
| 0:15 | ⌘L search and suggestions |
| 0:23 | ⌘K tab finder |
| 0:31 | Switching tabs |
| 0:37 | Page history |
| 0:44 | Reading progress while scrolling |
| 0:52 | Codegraff beside the page |
| 0:59 | ⌘S quiet mode |

## Recording notes

- Recorded from the development build at `110bd9d`, merged in PR #6; not a claim that all development changes are in the published 1.0.3 release.
- An isolated demo profile was used. No personal browsing history or account was recorded.
- The complete walkthrough and animated preview run at 1.5× speed. Voice pitch is preserved; subtitles and chapter times follow the faster playback.
- Native ScreenCaptureKit window capture, up to 60 frames per second. The export is 1920 × 1080 at 60 fps, with H.264 video, AAC narration, and optional English subtitles.
- Shortcuts ran through browse's keyboard handler. Page scrolling used WebKit's native smooth scrolling; the progress animation and sliding tab highlight are the app's own rendering.
- The AI shot shows the real Codegraff composer with the current page attached and a draft question; it does not show a submitted request or claim a completed answer.
- Animated keycaps and the enlarged tab strip are editorial overlays. The browser UI was not generated or recreated.
- Narration: Gemini 3.8 Flash TTS, Sulafat voice. [Transcript](transcript.txt) and [subtitles](browse-demo.srt).
- Public pages: [WebKit](https://en.wikipedia.org/wiki/WebKit), [Japan](https://en.wikipedia.org/wiki/Japan), and [Safari](https://en.wikipedia.org/wiki/Safari_(web_browser)). Wikipedia text is available under CC BY-SA 4.0; individual media licenses are on the linked Wikimedia Commons file pages.
- Raw footage, intermediate renders, and audio source files are kept out of Git. No API key is included.
