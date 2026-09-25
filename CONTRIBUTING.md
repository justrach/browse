# Contributing

SEACHAI is a Codegraff product. Contributions are welcome; a few things make a change easier to review.

## Before writing code

For anything beyond a small fix, open an issue first describing what you want to change and why. It saves a rewritten pull request later if the direction doesn't fit.

## New features: off until someone turns them on

The browser stays small by default. Anything new that changes how it
looks or behaves — spaces, groups, a visible address bar, a new panel — is:

- **minimal**: the smallest version that does the job, in the app's own quiet style;
- **optional, and off by default**: someone who never asks for it never sees it;
- **findable**: a switch in Settings, and a mention in the welcome screens if it's a big one, so people know it's there to turn on.

Fixes and things every browser is expected to do (Tab moving between a form's fields, ⌘1–⌘9) don't need a switch. Before building a bigger feature, look at how other browsers do it and read what people asked for on its issue; [ROADMAP.md](ROADMAP.md) lists where each request came from.

## Where things are tracked

- [ROADMAP.md](ROADMAP.md): everything asked for and not done yet, sorted into what's next and what isn't planned.
- [CHANGELOG.md](CHANGELOG.md): what has changed since the last version. A pull request that fixes or adds something also adds its line under **Unreleased** (and takes its item off the roadmap), so the next update's notes write themselves.

## What tends to get merged

- **Small, focused changes.** One thing per pull request, easy to read start to finish.
- **No new dependencies.** The whole point of this app is staying small; a browser this size doesn't need a package for something Foundation or WebKit already does.
- **Matches the existing style.** Comments here explain *why*, not *what the next line does* — read a couple of existing files before adding a new one. No force-unwraps on anything that can plausibly fail (a network response, a file read, a keychain lookup).
- **Builds clean.** `swift build` with zero warnings you introduced.

## What doesn't

- Rewrites of things that already work, for style reasons alone.
- Anything that phones home, adds analytics, or changes what leaves the app over the network without a clear reason and user control.
- Vendoring Chromium or any other engine. This is a WebKit browser on purpose.

## Review

Open pull requests against this repository. Explain the behavior you changed, how you checked it, and any user-visible tradeoffs. Codegraff maintainers review contributions; ping a stale PR after a couple of weeks.

## Reporting a bug

Open an issue with: what you did, what you expected, what happened instead, and your macOS version. A crash log, if there is one, lives at `~/Library/Application Support/Search by Codegraff/crash.log` — it stays on your Mac unless you attach it yourself.
