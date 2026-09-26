# browse

<img src="Icon/browse.png" alt="browse icon" width="72">

**A quieter browser for the Mac, with Codegraff beside the page.**

browse is a small WebKit browser for reading, searching, and getting things done. Keep the page in view while [Codegraff](https://github.com/justrach/codegraff) researches a question, follows links, or helps with a form.

**[Download browse for macOS](https://github.com/justrach/browse/releases/latest)** · macOS 14 or later · signed and notarized

![browse showing a Wikipedia article in a light window](docs/screenshots/browse.png)

## Room for the page

The tabs and the page are the whole window. Press **⌘L** for an address or search, **⌘K** to find an open tab, or **⇧⌘R** for reading mode. Put tabs across the top or down the side; pin the ones you keep, and idle tabs sleep to free memory.

The things you expect from a browser are here too: blocking for ads and trackers before pages load, picture-in-picture video, passwords in your Mac keychain, and Chrome extensions on macOS 15.4 or later. Peek, a bookmarks bar, and a small window for links from other apps are available in Settings when you want them.

## Ask, without leaving

The Ask tab gives Codegraff a place for a question or a task. Ask about the page you're reading with **⇧⌘A**, or press **⌘↩** in the address field to send the page with your question. The conversation can stay in a column next to the site, with its answer and sources in sight.

![Codegraff making a theme beside a Wikipedia page](docs/screenshots/make-a-theme.png)

*A theme made from a sentence, beside the page.*

Codegraff can search, read several pages, click, type, and fill forms on your tab. It reads the fields and their labels before filling them, then leaves you to check anything that matters. It is instructed to ask before submitting a payment, post, booking, or signup.

![Codegraff fills a form on the page and reports what it did](docs/screenshots/fill-a-form.png)

*Fields filled; the form is left for review before submission.*

For a series of small interactions, Codegraff can use [Jev](https://docs.typesafe.ai/introduction) to choose the next click or control. Your Codegraff account supplies the models available in the picker.

<p align="center"><img src="docs/images/reading-workshop-v1.png" alt="Two illustrated mice reading and filing pages" width="560"></p>
<!-- Illustration generated with OpenAI ImageGen. Product screenshots are captures of browse. -->

## Make it feel like yours

Choose a light or dark look in Settings › Themes: browse, Codegraff, Codegraff Paper, Nord, or Forest. You can also describe a theme to Codegraff, import one from a JSON file, or edit one yourself.

![Theme choices in browse settings](docs/screenshots/themes.png)

Sign in with your Codegraff account to use the agent. It is the same account used by `graff` in your terminal. When Codegraff's sync server supports it, you can switch on end-to-end encrypted sync for bookmarks, history, and themes; the sync key stays with your Macs and moves to a new Mac through a sync code. Settings › Sync shows when the service is available.

## What leaves your Mac

- Questions you send to Codegraff, and page text when you ask about a page, go to the model provider your Codegraff account uses. When Jev handles a step, the page's visible words and controls go to Jev through Codegraff. Password fields are excluded.
- If you turn on sync, encrypted bookmarks, history, and themes go to Codegraff's server.
- Anonymous device and memory statistics are optional and off by default in Settings › Privacy. You can see the [aggregate statistics](https://search-codegraff-stats.rachpradhan.workers.dev).
- The daily update check asks GitHub for the latest release. An update is installed for the next launch only after browse checks that it is newer and signed by the same developer.

Codegraff runs as the `graff` command on your Mac, installed by the Codegraff app. It can run commands and edit files as well as use the browser, without a permission prompt for each action. You can switch the agent off in Settings › Agent.

## Build from source

You need macOS 14 or later and Xcode 16.

```sh
swift build        # SwiftPM executable
./build.sh         # build/browse.app, signed for this Mac
open build/browse.app
```

`./fresh.sh` starts a copy with its own profile. `./bench --test` drives that test copy from the shell; see [browse-bench](skill/browse-bench/SKILL.md). The SwiftUI and AppKit source lives in `Sources/Browse/`.

Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first. [Release notes](CHANGELOG.md), the [roadmap](ROADMAP.md), and [release process](docs/releasing.md) have more detail.

## Current limits

- Passkeys depend on Apple granting browse the browser passkey entitlement and signing the app with it. See [releasing.md](docs/releasing.md).
- Sync needs Codegraff's server to support it. Until then, Settings › Sync says so.
- Versions before 1.0.2 need one manual download to start receiving automatic updates.

## License

browse is a Codegraff product under [AGPL-3.0](LICENSE). Earlier code retains its original owner's [MIT license and copyright notice](LICENSE.MIT). The Jev step code adapts Browser Use's jev-ultrafast (MIT).
