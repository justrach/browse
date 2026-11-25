Site search !bangs and custom keywords, Nanolight browse:// deep links and launcher.json indexing, Page Capture & Export (PNG, PDF, Markdown), opt-in native Cookie Banner Shield, per-site CSS Boosts and Force Dark Mode, global media & muted tabs popover, passive DevTools console/network MCP tools for Codegraff, Tab Group @group context mentions, native on-device Translation, and a Split View transition fix.

Faster streaming Markdown and Codegraff composer/tool latency, 120 FPS rendering across tabs, split views, and smooth scrolling, quicker startup, navigation, favicons, and extension loading, plus Reading Mode, floating video controls, tab group drag/split parity, SiteCard, Find, Bookmarks, and Downloads polish.

Real chrome.proxy support via WebKit proxyConfigurations, open-tab Web Notifications bridged to macOS Notification Center with per-site Privacy permissions, Universal Intel (x86_64) and Apple Silicon (arm64) macOS builds, and Roadmap cleanup.

User Tab Groups with chrome.tabGroups and a formal Lean 4 proof, docked chrome.sidePanel with Bitwarden and Vimium C fixes, Split View divider menu with Sync Scrolling and sidebar drag-to-split, opt-in smooth mouse-wheel scrolling, always-visible address bar, and page-tinted title bar, Codegraff activity/queue/context recovery UX improvements, Comet importer hardening, HTML5 video keyboard controls, pinned-tab new-tab routing, stuck closed-tab WebContent guard, cached Shield setup with Gmail $generichide exceptions, Dvorak–QWERTY Command shortcuts, and a zero-warning Swift build.

Calmer Relaxed/Balanced/Low RAM memory policy with formal Lean 4 proofs, live Downloads progress and retry, Dark/Sepia non-destructive Reading Mode, top page progress hairline, Back/Forward history menus, bookmark search and overflow menu, Recently Closed in Cmd+K and History, Move to Space and shared live pins, Add Image to Photos, Privacy site permissions management, opt-in in-window video full screen, native Web Inspector dock toggle, interactive PiP controls, Agent prompt retry/edit, full-screen Escape routing, and a TabCycleHUD release-build fix.

Calmer Relaxed/Balanced/Low RAM memory policy with formal Lean 4 proofs, live Downloads progress and retry, Dark/Sepia non-destructive Reading Mode, top page progress hairline, Back/Forward history menus, bookmark search and overflow menu, Recently Closed in Cmd+K and History, Move to Space and shared live pins, Add Image to Photos, Privacy site permissions management, opt-in in-window video full screen, native Web Inspector dock toggle, interactive PiP controls, Agent prompt retry/edit, and full-screen Escape routing.

Zero-delay single-reflow 120 FPS ⌘; Agent & Sidebar slides on heavy pages like X/Twitter, polished 5-step onboarding UX, and 13 kernel-verified Lean 4 proofs.

Silky 120 FPS Agent & Sidebar edge-drag resizing and open/close sliding: wired real WebKit async live-resize (viewWillStartLiveResize + backPage), deferred UserDefaults writes until drag end, disabled spring/timer churn and mid-drag drawer flips during drags, replaced blocking window.setFrame with non-blocking CoreAnimation window.animator().setFrame, and proved balanced single-write live-resize in Lean 4.

Engine-level 120 FPS scrolling across every website: enabled WebKit GPU fixed-position compositing for sticky headers/navbars (GitHub, X, Notion, Linear, Reddit, docs), added opaque CALayer blur occlusion behind WKWebView so WindowServer skips live backdrop blur on ~98% of viewport pixels, and converted ScrollRelay to trailing-edge debounce + native scrollend so active scrolling triggers zero layout reads, zero IPC, and zero SwiftUI redraws (proved in Browse.ScrollFastPath).

Universal 120 FPS scrolling across GitHub and every site on the web: eliminated scroll-induced mouseover IPC & LinkBubble redraws, removed all permanent wheel and idle capture scroll listeners across Swipe, AutoScroll, SelectionBar, and Forms, throttled ScrollRelay reading-bar IPC, switched the page backdrop to an explicit O(1) CALayer.shadowPath, and expanded the Lean 4 formal proof suite to 12 kernel-verified invariants (ScrollFastPath, AgentTabGroup, LinkModifiers, UpdatePolicy, HoverStability, EscapeTermination, OverlayMutex, and more).

Eliminated ⌘K and ⇧⌘\ hover/scroll shaking, removed hover row-height reflow across History, Downloads, Passwords, and Tab Overview cards, fixed Escape-key dismissal for Welcome, Bookmarks, and History search (verified by two new Lean 4 proofs: Browse.HoverStability and Browse.EscapeTermination), and upgraded automatic update checks to every 2 hours with a quiet in-chrome Relaunch banner and Check for Updates… menu item.

Added a dedicated collapsible Agent tab group (with one-click Clear, right-click Move to My Tabs / Move to Agent Group, and session persistence) so agent-opened tabs stay cleanly separated from personal tabs, and made ⌘+click open links in a new foreground tab (⌘⇧+click for background).

