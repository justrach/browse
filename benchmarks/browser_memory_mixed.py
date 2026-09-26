#!/usr/bin/env python3
"""Mixed 10-tab memory and 10-to-1 recovery probe. Requires websockets.

Run on an otherwise quiet desktop:
    python3 benchmarks/browser_memory_mixed.py --run > benchmarks/browser_memory_mixed.json

Only the exact isolated benchmark app/profile is launched or closed. The
loading value is a sampled maximum, not an instantaneous peak.
"""

import argparse
import asyncio
import datetime
import hashlib
import http.server
import json
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid

import browser_memory as memory
import workload


class MixedProbe(memory.Probe):
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path != "/page":
            return super().do_GET()
        index = int(urllib.parse.parse_qs(parsed.query).get("index", ["-1"])[0])
        if not 0 <= index < 10:
            self.send_error(404)
            return
        with self.server.condition:
            self.server.requested.add(index)
        body = workload.render(index)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class MixedServer(http.server.ThreadingHTTPServer):
    request_queue_size = 64


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Command failed ({args[0]}): {result.stderr.strip()}")
    return result.stdout.strip()


def checkpoint_fingerprint(browse_app, chrome_app, code_label):
    def bundle_build(bundle):
        with (bundle / "Contents" / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        return [info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")]
    return {
        "protocol": "mixed-ten-regular-tabs-1100x750-150s-close-nine-30s-v1",
        "browse_code_label": code_label,
        "mac_model": command("sysctl", "-n", "hw.model"),
        "macos_build": command("sw_vers", "-buildVersion"),
        "browse_version_build": bundle_build(browse_app),
        "chrome_version_build": bundle_build(chrome_app),
        "browse_executable_sha256": hashlib.sha256(
            (browse_app / "Contents" / "MacOS" / "Browse").read_bytes()).hexdigest(),
        "fixture_sha256": hashlib.sha256(b"".join(workload.render(index) for index in range(10))).hexdigest(),
    }


def chrome_port(profile, timeout=30):
    path = profile / "DevToolsActivePort"
    deadline = time.monotonic() + timeout
    while not path.is_file() and time.monotonic() < deadline:
        time.sleep(0.1)
    if not path.is_file():
        raise RuntimeError("Chrome debugging port unavailable")
    return int(path.read_text().splitlines()[0])


def targets(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=10) as response:
        return json.load(response)


def chrome_action(port, action, target_id):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/{action}/{target_id}", timeout=10) as response:
        return response.read().decode()


async def chrome_window(port, active_target):
    import websockets

    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=10) as response:
        endpoint = json.load(response)["webSocketDebuggerUrl"]
    async with websockets.connect(endpoint, max_size=2_000_000) as socket:
        async def call(number, method, params):
            await socket.send(json.dumps({"id": number, "method": method, "params": params}))
            while True:
                answer = json.loads(await socket.recv())
                if answer.get("id") == number:
                    if "error" in answer:
                        raise RuntimeError(f"Chrome window control failed: {answer['error']}")
                    return answer["result"]
        window = await call(1, "Browser.getWindowForTarget", {"targetId": active_target})
        await call(2, "Browser.setWindowBounds", {"windowId": window["windowId"],
                                                   "bounds": {"width": 1100, "height": 750}})
        actual = await call(3, "Browser.getWindowBounds", {"windowId": window["windowId"]})
    bounds = actual["bounds"]
    if (bounds["width"], bounds["height"]) != (1100, 750):
        raise RuntimeError("Chrome did not reach the requested 1100x750 window")
    return [bounds["width"], bounds["height"]]


async def chrome_page_diagnostics(port):
    import websockets

    diagnostics = {}
    for target in targets(port):
        url = target.get("url", "")
        if target.get("type") != "page" or "index=" not in url or "/page?trial=" not in url:
            continue
        index = int(urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["index"][0])
        try:
            async with websockets.connect(target["webSocketDebuggerUrl"], max_size=2_000_000) as socket:
                await socket.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                              "params": {"expression": """(() => {
  const canvas = document.querySelector('main canvas');
  let canvasDrawn = false;
  if (canvas && canvas.width === 1200 && canvas.height === 800) {
    const pixels = canvas.getContext('2d').getImageData(0, 0, 1200, 800).data;
    for (let i = 0; i < pixels.length; i += 64) {
      if (pixels[i] !== 255 || pixels[i+1] !== 255 || pixels[i+2] !== 255) { canvasDrawn = true; break; }
    }
  }
  return {state: document.readyState, title: document.title,
    paragraphs: document.querySelectorAll('main article p').length,
    cards: document.querySelectorAll('main .card').length,
    canvasDrawn};
})()""", "returnByValue": True}}))
                while True:
                    answer = json.loads(await socket.recv())
                    if answer.get("id") == 1:
                        diagnostics[index] = answer.get("result", {}).get("result", {}).get("value", {})
                        break
        except Exception:
            diagnostics[index] = {"state": "unavailable"}
    return diagnostics


