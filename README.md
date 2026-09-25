# browse

<img src="Icon/browse.png" alt="browse icon" width="96">

A Codegraff browser for the Mac. Browse with WebKit, ask about what you're reading, research something, or have [Codegraff](https://github.com/justrach/codegraff) fill in a form while you watch.

**[Download for macOS](https://github.com/justrach/search/releases/latest)** · macOS 14 or later · open the disk image and drag the app to Applications

![Illustration of a browser page with an assistant panel beside it](docs/readme-banner.png)

*Illustration above; the images below show the app.*

![browse showing a Wikipedia article, with the tabs across the top](docs/screenshots/browse.png)

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

For work of many small steps, like a search with its filters or a date picker, Codegraff can hand the clicking to [Jev](https://docs.typesafe.ai/introduction), the way [jev-ultrafast](https://github.com/browser-use/jev-ultrafast) does. Each step is one quick call that picks the action and the element. Codegraff's model still plans the task and gives Jev the text to type, and Jev doesn't make up any text of its own. It goes through your Codegraff sign-in. Settings › Agent › Quick steps with Jev turns it off.

![Codegraff has filled in a pizza order form on the page and says it did not submit it](docs/screenshots/fill-a-form.png)

The model picker under the field searches every model your Codegraff account reaches.

### What Codegraff needs

The browser doesn't ship an agent. It runs the `graff` command already on your Mac, the one the [Codegraff](https://github.com/justrach/codegraff) app installs, and uses your own Codegraff sign-in. Without it the browser works as normal, and the Ask tab offers to get it for you.

- **What leaves your Mac:** what you type to Codegraff, and the text of the page when you ask about it, go to the model provider your Codegraff account uses. When Jev takes the steps, the page's visible words and controls go to Jev through Codegraff. Password fields never go. Nothing else leaves.
- **It stays light:** by default it runs with the browser's tools and its own, not every MCP server your other apps know about (Settings › Agent can include them). After ten quiet minutes it stops, and your next message picks the same conversation up.
- **It acts without stopping to ask** before each step, as `graff acp --yolo` does, including commands and file edits on your Mac. Treat it as you would any agent with those powers.

Turn it all off in Settings › Agent.

## Known limits

- Passkeys aren't available in this build yet. They need a provisioning profile of this app's own, which it doesn't have.
- It doesn't update itself yet. New versions appear on the [releases page](https://github.com/justrach/search/releases).

## Build it yourself

You need macOS 14 or later and Xcode 16 (Swift 6).

```sh
swift build                        # the SwiftPM executable
./build.sh                         # build/browse.app, signed for this Mac
open build/browse.app
```

`./build.sh release dmg` also makes `build/browse.dmg` and `build/browse.zip`. `SEARCH_NOTARY_PROFILE=<profile> ./build.sh release ship` signs and notarizes them with your Developer ID and a `notarytool store-credentials` profile of your own.

`./fresh.sh` opens a copy with a profile of its own, apart from the one you browse with. `./bench` drives a running copy from the shell once Settings › General › "Let a script drive browse" is on. See `skill/search-bench/SKILL.md`.

The app keeps its data in `~/Library/Application Support/Search by Codegraff/`, under the bundle identifier `com.codegraff.search`. This name change preserves existing profiles.

The SwiftUI and AppKit code is in `Sources/Search/`. `Agent.swift`, `AgentColumn.swift`, `AgentHome.swift`, and `AgentTools.swift` connect the browser to Codegraff.

## License

browse is a Codegraff product released under [AGPL-3.0](LICENSE). Code from before the Codegraff work remains the property of its original owner and retains its [MIT license and copyright notice](LICENSE.MIT).
