# browse and Chrome: RAM and app comparison

The comparisons below measure app size and runtime memory on one Mac. Runtime totals include the browser and its attributable helper processes, including WebKit. These observations support specific workload comparisons, not a universal faster, cheaper, or better claim.

## Matched-window RAM results

**One local page: 186.1 MiB for browse and 340.0 MiB for Chrome.** These are whole-resource-coalition physical-footprint medians of three snapshots at 140, 145, and 150 seconds, with equal 1100 × 750 outer windows. browse's observed footprint was **45.3% lower** (Chrome/browse: 1.83×) in this specific run. This is a browser-overhead workload, not a general claim about RAM on real websites.

| One local page | 140-second sample | 145-second sample | 150-second sample | Median |
| --- | ---: | ---: | ---: | ---: |
| browse | 186.08 MiB | 186.08 MiB | 186.10 MiB | 186.1 MiB |
| Chrome | 340.00 MiB | 339.90 MiB | 340.04 MiB | 340.0 MiB |

browse retained one awake tab. Chrome's one page target was retained; its discard state was not measured. This repeat supersedes the unstable 30-second one-tab diagnostic below. [Raw matched one-tab results and process breakdown](../benchmarks/browser_memory_single.json).

The final one-tab process snapshots show why the main PID alone is incomplete:

| Recorded process role | browse | Chrome |
| --- | ---: | ---: |
| Main browser process | 51.5 MiB | 101.2 MiB |
| Web-content / renderer processes | 23.0 MiB (one process) | 51.6, 31.4, 26.1 MiB (three processes) |
| Engine and other helpers | WebKit GPU and Networking, Metal compiler services, audio helper, update service | Chrome helpers, Safari platform helper, crash handler, update service |
| Total coalition process count | 8 | 10 |

These role readings come from the final process snapshot, not the median timestamp. They are **not additive**: the aggregate de-duplicates shared mappings. The raw files retain every included PID, role, and footprint. Different engines allocate work differently, so renderer counts do not directly equal awake-tab counts.

### Ten-page synthetic workload

Both windows were 1100 × 750. The workload contains four articles, three 600-card boards, and three canvas charts; details and limitations follow below. Values are whole-coalition physical footprint.

| Ten retained pages | 140-second sample | 145-second sample | 150-second sample | Median | 30s after closing nine |
| --- | ---: | ---: | ---: | ---: | ---: |
| browse | 717.65 MiB | 288.51 MiB | 288.46 MiB | 288.5 MiB | 298.0 MiB |
| Chrome | 701.03 MiB | 700.93 MiB | 700.93 MiB | 700.9 MiB | 761.3 MiB |

browse retained **four awake pages and six sleeping tabs** at the end of the 150-second phase. Chrome retained all ten page targets; its discard state was not measured. browse's high 140-second reading makes this a variable sampled window, not a stable plateau. browse’s coalition process count remained 13 across those three readings; the saved observations do not establish the cause of the transient. Accordingly, this result is not presented as a general RAM multiplier.

After closing nine tabs, browse reported the remaining article awake. Both browsers' footprints were higher than their last 150-second readings; this test does **not** demonstrate immediate memory reclamation. Reopening the retained article can wake a sleeping page. [Raw mixed results, all observed phases, and process breakdowns](../benchmarks/browser_memory_mixed.json).

## Measured app size

Measured on September 26, 2026, on a Mac15,14 running macOS 27.0 (26A428), using `du -sk` on each complete app bundle:

| App | Version / build | Executable architectures | Allocated disk space |
| --- | --- | --- | ---: |
| browse, installed | 1.0.2 / 202609251554 | arm64 | 9,604 KiB (9.38 MiB) |
| Google Chrome, installed | 153.0.8010.54 / 8010.54 | arm64 + x86_64 | 2,192,536 KiB (2.09 GiB) |
| browse, CI commit `8452b4d` | 1.0.2 / 202609260345 | arm64 | 9,820 KiB (9.59 MiB) |