def valid_chrome_page(index, detail):
    kind = "Article" if index < 4 else "Board" if index < 7 else "Canvas"
    expected_title = f"{kind} {index + 1}"
    if detail.get("state") != "complete" or detail.get("title") != expected_title:
        return False
    if index < 4:
        return detail.get("paragraphs") == 240
    if index < 7:
        return detail.get("cards") == 600
    return detail.get("canvasDrawn") is True


def browse_tabs(world):
    rows = command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"), "--world", world, "tabs").splitlines()
    found = {}
    for row in rows:
        if "/page?trial=" in row and "index=" in row:
            url = next(part for part in row.split() if part.startswith("http://127.0.0.1:"))
            index = int(urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get("index", ["-1"])[0])
            tab_id = re.search(r"\b[0-9a-f]{8}\b", row)
            if not tab_id:
                raise RuntimeError("Could not parse browse tab ID")
            found[index] = {"id": tab_id.group(), "awake": not row.endswith(" z"),
                            "active": row.startswith("●"), "bench": row.startswith("⚗")}
    return found


def chrome_tabs(port):
    found = {}
    for item in targets(port):
        url = item.get("url", "")
        if item.get("type") == "page" and "/page?trial=" in url and "index=" in url:
            index = int(urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["index"][0])
            found[index] = item["id"]
    return found


def capture(marker, baseline, temp, label, phase):
    last_error = None
    for attempt in range(1, 5):
        try:
            group_id, members = memory.app_group(marker, baseline)
            data = memory.footprint([pid for pid, _ in members], temp / f"{label}-{phase}.json")
            if {item["pid"] for item in data["processes"]} != {pid for pid, _ in members}:
                raise RuntimeError("Coalition process set changed during footprint collection")
            return {"coalition_id": group_id, "physical_footprint_bytes": data["total footprint"],
                    "capture_attempts": attempt,
                    "processes": [{"pid": item["pid"], "role": pathlib.Path(item["name"]).name,
                                   "physical_footprint_bytes": item["footprint"]} for item in data["processes"]]}
        except RuntimeError as error:
            last_error = error
            if "No such process" not in str(error) and "process set changed" not in str(error):
                raise
            time.sleep(0.2)
    raise RuntimeError(f"Could not capture a stable coalition process set: {last_error}")


def loading_sampler(marker, baseline, temp, label, started, stop, samples):
    number = 0
    while not stop.wait(2):
        try:
            snapshot = capture(marker, baseline, temp, label, f"loading-{number}")
            samples.append({"elapsed_seconds": round(time.monotonic() - started, 2),
                            "physical_footprint_bytes": snapshot["physical_footprint_bytes"],
                            "process_count": len(snapshot["processes"])})
            number += 1
        except RuntimeError:
            pass  # Processes can spawn or exit during a loading sample.


def stop_known_group(group_id, baseline):
    members = [(pid, command) for pid, command in memory.processes() if memory.coalition(pid) == group_id]
    if any(pid in baseline for pid, _ in members):
        return False
    for pid, _ in members:
        try:
            import os
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not any(memory.coalition(pid) == group_id for pid, _ in memory.processes()):
            return True
        time.sleep(0.1)
    for pid, _ in memory.processes():
        if memory.coalition(pid) == group_id:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    return not any(memory.coalition(pid) == group_id for pid, _ in memory.processes())


