# Changelog

All notable changes to **browse** are documented here, newest first.

**Unreleased** tracks changes merged to `main` ahead of the next release. When a version ships via `./release.sh`, the **Unreleased** entries take the new version number and date, a concise summary is prepended to [NOTES.md](NOTES.md) for Settings and the in-app updater, and GitHub Actions publishes the signed DMG, ZIP, and `appcast.json`. Planned work lives in [ROADMAP.md](ROADMAP.md).

## Unreleased

### Fixed

- **On-demand `DevCapture` (`DevCapture.swift`, `Tab.swift`, `Browser.swift`, `AgentTools.swift`)**: Removed default `.page`-world `fetch`/`XMLHttpRequest`/`console` hooks from regular browsing tabs so page-world execution stays untouched; `console_logs` and `network_requests` now arm capture strictly on demand on inspected tabs and agent pages, using a `WeakMap` instead of `XMLHttpRequest` own properties and safe DOM/plain-object formatting.
- **Hardened `WebNotifications` (`WebNotifications.swift`)**: Made `Notification` inherit from `EventTarget`, removed the `window.__browseNotifInstalled` global, and moved the startup permission query into `Web.world` with zero `.page`-world startup `CustomEvent`.

## 1.14.0 — 25 November 2026

### Added

- **Site search shortcuts & `!bangs` (`SiteSearch.swift`, `Prefs.swift`, `Browser.swift`, `Settings.swift`)**: Added built-in `!gh`, `!yt`, `!mdn`, `!w`, `!hn`, `!r`, `!npm`, `!crates`, `!so`, `!maps`, `!g`, `!ddg`, `!kagi`, `!apple`, `!x`, and `!pkg` keywords plus customizable site-search templates in **Settings › General** resolving directly in the Omnibox (`⌘L`/`⌘T`) and Command Switcher (`⌘K`).
- **Nanolight companion URL scheme & launcher index (`BrowseScheme.swift`, `LauncherIndex.swift`, `Links.swift`, `Browser.swift`, `build.sh`)**: Registered the `browse://` URL scheme (`tab`, `space`, `open`, `search`, `ask`, `new-tab`, `private-tab`, `switcher`) and added a zero-secret debounced `launcher.json` snapshot of non-private tabs, Spaces, bookmarks, and shortcuts so Nanolight can search and route directly into `browse`.
- **Page capture & export (`PageExport.swift`, `AgentTools.swift`, `App.swift`, `SiteCard.swift`)**: Added **Copy Page as Markdown**, **Save Page as PDF…**, and **Capture Screenshot** (copy visible, save visible, and save full-page PNG off the main thread) to the File menu and Site Card.
- **Opt-in native cookie-banner blocking (`CookieShield.swift`, `Shield.swift`, `Prefs.swift`, `Settings.swift`, `Browser.swift`)**: Added **Settings › Privacy › Hide cookie banners** backed by a native `WKContentRuleList` blocking common third-party CMP scripts and exact-selector banners without runtime page JavaScript, respecting per-site shield pauses.
- **Per-site CSS Boosts & Force Dark Mode (`Curtain.swift`, `Hidden.swift`, `Browser.swift`, `SiteCard.swift`)**: Extended the per-site panel (`⇧⌘U`) and Site Card with **Force Dark Mode**, a document-start **Custom CSS** editor saved per host in `boosts.json`, and a **Draft with Codegraff** helper.
- **Global playing & muted tabs popover (`MediaPopover.swift`, `AsideBar.swift`, `Tab.swift`, `Browser.swift`)**: Upgraded background audio controls to surface playing and muted tabs across all Spaces in a single popover with play/pause, mute/unmute, Mute All, and cross-Space jump-to-tab.
- **DevTools agent inspection tools (`DevCapture.swift`, `Tab.swift`, `AgentTools.swift`)**: Added read-only `console_logs` and `network_requests` MCP tools powered by a passive page-world ring buffer (logging levels, uncaught errors, and `fetch`/`XHR` status/timings without cookies, auth headers, or bodies).
- **Tab Group → Codegraff multi-tab context (`TabGroups.swift`, `AgentComposer.swift`, `Browser.swift`)**: Added **Ask Codegraff about Group** to group context menus and group suggestions inside the composer `@` picker to attach every open tab in a group in one step.
- **Native on-device translation (`SelectionBar.swift`, `Browser.swift`, `App.swift`)**: Added a **Translate** action on the page selection pill on macOS 15+ backed by Apple's `Translation` presentation sheet (weak-linked for macOS 14 compatibility).

### Fixed

- **Split View slide transition race (`Stage.swift`, `App.swift`)**: Prevented an exiting single-pane `WebStage` from reclaiming `tab.web` mid-transition while entering Split View (`⌘D`), leaving both split panes intact on frame 0.

## 1.13.0 — 25 November 2026

### Improved

- **Codegraff streaming, composer, and agent tool latency (`MarkdownView.swift`, `Citations.swift`, `Agent.swift`, `AgentColumn.swift`, `AgentComposer.swift`, `AgentCards.swift`, `AgentHome.swift`, `AgentTools.swift`, `AgentTransport.swift`, `NanoComposerField.swift`)**:
  - Added incremental prefix-anchor caches (`MarkCache`, `MarkdownParser.StreamAnchor`), bounded `MathTex.inlineRich` and `MathParser.parse` caches, linear list prefix scans, and `Equatable` turn/block isolation so long streaming replies avoid $O(N^2)$ re-parsing and historical turn invalidations.
  - Guarded `NanoTextView.applyTypography`, deduplicated composer slash/mention scans, cached `DiffView` line diffs, `ChatRow` previews, `Model.label`, and `HarnessCache`, switched `Agent.run` from `usleep` polling to `terminationHandler`, made `AcpPipe.take` single-offset, fixed `read_pages` >6-sheet eviction while speeding up `settledIfLoading()` and offloading screenshot JPEG/PNG compression off `@MainActor`.
- **SwiftUI / AppKit 120 FPS render fast paths (`Design.swift`, `Stage.swift`, `Split.swift`, `TabOverview.swift`, `TabCycleHUD.swift`, `Side.swift`, `TabBar.swift`, `Fold.swift`, `WheelGlide.swift`)**:
  - Replaced `PageShimmerRim`'s continuous SwiftUI `AngularGradient` + `.drawingGroup()` with a lightweight WindowServer CoreAnimation conic layer (`ShimmerRimLayerView`), switched `PageProgressBar` to GPU `.scaleEffect`, guarded `BackdropShadowView`, `WebStage`, `SplitPaneSlot`, and `SplitHeaderView` updates, isolated `TabPreviewCache` per-tab slots (up to 4 concurrent snapshots) + memoized `SwitcherResultsCache` across hover/selection changes, replaced `SideBar`'s double `ViewThatFits` and idle row masks with single `ScrollView`, moved `TabBar` layout to single-pass $O(N+G)$ with `.clipped()`, guarded `Fold.follow()` WindowServer hits, and added 120 Hz `CAFrameRateRange` + cached probe to `WheelGlide`.
- **Launch, navigation IPC, favicons, disk writes & extension startup (`Tab.swift`, `Shield.swift`, `Icons.swift`, `Browser.swift`, `Store.swift`, `History.swift`, `Spaces.swift`, `Sleep.swift`, `ICloudSync.swift`, `Sync.swift`, `Prefs.swift`, `Extensions.swift`, `ExtensionShims.swift`, `ExtensionShimsScript.swift`, `ExtensionPopup.swift`, `ExtensionProxy.swift`, `WebNotifications.swift`)**:
  - Added per-controller `Shield.tune` attachment state and `Tab.arm` `ArmedSignature` + cached static `WKUserScript`s, `Web.safariVersion` caching, lazy sleeping-tab `WKWebViewConfiguration`, deferred `preloadSpaces` and sync JSON decodes, async `Favicons` directory index + `noDarkHosts` negative cache + shared `URLSession` + off-thread PNG compression, lock-free `Disk.write` turn pre-check, gated `Browser.select` `guess()`, and window-attach `Tab.wake()`.
  - Parallelized extension prep/loading and collapsed directory walks, fixed `>4 KB` `keyOf` 10 s broadcast stalls, moved `ExtensionPopup` sizing to `ResizeObserver` pushes, deduplicated `ExtensionProxy.sync`, and skipped redundant `"default"` notification query round-trips.
- **Daily UX polish (`TabGroups.swift`, `Side.swift`, `TabBar.swift`, `BrowserDelegates.swift`, `Reader.swift`, `Float.swift`, `SiteCard.swift`, `Find.swift`, `Shortcuts.swift`, `Bookmarks.swift`, `Recall.swift`, `Settings.swift`)**:
  - Added `UserGroupSection` sidebar drag/split parity, outside-click inline group rename dismissal, `target="_blank"` `userGroupID` inheritance, and group colour dots in **Add to Group**; upgraded Reading Mode scoring/H1 dedupe/comment stripping/tables/list CSS and dark typography; added inset scrubber + keyboard controls (`Space`/`←`/`→`/`M`/`Return`/`Esc`) to floating video; added bottom-edge above-field flip + conditional per-site Reset/Hidden rows to `SiteCard`; added select-all `FindField` + cross-tab Find refresh, clean `ShortcutStore` recording cancel, `BookmarkMenu` favicons + **Open All in New Tabs**, and missing-file status + clickable Downloads folder path in `DownloadsPanel`.

## 1.12.0 — 25 November 2026

### Added

- **`chrome.proxy` extension support (`ExtensionProxy.swift`, `ExtensionShims.swift`, `Extensions.swift`, `Spaces.swift`, `Tab.swift`)**: Parses `fixed_servers` (`singleProxy`, `proxyForHttp`, `proxyForHttps`, `fallbackProxy`, HTTP/HTTPS/SOCKS5, credentials, `<local>` and wildcard `bypassList` normalization) and `system`/`direct` configs into `Network.ProxyConfiguration` across Space and extension-enabled private `WKWebsiteDataStore` instances, while flagging unsupported modes (`pac_script`, `socks4`) cleanly.
- **Open-tab Web Notifications (`WebNotifications.swift`, `Tab.swift`, `Browser.swift`, `App.swift`, `Links.swift`)**: Bridges secure-origin `window.Notification` requests and banners to `UNUserNotificationCenter` using per-site prompts synced with **Settings › Privacy** (`PermissionSites`) and click activation back to the originating tab, leaving private tabs and insecure HTTP origins denied.
- **Universal macOS (`arm64` + `x86_64`) Intel Mac packaging (`build.sh`, `.github/workflows/release.yml`)**: Builds fat `arm64` + `x86_64` binaries (`lipo`) with universal `.dSYM` extraction automatically for `dmg`/`ship` releases and `SEARCH_UNIVERSAL=1` builds.

## 1.11.0 — 24 November 2026

### Added

- **Split View divider menu, Sync Scrolling & sidebar drag-to-split (`Split.swift`, `Side.swift`, `TabBar.swift`, `Session.swift`, `Tab.swift`)**: Added a right-click menu on the Split View divider, opt-in per-split **Sync Scrolling** (with loop-free echo detection and session persistence), and sidebar middle-band drag-and-drop onto another tab with a live 50/50 preview to create a split.
- **User Tab Groups & `chrome.tabGroups` (`TabGroup.swift`, `TabGroups.swift`, `Session.swift`, `Spaces.swift`, `Side.swift`, `TabBar.swift`, `ExtensionShims.swift`, `lean-proofs/Browse/UserTabGroups.lean`)**: Added collapsible coloured user tab groups per Space across Sidebar and Top Tabs with right-click creation, inline rename, Space movement, `chrome.tabGroups` extension API integration, and a verified Lean 4 formal partition/conservation proof (`Browse.UserTabGroups`).
- **Docked `chrome.sidePanel` & extension fixes (`ExtensionSidePanel.swift`, `ExtensionShims.swift`, `Extensions.swift`, `App.swift`, `Prefs.swift`)**: Added a resizable right-hand extension side panel (`SidePanelPages` / `SidePanelBeside`) with per-tab panel parking and private-tab protection; fixed Bitwarden `storage.onChanged` cross-view relay and hosted offscreen documents in an off-screen window; fixed Vimium C hybrid MV3 manifests by stripping legacy `scripts` when `service_worker` is declared.
- **Opt-in Always-Visible Address Bar (`#15`), Page-Tinted Title Bar (`#25`) & Smooth Mouse-Wheel Scrolling (`#Roadmap`) (`WheelGlide.swift`, `AsideBar.swift`, `App.swift`, `Tab.swift`, `Prefs.swift`, `Settings.swift`)**: Added opt-in toggles for an always-visible address bar in top-tab/folded modes, top-tab title bar page tinting, and `CADisplayLink` notched mouse-wheel smoothing.
- **Comet importer hardening (`Import.swift`)**: Added alternate profile folder lookup (`Comet/User Data`), Keychain storage fallbacks, and strict `0o700` temporary SQLite snapshot directory permissions.
- **Space and arrow keys for videos (`VideoKeys.swift`, `Prefs.swift`, `Settings.swift`)**: Added opt-in **Settings › General › Space and arrow keys control videos** so native HTML5 media elements with browser controls respond to `Space` (play/pause) and `←`/`→` (±5 s) without hijacking YouTube or custom players.
- **Links from pinned tabs open in a new tab (`Peek.swift`, `Prefs.swift`, `Settings.swift`, `Browser.swift`)**: Added opt-in **Settings › Tabs › Links from pinned tabs open in a new tab** (preserving same-page fragments and sign-in flows).
- **Stuck closed-tab WebContent guard (`Stuck.swift`, `Tab.swift`)**: Ends wedged spinning `com.apple.WebKit.WebContent` processes (> 80% CPU for 10 s after tab close/sleep with PID start-time verification and live/extension-page exclusions).

