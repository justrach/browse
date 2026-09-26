#!/usr/bin/env python3
"""Measure settled whole-browser physical footprint for 1, 5, and 10 local tabs.

Run only when the desktop is free for this interactive benchmark:
    python3 benchmarks/browser_memory.py --run > benchmarks/browser_memory.json

macOS libproc coalition IDs group an app with its launchd-managed helpers,
including WebKit processes. `footprint` measures those PIDs together and
de-duplicates shared mappings. The metric includes compressed/dirty physical
footprint, not RSS or total system memory. WebKit system frameworks are shared
OS resources, and this benchmark does not assign all system costs to browse.
"""

import argparse
import contextlib
import ctypes
import datetime
import json
import os
import pathlib
import plistlib
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid

from benchmark_server import Probe
import http.server


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_pidinfo.restype = ctypes.c_int
PROC_PIDCOALITIONINFO = 20  # macOS Darwin proc_info.h; 2 IDs + 3 reserved uint64s.


def processes():
    rows = []
    for line in subprocess.check_output(["ps", "-axo", "pid=,command=", "-ww"], text=True).splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            rows.append((int(fields[0]), fields[1]))
    return rows


def coalition(pid):
    values = (ctypes.c_uint64 * 5)()
    size = LIBPROC.proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, values, ctypes.sizeof(values))
    return int(values[0]) if size == ctypes.sizeof(values) else None


def app_group(marker, baseline):
    matches = [(pid, command) for pid, command in processes() if marker in command]
    if not matches:
        raise RuntimeError("Launched browser process was not found")
    # The app's command line carries the unique copied-bundle/profile marker.
    group_ids = {coalition(pid) for pid, _ in matches}
    if len(group_ids) != 1 or None in group_ids or 0 in group_ids:
        raise RuntimeError("Cannot read the browser's coalition ID")
    group_id = group_ids.pop()
    members = [(pid, command) for pid, command in processes() if coalition(pid) == group_id]
    if any(pid in baseline for pid, _ in members):
        raise RuntimeError("Browser coalition contains a process from before this trial")
    return group_id, members


def stop_group(marker, baseline):
    try:
        group_id, members = app_group(marker, baseline)
    except RuntimeError:
        return False
    for pid, _ in members:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not any(coalition(pid) == group_id for pid, _ in processes()):
            return True
        time.sleep(0.1)
    for pid, _ in processes():
        if coalition(pid) == group_id:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    return not any(coalition(pid) == group_id for pid, _ in processes())


def page(server):
    trial = uuid.uuid4().hex
    return trial, f"http://127.0.0.1:{server.server_port}/page?trial={trial}"


def await_page(server, trial, timeout):
    with server.condition:
        if not server.condition.wait_for(lambda: trial in server.ready, timeout=timeout):
            raise RuntimeError("Local page did not report DOMContentLoaded")
        server.ready.pop(trial)


def open_app(bundle, urls, env_args=(), app_args=()):
    command = ["open", "-n", "-a", str(bundle), *env_args, *urls]
    if app_args:
        command += ["--args", *app_args]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Launch Services failed: {result.stderr.strip()}")


def verify_tabs(label, count, server, world=None, profile=None):
    prefix = f"http://127.0.0.1:{server.server_port}/page?trial="
    if label == "browse":
        result = subprocess.run([str(pathlib.Path(__file__).resolve().parents[1] / "bench"), "--world", world, "tabs"],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f"browse tab inspection failed: {result.stderr.strip()}")
        tabs = [line for line in result.stdout.splitlines() if prefix in line]
        if len(tabs) != count or any(line.startswith("⚗") for line in tabs):
            raise RuntimeError("browse did not retain the expected regular tabs")
        return sum(not line.endswith(" z") for line in tabs)
    else:
        port = int((profile / "DevToolsActivePort").read_text().splitlines()[0])
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=10) as response:
            targets = json.load(response)
        tabs = [item for item in targets if item.get("type") == "page" and item.get("url", "").startswith(prefix)]
        if len(tabs) != count:
            raise RuntimeError("Chrome did not retain the expected regular tabs")
        return None