Inline /skills in the Agent composer and ⌘K switcher, @history mentions and local Personal Memory, YouTube video timestamp chat with clickable seeking, a floating selection action pill (Ask, Explain, Rewrite, Copy), a visual ⌃Tab MRU switcher with live previews, optional auto-archiving of stale unpinned tabs, and Lean-verified mutual exclusion across all modal overlays so ⌘K and ⌘Y can never stack.

Zero-warm-time multi-agent ACP engine (Antigravity, Codegraff, OpenCode, Gemini, Grok, Devin, Hermes, Pi), universal Shield cosmetic safety fixing blank Gmail emails, smoother 120 FPS X.com scrolling, and symmetric Full Screen Agent card alignment with desktop viewport preservation.

Auto-hiding Full Screen top panel with a seamless pure-black bezel canvas and centered reveal handle, plus a unified ⌘K Command Switcher that surfaces websites, bookmarks, history, and web search alongside open tabs.

Fix Apple Developer and Apple Account passkey sign-in via WebAuthn largeBlob support, and eliminate bright corner bleed artifacts on rounded page cards.

Image pasting and Fast/Ultra Fast speed modes in graff, Dark Mode chrome fix on dark SPAs, major X/Twitter and main-thread performance optimizations (48× faster History, 59× faster Bookmarks), and Lean 4 formal verification proofs.

Fixed ⌘L to always supersede web pages, focus the address bar immediately on mount, dismiss blocking overlays, and select the entire URL.

Single-letter visited domain autocomplete in the Omnibox (x → x.com) with visited-first exact host ranking, plus hardened macOS Keychain password vault (device-only accessibility, fail-closed Touch ID auth, 0o700 zero-wiped import snapshots, and 45s clipboard auto-clear).

Redesigned 5-step onboarding tour, automatic macOS Full Disk Access list registration, ⌘; / ⇧⌘; superseding macOS spellcheck and web page handlers, capsule pill layout fixes, and automated UI layout regression tests.

Smarter top bar with clickable Site Info/shield popover, one-click Zoom reset pill, Reading Mode badge, and Tab Overview button; Omnibox bookmarks, favicons, and open-tab badges; Find on Page live match counter and ⇧↩ stepping; Little-Arc header bar on Shift-click Peek with Open in Split; cross-Space ⌘K and ⇧⌘\ tab search with Space badges; live sidebar Downloads indicator; and graff/browse copy cleanup.

Arc & Dia frosted glass floating cards, deferred New Tab Command Bar, and @-tab mentions; upgraded ⌘K Tab Switcher with live sneak-peek previews and ⇧⌘\ Visual Tab Overview Grid; cross-section Settings Search (⌘F); graff Harness mark with local Harness MCP integration and Dia-style active-tab indicator; 120 FPS Agent sidebar slide and chat scrolling; and updated macOS 27 Chrome import flow.

True 120 FPS scrolling by default with passive/layout-free scroll hooks, zero-lag native AppKit composer and isolated omnibox typing, NanoHarness parity (rounded accent caret, slash-command completion, prompt recall, ⌘↩ interrupt/send-queued, ⌘⇧E full-page Write mode, context usage ring, jump-to-bottom pill, and rotating working trailer), cleaner left sidebar, unified 52pt title horizon, tactile active tab pills, Aside address pill with Split View button, and refined Split View framing & resizing.

Aside-style compact top address bar with page tint and top-right Ask pill, redesigned full-height Agent Sidebar with unified docked composer and streamlined header, BrowserBench/Speedometer DOM performance fixes, smoother ⌘S sidebar fold, sideways scroll Back-swipe guard, and embedded MCP read-only tool annotations.

Always-visible model picker with 1-click opaque popover, rich Markdown tables and native LaTeX math in Codegraff replies, Sync with iCloud, Handoff, Reddit ad blocking, 600% PDF zoom, 10 more browser imports, faster animations, and smaller release binaries.

Always-visible model picker with 1-click opaque popover, rich Markdown tables and native LaTeX math in Codegraff replies, Sync with iCloud, Handoff, Reddit ad blocking, 600% PDF zoom, 10 more browser imports, faster animations, and smaller release binaries.

Passkeys under sign-in fields with agent auto-focus, customizable hotkeys and global summon, bundled browse-mcp server with Follow pill, 120 FPS AppKit Split View, NanoHarness 1:1 model picker, Low-RAM memory profiles, and high-contrast ⌘; Agent Sidebar keycaps.

Continue the same Browse conversation in a browser. Enable Continue in browser from the chat menu, then open the link on another device and sign in to the same Codegraff account. Messages, activity, questions and Stop stay connected to the agent on your Mac.

Codegraff setup now takes you straight into the side chat, with native switches and clearer recovery when graff is missing. Browser tools are connected directly to each chat. Turning Codegraff off stops pending setup work, and web sign-in handles retries, cancellation and sign-out consistently.

A clearer five-step welcome tour gets you from setup to a first research draft. Codegraff now offers an optional local task library, drafts that stay with their tabs, and a visible guide to shortcuts, context and follow-ups. Saved instructions are reviewed before sending, and existing draft text is kept.

