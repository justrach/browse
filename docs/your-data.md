# Where your things go

![Passwords, bookmarks, history and sign-ins are read once from another browser's folder into browse on the same Mac. With sync on, each is sealed before it goes to Codegraff's server, and your other Macs open it. The sync key goes from Mac to Mac as a code you type.](images/data-flow.svg)

## Bringing things over

When you bring things over from Chrome, Arc, Dia, Brave, Edge, Vivaldi or Chromium, on the welcome screens or later from the Bookmarks, History and Passwords panels, browse copies what it needs out of that browser's folder on your Mac and reads the copy. Nothing is uploaded, and the other browser isn't changed.

| What | Where it goes | How |
|---|---|---|
| Passwords | Your Mac's keychain, under browse | The other browser keeps them sealed with a key in its own keychain entry. macOS asks you once before handing browse that key. |
| Bookmarks | browse's folder on this Mac | Folders and all, with the sites' icons. |
| History | browse's folder on this Mac | Up to 10,000 places, the ones you go to most first, with how often you went, so the address field knows them. |
| Sign-ins | Each space's own website data | Each profile's cookies go into a space of its own, so you stay signed in where you were. |

From macOS 27, Chrome, Brave and Edge (and Firefox) keep their folders to themselves: macOS lets only that browser, Safari's own importer and apps with Full Disk Access read them. To bring one of them over, turn on browse under System Settings › Privacy & Security › Full Disk Access, then reopen browse. browse says so, with a button to that page, when you try. Without it, the browser's own exports still work: its bookmarks file, and its passwords CSV. Dia, Arc and Vivaldi aren't locked this way.

From Safari, use Safari's File › Export Browsing Data to File… and choose the zip it makes. Its passwords file is unencrypted, so delete the zip afterwards.

## Sync, if you switch it on

Sync is off until you switch it on in Settings › Sync. When it's on:

- **Each thing is sealed on your Mac before it's sent.** Bookmarks, history and themes are sealed with AES-GCM. Passwords sync only behind their own switch, sealed the same way.
- **The key is yours.** It's made on your first Mac and kept in its keychain. It never goes to the server. A new Mac gets it as a sync code you type.
- **The server keeps what it can't open.** Codegraff's server stores the sealed boxes. Even their names are keyed hashes of the addresses, not the addresses.
- **Your other Macs open them** with the same key and merge them in.
- **Delete what's synced**, in Settings › Sync, removes everything from Codegraff's server for every Mac. Each Mac keeps its own copy.

The rest of what can leave your Mac is in the README, under [What leaves your Mac](../README.md#what-leaves-your-mac).
