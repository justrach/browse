# Releasing browse

A release is a tag, made on a release branch. `./release.sh 1.1.0 "What's new,
in a paragraph."` raises `VERSION`, puts the paragraph at the top of
`NOTES.md`, turns CHANGELOG's Unreleased into the version's section, commits,
tags `v1.1.0`, and pushes. The tag starts `.github/workflows/release.yml`,
which:

1. builds the app on a macOS runner,
2. when all signing secrets are present, signs it with the Developer ID and
   the hardened runtime, notarises the DMG and ZIP, staples and checks the
   DMG, then publishes `browse.dmg`, `browse.zip` and `appcast.json`;
3. otherwise, keeps a three-day release-candidate artifact with the ad-hoc
   signed app, source commit, version, build, and executable hash. It does
   **not** publish that candidate.

Every installed copy reads `releases/latest/download/appcast.json` once a day
(`Updater.swift`), fetches the ZIP, checks it is this app, newer, and signed
by the same team, and swaps it in for the next launch. So publishing is also
the update.

Every push to `main` or a release branch, and every pull request, runs
`.github/workflows/build.yml`: the app builds, and the stats Worker's tests
pass. Nothing there is signed.

## Branches

| Branch | What goes there |
|---|---|
| `main` | Everything, by pull request. What the next X.Y will be. |
| `release/vX.Y` | One per X.Y, cut from `main` for X.Y.0. Its tags, `vX.Y.0`, `vX.Y.1`…, are made here and nowhere else. |

- **A new X.Y** — on an up-to-date `main`, `./release.sh 1.1.0 "…"`. It cuts
  `release/v1.1` from `main`, releases from it, and merges the version's
  commit back into `main`.
- **A fix to a line that's out** — merge the fix into `main` first, then
  carry it over and release from the line's branch:

  ```sh
  git switch release/v1.1 && git pull --ff-only
  git cherry-pick -x <the fix's commit>
  git push
  ./release.sh 1.1.1 "…"
  ```

  The version's commit is merged back into `main` here too; when `main`'s
  CHANGELOG has moved on and the merge doesn't go cleanly, the script says so
  and leaves it to be finished by hand.
- A fix published for an older line (1.0.5 once 1.1 is out) is not marked
  the latest release, so installed copies keep reading the newest line's
  appcast.

`release/v1.0` holds 1.0.0 to 1.0.4, which were tagged on `main` before
release branches.

## The secrets, once