def footprint(pids, output):
    command = ["footprint", "--noCategories", "--swapped", "-f", "bytes", "-j", str(output)]
    for pid in pids:
        command += ["-p", str(pid)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"footprint failed: {result.stderr.strip()}")
    data = json.loads(output.read_text())
    output.unlink()
    if data.get("errors") or data.get("warnings"):
        raise RuntimeError(f"footprint returned errors or warnings: {data['errors']}; {data['warnings']}")
    return data


def measure(label, bundle, marker, count, server, temp, world, timeout, settle, baseline):
    pages = [page(server) for _ in range(count)]
    urls = [url for _, url in pages]
    if label == "browse":
        env = ["--env", f"SEARCH_PROBE={world}", "--env", "SEARCH_MEASURE=1"]
        open_app(bundle, urls, env_args=env)
    else:
        profile = temp / f"chrome-profile-{count}"
        profile.mkdir()
        open_app(bundle, urls, app_args=[f"--user-data-dir={profile}", "--no-first-run",
                                        "--no-default-browser-check", "--remote-debugging-port=0",
                                        "--disable-session-crashed-bubble"])
    for trial, _ in pages:
        await_page(server, trial, timeout)
    initial_awake = verify_tabs(label, count, server, world=world, profile=profile if label == "chrome" else None)
    initial_group_id, initial_members = app_group(marker, baseline)
    initial_data = footprint([pid for pid, _ in initial_members], temp / f"footprint-initial-{label}-{count}.json")
    started_settle = time.monotonic()
    ticks = sorted(set([30] if settle > 30 else []) | {max(0, settle - 10), max(0, settle - 5), settle})
    snapshots = []
    for target in ticks:
        time.sleep(max(0, started_settle + target - time.monotonic()))
        sampled_group_id, sampled_members = app_group(marker, baseline)
        if sampled_group_id != initial_group_id:
            raise RuntimeError("Browser coalition changed between snapshots")
        sampled_data = footprint([pid for pid, _ in sampled_members], temp / f"footprint-{label}-{count}-{target}.json")
        snapshots.append({"elapsed_seconds": round(time.monotonic() - started_settle, 1),
                          "physical_footprint_bytes": sampled_data["total footprint"],
                          "process_count": len(sampled_members)})
    settled_awake = verify_tabs(label, count, server, world=world, profile=profile if label == "chrome" else None)
    group_id, members = app_group(marker, baseline)
    if group_id != initial_group_id:
        raise RuntimeError("Browser coalition changed between snapshots")
    pids = [pid for pid, _ in members]
    data = footprint(pids, temp / f"footprint-{label}-{count}.json")
    if {process["pid"] for process in data["processes"]} != set(pids):
        raise RuntimeError("Some coalition processes exited during footprint collection")
    return {
        "browser": label,
        "tabs": count,
        "coalition_id": group_id,
        "process_count": len(pids),
        "initial_process_count": len(initial_members),
        "initial_physical_footprint_bytes": initial_data["total footprint"],
        "initial_browse_awake_tabs": initial_awake,
        "settled_browse_awake_tabs": settled_awake,
        "snapshots": snapshots,
        "final_three_median_physical_footprint_bytes": int(statistics.median(
            sample["physical_footprint_bytes"] for sample in snapshots[-3:])),
        "processes": [{"pid": process["pid"], "role": pathlib.Path(process["name"]).name,
                       "physical_footprint_bytes": process["footprint"]}
                      for process in data["processes"]],
        "physical_footprint_bytes": data["total footprint"],
        "footprint_process_count": len(data["processes"]),
    }


def version(bundle):
    with (bundle / "Contents" / "Info.plist").open("rb") as source:
        return plistlib.load(source).get("CFBundleShortVersionString")