### Improved

- **Codegraff UX, queue recovery & upstream WS prewarm (`AgentTaskState.swift`, `AgentActivity.swift`, `AgentColumn.swift`, `AgentComposer.swift`, `AgentCards.swift`, `AgentContext.swift`, `AgentHome.swift`, `AgentFeedbackView.swift`, `Agent.swift`, `AsideBar.swift`, `Browser.swift`)**:
  - Replaced rotating idle flavor words in `AgentActivity` with real active tool/plan progress, added inline **Reconnect** and **Report problem** actions on quiet turns (`>= 20 s`), and kept explicit **Stop** / **Cancel** / **Review** / **Report** / **Settings…** / **Follow up** / **New chat** actions across working, waiting, interrupted, missing, and finished states (`#21`, `#22`).
  - Exposed `queueHeld` state and added explicit **Send next** (`resumeHeldQueue()`) and **Clear** (`clearQueued()`) controls in `QueuePanel` and `AgentTaskStateView` after stops/reconnects, plus a **Report preview** box in `AgentFeedbackView` and **Report problem** pairing on stopped/broken banners.
  - Preserved host domain visibility when page context is pinned (`Title · Pinned · host`), kept expand-editor accessible in narrow sidebars (`< 340 pt`), surfaced the `.` key hint on `AsideBar`'s `graff` pill, and removed the `GRAFF_CODEX_WS=off` workaround after `justrach/codegraff#1252`.
- **Faster launch Shield setup (`Shield.swift`, `Browser.swift`)**: Cached the built-in `office-shield` rule list by content digest instead of recompiling at every launch, and deferred compilation when ad blocking is disabled.
- **Extension popup sizing & standards-mode HTML shims (`ExtensionPopup.swift`, `Extensions.swift`, `ExtensionShims.swift`)**: Persisted bounded `[25...800, 25...600]` popup dimensions across launches, tracked full-lifetime growth/shrinkage with zero `MutationObserver`s, cleared saved sizes on uninstall, and placed `<script>` shims after BOM/doctype/`<html>` while ignoring `<header>`.
- **Navigation, Dock, Forms, Hover & Dvorak–QWERTY `⌘` polish (`Links.swift`, `App.swift`, `Fold.swift`, `Browser.swift`, `Forms.swift`, `KeyLayout.swift`, `Shortcuts.swift`, `Spaces.swift`)**: Added `Dvorak – QWERTY ⌘` shortcut resolution, captioned bare email field recognition, folded-edge hover suppression, Dock reopen/Window menu registration, recent awake pin navigation on `⌘W`, appearance-toned Space swatches, and fixed `agentRowsOrigin` drag-out coordinates in the sidebar.

### Fixed

- **Gmail / Google Workspace Shield exceptions (`tools/shield-lists/src/main.rs`, `Assets/Shield/`, `Shield.swift`)**: Restored EasyList `$generichide` `ignore-previous-rules` exceptions (`#38`) and preserved them inside `Shield.pruneSlowGlobalCosmetics` so global cosmetic selectors no longer hide Gmail, Calendar, Drive, Docs, or Meet elements.
- **Zero-warning Swift build & test harness (`ExtensionShims.swift`, `Links.swift`, `Float.swift`, `Bench.swift`, `Tab.swift`, `tests/markdown-latex/main.swift`)**: Replaced deprecated `NSSpeechSynthesizer` with `AVSpeechSynthesizer`, fixed MainActor/Sendable closure capture warnings, removed unused `WKProcessPool`, discarded `fcntl` results cleanly, and restored `tests/markdown-latex.sh` execution.
- **Mega-file modularization & source guardrails (`ExtensionShimsScript.swift`, `AgentTransport.swift`, `BrowserDelegates.swift`, `tests/ui-layout/check_sources.py`)**: Extracted the extension JS shim payload, ACP transport helpers, and WebKit navigation/download delegates into focused files alongside Guardrail #22.

## 1.10.1 — 24 November 2026

### Fixed

- **Release build type-checking (`TabCycleHUD.swift`)**: Split `TabCycleHUD` into small SwiftUI subviews (`card`, `thumbnail`, `sleepBadge`, `titleRow`, `footer`) so production `-c release -Xswiftc -Osize` builds compile cleanly without hitting the compiler type-check timeout.

## 1.10.0 — 24 November 2026

### Added

- **Add Image to Photos (`ImageMenu.swift`, `build.sh`, `Browse*.entitlements`)**: Right-click image menus now include **Add Image to Photos** under **Download Image** using `PHAssetCreationRequest` with add-only library permission (`NSPhotoLibraryAddUsageDescription` and `com.apple.security.personal-information.photos-library`), supporting `http:`/`https:`/`data:` and live `blob:` URLs.
- **Per-site permissions list & reset in Privacy (`Browser.swift`, `Settings.swift`)**: **Settings › Privacy** now lists saved per-origin Camera, Microphone, Location, and Notification decisions (with search filtering when > 4 entries and one-click **Reset** per entry).
- **Opt-in in-window video full screen (`WindowFullScreen.swift`, `Prefs.swift`, `Forms.swift`, `Tab.swift`, `Stage.swift`, `Browser.swift`, `App.swift`, `Settings.swift`)**: Added **Settings › General › Full-screen video fills this window** (off by default) so HTML5 video full screen fills the browser window without spawning a new WebKit Space.
- **Opt-in shared live pins across Spaces (`Prefs.swift`, `Spaces.swift`, `Settings.swift`)**: Added **Settings › Tabs › Use the same pinned tabs across spaces** (off by default) to carry live pinned tabs cleanly across Spaces that share sign-ins.
- **Native Web Inspector Dock / Undock (`Inspector.swift`, `App.swift`)**: Added **View › Dock / Undock Web Inspector** to toggle docked vs. separate-window mode on the native WebKit Web Inspector.

### Fixed

- **Full-screen Escape routing (`App.swift`)**: Pressing single `Esc` while the browser window is in macOS Full Screen now passes to the page first so dismissing site popups/dialogs doesn't exit Full Screen.
- **Document-bound favicons (`Icons.swift`)**: Verified the responding `document.URL` matches the requested page before caching declared icons so rapid navigations never attach another site's icon.
- **Tab rename unchanged-title guard (`Browser.swift`)**: Canceling/submitting **Rename Tab** without editing the page title leaves `tab.name` unset so future navigations continue updating the tab title.
- **Cross-Space PiP return (`Browser.swift`)**: Both macOS native PiP return (`_webViewFullscreenMayReturnToInline:`) and floating video `onReturn` now locate and switch to parked Spaces before selecting the source tab and activating the window.

### Improved

- **UX Polish Tiers 1–3 & upstream Search ports (`Loot.swift`, `Reader.swift`, `Stage.swift`, `TabBar.swift`, `Bookmarks.swift`, `BookmarksBar.swift`, `TabOverview.swift`, `Recall.swift`, `Spaces.swift`, `AsideBar.swift`, `Float.swift`, `AgentColumn.swift`, `Swipe.swift`, `ImageMenu.swift`)**:
  - **Live Downloads & Folded Progress**: Tracked in-progress `WKDownload.progress` transfers (excluding private tabs) with live byte counts, linear progress bars, Cancel, Resume, Retry (clearing partial resume data after file write errors), file sizes on completed items, a Search bar in **Downloads (`⇧⌘J`)**, and a circular progress button in `AsideBar` when the sidebar is folded.
  - **Dark/Sepia & Non-Destructive Reading Mode**: Mounted Reading Mode (`⇧⌘R`) via `#office-reader-root` over a cloned article with system Dark Mode, Light, Sepia, and Dark themes, Serif/Sans/Mono typography, text size controls, estimated reading time, an appearance popover on the `AsideBar` Reader badge, and zero-reload exit preserving page state and scroll position.
  - **Page Loading Progress & Stable Nav Menus**: Added a top 2pt accent loading bar (`PageProgressBar`), stabilized Back/Forward slots in `Helm` to eliminate horizontal shift, and added right-click / press-and-hold Back/Forward history menus (`⌘`-click opens in new tab).
  - **Bookmarks, Recently Closed & Spaces**: Added full search filtering to **Bookmarks** and the Bookmarks popover, dynamic `»` overflow menus and middle-click `"Open All"` on `BookmarksBar` folders, Recently Closed tabs inside `⌘K` Command Switcher and **History (`⌘Y`)**, **Move to Space** in `TabMenu`, and Space accent colors in `SpaceMenu`.
  - **Audio, Floating Video, Agent & WebKit Feel**: Surfaced active/background tab audio mute controls in folded `AsideBar`, made `Float` video progress scrubbable with mute/playback-speed (`1×`–`2×`) toggles, double-click return, and resize cursor, added **Retry** (`Ask again`) and **Copy / Edit in composer** actions on Agent turns, honored CSS `overscroll-behavior-x: none|contain` in `Swipe.probe`, added **Open Image in Split View**, and kept `Metrics.tabRowHold` (40pt) draggable window handle room in full top tab rows.
- **Less aggressive RAM management & Lean 4 formal proof (`Prefs.swift`, `Sleep.swift`, `Browser.swift`, `Settings.swift`, `Agent.swift`, `AgentTools.swift`, `lean-proofs/Browse/MemoryPolicy.lean`)**:
  - Added a **Relaxed** memory profile (`12` awake background tabs, `15 min` crowd sleep, `2 h` idle) alongside calmer **Balanced** (`6` awake, `5 min` crowd, `30 min` idle) and **Low RAM** (`3` awake, `2 min` crowd, `10 min` idle, `45 min` pinned) defaults, raised `URLCache` to `32 MB / 128 MB`, and kept `graff` + offscreen MCP sheets warm longer (`20 min` / `6` pages / `5 min` TTL).
  - Debounced macOS memory-pressure events (`60 s` warning cooldown, `15 s` critical cooldown), trimmed decoded covers and `TabPreviewCache` first before sleeping tabs, protected recently left tabs (`< 60 s` even on critical pressure) plus tabs pinned/mentioned in `graff` or active Agent tabs, and added live `awake · asleep` counters to **Settings › Tabs** — formally verified in `Browse.MemoryPolicy`.
