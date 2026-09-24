// node --test analytics/test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { parse, breakdown, summarize, page } from "./src/index.js";

const good = {
  id: "3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e", app: "1.0.1", os: "26.0.1", chip: "Apple M3 Pro", arch: "arm64",
  cpu: { cores: 12, performance: 6, efficiency: 6 }, gpu: { name: "Apple M3 Pro", cores: 18 },
  memory_gb: 36, app_mb: 58, tabs: 5, awake: 2, thermal: "nominal",
};

test("a well-formed report is accepted, and only its known fields are kept", () => {
  const r = parse({ ...good, url: "https://secret.example", ip: "1.2.3.4" });
  assert.equal(r.chip, "Apple M3 Pro");
  assert.equal(r.gpu_cores, 18);
  assert.equal("url" in r, false);
  assert.equal("ip" in r, false);
});

test("reports that aren't one are refused", () => {
  assert.equal(parse(null), null);
  assert.equal(parse({ ...good, id: "not-a-uuid" }), null);
  assert.equal(parse({ ...good, cpu: { cores: 0 } }), null);
  assert.equal(parse({ ...good, memory_gb: 1e9 }), null);
  assert.equal(parse({ ...good, arch: "sparc" }), null);
  assert.equal(parse({ ...good, tabs: "5" }), null);
});

test("strings are cleaned and cut short", () => {
  const r = parse({ ...good, chip: "<script>alert(1)</script>" + "x".repeat(200) });
  assert.equal(r.chip.includes("<"), false);
  assert.ok(r.chip.length <= 64);
});

test("groups of fewer than three fold into Other", () => {
  const rows = [..."AAAABBBCD"].map((c) => ({ chip: c }));
  assert.deepEqual(breakdown(rows, (r) => r.chip), [
    { label: "A", machines: 4 }, { label: "B", machines: 3 }, { label: "Other", machines: 2 },
  ]);
});

test("with fewer than three Macs only the count is shown", () => {
  const s = summarize([parse(good)], []);
  assert.equal(s.machines, 1);
  assert.equal(s.breakdowns, null);
  assert.equal(s.app, null);
  assert.equal(page(s).includes("Apple M3 Pro"), false);
});

test("the totals and the page", () => {
  const rows = Array.from({ length: 5 }, (_, i) => ({ ...parse(good), app_mb: 50 + i * 10, tabs: i + 1, awake: 1 }));
  const s = summarize(rows, [{ day: "2026-09-24", machines: 3 }, { day: "2026-09-25", machines: 5 }]);
  assert.equal(s.app.memory_mb.median, 70);
  assert.equal(s.breakdowns.cpu[0].label, "12 cores (6 performance + 6 efficiency)");
  assert.equal(s.breakdowns.gpu[0].label, "18 GPU cores");
  const html = page(s);
  assert.ok(html.includes("Apple M3 Pro"));
  assert.ok(html.includes("Macs reporting each day"));
  assert.equal(html.includes("3f2b8c1e"), false); // no id ever reaches the page
});
