#!/usr/bin/env python3
"""What browse's ad blocker does on real sites, and what Jev's Tidy adds.

Needs a test world listening (skill/browse-bench/SKILL.md), and the lists'
checker built (cargo build --release in tools/shield-lists):

    python3 benchmarks/shield_check.py --world shield-check [--jev] [--sites URL,URL…]

Each site is loaded twice in a bench tab, the blocker off and then on, and
scrolled to the bottom and back so ads that wait for the reader turn up.
Each load records every request the page made, what's still on screen that
looks like an ad (frames from ad networks, boxes named like ads, overlays
over the page), images that didn't load, and how much text the page has —
a page that lost its article to the blocker says so there.

Every request from the unblocked loads is then put to
`shield-lists check`: what EasyList and EasyPrivacy mean, by Brave's own
engine, against what browse's WebKit rules do. Where they differ is a
conversion bug — an ad let through, or a page's own file blocked.

With --jev, Tidy This Page runs on each blocked load (the world needs a
Codegraff sign-in), and what Jev took off is listed per site.

Writes benchmarks/shield_check.json and prints the report as Markdown;
screenshots go to --shots (default /tmp/shield-check).
"""

import argparse
import collections
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKER = ROOT / "tools/shield-lists/target/release/shield-lists"
LISTS = {
    "easylist.txt": "https://easylist.to/easylist/easylist.txt",
    "easyprivacy.txt": "https://easylist.to/easylist/easyprivacy.txt",
}

# News, recipes, weather, fan wikis and tech sites carry the most ads; the
# rest are pages that should come through untouched.
SITES = [
    "https://www.theguardian.com/international",
    "https://www.independent.co.uk",
    "https://edition.cnn.com",
    "https://www.bbc.com/news",
    "https://www.forbes.com",
    "https://www.dailymail.co.uk/home/index.html",
    "https://www.theverge.com",
    "https://www.techradar.com",
    "https://weather.com",
    "https://www.allrecipes.com",
    "https://harrypotter.fandom.com/wiki/Hermione_Granger",
    "https://www.reddit.com/r/macapps",
    "https://stackoverflow.com/questions/231767",
    "https://www.youtube.com",
    "https://www.google.com",
    "https://en.wikipedia.org/wiki/Web_browser",
    "https://github.com/justrach/codegraff",
    "https://www.apple.com",
]

# Ad and tracking companies, named independently of EasyList, to count what
# reached them.
ADTECH = (
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagservices.com",
    "google-analytics.com", "googletagmanager.com", "adservice.google.", "amazon-adsystem.com",
    "adnxs.com", "adsrvr.org", "criteo.", "taboola.com", "outbrain.com", "rubiconproject.com",
    "pubmatic.com", "openx.net", "casalemedia.com", "smartadserver.com", "sharethrough.com",
    "indexww.com", "bidswitch.net", "33across.com", "teads.tv", "moatads.com", "adroll.com",
    "scorecardresearch.com", "quantserve.com", "chartbeat.", "hotjar.com", "clarity.ms",
    "facebook.net", "ads-twitter.com", "adsafeprotected.com", "doubleverify.com", "media.net",
    "yieldmo.com", "lijit.com", "3lift.com", "id5-sync.com", "permutive.", "ogury.", "sonobi.com",
)

