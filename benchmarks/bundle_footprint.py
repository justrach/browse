#!/usr/bin/env python3
"""Measure installed macOS app bundle disk footprints without launching them.

Run: python3 benchmarks/bundle_footprint.py --ci-app /path/to/browse.app \
    --ci-label browse_ci_8452b4d --ci-code-label 'CI commit 8452b4d' \
    > benchmarks/bundle_footprint.json
Only bundle basenames appear in output; supplied paths are never written to JSON.
"""

import datetime
import argparse
import json
import os
import pathlib
import plistlib
import subprocess
import sys


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def logical_file_bytes(bundle):
    total = 0
    for root, _, files in os.walk(bundle, followlinks=False):
        for filename in files:
            path = pathlib.Path(root, filename)
            if not path.is_symlink():
                total += path.stat().st_size
    return total


def measure(label, bundle, code_label):
    with (bundle / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executable_name = info["CFBundleExecutable"]
    executable = bundle / "Contents" / "MacOS" / executable_name
    return {
        "label": label,
        "bundle": bundle.name,
        "code_label": code_label,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "allocated_kib": int(command("du", "-sk", str(bundle)).split()[0]),
        "logical_file_bytes": logical_file_bytes(bundle),
        "executable": executable_name,
        "executable_architectures": command("lipo", "-archs", str(executable)).split(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browse-app", type=pathlib.Path, default=pathlib.Path("/Applications/browse.app"))
    parser.add_argument("--chrome-app", type=pathlib.Path, default=pathlib.Path("/Applications/Google Chrome.app"))
    parser.add_argument("--ci-app", type=pathlib.Path, help="optional CI browse bundle to measure")
    parser.add_argument("--ci-label", default="browse_ci")
    parser.add_argument("--ci-code-label", default="unverified CI build")
    args = parser.parse_args()
    apps_to_measure = [
        ("browse_installed", args.browse_app, "installed"),
        ("chrome_installed", args.chrome_app, "installed"),
    ]
    if args.ci_app:
        apps_to_measure.append((args.ci_label, args.ci_app, args.ci_code_label))
    apps = []
    for label, bundle, code_label in apps_to_measure:
        if not bundle.is_dir():
            raise FileNotFoundError(f"Required app bundle is missing: {bundle}")
        apps.append(measure(label, bundle, code_label))

    by_label = {app["label"]: app for app in apps}
    ratio = by_label["chrome_installed"]["allocated_kib"] / by_label["browse_installed"]["allocated_kib"]
    result = {
        "measured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "host": {
            "mac_model": command("sysctl", "-n", "hw.model"),
            "macos_version": command("sw_vers", "-productVersion"),
            "macos_build": command("sw_vers", "-buildVersion"),
        },
        "method": "du -sk app bundle; logical bytes sum regular files without following symlinks",
        "excludes": [
            "user profiles and caches",
            "system WebKit frameworks used by browse",
            "external graff engine or other helper costs outside the app bundle",
            "runtime memory and performance",
        ],
        "apps": apps,
        "chrome_to_browse_allocated_ratio": round(ratio, 3),
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