@contextlib.contextmanager
def isolated_directory(keep):
    path = pathlib.Path(tempfile.mkdtemp(prefix="browse-memory-bench-"))
    try:
        yield path
    finally:
        if not keep["value"]:
            shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="required guard before launching apps")
    parser.add_argument("--browse-app", type=pathlib.Path, default=pathlib.Path("build/browse.app"))
    parser.add_argument("--code-label", default="unverified build", help="source label for the measured browse bundle")
    parser.add_argument("--chrome-app", type=pathlib.Path, default=pathlib.Path("/Applications/Google Chrome.app"))
    parser.add_argument("--settle", type=float, default=150)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--checkpoint", type=pathlib.Path, default=pathlib.Path("benchmarks/browser_memory.partial.json"))
    args = parser.parse_args()
    if not args.run:
        parser.error("pass --run when the desktop is available for a memory benchmark")
    if args.settle < 0 or args.timeout <= 0:
        parser.error("settle must be nonnegative and timeout positive")
    for bundle in (args.browse_app, args.chrome_app):
        if not (bundle / "Contents" / "Info.plist").is_file():
            parser.error(f"app bundle missing: {bundle}")

    run_id = uuid.uuid4().hex[:10]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Probe)
    server.condition = threading.Condition()
    server.ready = {}
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    results = []
    keep_temp = {"value": False}
    with isolated_directory(keep_temp) as temp:
        browse_copy = temp / "browse.app"
        subprocess.run(["ditto", str(args.browse_app), str(browse_copy)], check=True)
        try:
            for count in (1, 5, 10):
                for label in (("browse", "chrome") if count != 5 else ("chrome", "browse")):
                    world = f"membench-{run_id}-{count}"
                    suite = f"com.codegraff.search.test.{world}"
                    marker = str(browse_copy if label == "browse" else temp / f"chrome-profile-{count}")
                    if label == "browse":
                        # A new bundle ID gives every case its own default
                        # WebKit container and prevents installed-app routing.
                        subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string",
                                        f"com.codegraff.search.membench.{run_id}.{count}",
                                        str(browse_copy / "Contents" / "Info.plist")], check=True)
                        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(browse_copy)],
                                       check=True, capture_output=True)
                        subprocess.run(["defaults", "write", suite, "welcomed", "-bool", "true"], check=True)
                        subprocess.run(["defaults", "write", suite, "bench", "-bool", "true"], check=True)
                    try:
                        baseline = {pid for pid, _ in processes()}
                        results.append(measure(label, browse_copy if label == "browse" else args.chrome_app,
                                               marker, count, server, temp, world, args.timeout,
                                               30 if count == 1 else args.settle, baseline))
                        args.checkpoint.write_text(json.dumps({"complete_cases": results}, indent=2) + "\n")
                    finally:
                        stopped = stop_group(marker, baseline)
                        if label == "browse" and stopped:
                            subprocess.run(["defaults", "delete", suite], capture_output=True)
                            support = pathlib.Path.home() / "Library" / "Application Support" / f"browse ({world})"
                            if support.is_dir():
                                shutil.rmtree(support)
                        if not stopped:
                            keep_temp["value"] = True
                            raise RuntimeError("Could not confirm benchmark browser exited; profile was preserved")
        finally:
            server.shutdown()
            server.server_close()

    result = {
        "measured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "host": {"mac_model": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                 "macos_version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
                 "macos_build": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
                 "logical_cpu_count": int(subprocess.check_output(["sysctl", "-n", "hw.ncpu"], text=True)),
                 "physical_memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))},
        "apps": {"browse": {"bundle": args.browse_app.name, "version": version(args.browse_app), "code_label": args.code_label},
                 "chrome": {"bundle": args.chrome_app.name, "version": version(args.chrome_app), "code_label": "installed"}},
        "metric": "footprint multi-PID de-duplicated total physical footprint, bytes",
        "method": "Fresh isolated profiles; identical local static page in 1/5/10 regular tabs; app resource coalition includes launchd-managed WebKit helpers; no AI prompt",
        "settle_seconds": {"one_tab": 30, "five_and_ten_tabs": args.settle},
        "results": results,
        "limitations": ["All tabs share one local origin; browser process allocation can differ for separate sites.",
                        "WebKit frameworks are system resources and shared with other apps.",
                        "No AI prompt is sent; external graff engine costs and user profiles are excluded.",
                        "Other user apps remain open; background machine activity may affect results.",
                        "Per-process footprint rows are not additive because shared memory is de-duplicated only in the total.",
                        "No runtime speed or user-session memory claim is inferred."],
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    args.checkpoint.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