# Read after the page settles, in the page's own world.
MEASURE = r"""
(function () {
  var words = /^(ad|ads|advert|advertisement|adslot|adunit|dfp|gpt|sponsored|promoted|taboola|outbrain)$/i;
  function shown(e) {
    if (e.checkVisibility && !e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return false;
    var r = e.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  }
  function named(e) {
    var s = (e.id || '') + ' ' + (typeof e.className === 'string' ? e.className : '');
    return s.split(/[\s_-]+/).some(function (w) { return words.test(w); });
  }
  var boxes = [], chosen = [];
  var all = document.body ? document.body.getElementsByTagName('*') : [];
  for (var i = 0; i < all.length && i < 20000; i++) {
    var e = all[i];
    if (chosen.some(function (c) { return c.contains(e); })) continue;
    if (!named(e) || !shown(e)) continue;
    var r = e.getBoundingClientRect();
    if (r.width * r.height < 2000) continue;
    chosen.push(e);
    boxes.push(e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + ' ' + Math.round(r.width) + '×' + Math.round(r.height));
  }
  var frames = [];
  document.querySelectorAll('iframe').forEach(function (f) {
    if (!shown(f)) return;
    var host = '';
    try { host = new URL(f.src, location.href).host; } catch (x) {}
    var r = f.getBoundingClientRect();
    frames.push(host + ' ' + Math.round(r.width) + '×' + Math.round(r.height));
  });
  var overlays = [];
  var area = innerWidth * innerHeight;
  for (var j = 0; j < all.length && j < 20000; j++) {
    var o = all[j];
    var p = getComputedStyle(o).position;
    if (p !== 'fixed' && p !== 'sticky') continue;
    if (!shown(o)) continue;
    var b = o.getBoundingClientRect();
    var w = Math.max(0, Math.min(b.right, innerWidth) - Math.max(b.left, 0));
    var h = Math.max(0, Math.min(b.bottom, innerHeight) - Math.max(b.top, 0));
    if (w * h > area * 0.25) overlays.push(o.tagName.toLowerCase() + (o.id ? '#' + o.id : '') + ' ' + Math.round(100 * w * h / area) + '%');
  }
  var broken = [];
  document.querySelectorAll('img').forEach(function (m) {
    if (m.complete && m.naturalWidth === 0 && (m.currentSrc || m.src) && shown(m)) broken.push((m.currentSrc || m.src).slice(0, 200));
  });
  var nav = performance.getEntriesByType('navigation')[0];
  return JSON.stringify({
    url: location.href,
    title: document.title,
    load: nav ? Math.round(nav.loadEventEnd || nav.duration) : null,
    text: (document.body ? document.body.innerText : '').length,
    requests: performance.getEntriesByType('resource').map(function (r) { return [r.name, r.initiatorType]; }),
    boxes: boxes, frames: frames, overlays: overlays, broken: broken
  });
})()
"""


def bench(world, *args, timeout=60):
    result = subprocess.run(
        [str(ROOT / "bench"), "--world", world, *args],
        capture_output=True, text=True, timeout=timeout,
    )
    out = result.stdout.strip()
    if result.returncode != 0:
        raise RuntimeError((result.stderr or out).strip())
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return out


def kind(url, initiator):
    """A request as WebKit's content blockers type it."""
    path = urllib.parse.urlsplit(url).path.lower()
    if initiator in ("img", "image", "input"):
        return "image"
    if initiator == "script":
        return "script"
    if initiator in ("iframe", "frame"):
        return "document"
    if initiator in ("video", "audio", "track"):
        return "media"
    if initiator in ("xmlhttprequest", "fetch", "beacon"):
        return "raw"
    if initiator in ("css", "link"):
        if path.endswith((".woff", ".woff2", ".ttf", ".otf", ".eot")):
            return "font"
        if path.endswith((".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico")):
            return "image"
        return "style-sheet"
    return "other"


def key(url):
    """A request, less what changes from one load to the next."""
    parts = urllib.parse.urlsplit(url)
    return parts.netloc.lower() + parts.path


def adtech(url):
    host = urllib.parse.urlsplit(url).netloc.lower()
    return any(name in host for name in ADTECH)


def visit(world, tab, site, shots, label):
    bench(world, "go", tab, site)
    bench(world, "wait", tab, "30", timeout=45)
    # Down the page and back: lazy ads load for a reader who gets there.
    for fraction in (0.25, 0.5, 0.75, 1.0):
        bench(world, "eval", tab, f"window.scrollTo(0, document.body.scrollHeight * {fraction}); 1")
        time.sleep(1.2)
    bench(world, "eval", tab, "window.scrollTo(0, 0); 1")
    time.sleep(2.5)
    page = bench(world, "eval", tab, MEASURE)
    page = json.loads(page) if isinstance(page, str) else page
    host = urllib.parse.urlsplit(site).netloc.replace("www.", "")
    page["shot"] = bench(world, "shot", tab, str(shots / f"{host}-{label}.png"))
    return page


