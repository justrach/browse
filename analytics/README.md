# Anonymous stats

The Worker behind browse's stats page:
https://search-codegraff-stats.rachpradhan.workers.dev

A Mac sends to it only when sharing is switched on (Settings › Privacy, off by default; see `Sources/Search/Stats.swift`). A report holds a random id made on that Mac, the app and macOS versions, the chip, CPU and GPU cores, memory, the app's own memory use, how many tabs are open and awake, and the thermal state. It is sent at most once a day.

- `POST /v1/ping` checks every field, keeps only those, and stores the latest report per id in Workers KV. Each report expires 30 days after it's sent, and a Mac that reports more than once an hour keeps its earlier report. The Worker never reads the address a request comes from, and logging is off.
- `GET /v1/stats` returns the totals as JSON. `GET /` shows them as a page. Any group of fewer than 3 Macs is shown as "Other", and until 3 Macs are reporting only the count is shown.

```sh
node --test test.mjs     # the checks and the totals
wrangler dev --local     # locally, with local KV
wrangler deploy
```
