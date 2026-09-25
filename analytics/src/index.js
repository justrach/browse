// Anonymous hardware stats for browse, and the page that shows them.
//
//   POST /v1/ping   one report from a Mac whose owner switched it on
//   GET  /v1/stats  the totals, as JSON
//   GET  /          the same, as a page
//
// Stored in Workers KV (see ping).
//
// A report carries a random id made on the Mac, the app and macOS versions,
// the chip, core counts, memory, and the app's own memory and tab counts.
// Nothing here reads the address a request came from, and nothing is logged.
// Every breakdown folds groups of fewer than MIN_GROUP machines into "Other",
// so no one Mac can be picked out of the totals.

const MIN_GROUP = 3;
const ACTIVE_DAYS = 30;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const THERMAL = new Set(["nominal", "fair", "serious", "critical"]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/v1/ping") {
        if (request.method !== "POST") return text("POST only", 405);
        return await ping(request, env);
      }
      if (request.method !== "GET" && request.method !== "HEAD") return text("Not allowed", 405);
      if (url.pathname === "/v1/stats") return json(await stats(env));
      if (url.pathname === "/") return html(page(await stats(env)));
      if (url.pathname === "/robots.txt") return text("User-agent: *\nAllow: /\n");
      return text("Not found", 404);
    } catch (error) {
      return text("Something went wrong", 500);
    }
  },
};

// ---------------------------------------------------------------- reports

/** A string field: trimmed, printable, short. Null if it isn't one. */
function str(value, max = 64) {
  if (typeof value !== "string") return null;
  const clean = value.replace(/[^\w .,()+\-@]/g, "").trim().slice(0, max);
  return clean.length ? clean : null;
}

/** A whole number within bounds, or null. */
function int(value, lo, hi) {
  return Number.isInteger(value) && value >= lo && value <= hi ? value : null;
}

/** The report, checked field by field; null if it isn't one. */
export function parse(body) {
  if (!body || typeof body !== "object") return null;
  const cpu = body.cpu ?? {}, gpu = body.gpu ?? {};
  const report = {
    id: typeof body.id === "string" && UUID.test(body.id) ? body.id.toLowerCase() : null,
    app: str(body.app, 24),
    os: str(body.os, 24),
    chip: str(body.chip),
    arch: body.arch === "arm64" || body.arch === "x86_64" ? body.arch : null,
    cpu_cores: int(cpu.cores, 1, 512),
    cpu_perf: int(cpu.performance, 0, 512),
    cpu_eff: int(cpu.efficiency, 0, 512),
    gpu: str(gpu.name) ?? "Unknown",
    gpu_cores: int(gpu.cores, 1, 1024),
    memory_gb: int(body.memory_gb, 1, 4096),
    app_mb: int(body.app_mb, 1, 65536),
    tabs: int(body.tabs, 0, 10000),
    awake: int(body.awake, 0, 10000),
    thermal: THERMAL.has(body.thermal) ? body.thermal : "nominal",
  };
  for (const key of ["id", "app", "os", "chip", "arch", "cpu_cores", "memory_gb", "app_mb", "tabs", "awake"]) {
    if (report[key] === null) return null;
  }
  return report;
}

// Storage is Workers KV. A Mac's latest report lives at m:<id>, whole, in the
// key's metadata so a list returns every report without a read per Mac, and
// it expires ACTIVE_DAYS after the last one: a Mac that stops reporting drops
// out of the totals on its own. d:<day>:<id> marks a Mac as seen that day.
const DAY = 86400;

async function ping(request, env) {
  const raw = await request.text();
  if (raw.length > 4096) return text("Too large", 413);
  let body;
  try { body = JSON.parse(raw); } catch { return text("Not JSON", 400); }
  const r = parse(body);
  if (!r) return text("Not a report", 422);

  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  // Once an hour at most: a Mac that sends more often keeps its last report.
  const { metadata: previous } = await env.KV.getWithMetadata(`m:${r.id}`);
  if (previous && now - new Date(previous.last_seen) < 60 * 60 * 1000) return new Response(null, { status: 204 });

  const { id, ...fields } = r;
  const report = { ...fields, first_seen: previous?.first_seen ?? day, last_seen: now.toISOString() };
  await Promise.all([
    env.KV.put(`m:${id}`, "", { metadata: report, expirationTtl: ACTIVE_DAYS * DAY }),
    env.KV.put(`d:${day}:${id}`, "", { expirationTtl: (ACTIVE_DAYS + 1) * DAY }),
  ]);
  return new Response(null, { status: 204 });
}