def fetch_lists(folder):
    for name, url in LISTS.items():
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(folder / name), url], check=True)
    return [str(folder / name) for name in LISTS]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--world", default="shield-check")
    parser.add_argument("--sites", help="comma-separated URLs instead of the default set")
    parser.add_argument("--jev", action="store_true", help="also run Tidy on each blocked page")
    parser.add_argument("--shots", default="/tmp/shield-check")
    parser.add_argument("--out", default=str(ROOT / "benchmarks/shield_check.json"))
    args = parser.parse_args()
    sites = args.sites.split(",") if args.sites else SITES
    shots = pathlib.Path(args.shots)
    shots.mkdir(parents=True, exist_ok=True)
    if not CHECKER.exists():
        sys.exit(f"build the checker first: cargo build --release --manifest-path {CHECKER.parents[2]}/Cargo.toml")

    # The big lists compile in the background; the short one alone would
    # make a poor showing.
    for _ in range(60):
        state = bench(args.world, "shield", "on")
        if state.get("lists", 0) >= 3:
            break
        time.sleep(2)
    else:
        sys.exit(f"the block lists never finished compiling: {state}")

    tab = bench(args.world, "open", "about:blank")  # the bench prints just the id
    results = []
    try:
        for site in sites:
            print(f"… {site}", file=sys.stderr)
            entry = {"site": site}
            try:
                bench(args.world, "shield", "off")
                entry["off"] = visit(args.world, tab, site, shots, "off")
                bench(args.world, "shield", "on")
                entry["on"] = visit(args.world, tab, site, shots, "on")
                if args.jev:
                    tidied = bench(args.world, "tidy", tab, timeout=60)
                    entry["jev"] = tidied
                    host = urllib.parse.urlsplit(site).netloc.replace("www.", "")
                    time.sleep(1)
                    entry["jev_shot"] = bench(args.world, "shot", tab, str(shots / f"{host}-jev.png"))
            except Exception as error:  # a site that times out shouldn't sink the run
                entry["error"] = str(error)
            results.append(entry)
    finally:
        bench(args.world, "shield", "on")
        bench(args.world, "close", tab)

    # Every unblocked request, put to both judges.
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        lists = fetch_lists(work)
        rules = work / "network.json"
        rules.write_bytes(subprocess.run(
            ["xz", "-dc", str(ROOT / "Assets/Shield/network.json.xz")], capture_output=True, check=True
        ).stdout)
        lines = []
        for entry in results:
            off = entry.get("off")
            if not off:
                continue
            for url, initiator in off["requests"]:
                if url.startswith("http"):
                    lines.append(f"{url}\t{off['url']}\t{kind(url, initiator)}")
        checked = subprocess.run(
            [str(CHECKER), "check", str(rules), *lists],
            input="\n".join(lines), capture_output=True, text=True, check=True,
        ).stdout
    verdicts = {}
    for line in checked.splitlines():
        url, page, _kind, says, does, why, webkit = (line.split("\t") + [""] * 7)[:7]
        verdicts[(url, page)] = {"lists": says, "browse": does, "list_rule": why, "webkit_rule": webkit}

    report = summarize(results, verdicts, args.jev)
    pathlib.Path(args.out).write_text(json.dumps({"generated": time.strftime("%Y-%m-%d %H:%M"), "sites": report["sites"],
                                                   "totals": report["totals"], "disagreements": report["disagreements"]}, indent=2))
    print(report["markdown"])