- **Browser UX pass (`AsideBar.swift`, `SiteCard.swift`, `Tab.swift`, `TabOverview.swift`, `TabCycleHUD.swift`, `TabBar.swift`, `Side.swift`, `AgentColumn.swift`, `BookmarksBar.swift`, `Recall.swift`, `Find.swift`, `Omnibox.swift`, `SelectionBar.swift`, `Stage.swift`)**:
  - Eliminated `AsideBar` hover reflow with a fixed-slot copy button, added `Reload` and `Paste and Go` to its context menu, surfaced `UpdateChip` when the sidebar is folded, and added a one-click per-site ad blocker toggle to `SiteCard`.
  - Decoded sleeping tab snapshots lazily for `⌘K` / `⇧⌘\` / `⌃Tab` previews, fixed `⌘K` filtered result counts and `.ask` action labels, added a sliding window + overflow indicators + sleep badges to `⌃Tab`, and prevented right-click **Copy Address** / **Copy as Markdown Link** from switching tabs or waking sleeping pages.
  - Added `Sleep Tab` / `Wake Tab` tab menu actions, sleep dimming & tooltips, active sidebar footer states, balanced resize-cursor cleanup on `SideBar` / `AgentColumn` edges, unified frosted `BookmarksBar` styling with `⌘+click` / `⌘⇧+click` support in Bookmarks & History, `FindBar` clear + empty/missed chevron disabling, `⌥↩` new-tab navigation in `Omnibox`, `usesAgent` gating + hover pills in `SelectionBar`, and a cleaner `Trouble` error view.
- **Smoother 0.42s ease-in-out `⌘;` / `⌘S` panel slide curve (`Design.swift`, `App.swift`, `Browser.swift`, `Fold.swift`, `Stage.swift`)**:
  - Replaced the fast initial-jump curve on `⌘;` and `⌘S` panel slides with a calm, zero-overshoot 0.42s ease-in-out `cubic-bezier(0.36, 0.0, 0.22, 1.0)` curve (`Motion.panelSlide`, ~50 frames at 120 Hz) matched identically to `animateWindowFrame`, so both opening and closing glide smoothly without snapping away in the first 80ms, and skipped redundant per-frame `backPage()` timer churn in `StageView.layout()`.

## 1.9.6 — 23 November 2026

### Improved

- **Onboarding UX & Lean 4 formal verification (`Welcome.swift`, `WelcomeResearch.swift`, `App.swift`, `lean-proofs/Browse/OnboardingFlow.lean`)**:
  - Persisted `prefs.welcomed = true` on `Esc` dismissal so first-time users who press `Esc` are never trapped in a repeat onboarding loop on next launch, and added a top `DragStrip` band so the window stays draggable throughout setup.
  - Moved Step 3 browser detection off the main thread (`scanSources()`), surfaced macOS 27 Full Disk Access locks up front, fixed non-Chromium `wantsSignIns` button enablement, and kept failed/denied Keychain imports retryable (`"Try again"`) instead of locking the button out.
  - Added an inline **Search engine** picker & live tinted floating-card Sidebar preview on Step 4, a **"Check again"** re-scan button on Step 2, clickable starter-prompt presets gated on `graff` actually being installed + live `didBecomeActive` default-browser status refresh on Step 5, removed the redundant `"Skip this step"` footer button, and proved all onboarding invariants in Lean 4 (`Browse.OnboardingFlow`).

### Fixed

- **Single-reflow 120 FPS `⌘;` Agent & Sidebar slide on heavy pages like X/Twitter (`Stage.swift`, `Tab.swift`, `AgentColumn.swift`, `Browser.swift`, `App.swift`, `lean-proofs/Browse/ScrollFastPath.lean`)**:
  - Added single-reflow GPU slide lockstep (`StageView.beginSlide(deltaWidth:)` / `pinnedSlideWidth`): pins the inner `WKWebView` ONCE to its exact post-slide width at `t = 0` while `StageView`'s rounded GPU mask glides at 120 FPS — eliminating 30× per-frame DOM/ResizeObserver reflow storms on X/Twitter and heavy feeds while preserving zero post-slide jump.
  - Replaced `@State var windowWidth` (which triggered 30× full `ContentView` + `SideBar` re-renders during window widening) with a threshold-only `narrowForAgent` boolean suppressed during `animatingWindowForAgent`.
  - Replaced `AgentColumn`'s offscreen SwiftUI `.shadow(...)` blur with O(1) GPU `BackdropShadowView` (`CALayer.shadowPath` + opaque occlusion) and kept `AgentColumn` warm after first open so repeated `⌘;` toggles glide via a pure GPU offset transform without recreating `NanoTextView` or chat turns — formally verified in `Browse.ScrollFastPath`.
- **Zero-delay lockstep Agent & Sidebar slide and edge-drag (`App.swift`, `AgentColumn.swift`, `lean-proofs/Browse/ScrollFastPath.lean`)**:
  - Removed the deferred 240ms/260ms `@State` room snap (`room`/`agentRoom`) and bound `stage` and `BookmarksBar` directly to `chrome` and `agentTrailing` so the webpage card and sidebars move together from frame 0 with zero post-slide jump and zero 1-frame drag lag.
  - Moved `AgentColumn`'s `.transition(.move(edge: .trailing))` out of a full-window-width `HStack` into a `.topTrailing` `ZStack` (translating by `prefs.agentWidth` instead of `windowWidth`) and gave docked `AgentColumn` zero redundant leading gap so the 6pt gutter between the page card and `graff` stays rock-solid on every single frame — formally verified in `Browse.ScrollFastPath`.

## 1.9.5 — 23 November 2026

### Fixed

- **Silky 120 FPS Agent & Sidebar slide and edge-drag resizing (`AgentColumn.swift`, `Side.swift`, `Tab.swift`, `Prefs.swift`, `App.swift`, `lean-proofs/Browse/ScrollFastPath.lean`)**:
  - Wired real WebKit async live-resize (`beginLiveResize()` / `endLiveResize()` invoking `StageView.startLiveResize()` → `viewWillStartLiveResize()` + `backPage()`) into `AgentColumn` and `SideBar` edge drags and open/close slides so WebKit no longer blocks the main thread on synchronous `DidUpdateGeometry` IPC.
  - Deferred `UserDefaults` writes during active drags (`isDraggingAgentWidth` / `isDraggingSideWidth`, committing once on mouse-up), suppressed spring interpolation and mid-drag `floatingAgentDrawer` flips during live drag, and replaced blocking `window.setFrame(..., animate: true)` with non-blocking `NSAnimationContext` + `window.animator().setFrame(...)` so the window and Agent card glide together at 120 FPS.

## 1.9.4 — 23 November 2026

### Fixed

- **Engine-level GPU compositing, opaque blur occlusion, and zero-mid-scroll `ScrollRelay` (`FrameRate.swift`, `Stage.swift`, `Tab.swift`, `Prefs.swift`, `lean-proofs/Browse/ScrollFastPath.lean`)**:
  - Enabled WebKit's `AcceleratedCompositingForFixedPositionEnabled` on every tab so sticky/fixed headers and navbars (GitHub, X, Notion, Linear, Reddit, docs) scroll on WebKit's GPU `ScrollingThread` instead of CPU main-thread repaints.
  - Added an opaque inner `CALayer` occlusion backing inside `BackdropShadowView` so macOS WindowServer skips behind-window `NSVisualEffectView` Gaussian blur for ~98% of the `WKWebView` viewport during 120 Hz scrolling.
  - Converted `ScrollRelay` to trailing-edge debounce + native `scrollend` (and gated injection on `prefs.showsReading`) so active scroll bursts trigger strictly zero `scrollHeight` layout reads, zero IPC, and zero SwiftUI `ReadingFill` redraws — formally proved in `Browse.ScrollFastPath`.

## 1.9.3 — 23 November 2026

### Fixed

- **Universal 120 FPS scrolling across GitHub and every website (`StatusLine.swift`, `Swipe.swift`, `AutoScroll.swift`, `SelectionBar.swift`, `Forms.swift`, `Tab.swift`, `Stage.swift`, `lean-proofs/Browse/ScrollFastPath.lean`)**:
  - Filtered synthetic scroll-induced `mouseover` events in `HoveredLink` when the pointer coordinates `(clientX, clientY)` have not moved — eliminating per-frame `LinkBubble` IPC & SwiftUI redraws while scrolling past links on GitHub, HN, Reddit, and X.
  - Eliminated ALL permanent `wheel` listeners and idle capture `scroll` listeners across `Swipe` (replaced per-frame JS listeners with an on-demand `Swipe.probe` invoked only on horizontal swipes), `AutoScroll` (dynamic attach/detach), `SelectionBar` (attached only while a selection pill is shown), and `Forms` (attached only while an autofill popup is anchored), keeping WebKit's GPU `ScrollingThread` completely off the main thread.
  - Throttled `ScrollRelay` reading-progress IPC to 240 ms / >= 2% delta and switched `FramedPageBackdrop` to an explicit `CALayer.shadowPath` for O(1) GPU shadow compositing — formally verified in Lean 4 (`Browse.ScrollFastPath`).
- **Expanded Lean 4 formal proof suite to 12 kernel-verified invariants (`lean-proofs/Browse/`, `tests/ui-layout/check_sources.py`)**: upgraded `Browse.ScrollFastPath` to a full inductive dynamic-listener lifecycle & hysteresis proof, and added `Browse.AgentTabGroup` (band partition ordering, clear isolation, pin promotion, child inheritance), `Browse.LinkModifiers` (`⌘+click` foreground / `⌘⇧+click` background consistency across normal and `target="_blank"` links), and `Browse.UpdatePolicy` (2-hour cadence, monotonic upgrades, SHA-256 + Team ID signing gate, per-build snooze invalidation), each backed by automated Swift-to-Lean CI guardrails.

## 1.9.2 — 23 November 2026

### Added

- **2-hour automatic update checks & quiet in-chrome Update Banner (`Updater.swift`, `Side.swift`, `TabBar.swift`, `Settings.swift`, `App.swift`)**: `browse` now checks for updates every 2 hours (and on wake/app activation when >= 2 hours have elapsed), adds **Check for Updates…** to the app menu, and shows a sleek frosted **Relaunch** / **Install** card in the sidebar (and compact capsule in Top Tabs) whenever a new version is ready, with one-click snooze.

### Fixed

- **Eliminated `⌘K` Command Switcher hover/scroll shaking (`TabOverview.swift`, `Browser.swift`, `App.swift`)**: decoupled keyboard scrolling (`keyboardScrollTick`) from mouse hover so hovering rows never triggers a `ScrollViewReader.scrollTo(anchor: .center)` feedback loop, reserved fixed space for the row close button, and removed preview card teardown (`.id(tab.id)`) so switching rows is completely steady and instantaneous.
- **Eliminated hover layout reflow & Escape-key modal traps across History, Downloads, Passwords, and Tab Overview (`TabOverview.swift`, `Recall.swift`, `Passwords.swift`, `TabCycleHUD.swift`, `App.swift`, `lean-proofs/Browse/HoverStability.lean`, `lean-proofs/Browse/EscapeTermination.lean`)**:
  - Replaced height/width-shifting `if hovering { ... }` button insertions in History, Downloads, Passwords, and `⇧⌘\` Tab Overview cards with fixed-slot opacity controls and removed card/HUD scale wobble and `⇧⌘\` `scrollTo(anchor: .center)` bounce — formally verified in Lean 4 (`Browse.HoverStability`).
  - Added Escape dismissal for `Welcome…` and the Bookmarks popover, made Escape clear History's search query before closing History, and guarded the `.` quick-agent shortcut against active modal overlays — formally proved to reach a clean page from every state in Lean 4 (`Browse.EscapeTermination`).

## 1.9.1 — 23 November 2026

### Added

- **Dedicated Agent Tab Group (`Tab.swift`, `Session.swift`, `Browser.swift`, `Side.swift`, `TabBar.swift`, `AgentTools.swift`, `AgentColumn.swift`, `TabOverview.swift`)**: tabs opened by the agentic browser (MCP `open_tab` / `show`, Follow, agent citations, and links clicked from Agent replies) now automatically land in their own collapsible, accent-tinted **Agent** tab group — cleanly separated from your personal `Today` tabs in both the Sidebar and Top Tab Bar, with a one-click **Clear** button, right-click **Move to My Tabs** / **Move to Agent Group**, session persistence across restarts, and an `Agent` badge in `⌘K` and `⇧⌘\`.

### Changed

- **⌘+click opens links in a new foreground tab (`Browser.swift`)**: `⌘+click` on any link now opens it in a new tab and switches straight to it (`⌘⇧+click` opens in the background).

## 1.9.0 — 23 November 2026

### Added

- **Dia inline `/skills`, `@history` mentions & local Personal Memory (`AgentSkills.swift`, `Agent.swift`, `AgentComposer.swift`, `NanoComposerField.swift`, `AgentColumn.swift`, `Prefs.swift`)**:
  - Added built-in Dia `/skills` (`/summarize`, `/factcheck`, `/explain`, `/compare`, `/reply`, `/extract`, `/translate`) plus automatic `/slug` registration for every saved custom task in `AgentTasks` — invocable directly in the composer `/` menu or inside the `⌘K` Command Switcher (`Ask graff` / `/skill`).
  - Extended `@` mentions in the composer to search and attach recently visited history pages (`@history` + fuzzy recent matches) alongside open tabs, and added local **Personal memory** in Settings › Agent (stored strictly on your Mac, injected once per chat).
- **Dia YouTube Video Timestamp Chat (`AgentSkills.swift`, `Agent.swift`, `MarkdownView.swift`, `AgentColumn.swift`, `Tab.swift`)**: automatically extracts YouTube video metadata, current playback timestamp `[MM:SS]`, and caption transcripts into page context, and turns `[MM:SS]` / `[H:MM:SS]` timestamps in agent replies into clickable links that seek the active `<video>` in place without reloading.
- **Dia Floating Selection Action Pill (`SelectionBar.swift`, `Tab.swift`, `Browser.swift`, `App.swift`, `Prefs.swift`)**: highlighting text on any page displays a quiet frosted capsule (`Ask`, `Explain`, `Rewrite` inside editable fields like Gmail compose or X reply boxes, and `Copy`) using passive `mouseup`/`keyup` listeners with zero scroll overhead (toggleable in Settings › Agent).
- **Visual `⌃Tab` MRU Tab Switcher with Live Previews & Arc-style Auto-Archive (`TabCycleHUD.swift`, `Browser.swift`, `App.swift`, `Sleep.swift`, `Settings.swift`, `Prefs.swift`)**: holding `⌃Tab` / `⌃⇧Tab` displays a centered frosted MRU tab switcher with live cached page thumbnails (releasing `⌃` commits the switch; `Esc` cancels), and Settings › Tabs now includes an optional **Auto-archive unpinned tabs** setting (`Never` / `12h` / `24h` / `7d`, recoverable anytime via `⌘⇧T` or History).

### Fixed

- **Strict modal overlay mutual exclusion (`Browser.swift`, `App.swift`, `lean-proofs/Browse/OverlayMutex.lean`)**: opening any full-window overlay (`⌘K`, `⇧⌘\`, `⌘Y`, `⇧⌘J`, `⌘,`, `⌥⌘B`, `⌘/`, Passwords, Import, Hidden-on-site, `⌃Tab`, Welcome, or `⌘L`) now atomically dismisses any other active overlay so two overlays (such as `⌘K` and `⌘Y`) can never stack on screen — formally proved for all shortcut sequences in Lean 4 (`Browse.OverlayMutex`).

## 1.8.8 — 23 November 2026

### Added

- **Zero-warm-time Swift Warm Agent Engine & full ACP lineup (`AgentEngine.swift`, `Agent.swift`, `AgentColumn.swift`, `AgentComposer.swift`, `ProviderMark.swift`, `Prefs.swift`)**:
  - Auto-discovers native ACP agent CLIs installed on your Mac — **Codegraff (`graff acp`)**, **Antigravity (`agy acp`)**, **OpenCode (`opencode acp`)**, **Gemini CLI (`gemini --acp`)**, **Grok (`grok --no-auto-update agent --no-leader stdio`)**, **Devin (`devin acp`)**, **Hermes (`hermes acp`)**, and **Pi (`pi-acp`)** — with `browse`'s local MCP browser tools attached to every backend.
  - Eliminates agent warm times with a one-shot cached login-shell PATH & binary table, atomic on-disk model catalog persistence (also seeding from `~/.harness/model-catalogs/` when available for <1 ms instant model lists), launch-time background pre-warming, a multi-backend warm worker pool (0 ms switches between Codegraff ↔ Antigravity ↔ OpenCode, 10 ms warm `session/new` on New Chat), and 6 ms live in-session `/model` switching in Codegraff.

### Fixed

- **Universal Shield cosmetic safety — fixes blank Gmail emails and broken web apps across all sites (`Shield.swift`, `lean-proofs/Browse/ShieldFilter.lean`)**: structurally hardened global EasyList cosmetic filtering (`shield-cosmetic-v5`) to drop short/ambiguous minified-class-colliding selectors (like `.ads`, `.ad10`, `.adHz`, `.ad_0`) and rules with `unless-domain` breakage history, keeping 100% of all 106k+ network ad/tracker rules, 100% of domain-scoped cosmetic rules, and only fast, explicit >=10-char ad-network/ad-slot global selectors (~1,800 vs ~14,000) — formally verified in Lean 4.
- **X.com 120 FPS scrolling performance (`Forms.swift`, `Shield.swift`, `Design.swift`)**: stopped `FormRelay`'s `MutationObserver` from reading `liveInputs.length` synchronously on every virtualized timeline DOM mutation (which forced WebKit to re-walk the entire 15,000-node DOM before every scroll paint), exempted `*x.com` / `*twitter.com` from the 13,485 generic global blog cosmetic CSS rules in `Shield` while keeping all network ad/tracker blocking active, and replaced `PageShimmerRim`'s live full-window Gaussian `.blur(radius: 3.5)` over `WKWebView` with a GPU-cheap dual-stroke rim.
- **Full Screen Agent sidebar symmetry & desktop viewport preservation (`App.swift`, `AgentColumn.swift`, `AgentComposer.swift`, `Design.swift`)**: strictly bounded `AgentColumn`'s inner card width (`prefs.agentWidth - Split.gap * 2`) and enabled matching 10pt squircle framing across all Full Screen modes so the webpage card and Agent card keep a clean 6pt pure-black bezel and center gap on all four sides; prevented the composer model chip from collapsing to a single letter at narrow widths; and smoothly expanded windowed frames (or auto-floated the Agent drawer on narrow half-screen windows) when opening the Agent sidebar so pages like Gmail and X.com keep their desktop layout instead of being squeezed to mobile width.

## 1.8.7 — 23 November 2026

### Added

- **Unified `⌘K` Command Switcher — open tabs, sites, and web search together (`Browser.swift`, `TabOverview.swift`)**: typing in `⌘K` now surfaces direct URLs, matching bookmarks & visited sites (prioritizing exact visited host labels like `apple` → `apple.com`), and web search with your configured engine both below matching open tabs (deduplicated against open tabs, with a right-side action preview pane) and as a full search/launcher view when no open tabs match — all navigable with `↑`/`↓`, `↩` (switch/open), and `⌘D` (open in Split View).
- **Auto-hiding Full Screen top panel with pure black bezel canvas (`App.swift`, `Fold.swift`, `AsideBar.swift`, `Side.swift`, `Split.swift`, `Browser.swift`)**: entering macOS Full Screen switches the surrounding frame canvas to pure `#000000` black (blending seamlessly into the macOS menu bar and physical display bezel, with dark chrome on the peeking top bar, sidebar, and Split View headers) and frees up the 44pt top panel (`AsideBar` / `TabBar`) into a uniform 6pt top bezel with a single centered reveal handle (reclaiming 38pt of vertical screen space). Hovering the top edge or clicking the centered handle smoothly slides the floating top bar down over the page without WebKit reflow.