The release workflow needs five repository secrets
(Settings › Secrets and variables › Actions on GitHub, or `gh secret set`):

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE` | The **Developer ID Application** certificate with its private key, exported as .p12, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | The password given when exporting it |
| `AC_API_KEY_P8` | An App Store Connect API key, which notarises: the downloaded `AuthKey_<id>.p8`, as it is |
| `AC_API_KEY_ID` | Its key ID |
| `AC_API_ISSUER_ID` | The issuer ID shown above the keys |

The certificate: in Keychain Access, find "Developer ID Application: …" under
My Certificates, open it to show the private key under it, select the
certificate, File › Export Items…, save as .p12 with a password.

The API key: in App Store Connect, Users and Access › Integrations › App Store
Connect API, make a Team key with the Developer role and download its .p8
(Apple offers it only once). The issuer ID is above the list of keys. Then:

```sh
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE -R justrach/browse
gh secret set MACOS_CERTIFICATE_PASSWORD -R justrach/browse   # asks for it
gh secret set AC_API_KEY_P8 -R justrach/browse < AuthKey_<id>.p8
gh secret set AC_API_KEY_ID -R justrach/browse --body <id>
gh secret set AC_API_ISSUER_ID -R justrach/browse   # asks for it
rm DeveloperID.p12
```

Export that one certificate only, not the whole keychain.

## Finish a CI candidate on the signing Mac

When the repository has no signing secrets, wait for the tag's release job to
finish. On the signing Mac, with the exact tagged commit checked out, download
that run's `browse-release-candidate-vX.Y.Z` artifact (the run ID is on its
Actions page):

```sh
TAG=vX.Y.Z
gh run download RUN_ID -R justrach/browse -n "browse-release-candidate-$TAG" -D "/tmp/browse-$TAG"
ditto -x -k "/tmp/browse-$TAG/browse-app.zip" "/tmp/browse-$TAG"
SEARCH_PREBUILT_APP="/tmp/browse-$TAG/browse.app" \
SEARCH_PREBUILT_METADATA="/tmp/browse-$TAG/metadata.json" \
SEARCH_NOTARY_PROFILE=codedb-notary ./build.sh release ship
./publish.sh github
```

`build.sh` checks the candidate's bundle ID, version, build, executable
hash, and source commit against the local release tag before copying it. It
re-signs the copied app and uses the existing DMG, ZIP, appcast and notarisation
path. `publish.sh` refuses to publish unless the DMG passes Gatekeeper and
stapler checks, the app is signed by team `WWP9DLJ27P`, and the appcast
matches the app and ZIP. Nothing in this path exports the local certificate.

## By hand, without CI

The same steps run on a Mac that has the certificate and a notarytool profile
(`xcrun notarytool store-credentials <name>`):

```sh
SEARCH_NOTARY_PROFILE=<name> ./build.sh release ship
./publish.sh github
```

## Passkeys

Passkeys in a browser that isn't Safari need an entitlement Apple grants to
web browsers on request, `com.apple.developer.web-browser.public-key-credential`,
and a Developer ID provisioning profile that carries it. The app already
knows what to do with it (Passkeys.swift; Settings › Passwords › Offer
passkeys); only the signing needs it.

1. On developer.apple.com, in Certificates, Identifiers & Profiles, make an
   explicit App ID for **com.codegraff.search** under the team, if there
   isn't one.
2. Request the **Web Browser Public Key Credential Requests** capability for
   it (Apple reviews these; it can take a few days). Once granted, it shows
   under the App ID's Additional Capabilities — switch it on there.
3. Profiles › + › **Developer ID**, for that App ID and the Developer ID
   Application certificate. Download it.
4. Put it next to build.sh as `browse.provisionprofile` (it's ignored by
   git). `./build.sh` checks it's for com.codegraff.search and carries the
   passkey entitlement, embeds it, and signs with `Browse.passkeys.entitlements`.
5. For CI: `base64 -i browse.provisionprofile | gh secret set MACOS_PROVISION_PROFILE -R justrach/browse`.

The profile expires after some years; a new one goes in the same way.

## WebKit's security fixes

browse runs on the WebKit built into macOS, so Apple's fixes reach it
through Software Update — nothing to rebuild here. What browse adds is a
nudge for a Mac that's behind: every appcast carries `webkit`, the oldest
WebKit build per macOS line that has the fixes that matter (from
`webkit-floor.json`), and a Mac under it is told so at each update check and
in Settings › About, with a button to Software Update (WebKitCheck.swift).

When Apple ships a WebKit security fix (support.apple.com/100100 lists them):

1. On a Mac that has the fix, read the build:
   `/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /System/Library/Frameworks/WebKit.framework/Resources/Info.plist`
2. `./webkit-floor 22625.1.29.11.27` (that build) — it raises the floor for
   that macOS line in `webkit-floor.json` and on the live release's
   `appcast.json`, so installed copies see it within a day.
3. Commit `webkit-floor.json`.

A build's first number over a thousand is its macOS (22625 → 22); floors
are only compared within their own line, and a line with no floor is never
warned about.

## The ad blocker's lists

The app carries EasyList and EasyPrivacy, already converted into WebKit's
content blocker rules, in `Assets/Shield` (Shield.swift). They're only as new
as the last time someone made them, so before a release:

1. `./shield-lists` — downloads both lists, converts them with Brave's
   adblock engine (`tools/shield-lists`, needs cargo), and writes the two
   `.json.xz` files and `version`.
2. Commit `Assets/Shield`.

A new `version` is compiled once on each Mac, in the background, the first
time the release opens; the compiled copy of the old one is thrown away.