Chrome's installed bundle occupied **228.3 times the disk space** of the installed browse bundle in this measurement. The distributions differ: Chrome contains both CPU architectures, while browse contains arm64, and browse uses WebKit supplied by macOS. The calculation excludes the system WebKit frameworks, profiles, caches, downloads, and the separate `graff` installation. It measures neither total dependency size nor RAM, energy, download size, or page speed. The CI build is listed separately because it is not the same binary as the installed release.

Reproduce the bundle measurement with:

```sh
python3 benchmarks/bundle_footprint.py > benchmarks/bundle_footprint.json
```

To include a test/CI bundle as the third row, add `--ci-app /path/to/test/browse.app --ci-code-label YOUR_COMMIT`.

[Raw measurements](../benchmarks/bundle_footprint.json) include versions, architecture, logical file bytes, allocated KiB, and the exact ratio. The script reads bundles without opening either browser. Filesystem compression and allocation can affect these results on another Mac.

## Price and capabilities

[Google Chrome is free to download](https://support.google.com/chrome/answer/95346/download-and-install-google-chrome-computer?co=GENIE.Platform%3DDesktop&hl=en-GB). browse's [direct release download](https://github.com/justrach/browse/releases/latest) and [source](../LICENSE) are available without a browser purchase. There is no meaningful “times cheaper” ratio between two zero-price downloads. Codegraff account and model usage are separate from downloading browse; a task-cost comparison would need the same tasks, model, success criteria, retries, and actual charges for both alternatives.

browse's native Mac interface, optional hidden tab bar, and Codegraff beside the page are reasons someone may prefer it. They do not turn into a numerical “better” score. Chrome and browse also use different engines; compatibility, extensions, accessibility, and everyday sites should be evaluated against the person's own needs.

## App comparison

Capabilities checked September 26, 2026. The runtime measurements below concern the Mac versions.

| | browse | Google Chrome |
| --- | --- | --- |
| Platforms | macOS 14 or later ([package](../Package.swift)). | Windows, macOS, Linux, Android, and iOS; requirements vary by platform ([Google requirements](https://support.google.com/chrome/answer/95346?hl=en)). |
| Engine on Mac | WebKit supplied by macOS; native SwiftUI/AppKit browser shell. | Bundled Blink rendering engine and V8 JavaScript engine ([Chrome engine overview](https://developer.chrome.com/docs/web-platform/blink)). |
| Browser controls | Tabs across the top or in a sidebar; ⌘S hides either, with temporary edge reveal. | Standard tabs, toolbar, and address field in the captured comparison. |
| Agent | Codegraff beside the page, using the separately installed `graff` and the user's account/model configuration. Usage terms are separate from the browser download. | Optional Gemini features depend on account and availability; advanced Auto Browse has paid-plan eligibility ([Gemini](https://support.google.com/chrome/answer/16283624?hl=en), [Auto Browse](https://support.google.com/gemini/answer/16821166?hl=en)). |
| Extensions | Chrome Web Store packages through Apple's `WKWebExtension` on macOS 15.4+. Compatibility must be checked per extension; this is not full Chrome API parity ([implementation](../Sources/Browse/Extensions.swift), [Apple unsupported APIs](https://developer.apple.com/documentation/webkit/wkwebextensioncontext/unsupportedapis)). | Desktop Chrome Web Store extension platform ([Google extension help](https://support.google.com/chrome/answer/2664769?hl=en)). |
| Runtime memory | Measured as aggregate physical footprint of the app and its resource-coalition helpers, including WebKit. | Measured with the same macOS tool and aggregation rule, including renderers, GPU, and other attributable helpers. |

## Runtime memory measurements

Runtime observations use the same Mac15,14 with 28 logical CPUs and 256 GiB RAM. This high-memory machine does not reproduce the memory pressure of a typical laptop.

The reproducible runtime harness measures **the browser's whole resource coalition**, including its WebKit or Chrome helper processes. This is different from reading the main application PID. It queries macOS resource-coalition membership through `libproc`, then passes the identified PIDs together to Apple's `footprint` tool. The tool de-duplicates shared mappings in its aggregate physical-footprint result. Per-process values are retained for inspection and should not be added to reconstruct the aggregate.

This is physical footprint, including charged dirty/compressed memory, rather than RSS, the size of the app on disk, or all system RAM attributable to browsing. OS frameworks and services may be shared with other applications. The coalition query uses a private Darwin interface verified on the measured OS; the script rejects failed or ambiguous ownership rather than reporting an incomplete number. The layout is defined in Apple's [XNU process header](https://github.com/apple/darwin-xnu/blob/main/bsd/sys/proc_info.h).

The workload is deliberately small: 1, 5, or 10 normal tabs containing the same minimal local HTML page, each with a unique URL. This isolates browser overhead. It is not representative of ten independent web applications; same-origin pages can share processes. Each case uses a fresh test profile, no extensions added, and no AI prompt. Default tab-sleep behavior remains enabled. browse runs from an isolated copy of CI commit `8452b4d`, with a separate bundle identifier and test world; Chrome uses a temporary profile. The user’s existing browser sessions remain open and untouched. The minimal-page cases used each browser’s default window bounds, so their viewport sizes were not matched; treat those as diagnostic overhead observations.

For 1 tab, samples at 20, 25, and 30 seconds describe the startup window. For 5 and 10 tabs, the harness takes a 30-second snapshot, then samples at 140, 145, and 150 seconds and reports their median. The longer interval allows browse’s default crowded-tab sleeping policy to run. browse’s awake-tab count is recorded, because a sleeping tab may have to reload when revisited. Chrome’s page targets are checked for retention, but the harness does not measure Chrome’s discard/awake state. An initial snapshot after all pages report `DOMContentLoaded` is retained; it is **not a loading peak**. These are snapshots of one launch per case, not independent repeated trials. Run order is alternated across cases; OS caches are not flushed, and fresh profiles can perform background initialization or update work. Observed coalition members include Metal compiler services and, for Chrome, updater processes.

### Matched mixed workload

The second workload uses ten synthetic pages: four long articles (240 paragraphs each), three boards (600 cards each, with inline SVG and controls), and three 1200 × 800 canvas charts (100 series of 600 points). All assets are local and deterministic. This is a DOM/canvas stress fixture, not a representative sample of everyday websites. It omits real-site network traffic, media playback, and application JavaScript. The fixture source is [workload.py](../benchmarks/workload.py); the results retain its content hash.

Both outer windows are verified at **1100 × 750 points**, with page 9 (a canvas chart) active. This matches window dimensions, not content viewport height: the browsers have different controls. After all page-ready beacons and window setup, measurements run for 150 seconds with normal tab sleeping enabled. The final three readings form the median of the sampled window; a median does not establish a stable plateau. Then nine tabs close, leaving article 0 selected; a further snapshot follows 30 seconds later. That reading describes this particular close-and-wait sequence, not a guarantee that all memory is returned immediately. Selecting article 0 can wake and reload a sleeping page.

Loading samples occur roughly every two seconds and can miss short spikes. Their largest successful value is an **observed sample maximum**, not an instantaneous peak. Readiness means DOM construction and synchronous canvas drawing commands have completed, not visible first paint. Loading starts before the window-size adjustment, so loading observations do not have the matched-window guarantee of the settled and post-close phases. Only one successful loading sample was captured for browse; no loading-peak comparison is reported. Both retained mixed cases received all expected page-ready beacons; neither required a DOM-readiness fallback.

### Minimal-page diagnostic results

The initial run used default, unmatched window bounds. These figures are supporting observations; use the matched-window mixed workload for the stronger comparison. Physical footprint is in MiB (1,048,576 bytes).

| Retained tabs | browse median | Chrome median | Sampling window | browse awake tabs |
| ---: | ---: | ---: | --- | ---: |
| 1 | 216.7 | 600.9 | 20–30 seconds; Chrome still declining | 1 |
| 5 | 239.5 | 495.9 | 140–150 seconds | 4 |
| 10 | 224.8 | 623.1 | 140–150 seconds | 4 |

The 1-tab Chrome readings fell from 1,300.6 to 475.3 MiB over the sampling window, so its median is **not a steady-state result** and should not be compared with the 150-second rows as a scaling curve. The 5- and 10-tab browse values both represent four awake pages with the remaining tabs retained asleep. The lower 10-tab result does not establish that adding tabs saves memory. [Complete raw run and per-process breakdown](../benchmarks/browser_memory.json).

Several diagnostic attempts were excluded after harness errors: tab-ID parsing, an asynchronous close confirmation, a missing page-ready beacon, and a helper exiting during memory collection. The completed datasets retain only verified observations. Captures now retry transient PID exits with a fresh coalition enumeration; a failed observation must not silently omit a live helper. The successful Browse rows were retained when only the Chrome case needed rerunning. These are one observed case per workload/browser, not repeated independent trials or confidence intervals.

### Reproduce the runtime measurements

Run only against a test build while the desktop is available; these commands open temporary browser windows. The scripts use Python 3 and macOS system tools. The mixed and one-tab scripts additionally need the Python `websockets` package for Chrome's debugging protocol (`python3 -m pip install websockets`). Their isolated profiles contain no account sign-in or personal browsing data.

```sh
python3 benchmarks/browser_memory.py --run --browse-app /path/to/test/browse.app --code-label YOUR_COMMIT > benchmarks/browser_memory.json
python3 benchmarks/browser_memory_mixed.py --run --browse-app /path/to/test/browse.app --code-label YOUR_COMMIT > benchmarks/browser_memory_mixed.json
python3 benchmarks/browser_memory_single.py --run --browse-app /path/to/test/browse.app --code-label YOUR_COMMIT > benchmarks/browser_memory_single.json
```

Use a destination outside the checked-in evidence files when keeping the original run for comparison. The recorded run used CI commit `8452b4d`; passing a different app does not reproduce that exact binary. The isolated copy is given a unique bundle identifier and ad hoc signature. That isolation differs from an installed, signed production profile and is recorded as part of the method.

## What these results do not measure

No speed benchmark or “times faster” claim is reported. A small app bundle does not imply a faster rendering engine. Any launch result should be named for its exact workload: warm-profile launch request to a local page's `DOMContentLoaded` beacon, including Launch Services and loopback delivery. That result would not measure first paint, cold boot, real-site navigation, JavaScript throughput, or agent task completion.

A broader comparison should keep the same Mac, window dimensions, foreground state, tab count, fixture, network conditions, and profile state. Report repeated paired runs and their spread; separate cold and warm conditions. Future memory studies should retain the same full-process accounting used here, and add representative real-site workloads and repeated independent launches. Energy needs a fixed-duration workload. Publish raw trials, failures, versions, and methodology alongside any multiplier.

## How to make it lighter next

These are candidates for measurement, not claimed savings:

1. **Bound the in-memory favicon cache.** [`Icons.swift`](../Sources/Browse/Icons.swift) keeps decoded images and negative lookup sets for the process lifetime. A cost-limited image cache and bounded negative caches could limit growth during long sessions while retaining disk PNGs. Verify memory with thousands of distinct history sites and measure disk reads before choosing a limit.
2. **Make speculative agent startup earn its cost.** [`Browser.swift`](../Sources/Browse/Browser.swift) warms the agent when a multiword query is typed. Starting only after Ask is chosen could reduce unnecessary agent launches, at the cost of slower first responses. Compare process lifetime, idle memory, and first-token latency for ordinary search and Ask workloads.
3. **Reduce updates that nobody can see.** [`AgentColumn.swift`](../Sources/Browse/AgentColumn.swift) updates live-turn duration every second; [`TabBar.swift`](../Sources/Browse/TabBar.swift) animates progress during active work. Pause work when the relevant UI is hidden, then measure CPU and responsiveness during long agent tasks. Active progress feedback should stay understandable.
4. **Protect the optimizations already present.** Web views are created lazily; [`Sleep.swift`](../Sources/Browse/Sleep.swift) sleeps eligible old tabs and responds to memory pressure. [`Tab.swift`](../Sources/Browse/Tab.swift) releases sleeping web views while retaining interaction state. The agent starts lazily in normal use and rests after inactivity. Session writes are already debounced and normally run off the main thread. Benchmark these paths before making them more aggressive: extra reloads and delayed answers also have a cost.

Start with favicon residency because its growth is directly visible in the code. Use identical long-session workloads before and after, and record whole-browser memory, cache misses, and UI latency. None of these changes has a measured saving yet.