## 1.8.6 — 23 November 2026

### Fixed

- **Passkey sign-in on Apple Developer / Apple Account / iCloud (`Passkeys.swift`)**: implemented the WebAuthn `largeBlob` extension (`read`, `write`, and `support`, sealed over the existing one-time ECDH P-256 + HKDF-SHA256 + AES-GCM bridge and advertised via `extension:largeBlob` in `PublicKeyCredential.getClientCapabilities()`). Apple's `idmsa.apple.com` sign-in requires `largeBlob.blob` (`extensionData`) on passkey assertions and previously rejected otherwise-valid assertions with *"Your browser needs to be updated to support signing in with a passkey."*
- **Eliminated bright corner bleed artifacts on rounded page cards (`App.swift`, `Stage.swift`, `AgentColumn.swift`)**: replaced the full-size `Palette.ground` backdrop behind `StageView` with `FramedPageBackdrop`, which insets the shadow-casting backdrop by `1pt` and matches `darkCanvas` whenever a live `WKWebView` is displayed — preventing subpixel misalignment between SwiftUI's `RoundedRectangle` and CoreAnimation's `CALayer.cornerCurve = .continuous` from bleeding white/light crescent fringes around the four corners on dark pages. Also clipped `PageOverlays` to the card corner radius and removed redundant double-clipping in `AgentColumn`.

## 1.8.5 — 22 November 2026

### Added

- **Image pasting, drag-and-drop, and photo attach in `graff` (`Agent.swift`, `NanoComposerField.swift`, `AgentComposer.swift`, `AgentColumn.swift`)**: paste screenshots or copied images (`⌘V`), drag image files onto the composer, or click the photo button to attach up to 6 images (`56×56` removable composer thumbnails + `112×80` chat thumbnails), sent natively as ACP `image` vision blocks (including image-only prompts).
- **Fast & Ultra Fast speed modes (`Agent.swift`, `AgentColumn.swift`, `AgentComposer.swift`, `NanoComposerField.swift`, `Prefs.swift`)**: added NanoHarness-style `SPEED` selector (`Standard` | `Fast` | `Ultra Fast`) inside the Model Picker popover for supported Codex / ChatGPT models (e.g. `gpt-6.2-sol`, `gpt-6.2-astra`), live lightning status badge on the model chip, persistent preference, and `/fast` + `/ultrafast` slash commands.

### Performance

- **Core main-thread & data-structure optimizations + Lean 4 formal proofs (`lean-proofs/`, `History.swift`, `Bookmarks.swift`, `Browser.swift`, `Shortcuts.swift`)**:
  - Replaced `History.recent()`'s O(N log N) full-history sort + 10k `URL` allocation with an O(N) top-8 partial selection (**~48× faster**, dropping from ~9.5 ms to ~0.20 ms on 10k visits), preserved `searched` / `recentCache` on non-top-8 `retitle()`, gated `Browser.objectWillChange` on actual top-8 changes, and precomputed `frecency` once in `History.save()` (**~3.8× faster**).
  - Pre-indexed `Bookmarks` into a flat cache + O(1) `contains(url)` set with ASCII UTF-8 byte-level top-K matching for instant Omnibox typing over large imported bookmark libraries.
  - Added an O(1) zero-allocation fast path to `MenuKeySanitizer` so 120–240 Hz `NSApplication.didUpdateNotification` events never re-walk the `Edit` menu.
  - Added zero-dependency **Lean 4.36 formal proofs** (`lean-proofs/`, `tests/lean-proofs.sh`) machine-verifying `TopKSelection`, `ShieldFilter`, `OmniboxRank`, `VaultPolicy`, and `PageTintDark` with zero `sorry`s.
- **Faster X / Twitter & heavy SPA scrolling (`Shield.swift`, `Forms.swift`, `Swipe.swift`, `StatusLine.swift`, `Tab.swift`)**: pruned ~489 unindexed global attribute/combinator cosmetic CSS rules (`[class^=...]`, `[data-testid^=...]`, `[href^=...]`) from the compiled Shield cosmetic list (`shield-cosmetic-v2`), replaced full-DOM `querySelectorAll('input[type="password"]')` scans in `FormRelay.script` with O(1)-collection `liveInputs` checks, eliminated synchronous `scrollWidth`/`clientWidth` layout flushes on non-scrollable divs in `Swipe.swift`, moved `StatusLine.swift` hover onto light-DOM `closest()` + `requestAnimationFrame` coalescing, and deduplicated `Tab` KVO updates.

### Fixed

- **Dark Mode window chrome staying Dark Mode on dark SPAs (`Design.swift`)**: `PageTint` no longer flips a Dark Mode window frame and top bar into bright white `.aqua` chrome when a site's unpainted WebKit `underPageBackgroundColor` defaults to `#FFFFFF` or specifies a light-only `theme-color`.

## 1.8.4 — 22 November 2026

### Fixed

- **Reliable `⌘L` focus & full URL selection (`Omnibox.swift`, `Browser.swift`, `Shortcuts.swift`)**: marked `⌘L` (`Open Address…`) as `alwaysOurs` so websites can never swallow it, added `FocusableAddressField` (`viewDidMoveToWindow`) with retry-safe focus & full-text selection so mounting the Omnibox never drops focus or leaves the URL unselected, cleared stale autocomplete endings on `edit()`, and dismissed blocking overlays (`Settings`, `Find`, `Tab Overview`, `Peek`) before focusing.

## 1.8.3 — 22 November 2026

### Added

- **Single-letter visited domain autocomplete (`x` → `x.com`)**: typing a single character in the Omnibox now inline-completes to visited or bookmarked sites whose host starts with that letter (e.g. typing `x` + `↩` goes straight to `x.com`), with exact host-label matches decisively outranking longer prefixes and visited host matches ranking ahead of noisy bookmark title/path substrings.

### Security

- **Hardened macOS Keychain password vault (`Vault.swift`, `Import.swift`, `SafariImport.swift`, `Passwords.swift`)**: stores newly saved and imported passwords with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, fails closed on `LocalAuthentication` errors (only bypassing if the Mac truly has `passcodeNotSet`), locks temporary browser-import SQLite/export directories to owner-only `0o700` permissions with zero-overwrite cleanup on teardown, and tightens clipboard auto-clear to 45 seconds.

