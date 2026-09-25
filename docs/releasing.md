# Releasing browse

A release is a tag. `./release.sh 1.0.2 "What's new, in a paragraph."` raises
`VERSION`, puts the paragraph at the top of `NOTES.md`, turns CHANGELOG's
Unreleased into the version's section, commits, tags `v1.0.2`, and pushes.
The tag starts `.github/workflows/release.yml`, which:

1. builds the app on a macOS runner,
2. signs it with the Developer ID and the hardened runtime,
3. has Apple notarise the DMG and the ZIP, and staples the DMG,
4. checks the DMG the way a Mac that downloads it will (`spctl`, `stapler validate`),
5. publishes a GitHub release with `browse.dmg`, `browse.zip` and `appcast.json`.

Every installed copy reads `releases/latest/download/appcast.json` once a day
(`Updater.swift`), fetches the ZIP, checks it is this app, newer, and signed
by the same team, and swaps it in for the next launch. So publishing is also
the update.

Every push and pull request runs `.github/workflows/build.yml`: the app
builds, and the stats Worker's tests pass. Nothing there is signed.

## The secrets, once

The release workflow needs five repository secrets
(Settings › Secrets and variables › Actions on GitHub, or `gh secret set`):

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE` | The **Developer ID Application** certificate with its private key, exported as .p12, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | The password given when exporting it |
| `APPLE_ID` | The Apple Account that notarises |
| `APPLE_APP_PASSWORD` | An app-specific password for it, from account.apple.com › Sign-In and Security |
| `APPLE_TEAM_ID` | The team, `WWP9DLJ27P` |

The certificate: in Keychain Access, find "Developer ID Application: …" under
My Certificates, open it to show the private key under it, select the
certificate, File › Export Items…, save as .p12 with a password. Then:

```sh
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE -R justrach/browse
gh secret set MACOS_CERTIFICATE_PASSWORD -R justrach/browse   # asks for it
gh secret set APPLE_ID -R justrach/browse
gh secret set APPLE_APP_PASSWORD -R justrach/browse
gh secret set APPLE_TEAM_ID -R justrach/browse --body WWP9DLJ27P
rm DeveloperID.p12
```

Export that one certificate only, not the whole keychain.

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