def summarize(results, verdicts, jev):
    rows, totals = [], collections.Counter()
    missed, over = collections.defaultdict(set), collections.defaultdict(set)
    md = ["# What the ad blocker does", ""]
    for entry in results:
        site, off, on = entry["site"], entry.get("off"), entry.get("on")
        if not off or not on:
            rows.append({"site": site, "error": entry.get("error", "no data")})
            continue
        off_urls = [u for u, _ in off["requests"] if u.startswith("http")]
        on_urls = [u for u, _ in on["requests"] if u.startswith("http")]
        on_keys = {key(u) for u in on_urls}
        predicted = [u for u in off_urls if verdicts.get((u, off["url"]), {}).get("browse") == "block"]
        # Of what the checker says WebKit blocks, how much really went
        # missing from the blocked load — the checker's own check.
        gone = [u for u in predicted if key(u) not in on_keys]
        for u in off_urls:
            v = verdicts.get((u, off["url"]))
            if not v:
                continue
            if v["lists"] == "block" and v["browse"] == "allow":
                missed[v["list_rule"]].add(u)
            elif v["lists"] == "allow" and v["browse"] == "block":
                over[v["webkit_rule"]].add(u)
        row = {
            "site": site,
            "requests": [len(off_urls), len(on_urls)],
            "adtech": [sum(map(adtech, off_urls)), sum(map(adtech, on_urls))],
            "third_party_hosts": [
                len({urllib.parse.urlsplit(u).netloc for u in off_urls} - {urllib.parse.urlsplit(off["url"]).netloc}),
                len({urllib.parse.urlsplit(u).netloc for u in on_urls} - {urllib.parse.urlsplit(on["url"]).netloc}),
            ],
            "load_ms": [off.get("load"), on.get("load")],
            "text": [off["text"], on["text"]],
            "predicted_blocked": len(predicted),
            "predicted_and_gone": len(gone),
            "left_on_screen": {"ad_frames": [f for f in on["frames"] if adtech("https://" + f.split(" ")[0])],
                               "ad_boxes": on["boxes"], "overlays": on["overlays"]},
            "broken_images": [off["broken"], on["broken"]],
            "shots": [off.get("shot"), on.get("shot")],
        }
        if jev:
            lines = (entry.get("jev") or {}).get("lines") if isinstance(entry.get("jev"), dict) else None
            row["jev"] = {"hidden": [l["about"] for l in lines if l["hidden"]],
                          "kept": [l["about"] for l in lines if not l["hidden"]]} if lines is not None else {"error": str(entry.get("jev"))}
            row["jev_shot"] = entry.get("jev_shot")
        rows.append(row)
        for i, name in ((0, "off"), (1, "on")):
            totals[f"requests_{name}"] += row["requests"][i]
            totals[f"adtech_{name}"] += row["adtech"][i]
        totals["predicted_blocked"] += row["predicted_blocked"]
        totals["predicted_and_gone"] += row["predicted_and_gone"]

    md += ["| Site | Requests off → on | Ad-tech off → on | 3rd-party hosts | Text off → on | Still showing | Broken images on |",
           "|---|---|---|---|---|---|---|"]
    for r in rows:
        if "error" in r:
            md.append(f"| {r['site']} | error: {r['error'][:80]} | | | | | |")
            continue
        left = r["left_on_screen"]
        showing = ", ".join(filter(None, [
            f"{len(left['ad_frames'])} ad frames" if left["ad_frames"] else "",
            f"{len(left['ad_boxes'])} ad boxes" if left["ad_boxes"] else "",
            f"{len(left['overlays'])} overlays" if left["overlays"] else "",
        ])) or "—"
        broken_new = len(set(r["broken_images"][1]) - set(r["broken_images"][0]))
        md.append(
            f"| {urllib.parse.urlsplit(r['site']).netloc} | {r['requests'][0]} → {r['requests'][1]} "
            f"| {r['adtech'][0]} → {r['adtech'][1]} | {r['third_party_hosts'][0]} → {r['third_party_hosts'][1]} "
            f"| {r['text'][0]} → {r['text'][1]} | {showing} | {broken_new or '—'} |"
        )
    off_total, on_total = totals["requests_off"], totals["requests_on"]
    md += ["", f"**Requests:** {off_total} → {on_total} ({100 - round(100 * on_total / max(off_total, 1))}% fewer). "
           f"**Ad-tech requests:** {totals['adtech_off']} → {totals['adtech_on']}. "
           f"**Checker vs reality:** of {totals['predicted_blocked']} requests the checker says WebKit blocks, "
           f"{totals['predicted_and_gone']} were indeed missing from the blocked loads."]

    def block(title, groups, note):
        out = ["", f"## {title}", "", note, ""]
        if not groups:
            return out + ["None."]
        for rule, urls in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:40]:
            sample = sorted(urls)[0]
            out.append(f"- `{rule or '(no rule)'}` — {len(urls)} request(s), e.g. {sample[:140]}")
        return out

    md += block("Missed: the lists block it, browse lets it through", missed,
                "The list filter that should have caught it. Usually an option WebKit's rules can't express.")
    md += block("Over-blocked: the lists allow it, browse blocks it", over,
                "The WebKit rule that caught it. These are the ones that break pages.")
    if jev:
        md += ["", "## Jev's Tidy, on top of the blocker", ""]
        for r in rows:
            if "jev" not in r:
                continue
            j = r["jev"]
            if "error" in j:
                md.append(f"- **{urllib.parse.urlsplit(r['site']).netloc}**: {j['error'][:120]}")
                continue
            md.append(f"- **{urllib.parse.urlsplit(r['site']).netloc}**: hid {len(j['hidden'])}, kept {len(j['kept'])}")
            md += [f"  - hid: {h[:150]}" for h in j["hidden"]]
    disagreements = {
        "missed": {rule: sorted(urls)[:5] for rule, urls in missed.items()},
        "over_blocked": {rule: sorted(urls)[:5] for rule, urls in over.items()},
    }
    return {"sites": rows, "totals": dict(totals), "disagreements": disagreements, "markdown": "\n".join(md)}


if __name__ == "__main__":
    main()
