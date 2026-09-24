# Search by Codegraff

<img src="Icon/search-by-codegraff.png" alt="Search by Codegraff icon" width="128">

A small, fast browser for the Mac with an agent built in. It is the quiet WebKit browser [Search](https://github.com/driceroland/Search) with [Codegraff](https://github.com/justrach/codegraff) working beside the page: ask it about what you're reading, send it off to research something, or have it fill in a form while you watch.

**[Download for macOS](https://github.com/justrach/search/releases/latest/download/Search-by-Codegraff.dmg)** · macOS 14 or later · signed and notarized · open the disk image and drag the app to Applications

![Search by Codegraff showing a Wikipedia article, with the tabs across the top](docs/screenshots/browse.png)

## The browser

Tabs and the page, and nothing else in the way.

- **One field.** ⌘L to type an address or a search; it finishes addresses from your own history. ⌘K switches to a tab you already have open.
- **Tabs your way.** Across the top or down the side. Pin the ones you keep all day, and tabs you haven't looked at in a while go to sleep and give their memory back.
- **Built in, not bolted on.** An ad and tracker blocker that runs before the page loads, reading mode (⇧⌘R), video that floats above everything (⇧⌘P), and ⇧⌘H to hide anything on a site for good.
- **Passwords in your keychain,** offered once a sign-in has actually worked.
- **Chrome extensions** from the Chrome Web Store, on macOS 15.4 or later.
- **Light, dark, or the Mac's own.** It runs on WebKit, the engine already in macOS, so the whole app is a few megabytes and opens at once.

## Codegraff, beside the page

The sparkle at the head of the tab row is the Ask tab. It opens Codegraff's own page: one field that asks it anything (Tab switches it to a plain search), and your conversations so far, each a card you can pick back up.

![The Ask tab: a field for a question and the chats so far](docs/screenshots/ask.png)

A conversation reads like a page of its own: what you asked, the work folded into one line that opens to every step, and the answer with its sources.

![A conversation on its own page, answered with three linked sources](docs/screenshots/chat.png)

Ask about the page you're on with ⌘↩ in the address field or ⇧⌘A, and the page goes along with the question. Keep the talk in a column beside the page if you'd rather see both.

![Codegraff in a column beside Hacker News, listing the top five stories with links](docs/screenshots/beside-the-page.png)

It can use the browser too: search, read many pages at once, click, type, and **fill in forms**. It reads a form the way you do (labels, choices, what's required) and fills it in on your tab in front of you. It's told to ask before sending anything that pays, posts, books or signs you up, so check what it has filled before it submits anything that matters.

![Codegraff has filled in a pizza order form on the page and says it did not submit it](docs/screenshots/fill-a-form.png)

The model picker under the field searches every model your Codegraff account reaches.

### What Codegraff needs

Search doesn't ship an agent. It runs the `graff` command already on your Mac, the one the [Codegraff](https://github.com/justrach/codegraff) app installs, and uses your own Codegraff sign-in. Without it the browser works as normal, and the Ask tab offers to get it for you.

- **What leaves your Mac:** what you type to Codegraff, and the text of the page when you ask about it, go to the model provider your Codegraff account uses. Nothing else does.
- **It stays light:** by default it runs with the browser's tools and its own, not every MCP server your other apps know about (Settings › Agent can include them). After ten quiet minutes it stops, and your next message picks the same conversation up.
- **It acts without stopping to ask** before each step, as `graff acp --yolo` does, including commands and file edits on your Mac. Treat it as you would any agent with those powers.

Turn it all off in Settings › Agent.

## Known limits

- Passkeys aren't available in this build yet. They need a provisioning profile of this app's own, which it doesn't have.
- It doesn't update itself yet. New versions appear on the [releases page](https://github.com/justrach/search/releases).

## Build it yourself

You need macOS 14 or later and Xcode 16 (Swift 6).

```sh
swift build                                  # the SwiftPM executable
./build.sh                                   # build/Search by Codegraff.app, signed for this Mac
open "build/Search by Codegraff.app"
```

`./build.sh release dmg` also makes `build/Search-by-Codegraff.dmg`. `SEARCH_NOTARY_PROFILE=<profile> ./build.sh release ship` signs it with your Developer ID and notarizes and staples it, with a `notarytool store-credentials` profile of your own.

`./fresh.sh` opens a copy with a profile of its own, apart from the one you browse with. `./bench` drives a running copy from the shell once Settings › General › "Let a script drive Search" is on. See `skill/search-bench/SKILL.md`.

The app keeps its data in `~/Library/Application Support/Search by Codegraff/`, under the bundle identifier `com.codegraff.search`. It never touches the original Search app or its profile.

The code is SwiftUI and AppKit in `Sources/Search/`. `Agent.swift`, `AgentColumn.swift`, `AgentHome.swift` and `AgentTools.swift` are Codegraff's part; the rest is the browser. [CONTRIBUTING.md](CONTRIBUTING.md) is the original project's guide.

## Origin and license

A fork of [Search](https://github.com/driceroland/Search) by [Office Commun](https://officecommun.com), which keeps its history and its [MIT license](LICENSE), including **Copyright (c) 2026 Office Commun**. The Search name and icon are Office Commun's; this fork has a name and icon of its own.