Command-semicolon (⌘;) now opens and closes Codegraff, including while typing. The menu, hints and shortcut guide show the new key. Refreshed the bundled rules for blocking ads and trackers.

Codegraff now shares a calmer chat beside your pages and in the expanded conversation. See which page is attached, pin or exclude it, and review selected passages before sending. Follow reported actions, sources and task progress, inspect agent pages when you choose, and see when the agent needs an answer or approval. Provider logos make model choices easier to recognise. Reconnect restores the conversation and holds queued follow-ups for your next send; reviewed problem reports are available in the chat and through /feedback. Includes refreshed ad and tracker blocking rules.

A simpler icon, the same as the website's: two pages and the sun between them.

Onboarding shows what Google's suggestions as you type look like, and asks before turning them on. Google's suggestion rows wear its icon, and a new Mac fetches it once instead of showing a magnifying glass.

Bring things over from another browser in one sheet — Chrome and its channels, Arc, Brave, Edge, Vivaldi, Dia, Opera, Comet, Helium, Firefox and Zen: bookmarks, history and passwords from every profile, with nothing added twice, and on macOS 27 browse asks for Full Disk Access and carries on by itself once it's on. ⌘D splits with a new tab when there's no other page to put beside. Bookmark folders of your own, a default page zoom for every site, a switch for Prevent cross-site tracking, and a long list of fixes to tabs, scrolling, downloads and extensions.

In Split View, the page you're typing in is now the page in front, so ⌘L, Find and Codegraff act on it. And the highlight in Settings' list of pages follows the pointer instead of staying on a row it has left.

In Split View, the page you're typing in is now the page in front — a page that put its own search box in focus no longer leaves ⌘L, Find and Codegraff acting on the other side.

Split View: ⌘D puts two tabs side by side, or pull a tab onto the page — each on a card of its own, the gap pulled to share the room, and the pair still there next launch. The sidebar is glass that takes on the colour of the page beside it, and goes dark on a dark page. Codegraff's chat reads as Harness draws it, keeps a queue of what you type while it works, and can be pinned to one tab — Fill in with Codegraff appears on a page with a form. Tidy This Page takes off the cookie bars and pop-ups the ad blocker let through. Chrome's history comes over, from onboarding or History, and the ad blocker no longer blocks whole sites by accident — Google's logo is back.

Bring your Chrome, Arc or Dia profiles over as spaces, signed in where you were, and Safari's bookmarks, history and passwords from its export. Ads and trackers are blocked with EasyList and EasyPrivacy — many more of them, still before a page loads. Passwords can sync between your Macs, sealed like your history and bookmarks. And Connected apps lets another app on your Mac — Harness first — use browse for its agents: paired once with a code you check, only what you allow, and a pill that says when it's working.

browse 1.0.3 makes setup clearer with live site-icon previews, more keyboard shortcuts, and an optional one-time reminder after setup. Codegraff now sits in a rounded panel with a roomier composer, and About has clearer product information and update controls. Search history brings back past queries as you type and keeps literal plus signs such as C++. Background tabs sleep sooner, and Codegraff's page-reading tools avoid unnecessary resources. The README includes quiet-window screenshots, a polished form demo, and a reproducible RAM and app comparison with Chrome.

browse, with Codegraff built in. Themes — browse's own, the Codegraff app's and codegraff.com's colours, Nord, Forest, or one Codegraff makes from a sentence. Sign in with Codegraff from the welcome screens, and your history, bookmarks and themes sync between your Macs — once Codegraff's server turns it on — sealed so only your Macs can read them. Codegraff hands the clicking on forms and filters to Jev, a step at a time. browse now updates itself, and tells you when your Mac's web engine is missing Apple's security fixes. And everything from Search 1.0.2 and 1.0.3: peek at a link, a bookmarks bar, a small window for links from other apps, and their security and stability fixes. Google's sign-in card no longer sits in a white box on dark sites.

The first update, made of a day of your replies and pull requests. Search opens again on macOS 14, and signing in to Google no longer reloads the page over and over with iCloud Passwords installed. New, each off until you turn it on in Settings: Spaces, a sidebar that hides until the pointer reaches the edge, and the search engine of your choice. Also new: ⌘S folds the sidebar away, a middle-click closes a tab, a tab can be renamed, and the Web Inspector is in the View menu. Fixed among others: ⌘1–⌘9 on every keyboard layout, Tab between the fields of a form, dragging tabs, a double-click along the top to fill the screen, and the Mac's beep while typing.

The first version. A browser for the Mac with nothing in the way: tabs in a row or down the side, pinned tabs that keep their place, and one field for addresses and searches. Ads are blocked before they load; passwords and passkeys stay in your keychain; anything on a page can be hidden; articles open in a reading mode and videos float. Chrome extensions install from the Chrome Web Store on macOS 15.4 or later — its button says Add to Search. Tabs you haven't looked at for half an hour sleep and give their memory back. It runs on the engine already in macOS and weighs 2.9 MB.
