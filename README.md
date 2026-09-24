# Search by Codegraff

<img src="Icon/search-by-codegraff.png" alt="Search by Codegraff icon" width="160">

Search by Codegraff is a macOS web browser built from [Search by Office Commun](https://github.com/driceroland/Search). It keeps Search's compact WebKit browser and adds Codegraff alongside the page for working with what you find. This repository remains a fork of the original project; Office Commun's authorship and MIT copyright notice are preserved in [LICENSE](LICENSE).

## What it does

- Opens pages with the WebKit engine included with macOS.
- Keeps tabs across the top or in a sidebar, with bookmarks, history, downloads, private tabs, reading mode, and page search.
- Supports ad blocking and per-site hidden elements.
- Supports WebKit browser extensions on macOS 15.4 or later.
- Offers a Codegraff panel and Ask tab for working beside a page. The browser launches the installed `graff` command for these conversations; it does not bundle the agent.

![Browser window inherited from Search](.github/screenshot.png)

The screenshot comes from the upstream browser and may not show the current Codegraff interface.

## Build

You need macOS 14 or later and an Xcode 16 / Swift 6 toolchain.

```sh
swift build
./build.sh
open "build/Search by Codegraff.app"
```

`swift build` makes the command-line SwiftPM executable. `./build.sh` assembles the macOS app, including the Codegraff icon in `Icon/search-by-codegraff.png`. The local app is ad-hoc signed. macOS may require **Open** from the context menu on first launch.

`./build.sh release dmg` also makes `build/Search-by-Codegraff.dmg` and `build/Search-by-Codegraff.zip`. Publishing a notarized release needs your own Developer ID identity, provisioning, and release host. The upstream Office Commun passkey provisioning profile does not apply to this fork's bundle identifier.

## Data and updates

Search by Codegraff uses the bundle identifier `com.codegraff.search` and keeps its data in `~/Library/Application Support/Search by Codegraff/`. It does not overwrite the original Search app or its local browser profile.

No update feed is configured by default. A distributor can set `SEARCH_FEED` to a fork-owned appcast URL; `SEARCH_DOWNLOAD_URL` supplies the corresponding download base when packaging a release. The browser does not fetch or install Office Commun releases.

For an isolated test profile, run `./fresh.sh`. Set `SEARCH_PROBE=NAME` to name a separate test world.

## Project layout

The SwiftUI and AppKit app lives in `Sources/Search/`. `Package.swift` builds the `Search` executable, which `build.sh` places inside the branded app bundle. `Icon/search-by-codegraff.png` supplies both the Dock icon and the in-app brand image. `./bench` drives a test run through its local socket when the test setting is enabled.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the original project's development guide. Some historical documents and helper scripts in this fork still describe upstream Search releases; they are kept as part of the fork history.

## Origin and license

This project is forked from [driceroland/Search](https://github.com/driceroland/Search), created by [Office Commun](https://officecommun.com). Search by Codegraff retains the upstream source, its history, and its [MIT license](LICENSE), including **Copyright (c) 2026 Office Commun**. The original Search name and icon belong to Office Commun; this fork uses its own name and icon.