## 1.8.2 — 22 November 2026

### Added

- **Redesigned 5-step onboarding tour (`Welcome.swift`, `WelcomeResearch.swift`)**: live miniature preview of the unified Arc/Dia frosted glass frame (`graff` card, Dia active-tab badge, and `@`-tab mention chip), live `System / Light / Dark` appearance + layout + page-tint picker, macOS 27 Full Disk Access `+` guidance during browser import, and updated shortcut cards (`⌘L`, `⌘K`, `⇧⌘\`, `⌘;`).
- **Automated UI layout & artifact regression test suite (`tests/ui-layout.sh`)**: headless AppKit/SwiftUI `NSHostingView` geometry assertions plus source guardrails running on every CI build to prevent vertically-wrapped pills, overflowing palettes, narrow-header collisions, clipped Settings descriptions, and ScrollView `.mask` 120 FPS regressions.

### Fixed

- **Agent `⌘;` / `⇧⌘;` supersedes all other `⌘;` handlers**: added `MenuKeySanitizer` to strip macOS's built-in `Edit › Spelling and Grammar` shortcuts (`⌘;` Check Document Now and `⌘:` / `⇧⌘;` Show Spelling and Grammar), elevated `⌘;` / `⇧⌘;` to top priority in `ContentView.take(_:)`, and intercepted `performKeyEquivalent(with:)` in `PageView` and `NanoTextView` so web pages, editors, extensions, and spellcheck can no longer steal `⌘;`.
- **Auto-register `browse` in System Settings › Full Disk Access**: when a locked browser is detected during import or when opening Full Disk Access settings, `browse` triggers macOS's `SystemPolicyAllFiles` registration so `browse` appears directly in the Full Disk Access toggle list instead of requiring manual `+` addition.
- Locked `Pill`, `Quick`, and onboarding `Big` buttons to `.lineLimit(1).fixedSize()` so capsule controls never wrap into vertical single-letter columns, stacked Settings › Tabs › Memory profile cleanly above `Sleep now`, and removed the 3-line truncation cap on Settings `Line` descriptions.

## 1.8.1 — 22 November 2026

### Added

- **Smarter top address bar**: clickable favicon/shield popover opening `SiteCard` (with paused-shield indicator dot), clickable Zoom reset pill (`125%`), active Reading Mode badge, and one-click `⇧⌘\` Tab Overview button beside Split View.
- **Smarter Omnibox (`⌘L` / `⌘T`)**: surfaces matching saved Bookmarks with star indicators, shows cached favicons on visited and bookmark rows, and badges URLs already open in another tab.
- **Upgraded Find on Page (`⌘F`)**: frosted glass capsule with a live match counter (`3 / 12` / `0 / 0`) and `⇧↩` previous-match stepping.
- **Little-Arc Peek**: integrated `38pt` header bar on Shift-click Peek panels with Back/Forward/Reload, favicon + title/host (click to copy), Copy Link, Open in Split View, Expand to Tab, and Close.
- **Cross-Space Tab Switcher & Downloads indicator**: `⌘K` and `⇧⌘\` search and jump across all Spaces with tinted Space badges, and the sidebar footer displays a live Downloads button with an active download pulse dot.

### Fixed

- Unified remaining `Codegraff` / `Search` copy to `graff` / `browse` across context menus, composer, Agent home, and Settings › Agent, and added the `+` button instructions to the macOS 27 Full Disk Access prompt.

## 1.8.0 — 22 November 2026

### Added

- **Arc & Dia browser chrome**: unified frosted glass window canvas with floating `10pt` squircle webpage and `graff` cards, dynamic Back/Forward/Reload navigation buttons, inline hover Copy Link inside the URL pill, Arc-style `Today` divider with hover `Clear`, deferred floating New Tab Command Bar (`⌘T` / `+ New Tab`), and Dia-style `@`-tab mentions inside the `graff` composer.
- **`⌘K` Tab Switcher with live sneak-peek & `⇧⌘\` Visual Tab Overview Grid**: upgraded `⌘K` into a floating frosted command palette with fuzzy multi-token search, recency ordering, real favicons/status badges, `⌘D` open-in-Split, `⌘⌫` quick-close, and a live WebKit snapshot sneak-peek pane; added `⇧⌘\` (`Tab Overview`) for a full-window visual card overview grid with real-time filtering.
- **Cross-section Settings Search (`⌘F`)**: native macOS-style Search field in the Settings rail indexing all 11 Settings sections plus every keyboard shortcut dynamically, with grouped results and instant jump-to-page.
- **`graff` branding & local Harness MCP**: replaced corporate `Codegraff` chrome labels with `graff` + the vector Harness mark, added a quiet Dia-style active-tab connection badge in the sidebar, and automatically wired the local Harness engine MCP server when installed.

### Performance

- **120 FPS Agent sidebar slide & chat scrolling**: deferred WebKit layout reflow across single and Split View panes during sidebar open/close, replaced full-`ScrollView` `.mask(...)` compositing with a lightweight top fade overlay, and added an LRU parse cache to `MarkdownParser`.

### Fixed

- Updated macOS 27 Chrome import flow to promote Full Disk Access when macOS locks Chromium folders with `com.apple.macl`, report permission-denied errors accurately on folder selection, and surface undecrypted password counts.
- Aligned the top bar cleanly across full window width so webpage and `graff` cards share flush top/bottom edges, prevented the model picker label from collapsing at narrow widths, and kept the `6pt` middle gutter spotless at rest.

## 1.7.1 — 22 November 2026

### Added

- **NanoHarness parity in Codegraff sidebar**: native AppKit composer with NanoHarness's crisp rounded accent caret, `/` slash-command completion popup (`/new`, `/model`, `/write`, `/expand`, `/stop`, `/feedback`, `/reconnect`, `/help`, plus live `graff` commands), `↑`/`↓` prompt history recall preserving unsent drafts, `⌘↩` interrupt / send-latest-queued shortcut, inline `"Editing in composer"` queue editing, full-page distraction-free Write mode (`⌘⇧E`) with live word count, compact context-window usage ring & percentage, jump-to-bottom pill (`↓`), and NanoHarness's seeded rotating working trailer (`Harnessing…`, `Thinking…`, `Brewing…`) with tabular elapsed timers and live `Now`/`Plan` detail lines.
- **Cleaner left sidebar & refined Split View resizing**: removed the redundant `Ask Codegraff` and recent-chat list from the top of the left tab sidebar; refined Split View cards with subtle hairline frames (replacing heavy borders and drop shadows), active indicator dot and hoverable header buttons, and a wider `16pt` split resize divider with a full-height hover/drag accent guide rail and `18%–82%` resize range.

### Performance

- **True 120 FPS scrolling by default**: enabled WebKit's 120 Hz ProMotion page rendering flag (`pages.120`) by default on fresh installs, eliminated synchronous `scrollWidth`/`clientWidth` layout reads during vertical scrolling in `Swipe.swift`, made `Forms.swift`'s scroll listener passive and zero-work unless a sign-in popup is anchored, throttled `ScrollRelay` IPC to integer-percent changes, and coalesced agent streaming chunks at ~60 Hz so rapid replies never stall 120 Hz scrolling.
- **Zero-lag typing in composer and omnibox**: replaced SwiftUI's `TextField(..., axis: .vertical)` with a native AppKit `NSTextView` (`NanoComposerField`) backed by an isolated `ComposerBuffer`, and isolated `OmniboxState` from `Browser` so typing in the composer or `⌘L`/`⌘K` triggers zero re-renders of the transcript, sidebar, or window chrome.

## 1.7.0 — 22 November 2026

### Added

- **Compact top address bar (Aside style)**: single-row top bar in sidebar and folded modes showing sidebar toggle (`⌘S`), navigation buttons, clickable `domain | page title` (`⌘L`), Passwords (`🔑`), Extensions (`🧩`), and a pinned top-right **`✦ Ask [⌘;]`** pill that adapts to page tint (toggleable in Settings › Tabs).
- **Redesigned full-height Agent Sidebar & unified composer**: in sidebar/Aside-bar layouts, Codegraff spans full window height beside the page with a flush `52pt` draggable header, untruncated title, streamlined 4-icon controls, calm bottom-anchored empty state with full-width starter rows, and a single docked composer card unifying the slim page-context strip with the input and model picker.

### Performance

- **BrowserBench / Speedometer 3.1 optimizations**: replaced the per-iframe `MutationObserver` in `Frames.swift` with a single pure CSS rule (zero JS per DOM mutation), debounced `Forms.swift`'s password-form observer with an O(1) `liveInputs.length` guard and skipped `pair()` on non-input focus/scroll/click events, and fast-exited `PasskeyRelay` on non-`http(s)` subframes.
- **Smooth `⌘S` sidebar fold**: suppresses WebKit's synchronous geometry wait during the spring slide, keeps window traffic lights steady when the compact top bar is visible, and animates the top bar inset in sync with the sidebar.

### Fixed

- Sideways swipe navigation checks whether horizontally scrollable elements were recently moving before triggering Back (preventing accidental Back navigation on Google Sheets and wide tables).
- Embedded HTTP MCP server (`AgentTools`) now emits standard MCP `annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) on `tools/list`, allowing Codegraff's read-only planning phase to use `search`, `read_pages`, `read`, `read_markdown`, `page_info`, `links`, `tabs`, `snapshot`, `form_fields`, `screenshot`, and `wait_for`.

## 1.6.2 — 22 November 2026

### Added

- Rich Markdown & native LaTeX rendering in Codegraff replies: GFM tables with alignment and horizontal scrolling, fenced code blocks with language headers and Copy button, heading hierarchy, blockquotes, task checkboxes, horizontal rules, inline math (`$...$`, `\(...\)`), and display math (`$$...$$`, `\[...\]` with stacked fractions, roots, big-operator limits, matrices, and Copy TeX).
- **Sync with iCloud** (Settings › Sync, off by default): `CKSyncEngine` private CloudKit sync for open tabs (shown in History › Tabs on Your Other Devices and omnibox suggestions), spaces, bookmarks, and shared settings; `build.sh` automatically enables CloudKit entitlements when the provisioning profile carries `iCloud.com.codegraff.search`.
- **Handoff** (Settings › General, off by default): offers the active page to your iPhone, iPad, and other Macs over Continuity (never private tabs or isolated spaces), and receives incoming Handoff pages.
- **More browser imports**: added Thorium, Naver Whale, Island, Sidekick, Yandex, ChatGPT Atlas, Floorp, LibreWolf, Waterfox, and Mullvad Browser, plus inode deduplication for case-insensitive Gecko profile paths.
- **Shield upgrades**: hides Reddit promoted posts on `reddit.com` and holds first-launch page loads up to 1 second while the initial block list compiles.
- **Smaller release binaries & faster animations**: release builds compile with `-Osize`, `-Xlinker -dead_strip`, full symbol stripping (keeping full `.dSYM` beside the build), and a resized 256 px `BrandMark.png`; `Motion` springs are tightened under 300 ms with opacity-only Reduce Motion fades and GPU-composited `PulseDot` scale/opacity animations.

### Fixed

