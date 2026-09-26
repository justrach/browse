#!/usr/bin/env python3
"""Repeat the one-tab local fixture at a matched window size and 150s settle.

Run only on a quiet desktop:
    python3 benchmarks/browser_memory_single.py --run > benchmarks/browser_memory_single.json
"""

import argparse
import asyncio
import datetime
import http.server
import json
import pathlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import browser_memory as memory
import browser_memory_mixed as mixed


def run_case(label, bundle, server, temp, run_id, baseline, preflight=False):
    world = f"onebench-{run_id}"
    suite = f"com.codegraff.search.test.{world}"
    profile = temp / "chrome-profile"
    marker = str(bundle if label == "browse" else profile)
    if label == "browse":
        mixed.command("defaults", "write", suite, "welcomed", "-bool", "true")
        mixed.command("defaults", "write", suite, "bench", "-bool", "true")
    else:
        profile.mkdir()
    trial, url = memory.page(server)
    group_id = None
    try:
        if label == "browse":
            memory.open_app(bundle, [url], env_args=["--env", f"SEARCH_PROBE={world}",
                                                     "--env", "SEARCH_MEASURE=1"])
        else:
            memory.open_app(bundle, [url], app_args=[f"--user-data-dir={profile}", "--no-first-run",
                                                     "--no-default-browser-check", "--remote-debugging-port=0",
                                                     "--window-size=1100,750"])
        group_id, _ = memory.app_group(marker, baseline)
        memory.await_page(server, trial, 45)
        if label == "browse":
            # The simple fixture has no index parameter; verify through bench.
            lines = mixed.command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"),
                                  "--world", world, "tabs").splitlines()
            if len([line for line in lines if "/page?trial=" in line and not line.startswith("⚗")]) != 1:
                raise RuntimeError("browse did not retain one regular local tab")
            size = json.loads(mixed.command(str(pathlib.Path(__file__).resolve().parents[1] / "bench"),
                                            "--world", world, "resize", "1100", "750"))["size"]
            if size != [1100, 750]:
                raise RuntimeError("browse did not reach 1100x750 outer window")
        else:
            port = mixed.chrome_port(profile)
            targets = [item for item in mixed.targets(port) if item.get("type") == "page" and url in item.get("url", "")]
            if len(targets) != 1:
                raise RuntimeError("Chrome did not retain one local page tab")
            size = asyncio.run(mixed.chrome_window(port, targets[0]["id"]))
        start = time.monotonic()
        snapshots = []
        last_valid_capture = None
        last_valid_target = None
        for target in ((0, 0, 0, 0, 0) if preflight else (30, 140, 145, 150)):
            time.sleep(max(0, start + target - time.monotonic()))
            try:
                capture = mixed.capture(marker, baseline, temp, label, f"single-{target}")
                last_valid_capture = capture
                last_valid_target = target
                snapshots.append({"target_seconds": target, "elapsed_seconds": round(time.monotonic() - start, 1),
                                  "physical_footprint_bytes": capture["physical_footprint_bytes"],
                                  "process_count": len(capture["processes"])})
            except RuntimeError as error:
                if preflight:
                    raise
                snapshots.append({"target_seconds": target, "elapsed_seconds": round(time.monotonic() - start, 1),
                                  "error": str(error)})
            if not preflight:
                pathlib.Path("benchmarks/browser_memory_single.progress.json").write_text(
                    json.dumps({"browser": label, "completed_snapshots": snapshots}, indent=2) + "\n")
        try:
            final = mixed.capture(marker, baseline, temp, label, "single-final")
            final_role_snapshot_source = "after final scheduled sample"
        except RuntimeError:
            final = last_valid_capture
            final_role_snapshot_source = f"scheduled sample at {last_valid_target}s" if last_valid_capture else None
        awake = memory.verify_tabs(label, 1, server, world=world,
                                   profile=profile if label == "chrome" else None)
        final_values = [item["physical_footprint_bytes"] for item in snapshots
                        if item["target_seconds"] >= 140 and "physical_footprint_bytes" in item]
        return {"browser": label, "window_outer_size": size, "snapshots": snapshots,
                "final_window_median_physical_footprint_bytes": int(statistics.median(final_values)) if len(final_values) >= 2 else None,
                "final_window_valid_sample_count": len(final_values),
                "final_role_snapshot": final, "final_role_snapshot_source": final_role_snapshot_source,
                "browse_awake_tabs": awake}
    finally:
        stopped = mixed.stop_known_group(group_id, baseline) if group_id else memory.stop_group(marker, baseline)
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
    parser.add_argument("--preflight", action="store_true", help="exercise both one-tab flows without settling or saving results")
    args = parser.parse_args()
    if not args.run:
        parser.error("pass --run when the desktop is available")
    for bundle in (args.browse_app, args.chrome_app):
        if not (bundle / "Contents" / "Info.plist").is_file():
            parser.error(f"app bundle missing: {bundle}")
    try:
        import websockets  # noqa: F401 — required for Chrome window inspection.
    except ImportError:
        parser.error("the websockets Python package is required for this benchmark")
    run_id = uuid.uuid4().hex[:10]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), memory.Probe)
    server.condition = threading.Condition()
    server.ready = {}
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    temp = pathlib.Path(tempfile.mkdtemp(prefix="browse-single-bench-"))
    clean = False
    checkpoint = pathlib.Path("benchmarks/browser_memory_single.partial.json")
    results = []
    try:
        browse_copy = temp / "browse.app"
        mixed.command("ditto", str(args.browse_app), str(browse_copy))
        mixed.command("plutil", "-replace", "CFBundleIdentifier", "-string",
                      f"com.codegraff.search.onebench.{run_id}", str(browse_copy / "Contents" / "Info.plist"))
        mixed.command("codesign", "--force", "--deep", "--sign", "-", str(browse_copy))
        for label, bundle in (("browse", browse_copy), ("chrome", args.chrome_app)):
            baseline = {pid for pid, _ in memory.processes()}
            results.append(run_case(label, bundle, server, temp, run_id, baseline, preflight=args.preflight))
            if not args.preflight:
                checkpoint.write_text(
                    json.dumps({"complete_cases": results}, indent=2) + "\n")
        clean = True
    finally:
        server.shutdown()
        server.server_close()
        if clean:
            shutil.rmtree(temp)
    if not args.preflight:
        checkpoint.unlink(missing_ok=True)
        pathlib.Path("benchmarks/browser_memory_single.progress.json").unlink(missing_ok=True)
    if args.preflight:
        print("Browse and Chrome one-tab launch, matched window, snapshot, and cleanup passed")
        return
    result = {
        "measured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "host": {"mac_model": mixed.command("sysctl", "-n", "hw.model"),
                 "macos_version": mixed.command("sw_vers", "-productVersion"),
                 "macos_build": mixed.command("sw_vers", "-buildVersion")},
        "apps": {"browse": {"bundle": args.browse_app.name, "version": memory.version(args.browse_app),
                            "code_label": args.code_label},
                 "chrome": {"bundle": args.chrome_app.name, "version": memory.version(args.chrome_app)}},
        "metric": "footprint multi-PID de-duplicated total physical footprint, bytes",
        "method": "One regular local static page, 1100x750 outer window, 150-second settle, three final samples over ten seconds",
        "limitations": ["WebKit frameworks are shared system resources.",
                        "Chrome awake/discard state was not measured.",
                        "Other user apps remained open; external graff engine and user profiles are excluded."],
        "results": results,
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