/** Every key under a prefix, a page of a thousand at a time. */
async function listAll(kv, prefix) {
  const keys = [];
  let cursor;
  do {
    const page = await kv.list({ prefix, cursor });
    keys.push(...page.keys);
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return keys;
}

// ---------------------------------------------------------------- totals

/** Counts by label, groups under MIN_GROUP folded into "Other", largest first. */
export function breakdown(rows, label) {
  const counts = new Map();
  for (const row of rows) {
    const key = label(row);
    if (key == null) continue;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  let other = 0;
  const kept = [];
  for (const [key, n] of counts) (n < MIN_GROUP ? (other += n) : kept.push({ label: key, machines: n }));
  kept.sort((a, b) => b.machines - a.machines || String(a.label).localeCompare(String(b.label), undefined, { numeric: true }));
  if (other) kept.push({ label: "Other", machines: other });
  return kept;
}

function quantile(sorted, q) {
  if (!sorted.length) return null;
  const at = (sorted.length - 1) * q, lo = Math.floor(at), hi = Math.ceil(at);
  return Math.round(sorted[lo] + (sorted[hi] - sorted[lo]) * (at - lo));
}

export function summarize(rows, daily, now = new Date()) {
  const n = rows.length;
  const footprint = rows.map((r) => r.app_mb).sort((a, b) => a - b);
  const tabs = rows.map((r) => r.tabs).sort((a, b) => a - b);
  const enough = n >= MIN_GROUP;
  return {
    updated: now.toISOString(),
    active_days: ACTIVE_DAYS,
    machines: n,
    // Too few to show anything but the count without it pointing at someone.
    breakdowns: !enough ? null : {
      chip: breakdown(rows, (r) => r.chip),
      cpu: breakdown(rows, (r) => r.cpu_perf != null && r.cpu_eff != null
        ? `${r.cpu_cores} cores (${r.cpu_perf} performance + ${r.cpu_eff} efficiency)` : `${r.cpu_cores} cores`),
      gpu: breakdown(rows, (r) => r.gpu_cores ? `${r.gpu_cores} GPU cores` : null),
      memory: breakdown(rows, (r) => `${r.memory_gb} GB`),
      os: breakdown(rows, (r) => `macOS ${String(r.os).split(".").slice(0, 1).join(".")}`),
      app: breakdown(rows, (r) => r.app),
      thermal: breakdown(rows, (r) => r.thermal),
    },
    app: !enough ? null : {
      memory_mb: { median: quantile(footprint, 0.5), p90: quantile(footprint, 0.9) },
      tabs: { median: quantile(tabs, 0.5), p90: quantile(tabs, 0.9) },
      awake_share: Math.round((100 * rows.reduce((s, r) => s + r.awake, 0)) / Math.max(1, rows.reduce((s, r) => s + r.tabs, 0))),
    },
    daily,
  };
}

async function stats(env) {
  const rows = (await listAll(env.KV, "m:")).map((k) => k.metadata).filter(Boolean);
  // Macs seen each day: one key each, counted by day.
  const counts = new Map();
  for (const k of await listAll(env.KV, "d:")) {
    const day = k.name.slice(2, 12);
    counts.set(day, (counts.get(day) ?? 0) + 1);
  }
  const since = new Date(Date.now() - ACTIVE_DAYS * DAY * 1000).toISOString().slice(0, 10);
  const daily = [...counts].filter(([d]) => d >= since).sort().map(([day, machines]) => ({ day, machines }));
  return summarize(rows, daily);
}

// ---------------------------------------------------------------- responses

const text = (body, status = 200) => new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
const json = (body) => new Response(JSON.stringify(body, null, 2), {
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300", "access-control-allow-origin": "*" },
});
const html = (body) => new Response(body, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" } });

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/** One breakdown: a titled list of bars, one series, the value at each tip. */
function bars(title, rows, total) {
  if (!rows?.length) return "";
  const most = Math.max(...rows.map((r) => r.machines));
  const items = rows.map((r) => {
    const pct = Math.round((100 * r.machines) / total);
    const width = Math.max(1, (100 * r.machines) / most);
    return `<li data-tip="${esc(r.label)}: ${r.machines} Mac${r.machines === 1 ? "" : "s"} (${pct}%)">
      <span class="label">${esc(r.label)}</span>
      <span class="track"><span class="bar" style="width:${width.toFixed(1)}%"></span></span>
      <span class="value">${r.machines}</span></li>`;
  }).join("");
  const table = rows.map((r) => `<tr><td>${esc(r.label)}</td><td>${r.machines}</td><td>${Math.round((100 * r.machines) / total)}%</td></tr>`).join("");
  return `<section class="card"><h2>${esc(title)}</h2><ul class="bars">${items}</ul>
    <details><summary>Table</summary><table><thead><tr><th>${esc(title)}</th><th>Macs</th><th>Share</th></tr></thead><tbody>${table}</tbody></table></details></section>`;
}

/** Macs reporting each day: columns, the latest labelled. */
function days(daily) {
  if (!daily?.length) return "";
  const most = Math.max(...daily.map((d) => d.machines));
  const cols = daily.map((d, i) => `<span class="col" data-tip="${esc(d.day)}: ${d.machines} Mac${d.machines === 1 ? "" : "s"}"
      style="height:${Math.max(2, (100 * d.machines) / most).toFixed(1)}%">${i === daily.length - 1 ? `<b>${d.machines}</b>` : ""}</span>`).join("");
  const table = daily.map((d) => `<tr><td>${esc(d.day)}</td><td>${d.machines}</td></tr>`).join("");
  return `<section class="card wide"><h2>Macs reporting each day</h2><div class="cols">${cols}</div>
    <div class="axis"><span>${esc(daily[0].day)}</span><span>${esc(daily[daily.length - 1].day)}</span></div>
    <details><summary>Table</summary><table><thead><tr><th>Day</th><th>Macs</th></tr></thead><tbody>${table}</tbody></table></details></section>`;
}

const tile = (value, label) => `<div class="tile"><div class="big">${esc(value)}</div><div class="small">${esc(label)}</div></div>`;

export function page(s) {
  const b = s.breakdowns, total = s.machines;
  const tiles = [
    tile(total.toLocaleString("en"), `Macs in the last ${s.active_days} days`),
    s.app ? tile(`${s.app.memory_mb.median} MB`, "The app's own memory, median") : "",
    s.app ? tile(String(s.app.tabs.median), "Tabs open, median") : "",
    s.app ? tile(`${s.app.awake_share}%`, "Of tabs holding their page") : "",
  ].join("");
  const body = b ? [
    days(s.daily),
    bars("Chip", b.chip, total), bars("CPU", b.cpu, total), bars("GPU", b.gpu, total),
    bars("Memory", b.memory, total), bars("macOS", b.os, total), bars("App version", b.app, total),
  ].join("") : `<p class="note">Fewer than ${MIN_GROUP} Macs so far: breakdowns appear once there are enough that none points at one Mac.</p>`;

  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>browse · anonymous stats</title>
<style>
.viz-root { color-scheme: light; --surface-0:#f4f4f2; --surface-1:#fcfcfb; --hair:#e4e3df; --text-primary:#0b0b0b; --text-secondary:#52514e; --text-muted:#76756f; --series-1:#2a78d6; }
@media (prefers-color-scheme: dark) { :root:where(:not([data-theme="light"])) .viz-root { color-scheme: dark; --surface-0:#111110; --surface-1:#1a1a19; --hair:#2c2c2a; --text-primary:#ffffff; --text-secondary:#c3c2b7; --text-muted:#9a998f; --series-1:#3987e5; } }
:root[data-theme="dark"] .viz-root { color-scheme: dark; --surface-0:#111110; --surface-1:#1a1a19; --hair:#2c2c2a; --text-primary:#ffffff; --text-secondary:#c3c2b7; --text-muted:#9a998f; --series-1:#3987e5; }
* { box-sizing: border-box; }
body { margin: 0; }
.viz-root { min-height: 100vh; background: var(--surface-0); color: var(--text-primary); font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Inter", system-ui, sans-serif; padding: 40px 24px 64px; }
main { max-width: 1040px; margin: 0 auto; }
h1 { font-size: 22px; font-weight: 600; margin: 0 0 6px; }
.lede { color: var(--text-secondary); margin: 0 0 28px; max-width: 720px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin-bottom: 12px; }
.tile, .card { background: var(--surface-1); border: 1px solid var(--hair); border-radius: 14px; padding: 18px 20px; }
.big { font-size: 30px; font-weight: 600; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; }
.small { color: var(--text-secondary); font-size: 13px; margin-top: 2px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(460px, 1fr)); gap: 12px; }
.wide { grid-column: 1 / -1; }
h2 { font-size: 13px; font-weight: 600; margin: 0 0 12px; color: var(--text-secondary); }
.bars { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.bars li { display: grid; grid-template-columns: minmax(120px, 40%) 1fr 44px; align-items: center; gap: 10px; padding: 3px 4px; border-radius: 6px; }
.bars li:hover { background: color-mix(in srgb, var(--text-primary) 5%, transparent); }
.label { color: var(--text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 13px; }
.track { height: 14px; }
.bar { display: block; height: 14px; background: var(--series-1); border-radius: 0 4px 4px 0; }
.value { text-align: right; font-variant-numeric: tabular-nums; color: var(--text-secondary); font-size: 13px; }
.cols { height: 140px; padding-top: 20px; display: flex; align-items: flex-end; gap: 2px; border-bottom: 1px solid var(--hair); }
.col { flex: 1; max-width: 24px; background: var(--series-1); border-radius: 4px 4px 0 0; position: relative; }
.col b { position: absolute; bottom: 100%; left: 50%; transform: translateX(-50%); font-size: 12px; font-weight: 600; color: var(--text-primary); padding-bottom: 2px; }
.axis { display: flex; justify-content: space-between; color: var(--text-muted); font-size: 12px; margin-top: 6px; }
details { margin-top: 12px; color: var(--text-secondary); font-size: 12.5px; }
summary { cursor: pointer; color: var(--text-muted); }
table { border-collapse: collapse; width: 100%; margin-top: 8px; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid var(--hair); }
td:not(:first-child), th:not(:first-child) { text-align: right; }
.note { color: var(--text-secondary); }
footer { color: var(--text-muted); font-size: 12.5px; margin-top: 28px; max-width: 760px; }
#tip { position: fixed; pointer-events: none; background: var(--text-primary); color: var(--surface-1); font-size: 12px; padding: 5px 8px; border-radius: 6px; opacity: 0; transition: opacity .08s; white-space: nowrap; z-index: 9; }
</style></head>
<body><div class="viz-root"><main>
<h1>browse · anonymous stats</h1>
<p class="lede">The Macs that people have chosen to share numbers from: their chips, cores, memory, and how much memory the browser itself uses on them. Nothing here names a person or a Mac.</p>
<div class="tiles">${tiles}</div>
<div class="grid">${body}</div>
<footer>Sharing is off unless it's switched on, in Settings › Privacy. A Mac that shares sends, at most once a day: a random id made on that Mac, the app and macOS versions, the chip, CPU and GPU core counts, memory, the app's own memory use, how many tabs are open and awake, and the thermal state. The address it comes from is never read or stored. Groups of fewer than ${MIN_GROUP} Macs are shown as "Other". Updated ${esc(s.updated.slice(0, 16).replace("T", " "))} UTC · <a href="/v1/stats" style="color:inherit">JSON</a></footer>
</main><div id="tip" role="tooltip"></div></div>
<script>
const tip = document.getElementById("tip");
document.addEventListener("pointermove", (e) => {
  const at = e.target.closest("[data-tip]");
  if (!at) { tip.style.opacity = 0; return; }
  tip.textContent = at.dataset.tip; tip.style.opacity = 1;
  const w = tip.offsetWidth;
  tip.style.left = Math.min(window.innerWidth - w - 8, e.clientX + 12) + "px";
  tip.style.top = (e.clientY + 14) + "px";
});
</script></body></html>`;
}