def run_case(label, bundle, server, temp, run_id, baseline, preflight=False):
    world = f"mixbench-{run_id}"
    suite = f"com.codegraff.search.test.{world}"
    profile = temp / "chrome-profile"
    marker = str(bundle if label == "browse" else profile)
    if label == "browse":
        command("defaults", "write", suite, "welcomed", "-bool", "true")
        command("defaults", "write", suite, "bench", "-bool", "true")
    else:
        profile.mkdir()
    pages = []
    for index in range(10):
        trial = uuid.uuid4().hex
        pages.append((trial, f"http://127.0.0.1:{server.server_port}/page?trial={trial}&index={index}"))
    samples = []
    stop = threading.Event()
    started = time.monotonic()
    sampler = threading.Thread(target=loading_sampler,
                               args=(marker, baseline, temp, label, started, stop, samples), daemon=True)
    sampler.start()
    group_id = None
    progress = pathlib.Path("benchmarks/browser_memory_mixed.progress.json")
    try:
        if label == "browse":
            memory.open_app(bundle, [url for _, url in pages],
                            env_args=["--env", f"SEARCH_PROBE={world}", "--env", "SEARCH_MEASURE=1"])
        else:
            memory.open_app(bundle, [url for _, url in pages],
                            app_args=[f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
                                      "--remote-debugging-port=0", "--window-size=1100,750"])
        group_id, _ = memory.app_group(marker, baseline)
        readiness_fallback_indices = []
        with server.condition:
            complete = server.condition.wait_for(
                lambda: all(trial in server.ready for trial, _ in pages), timeout=45)
        if not complete:
            details = asyncio.run(chrome_page_diagnostics(chrome_port(profile))) if label == "chrome" else {}
            with server.condition:
                missing = [index for index, (trial, _) in enumerate(pages) if trial not in server.ready]
                requested = sorted(server.requested)
            if details and all(details.get(index, {}).get("state") in ("loading", "interactive") for index in missing):
                with server.condition:
                    complete = server.condition.wait_for(
                        lambda: all(trial in server.ready for trial, _ in pages), timeout=45)
            if not complete:
                details = asyncio.run(chrome_page_diagnostics(chrome_port(profile))) if label == "chrome" else details
                with server.condition:
                    missing = [index for index, (trial, _) in enumerate(pages) if trial not in server.ready]
                loaded_targets = sorted(chrome_tabs(chrome_port(profile))) if label == "chrome" else sorted(browse_tabs(world))
                if label == "chrome" and all(valid_chrome_page(index, details.get(index, {})) for index in missing):
                    readiness_fallback_indices = missing
                else:
                    raise RuntimeError(f"Local page beacons missing at indices {missing}; page requests {requested}; "
                                       f"open target indices {loaded_targets}; page diagnostics {details}")
        with server.condition:
            for trial, _ in pages:
                server.ready.pop(trial, None)
        all_ready_seconds = None if readiness_fallback_indices else round(time.monotonic() - started, 2)
        if not preflight:
            progress.write_text(json.dumps({"browser": label, "phase": "pages ready",
                                            "readiness_fallback_indices": readiness_fallback_indices}, indent=2) + "\n")
        stop.set()
        sampler.join()
        after_load = capture(marker, baseline, temp, label, "after-load")
        if label == "browse":
            tabs = browse_tabs(world)
            if set(tabs) != set(range(10)) or any(row["bench"] for row in tabs.values()):
                raise RuntimeError("browse did not retain ten regular mixed tabs")
            command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"), "--world", world,
                    "select", tabs[9]["id"])
            size = json.loads(command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"),
                                      "--world", world, "resize", "1100", "750"))["size"]
            if size != [1100, 750]:
                raise RuntimeError("browse did not reach the requested 1100x750 window")
            initial_awake = sum(row["awake"] for row in browse_tabs(world).values())
        else:
            port = chrome_port(profile)
            tabs = chrome_tabs(port)
            if set(tabs) != set(range(10)):
                raise RuntimeError("Chrome did not retain ten regular mixed tabs")
            chrome_action(port, "activate", tabs[9])
            size = asyncio.run(chrome_window(port, tabs[9]))
            initial_awake = None
        settled_start = time.monotonic()
        settled_samples = []
        for target in ((0,) if preflight else (30, 140, 145, 150)):
            time.sleep(max(0, settled_start + target - time.monotonic()))
            snap = capture(marker, baseline, temp, label, f"settled-{target}")
            settled_samples.append({"elapsed_seconds": round(time.monotonic() - settled_start, 1),
                                    "physical_footprint_bytes": snap["physical_footprint_bytes"],
                                    "process_count": len(snap["processes"]),
                                    "capture_attempts": snap["capture_attempts"]})
            if not preflight:
                progress.write_text(json.dumps({"browser": label, "phase": "settling",
                                                "settled_samples": settled_samples}, indent=2) + "\n")
        settled = capture(marker, baseline, temp, label, "settled-final")
        if label == "browse":
            tabs = browse_tabs(world)
            if set(tabs) != set(range(10)) or not tabs[9]["active"]:
                raise RuntimeError("browse mixed tabs or active page changed during settle")
            settled_awake = sum(row["awake"] for row in tabs.values())
            for index in range(9, 0, -1):
                command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"), "--world", world,
                        "select", tabs[index]["id"])
                command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"), "--world", world,
                        "press", "13", "w", "cmd")
            remaining = browse_tabs(world)
            if set(remaining) != {0}:
                raise RuntimeError("browse did not close nine mixed tabs")
            command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"), "--world", world,
                    "select", remaining[0]["id"])
        else:
            settled_awake = None
            for index in range(9, 0, -1):
                chrome_action(port, "close", tabs[index])
            deadline = time.monotonic() + 20
            while set(chrome_tabs(port)) != {0} and time.monotonic() < deadline:
                time.sleep(0.2)
            if set(chrome_tabs(port)) != {0}:
                raise RuntimeError("Chrome did not close nine mixed tabs")
            chrome_action(port, "activate", tabs[0])
        time.sleep(0 if preflight else 30)
        recovered = capture(marker, baseline, temp, label, "recovered")
        if not preflight:
            progress.write_text(json.dumps({"browser": label, "phase": "closed nine",
                                            "settled_samples": settled_samples,
                                            "recovered_after_close_nine_and_30s": recovered}, indent=2) + "\n")
        remaining_awake = sum(row["awake"] for row in browse_tabs(world).values()) if label == "browse" else None
        return {"browser": label, "window_outer_size": size, "all_pages_ready_seconds": all_ready_seconds,
                "readiness_fallback_indices": readiness_fallback_indices,
                "loading_samples": samples, "maximum_sampled_loading_footprint_bytes": max(
                    (item["physical_footprint_bytes"] for item in samples), default=None),
                "after_load": after_load, "initial_browse_awake_tabs": initial_awake,
                "settled_samples": settled_samples, "settled": settled,
                "settled_browse_awake_tabs": settled_awake, "recovered_after_close_nine_and_30s": recovered,
                "remaining_browse_awake_tabs": remaining_awake, "retained_page_kind": "article"}
    finally:
        stop.set()
        sampler.join(timeout=5)
        stopped = stop_known_group(group_id, baseline) if group_id else memory.stop_group(marker, baseline)
        if label == "browse" and stopped:
            subprocess.run(["defaults", "delete", suite], capture_output=True)
            support = pathlib.Path.home() / "Library" / "Application Support" / f"browse ({world})"
            if support.is_dir():
                shutil.rmtree(support)
        if not stopped:
            raise RuntimeError("Could not confirm benchmark browser exited; isolated profile preserved")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="required guard before launching apps")
    parser.add_argument("--browse-app", type=pathlib.Path, default=pathlib.Path("build/browse.app"))
    parser.add_argument("--code-label", default="unverified build", help="source label for the measured browse bundle")
    parser.add_argument("--chrome-app", type=pathlib.Path, default=pathlib.Path("/Applications/Google Chrome.app"))
    parser.add_argument("--browser", choices=("all", "browse", "chrome"), default="all",
                        help="resume one browser after a failed case; Chrome resume reads the Browse checkpoint")
    parser.add_argument("--preflight", action="store_true", help="exercise the complete Chrome tab/window/close flow without settling or saving results")
    args = parser.parse_args()
    if not args.run:
        parser.error("pass --run when the desktop is available")
    for bundle in (args.browse_app, args.chrome_app):
        if not (bundle / "Contents" / "Info.plist").is_file():
            parser.error(f"app bundle missing: {bundle}")
    try:
        import websockets  # noqa: F401 — required for Chrome window and page inspection.
    except ImportError:
        parser.error("the websockets Python package is required for this benchmark")
    fingerprint = checkpoint_fingerprint(args.browse_app, args.chrome_app, args.code_label)
    checkpoint = pathlib.Path("benchmarks/browser_memory_mixed.partial.json")
    resume = json.loads(checkpoint.read_text()) if args.browser == "chrome" and not args.preflight else None
    if resume and (resume.get("fingerprint") != fingerprint or
                   [row["browser"] for row in resume.get("complete_cases", [])] != ["browse"]):
        parser.error("Chrome resume requires a matching Browse checkpoint fingerprint")
    results = resume["complete_cases"] if resume else []
    run_id = uuid.uuid4().hex[:10]
    server = MixedServer(("127.0.0.1", 0), MixedProbe)
    server.condition = threading.Condition()
    server.ready = {}
    server.requested = set()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    temp = pathlib.Path(tempfile.mkdtemp(prefix="browse-mixed-bench-"))
    clean = False
    try:
        browse_copy = temp / "browse.app"
        command("ditto", str(args.browse_app), str(browse_copy))
        command("plutil", "-replace", "CFBundleIdentifier", "-string",
                f"com.codegraff.search.mixbench.{run_id}", str(browse_copy / "Contents" / "Info.plist"))
        command("codesign", "--force", "--deep", "--sign", "-", str(browse_copy))
        cases = (("browse", browse_copy), ("chrome", args.chrome_app))
        for label, bundle in cases:
            if args.preflight and label != "chrome":
                continue
            if args.browser != "all" and label != args.browser:
                continue
            baseline = {pid for pid, _ in memory.processes()}
            results.append(run_case(label, bundle, server, temp, run_id, baseline, preflight=args.preflight))
            if not args.preflight:
                checkpoint.write_text(json.dumps({"fingerprint": fingerprint, "complete_cases": results}, indent=2) + "\n")
        clean = True
    finally:
        server.shutdown()
        server.server_close()
        if clean:
            shutil.rmtree(temp)
    if clean and not args.preflight:
        pathlib.Path("benchmarks/browser_memory_mixed.partial.json").unlink(missing_ok=True)
        pathlib.Path("benchmarks/browser_memory_mixed.progress.json").unlink(missing_ok=True)
    if args.preflight:
        print("Chrome 10-tab launch, window, activate, close-nine, retain-one, and cleanup passed")
        return
    digest = hashlib.sha256(b"".join(workload.render(index) for index in range(10))).hexdigest()
    result = {
        "measured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "host": {"mac_model": command("sysctl", "-n", "hw.model"),
                 "macos_version": command("sw_vers", "-productVersion"),
                 "macos_build": command("sw_vers", "-buildVersion")},
        "apps": {"browse": {"bundle": args.browse_app.name, "version": memory.version(args.browse_app),
                            "code_label": args.code_label},
                 "chrome": {"bundle": args.chrome_app.name, "version": memory.version(args.chrome_app)}},
        "fixture": "4 long articles, 3 boards of 600 DOM cards, 3 canvas charts at 1200x800; local only",
        "fixture_sha256": digest,
        "method": "Ten regular mixed tabs, page index 9 active, 1100x750 outer window, 150-second settle; close nine tabs and keep article index 0 for 30 seconds",
        "metric": "footprint multi-PID de-duplicated total physical footprint, bytes",
        "limitations": ["Loading maximum is sampled at roughly two-second intervals and is not a true peak.",
                        "Canvas readiness means drawing commands issued, not first visible paint.",
                        "Default browse tab sleep policy applies; Chrome awake/discard state is unmeasured.",
                        "External graff engine and user profiles are excluded; other user apps remain open."],
        "results": results,
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