- Agent composer always keeps the model + reasoning button visible (instead of collapsing it when the text field loses focus), fixing the model picker popover disappearing when clicked or searched.
- Model picker now opens in a single opaque popover with search, inline reasoning slider, and 1-click model selection (no hidden second step or translucent bleed across the sidebar edge).
- Citation rewriting skips Markdown table rows and display math blocks so links inside tables no longer lose their closing parenthesis.
- PDFs zoom up to 600% with `⌘+` (matching WebKit's PDF bar) without altering the host site's saved zoom; Clear › Cache also clears service-worker Cache Storage (`WKWebsiteDataTypeFetchCache`).

## 1.6.1 — 22 November 2026

Tagged but not published. These changes shipped in 1.6.2.

## 1.6.0 — 21 November 2026

### Added

- Customizable keyboard shortcuts in **Settings › Shortcuts**: search commands or keys, click any key pill to rebind (with conflict handling and macOS reserved-key checks), right-click to clear or reset, and configure an optional system-wide global hotkey to summon `browse` from any app. Added default shortcuts across menus (`⌥⌘P` pin/unpin, `⌥⌘E` rename tab, `⌥⌘M` copy Markdown link, `⌥⌘B` bookmarks, `⇧⌘O` bookmarks bar, `⌃⌘F` full screen, `⌥⌘D` swap split, `⌥⌘T` tidy page, `⇧⌘;` expand Codegraff, `⌘/` searchable shortcut guide).
- Bundled **`browse-mcp`** stdio MCP server (built on `modelcontextprotocol/swift-sdk`) inside `browse.app/Contents/MacOS/browse-mcp`, with live server status, checkmark **Copy JSON** / **Claude Code** / **Codex** / **Pair CLI** buttons + inline config preview in **Settings › Agent › Connected apps**, one-click **Follow** button on the live `ConnectPill`, MCP `Tool.Annotations`, MCP resources (`browse://tabs`, `browse://active`), resilient port reconnect, and clear permission errors.
- New and upgraded MCP tools (`snapshot` interactive accessibility map with secret redaction, `page_info` with `passkeysAvailable`, `read_markdown`, `click_at`, `open_tab`, `scroll`, `press_key`, `hover`, `wait_for`, `page: "active"` targeting, and upgraded `screenshot` supporting `full_page`, CSS `selector` crops, `target: "window"`, secret-field masking, and optional `save_to` file output alongside inline MCP image blocks).
- Passkey auto-focus for agents: interactive agent pages carry `PasskeyRelay`, explicit passkey prompts bring `browse` + the tab into focus to anchor Touch ID instead of failing unfocused, and conditional passkeys open/focus the sign-in tab when a matching passkey exists on this Mac.
- Low-RAM memory profiles in **Settings › General** (**Balanced** vs **Low RAM** + one-click **Sleep now**), 1× capped tab sleep snapshots (~4× lower bitmap RAM), bounded `URLCache` (12 MB RAM), explicit background WebKit timer throttling, and a 3-minute idle reaper for offscreen MCP/agent WebKit pages.
- 120 FPS Split View: direct AppKit layout (`StageView` + `SplitHeaderView`) with zero SwiftUI invalidations during drag, `PageView.inLiveResize` + `backPage()` eliminating WebKit resize stalls and dark flashes, cached `CALayer.shadowPath`, trackpad alignment haptics on `1/3`, `1/2`, `2/3` stops, and a 120 Hz `CADisplayLink` ease-out snap back to 50 : 50 on double-click.
- NanoHarness 1:1 model picker, composer & page context: unified `[Maker] Model Effort` trigger chip (never colliding with the send button), compact popover with brand-colored capsule reasoning slider, searchable catalog with subscription `Plan` badges, favorites, accurate route/maker icons (`chatgpt-new`, `claude-agent`, etc.), stable model IDs fixing stale search rows, two-step model reasoning stage, and a docked favicon page-context card.
- Polished agent UX and motion: breathing live status indicators (`PulseDot`), live-action `ConnectPill` with a one-click **Stop** button, smooth rotating activity disclosures, numeric-text timer transitions, refined spring transitions for Codegraff column/stage swaps (respecting macOS Reduce Motion), and high-contrast `ShortcutBadge` keycaps on the **Ask** button (both sidebar and top tab bar) and empty chat state so `⌘;` (toggle agent sidebar) and `⇧⌘;` (expand full view) are immediately visible.
- Passkeys under the sign-in field, as in Safari: on sites that offer conditional WebAuthn (such as GitHub and Google), the Mac's passkeys for the site appear first under the sign-in box beside saved passwords, and clicking one opens the Mac's sheet for that passkey and signs you in.

### Fixed

- Passkey sign-ins on GitHub now complete after Touch ID: returned credential methods are writable (matching native credentials), so libraries like GitHub's `webauthn-json` can assign `toJSON`.
- Passkeys work from same-site iframes (such as Apple Account's `idmsa.apple.com` frame inside `account.apple.com` and Sign in with Apple), naming the committed page's `topOrigin` and `crossOrigin` in client data while still refusing cross-site frames.
- Security-key assertions without a user handle (such as Okta) no longer crash; the site receives a `null` `userHandle`.
- Passkeys are offered only to the tab's committed page origin, and relying-party domains and origins are kept private in the macOS system log.

## 1.5.0 — 1 October 2026

### Added

- Continue in browser shares the current Codegraff conversation with your signed-in browser or phone through the account relay. It is off until enabled, preserves drafts on the Mac, and disconnects when you turn it off or change conversations. Browse must remain open on an awake Mac.

## 1.4.1 — 1 October 2026

### Fixed

- Settings switches expose their name and state to keyboard navigation and accessibility. Enabling Codegraff offers Open beside page; missing installations link directly to setup. Switching it off closes either chat mode and prevents late page reads or startup work from reviving it.
- Cancelled web sign-ins cannot overwrite a newer attempt. Signing out stops Codegraff and sync, as the confirmation describes.
- Codegraff sessions receive the browser's MCP server directly over ACP, including restored sessions, so page tools are available without depending only on background config discovery.

## 1.4.0 — 1 October 2026

### Changed

- Settings › Agent can enable a local task library with editable research examples, search, save and edit controls, and drafts that stay with their tab and selected excerpt. Task choices and research starters preserve existing draft text and never send it. The chat header has a visible usage guide with current shortcuts, page context and follow-up instructions.
- Refreshed the bundled EasyList and EasyPrivacy rules for blocking ads and trackers.
- A five-step welcome tour introduces page-to-chat research, shows Codegraff installation and sign-in choices, and explains ⌘; and the period shortcut. Steps can be skipped individually or revisited, compact windows scroll, and the final screen can open a first research question as an editable draft without sending it.

## 1.3.2 — 30 September 2026

### Changed

- Command–semicolon (⌘;) shows and hides Codegraff, replacing Shift–Command–A. The menu, close-button hint and keyboard shortcut guide use the new key.
- Refreshed the bundled EasyList and EasyPrivacy rules for blocking ads and trackers.

## 1.3.1 — 30 September 2026

### Changed

- Refreshed the bundled EasyList and EasyPrivacy rules for blocking ads and trackers.
- Page context shows the title and domain with include, exclude and pin controls. Settings › Agent can add Ask Codegraff to selected text's context menu; excerpts are reviewed before sending and keep their original source across tab changes and queued messages. Conversations show actionable task states and a collapsible list of agent pages that opens only when requested.
- Model controls show provider logos beside the selected model and in the picker, with appearance-aware marks and a Claude accent matching Harness. Custom providers use their initial.
- Codegraff's expanded view and side column share a multiline composer, with model and reasoning controls on the Ask page too. Recent conversations can be searched from either header; the Ask page lists them in compact rows, and research starters leave an editable draft. Long model names scroll without moving Send or Stop out of reach.
- The side composer folds down while reading. Page context says whether it will be included; conversation options explains the research workflow and opens a reviewed feedback draft, also available with `/feedback`.
- The agent column shares the browser's surface, with a soft input fill and quieter source links instead of an inset panel and stacked outlines. Its compact header keeps the status beside the name and softens the edge of scrolling replies. The permanent divider is gone; a small resize handle appears on hover.
- Pressing `.` while reading opens the enabled Codegraff agent beside the page; text fields keep punctuation. Ask, the empty conversation and the shortcut guide explain it. Live activity shows recent actions, running tools and task progress, with Details for the full activity and Result for tool output.

### Fixed

- Codegraff's sign-in notice describes its web approval flow instead of telling people the button opens Terminal.
- Reconnecting Codegraff restores the conversation instead of starting an empty session, and holds queued messages for an explicit next send. Conversation options offers recovery when a run stops responding.
- Agent replies and composer layout changes leave keyboard focus where it was. Opening the agent, choosing a starter or starting a conversation still focuses its input.

## 1.3.0 — 30 September 2026

Tagged but not published. These changes shipped in 1.3.1.

## 1.2.2 — 29 September 2026

### Changed

- A simpler icon, the same as the website's: two pages and the sun between them, in the Dock, the disk image, onboarding and Settings.

## 1.2.1 — 29 September 2026

### Added

- Onboarding has a page for Google's suggestions as you type: a drawn address field types a few searches by itself, with Google's rows under them while the switch is on, so what it does is seen before it's chosen. Still off until turned on.
- The search engine's icon on its rows under the address field, Google's suggestions included. On a Mac that has never opened the engine's site, browse fetches the icon once, instead of showing a magnifying glass.

## 1.2.0 — 29 September 2026

### Added

- Bring things over from another browser in one sheet: Chrome and its Beta, Dev and Canary, Arc, Brave, Edge, Vivaldi, Chromium, Dia, Opera and Opera GX, Comet, Helium, Firefox and Zen. Bookmarks (the ones Chrome keeps for your account, and sealed ones, too), history and passwords, from every profile, the newest copy, with nothing added twice. On macOS 27, where other browsers' folders need Full Disk Access, browse opens the setting and carries on by itself once it's on. Passwords can come from a CSV file too.
- ⌘D with one page open, or from an empty tab, splits with a new tab: the empty side has the address field, standing over that half. Split View in the menu works whenever there's a page.
- Bookmark folders of your own, folders inside folders too; a bookmark or a folder is renamed from its right-click menu, and a middle-click on one opens it in a new tab.
- A default page zoom for every site, in Settings › General.
- Prevent cross-site tracking can be turned off, as in Safari.
- A double-click below the tabs opens a new one.
- ⇧⌘⌫ opens the controls for clearing browsing data.
- ⌥⌘R reloads from the origin, as in Safari; ⌘R reloads as before.
- A mouse's sideways wheel goes from space to space in the column.
- Two fingers sideways on a canvas pan it instead of going back.
- A search suggestion wears the engine's icon.

### Fixed

- ⌘K is browse's on every page, and ⌘← and ⌘→ go back and forward again.
- A tab no longer wears another site's icon.
- The window opens at its saved size instead of jumping to it, and moves from the top band with the tab bar folded away too.
- A folded sidebar comes out when the pointer overshoots the window's left edge, and stays out while the bookmarks list is open.
- A tab opened only to download a file closes once the file is on its way; the download button on a PDF saves it.
- A middle-click opens a link on pages that stop the click on its way up; a link's right-click menu says Open Link in New Tab.
- Scrolling is lighter: it no longer redraws the window for the reading fill, the caret or a turning load ring.
- Faster address suggestions with a large history; ⌥⌫ lets go of an inline completion and deletes the last word; editing a tab's address keeps its port, query and fragment.
- Saves land in order, the right tab comes back at launch, and pages parked in another space reach History.
- Passkeys carry the WebAuthn PRF extension through.
- Extensions: ScriptCat's requests work, Figma's and NordPass's sign-ins return, 1Password's popup hears the app, Bitwarden signs in, a second click on a button closes its popup, popups stay anchored after switching tab layouts, and extensions load before a restored page. Their permissions are kept to what they asked for.
- Camera and microphone choices are kept per site, and never for a private tab; a private tab's downloads stay out of the list.
- The floating video drags on the first click, the Web Inspector comes back with its tab, and Reduce Motion follows the system setting.
- Dev servers' addresses open: 0.0.0.0, [::1], .local and 172.16/12.

## 1.1.2 — 27 September 2026

### Fixed

- Settings: the highlight in the list of pages follows the pointer — one row at a time, gliding to the next — instead of staying on a row the pointer had already left.

## 1.1.1 — 27 September 2026

### Fixed

- In Split View, the page you're typing in is the page in front. A page that took the keys itself — Google's search box as it loads, or Tab from the other page — left the other one in front, so ⌘L, Find and Codegraff went to the wrong side. And the page put in front gets the keys.

## 1.1.0 — 27 September 2026

### Added

- Split View: two tabs side by side, each page on a card of its own under a strip that names it, in a frame of the same glass and colour as the sidebar. ⌘D pairs the tab in front with the one before it, and goes back to one page; or pull a tab out of the sidebar or the tab bar onto the page — the half it's over lights up — and it opens on that side, or in place of what was there. Click a page to put it in front: the address field, Codegraff and the sidebar's colour follow it. Pull the gap between them to share the room, settling on a third, a half or two thirds; double-click it to even it out. Each page's strip has Swap Sides, Just This One and Close This Side, and pulled across, swaps them. The pair stays a pair, held in one frame in the sidebar — pick either tab and both come back — and is still there the next time browse opens. Closing one half lands you on the other. Duplicate Tab moves to ⇧⌘D.
- The sidebar takes on the colour of the page beside it, through its glass: the colour a site asks browsers to use, or the page's own background. A quiet colour goes on nearly solid, a loud one is softened, and on a dark page the sidebar turns dark with light words. Settings › Tabs › Colour the sidebar like the page turns it off.
- View › Tidy This Page, or Tidy in the list of what's hidden on a site: Jev takes off what the ad blocker let through — cookie bars, sign-up and newsletter pop-ups, sponsored cards, ad slots — and keeps them off on that site. Only boxes that look like clutter are offered to it, never the article, the navigation or a sign-in form, and only what it's sure of goes. What went is listed right after, marked tidied, each one a Restore away. Needs a Codegraff sign-in; only the page you tidy is looked at.
- The sidebar, redone after Arc: pinned tabs are taller tiles led by the site's icon, the tab you're on sits raised on Liquid Glass (macOS 26 and later; the theme's wash before), and the column is glass too — the desktop through it, under your theme. A line under the tiles has + for a new tab and a trash can that closes every tab that isn't pinned (⌘⇧T brings them back), and a link button beside back and forward copies the page's address.
- Chats with Codegraff are kept in the sidebar too: the latest four under Ask Codegraff, pinned ones first, each a click from being picked up again. Right-click any chat — there or on the Ask page — to rename it, pin it to the top, or delete it; a name you give it stays. The Ask page can search every chat, titles and all that was said.
- Bring In History, at the foot of the History panel: Chrome's history — or Arc's, Dia's, Brave's, Edge's, Vivaldi's, every profile of it — comes into browse's any time, not only on the welcome screens, and Safari's from its export. Visits the other browser hasn't written to its file yet, as while it's open, come too. From macOS 27, Chrome, Brave and Edge keep their folders to themselves, and only Full Disk Access lets another app read them: choosing one of those now says so, with a button to that page in System Settings, instead of bringing in nothing without a word.
- The welcome's Bring page draws where things go — read once from the other browser's folder into browse on the same Mac, and only with sync on, sealed before it leaves — and says up front which browsers macOS keeps locked and what browse needs to read them. Every Chromium browser on the Mac is listed, where only the ones macOS had already let browse into were before. The same picture is in the README and in docs/your-data.md.

- Codegraff on one tab alone. On a page with a form, a small "Fill in with Codegraff" pill appears in the corner; one click opens Codegraff beside the tab, pinned to it, and it fills the form with what it knows, asks for the rest in one question, and leaves the submitting to you. The tab's menu has Ask Codegraff About This Tab and Fill In the Form with Codegraff, and View › Fill In This Form (⌥⌘F) does it for the tab in front. While a chat is pinned, a chip says which tab, every message goes with it, and Codegraff's tools act there unless told otherwise; the chip's cross lets it go. The pill's cross hides it on that site.
- The welcome has a page on Codegraff at work on a page: the form pill as it looks, and a line each on filling forms, one agent to a tab, the queue and Tidy. The first time the pill shows on a page, a line over it says what it does.
- A queue for Codegraff, as Harness has: type while it works and Return puts the message in line, shown above the box; each goes in turn once the one before it is answered. A queued message can go now (the turn under way stops for it), go back into the box to be changed, or be taken out. Stopping a turn by hand holds the queue until you send again.

### Changed

- Codegraff's work reads as it does in Harness. A turn's steps fold to one line that says what was done ("Ran 2 commands · edited 1 file · 1 failed"), and open to a card each, named the same way Harness names them: Run and its command, Read or Edit and the file, Search, Fetch, Browse for the browser's own tools. A card opens to what the step printed, or to its diff, line by line in red and green. graff's plan is a Todo card ("2/3 done") that keeps up as it goes, graff's name for a conversation becomes its title unless you've named it, and each turn is stamped as Harness stamps it.
- Google suggestions keep up with you: the ones that still fit stay in the list while Google answers the next letter, rather than the list emptying and filling on every key; they're asked for sooner; the words you haven't typed yet are in bold; and what Google has said is kept while the field is open, so going back a letter is instant. Still off until you switch them on in Settings › General.
- History keeps 10,000 places instead of 2,000, so another browser's history comes over nearly whole; the ones kept are those you go to most, and trimming them now happens off the main thread.

### Fixed

- Google's logo and doodles show again. An EasyPrivacy rule meant for Google's logging address, google.com/log?…, was also blocking google.com/logos/…: turning the lists into WebKit's rules lost where a rule ends, so every rule matched anything that merely began like it. Rules end where they should now — which also stops a blocked host like ads.com taking ads.community.org with it — and the lists are today's.

## 1.0.4 — 27 September 2026

### Added

- Optional recent searches in the empty address field and Google query suggestions while typing, with separate switches in Settings › General. Google suggestions only run with Google selected and stay off in private tabs.
- Bring things over from Safari: export from Safari with File › Export Browsing Data to File…, then choose the zip on the welcome screens or under Bookmarks › Safari or a file… Bookmarks (the Reading List included), history and, if exported, passwords come in. A bookmarks file from Firefox or any other browser works too.
- Connected apps, in Settings › Agent, off by default: another app on your Mac — Harness first — can use browse for its agents' web tasks, with your sign-ins. It pairs once, with a code you check on both sides; you choose what it may do; every request is signed, a pill names the app while it works, and Revoke takes it back. It never types a password. See docs/connected-apps.md.
- Bring each Chrome, Arc, Brave, Dia or Edge profile over as a space of its own, signed in where it was: its sign-ins go into that space's own cookies, and its bookmarks into a folder under the profile's name.
- Passwords can sync between your Macs too, behind their own switch in Settings › Sync, off until you switch it on: sealed on your Mac with the same key as history and bookmarks, so Codegraff's server can't read them.

### Changed

- Ad and tracker blocking uses EasyList and EasyPrivacy, about 130,000 rules instead of a short list of our own: on busy news sites, a quarter to a third fewer requests, reaching a third to a half as many servers as before. The lists are compiled once, in the background, the first time a new version opens; the short list blocks in the meantime.

### Fixed

- Two Macs switching sync on at the same moment could each make a key of their own and go on syncing apart, neither able to read the other's. Now the second gives way and asks for the first's code, and every round checks the key still fits the account before sending anything.
- Search recall offers more useful history matches and keeps queries available when a results page fails to load.

## 1.0.3 — 26 September 2026

### Added

- Searches you've made come back as you type: a few of their words, in any order, bring up the whole search — from your history, whichever engine it went to and wherever it was typed — and the field finishes it in grey for Return. Pages of search results stop showing up as places.
- The first-run layout previews show sample site icons or letters as you choose, and setup teaches more of the browser's real keyboard shortcuts. The full guide is in Help › Keyboard Shortcuts; if you ask during setup, a one-time reminder appears after you open a page.

### Changed

- About now shows the version and build, update status, project and license links, and a link to the full keyboard shortcut guide.
- Codegraff's answers read cleaner: a source it cites becomes a small number, the same number each time, and the sources sit once under the answer as chips you can click. The field holds everything in one box — what you type, the model, how hard it thinks, and a send button in the theme's accent.
- Codegraff answers what it knows, and from the page you sent, without going to the web first; it searches when something is current or checkable, or when you ask for sources, and keeps answers brief unless asked for more.
- Less memory with many tabs: three stay awake behind the one you're on (it was six), the rest sleep after a minute, and any tab after a quarter of an hour. With ten ordinary sites open that's about 280 MB less.
- Codegraff reads a page once its text is in and has stopped changing, not once the last ad and tracker has loaded — on busy sites that's a second or two instead of up to fifteen, with the same text read.
- The pages Codegraff opens for itself block ads and trackers as your tabs do, and follow the same switch and the same sites you've paused it on: a third to three-fifths fewer requests on news sites, and a busy page done loading two seconds sooner.
- A page Codegraff only reads — a search, a batch of pages — loads without its pictures, video or fonts, and no page it opens plays video or sound until it clicks.
- Codegraff sits in a rounded, inset panel beside the page, with a roomier box for writing to it.

### Fixed

- Search history keeps literal plus signs in searches such as C++, and recognizes custom engines that put search words in the address path or fragment.

## 1.0.2 — 25 September 2026

### Added

- A Mac whose web engine is missing Apple's security fixes is told so, with a button to Software Update: browse runs on the WebKit built into macOS, and now knows when that WebKit is behind. It's in Settings › About too.
- Everything new in Search 1.0.2 and 1.0.3, the browser browse is built on: peek at a link with a shift-click, a bookmarks bar, a small window for links from other apps (each off until you turn it on), the site card by the address, a link's address in the corner as you point at it, pages at 120 Hz, updates that can wait for Install, and its fixes — iCloud Passwords stays paired, full-screen video shows its picture, floating video keeps Netflix subtitles, History opens at once, Logitech back and forward buttons, and more. And its security work: the browser's scripts run where pages can't see them, pop-ups need a click, a saved password is offered only on its own site and copying one asks who you are, and tighter rules for extensions, certificates and updates.
- Themes, in Settings › Themes: browse's own, Codegraff and Codegraff Paper (the Codegraff app's and codegraff.com's colours), Nord and Forest, each for light and dark. A theme is a small JSON file — add one, or describe one in a sentence and Codegraff makes it, checks that everything reads, and switches to it. Themes you add or make sync between your Macs with sync on.
- Sign in with Codegraff from inside the browser, on the welcome screens or in Settings: a code, a page on codegraff.com to approve it, and you're in. One sign-in serves Codegraff beside the page, Jev and sync, and it's the same one `graff login` makes, so graff in a terminal is signed in too.
- Sync, off until you switch it on in Settings › Sync: history and bookmarks, the same on every Mac you sign in to Codegraff on. Everything is sealed on your Mac first, with a key only your Macs have (a sync code carries it to the next one), so Codegraff stores it without being able to read it — the addresses included. Forgetting a page or clearing history does it on every Mac; a bookmark moved, renamed or deleted on one is on all of them. Settings › Sync also deletes everything synced from Codegraff.
- The app is called browse now: the window, Settings, the welcome screens and the downloads (browse.dmg). Your tabs, history, passwords and settings stay where they were.
- Codegraff hands the clicking to Jev. On a form, a search's filters or a date picker, its new `drive` tool gives Jev the goal and the words to type. Jev then takes one quick step at a time: each step is a single call that picks what to do and where, and Search checks the element is still there, shown and not covered before touching it. Codegraff's model plans the task and says what gets typed, so Jev makes up nothing. It stops before paying, sending, posting, booking, deleting or creating an account. It goes through your Codegraff sign-in; Settings › Agent › Quick steps with Jev turns it off. When Jev can't be reached, Codegraff fills forms field by field as before.
- Updates on their own: once a day, and whenever Settings › Updates › Check now is pressed, the app looks at this repository's newest GitHub release. A newer build is fetched in the background, checked — same app, newer, signed by the same Developer ID team — and put in place for the next time it opens, or right away with Relaunch now. Nothing you have set is touched. Versions before this one don't look, so they need this one downloaded by hand once.
- The Ask tab: a small square at the head of the row of tabs (and a row at the top of the column) that puts Codegraff's own page where the page was — the mark, one field that asks Codegraff or, with Tab, searches and goes somewhere, and your chats so far, a card each, to pick one back up where it was left. A conversation on the stage reads like a chat's page: what you asked, the work folded into one "Worked for 58s" line that opens to every step, and the answer with its lists and links, a copy button and the time. Picking any tab gives the stage back. ⌘L and the empty tab's field are as they were.
- Codegraff opens over the whole tab: ⇧⌘A and ⌘↩ in the address field bring the talk up where the page was, and the column beside the page is a door in its head. Picking a tab, ⌘T or an address typed with ⌘L gives the page back, with no column left behind. While it works, one line says how long and the step it is on; done, the steps fold into "Worked for …", and the pages it only read are closed.
- The model menu is a search: type to narrow five hundred models to the one you mean, arrows and Return to take it, the ones used last on top and each provider in a section of its own. Names read as their makers write them, image, video and batch-only models are left out, and a router's models name their maker.
- Anonymous stats, off unless you switch them on in Settings › Privacy. Once a day they send this Mac's chip, CPU and GPU cores, memory and macOS version, how much memory the app uses, and how many tabs are open, under a random id made on the Mac. Everyone's put together is at search-codegraff-stats.rachpradhan.workers.dev, where groups of fewer than three Macs show as "Other". "This Mac's" shows the report word for word before anything is sent.
- No more than six tabs stay awake behind the one on screen. Past that, the ones looked at longest ago sleep once they've been left two minutes, rather than holding their pages for half an hour. When macOS says memory is short, Codegraff lets go of its pages too, and of graff itself when it's critical.
- Codegraff holds less. It runs with the browser's tools and its own, not every MCP server other apps name, each of which was a process for every chat; Settings › Agent › Your other MCP servers brings them back. Ten quiet minutes and it stops, giving back what it and its pages hold, and the next message picks the same conversation up. It keeps fewer pages of its own open at once, and the address it leaves for its tools goes when Search quits.
- Codegraff answers sooner. Its first reply no longer waits out two failed WebSocket tries before streaming, and it starts while a question is still being typed in the address field.
- Codegraff fills in forms: it lists a page's fields as a person reads them — labels, options, what is required — and fills many at once, typed the way a keystroke would be so the page's own scripts notice, selects, checkboxes and radio groups included. It is shown the tab you are on, so it fills that one in front of you, and asks before sending anything that pays, posts, books or signs you up.
- Codegraff's chat takes the whole window when asked: the door in its head, between New conversation and Close, moves the same talk from the column to the stage the page had — held to one measure down the middle, and with the invitation and the field standing in the middle of it before anything has been said — and back to the column with the door beside it.
- Codegraff, down the right of the window: ⇧⌘A opens a chat with the `graff` on your Mac — the one you already sign in to — which reads the page you're on and works on your Mac with its own tools, commands and file edits included. It gets Search's hands as well: your tabs, opening pages and reading them in hidden ones of its own, searching the web and taking up to a dozen results in at once. What it read comes out as one card of links, each a click from being a tab of yours. ⌘↩ in the address field, or the row under it, asks it instead of a search engine. Under its field, the model it works on and how hard it thinks, each a menu. Settings › Agent.
- Spaces with the tabs across the top: two fingers up or down over the bar, or a notch of a mouse wheel, bring the next space's tabs in as these go; past the last, a new space is made right in the bar. "New Space…" makes it in place in the column too.
- Reopen Closed Tab is in the right-click menu of every tab, in the row and in the column, beside Close Other Tabs; it was only on ⌘⇧T and in the History menu. Thanks [@andupoto](https://x.com/andupoto) for asking
- Extensions on private tabs, if you allow them: Settings › Extensions › Allow on private tabs, off by default. It applies to private tabs opened after it is turned on. Thanks [@merttopuz](https://github.com/merttopuz) ([#55](https://github.com/driceroland/Search/pull/55))
- Scroll with the middle button, as on Windows: click the wheel on a page, then move the mouse up or down; another click stops it. Settings › General › Scroll with the middle button.
- Homebrew: `brew install --cask driceroland/tap/search`, and `brew upgrade` brings each new version.
- ⌘S folds the tab bar away in its layout across the top too, as it folds the column: the page takes the whole height, and the bar comes back down over it when the pointer rests against the top edge. The View menu says Hide Tab Bar there.

### Fixed

- Google's "Sign in with Google" card no longer sits in a white box on dark sites like ChatGPT.
- Codegraff's fill set every field but a dropdown, which it said wouldn't take the value.
- The stand-in traffic lights drawn while Search is in the background are no longer redrawn each time the window changes screen or size, only when they move.
- An empty tab no longer works the processor while it waits: the slow breath under the address field was redrawn by the app every frame, about a sixth of a core with nothing happening. The same breath now runs in macOS's own animation layer, at no cost to Search.
- With extensions installed, the window no longer waits for them: they load once it is up. The first launch after an update, when Search fits its Chrome compatibility layer to each extension again, does that away from the main thread — with Grammarly, the window had stood still for half a second. Thanks [@andupoto](https://x.com/andupoto) for the report
- Search opens faster when you have many bookmarks: the Bookmarks menu used to be built in full, every folder included, before the window could appear — about a quarter of a second for 1,500 bookmarks, at every launch. Its bookmarks are now put in as the menu opens, a folder's as that folder opens. Thanks [@andupoto](https://x.com/andupoto) for the report
- Before macOS 15.4, where Search can't run extensions, the Chrome Web Store no longer shows an "Add to Search" button that did nothing when pressed; Settings › Extensions says what they need. Thanks [@andupoto](https://x.com/andupoto) for the report
- Started hidden — `open -j`, or anything that launches Search in the background — Search comes up with its window, hidden with it until shown, where it could come up with no window at all.
- A new tab starts loading the moment you press Return or pick a bookmark. Each new tab used to start its web process from cold first — about 40 to 60 milliseconds with the window stuck — where it now takes about 10. Thanks [@andupoto](https://x.com/andupoto) for the report
- A bookmark picked from the list under its button closes the list as its page starts, instead of leaving it open over the page. Thanks [@andupoto](https://x.com/andupoto) for the report
- A link pasted into the address field shows at once. Every key and every paste sorted the whole history again for the History menu, and cut every address in it into pieces to find its host, before the field could catch up. Thanks [@andupoto](https://x.com/andupoto) for the report
- Passkeys work: a site's "Sign in with a passkey" or "Create a passkey" brings up your Mac's own passkey sheet — Touch ID with your passkeys from iCloud Keychain or a password app, your iPhone over the QR code, or a security key — where it could end in "authentication failed" on every site. Left to WebKit, a sign-in page that offers your passkey under its name field kept a request open with macOS, and if Search quit or crashed while such a page was open, macOS went on refusing all of Search's passkeys until the Mac restarted. Search now carries passkeys out itself, as Chrome does, and never leaves one open; the first time, macOS asks whether Search may use them. **Passkeys still failing after the update? Restart your Mac once.** Not yet: the passkey offered under a sign-in field as the page loads — the site's passkey button is the way in for now. ([#17](https://github.com/driceroland/Search/issues/17))
- ⌘⇧N no longer piles up empty private tabs: one already open comes to the end of the row, as with ⌘T.
- A new space's choice of sign-ins reads in full in the column ("Signed in" / "Signed out"), where it was cut short.

## 1.0.1 — 23 September 2026

### Added

- A middle-click on a tab closes it, in the row across the top and in the column. A pinned tab is put down, as with ⌘W. Thanks [@lusqua](https://github.com/lusqua) ([#27](https://github.com/driceroland/Search/pull/27))
- Rename a tab: Rename in a tab's right-click menu, or Tabs › Rename Tab, types a name over the title in place. The name stays with the tab wherever it goes, and survives a quit; emptying the field gives the page's own title back. Thanks [@theosementa](https://github.com/theosementa) ([#32](https://github.com/driceroland/Search/pull/32))
- The sidebar can hide by itself until the pointer reaches the left edge: Settings › Tabs › Hide the sidebar until the pointer reaches the edge. ⌘S still brings it out to stay. Thanks [@lusqua](https://github.com/lusqua) ([#30](https://github.com/driceroland/Search/pull/30))
- Spaces: separate sets of tabs in the one window, each with its own icon and, if you like, its own downloads folder — signed in wherever your other spaces are, or starting afresh with cookies and sign-ins of its own, as you choose when you make it. Turn them on in Settings › Tabs, then switch with ⌃1–⌃9, the space's icon, or two fingers sideways over the column of tabs, where the next space slides in beside this one; past the last, the column offers to make a new one. ([#4](https://github.com/driceroland/Search/issues/4))
- Web Inspector: Inspect Element in a page's right-click menu, and in the View menu the inspector (⌥⌘I), the JavaScript console (⌥⌘J) and picking an element (⌥⌘C), the keys Chrome and Arc use. ([#13](https://github.com/driceroland/Search/issues/13))
- ⌘S folds the sidebar away and the page takes the whole window; the left edge brings the tabs back out. Thanks [@kndpt](https://github.com/kndpt) ([#7](https://github.com/driceroland/Search/pull/7))
- Search with something other than Google: Settings › General › Search with offers DuckDuckGo, Bing, Ecosia, Startpage and Kagi, or any address with `%s` where the words go. Google stays the default. Thanks [@karadoganyi](https://github.com/karadoganyi) ([#43](https://github.com/driceroland/Search/issues/43))
- The grey that fills the tab you're on as you read down the page can be turned off: Settings › Tabs › Show how far you've read. Thanks [@karadoganyi](https://github.com/karadoganyi) ([#57](https://github.com/driceroland/Search/pull/57))
- A skill that teaches coding agents to drive Search with `./bench`. Thanks [@jasonkneen](https://github.com/jasonkneen) ([#14](https://github.com/driceroland/Search/pull/14))
- Extensions can be pinned to the toolbar from Settings › Extensions, not just from the puzzle-piece menu.

### Fixed

- Search opens on macOS 14 again: it quit as it opened, before its window, setting the look chosen in Settings on an application that didn't exist yet. Thanks [@serhiitroinin](https://github.com/serhiitroinin) ([#38](https://github.com/driceroland/Search/pull/38))
- A column of more tabs than the window holds scrolls between the pinned tabs and its foot, instead of running under the traffic lights and off the bottom of the window; the tab you go to is brought into view. Thanks [@lusqua](https://github.com/lusqua) ([#39](https://github.com/driceroland/Search/pull/39))
- ⌘T never leaves two empty tabs: an empty tab already open elsewhere in the row comes to its end and opens, with whatever was typed in it and not gone to cleared. ([#35](https://github.com/driceroland/Search/issues/35)) Thanks [@SamarthaB10](https://github.com/SamarthaB10)
- While a tab's address or name is being edited in the tab itself, a click anywhere else — the page, the column below, the rest of the strip — keeps what was typed, as Return does, instead of throwing it away. An address left as it was loads nothing again.
- Folded away with ⌘S and brought out at the edge, the column arrives whole: the traffic lights and the pinned tabs come in with it instead of standing there before it.
- A double-click along the top of the window fills the screen, as a title bar's does: it was answered twice and ended where it started. In the column's mode the page's top edge takes it too, folded away with ⌘S included, where nothing did.
- ⌘← and ⌘→ move through text while editing; adding Shift selects text instead of navigating away from the page. Thanks [@yuxino](https://github.com/yuxino) ([#19](https://github.com/driceroland/Search/pull/19))
- Extensions that open something inside a page no longer make it reload: signing in to Google with iCloud Passwords installed reloaded the page over and over, and every Vimium key that opens its bar or its link hints reloaded the page. Such a panel now gets the same answers from the browser as in Chrome. ([#2](https://github.com/driceroland/Search/issues/2))
- Dragging a tab to put it elsewhere in the row across the top moves the tab, not the whole window, and a tab being dragged stays under the pointer as it passes the others, in the column too.
- A fresh install follows the Mac's appearance: on a Mac set to dark the browser and its pages start out dark, instead of always starting light. Thanks [@mikuteto-dev](https://github.com/mikuteto-dev) ([#22](https://github.com/driceroland/Search/pull/22))
- The address field on a new tab holds still while its suggestions appear under it, instead of jumping up. Thanks [@fschrhunt](https://github.com/fschrhunt) ([#16](https://github.com/driceroland/Search/pull/16))
- 1Password's Sign in button works: an extension's page can send its tab to a website again, where it used to do nothing.
- A video in the floating window costs no more to play than in its tab. The window's shadow made WindowServer composite every frame; it has none now. ([#33](https://github.com/driceroland/Search/issues/33)) Thanks [@AxxzyWasTaken](https://github.com/AxxzyWasTaken)
- Tab moves between a form's fields again, as in every browser; ⌃Tab and ⌃⇧Tab switch tabs.
- ⌘1–⌘9 (and ⌘0 to reset the zoom) work on every keyboard layout, AZERTY included: they follow the key, not the character it types.
- A private tab now leaves nothing behind: it no longer shows up in Recently Closed. Thanks [@yuxino](https://github.com/yuxino) ([#6](https://github.com/driceroland/Search/pull/6))
- ⌘L then Return keeps the whole address, the part after `?` included. Thanks [@yuxino](https://github.com/yuxino) ([#5](https://github.com/driceroland/Search/pull/5))
- A floating video shows the whole picture on YouTube, and the page comes back to its tab when it lands. Thanks [@Chinteyley](https://github.com/Chinteyley) ([#9](https://github.com/driceroland/Search/pull/9))
- No white flash when a link opens a new tab in dark mode. Thanks [@RanaOsamaAsif](https://github.com/RanaOsamaAsif) ([#3](https://github.com/driceroland/Search/pull/3))
- Typing no longer makes the Mac beep when a page hasn't put its cursor in a field yet — starting a reply on X, for one. ([cc8aa58](https://github.com/driceroland/Search/commit/cc8aa58))

## 1.0 — 23 September 2026

The first version. A browser for the Mac with nothing in the way: tabs in a row or down the side, pinned tabs that keep their place, and one field for addresses and searches. Ads blocked before they load, passwords and passkeys in your keychain, anything on a page hidden for good, reading mode, floating video, Chrome extensions from the Chrome Web Store (macOS 15.4 or later), and tabs that sleep after half an hour. 2.9 MB, on the engine already in macOS.
