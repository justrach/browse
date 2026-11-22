#!/usr/bin/env python3
"""Static UI artifact & layout regression guardrails for browse."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "Sources" / "Browse"

failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"PASS: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        failures.append(msg)


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


# 1. Pill, Quick, and WelcomePanel.Big must lock text to single-line fixedSize
#    so capsule buttons never wrap into vertical single-letter columns.
settings = read("Sources/Browse/Settings.swift")
pill_match = re.search(r"struct Pill: View \{.*?\n\}", settings, re.S)
check(
    pill_match is not None
    and ".lineLimit(1)" in pill_match.group(0)
    and ".fixedSize()" in pill_match.group(0),
    "Settings.Pill enforces .lineLimit(1) and .fixedSize()",
)

plate = read("Sources/Browse/Plate.swift")
quick_match = re.search(r"struct Quick: View \{.*?\n\}", plate, re.S)
check(
    quick_match is not None
    and ".lineLimit(1)" in quick_match.group(0)
    and ".fixedSize()" in quick_match.group(0),
    "Plate.Quick enforces .lineLimit(1) and .fixedSize()",
)

welcome = read("Sources/Browse/Welcome.swift")
big_match = re.search(r"private struct Big: View \{.*?\n    \}", welcome, re.S)
check(
    big_match is not None
    and ".lineLimit(1)" in big_match.group(0)
    and ".fixedSize()" in big_match.group(0),
    "WelcomePanel.Big enforces .lineLimit(1) and .fixedSize()",
)

# 2. Plate.Line descriptions must not truncate to 3 lines.
line_match = re.search(r"struct Line<Control: View>: View \{.*?\n\}", plate, re.S)
check(
    line_match is not None and ".lineLimit(3)" not in line_match.group(0),
    "Plate.Line detail text does not truncate at 3 lines",
)

# 3. No GooeyTabBridge or gutter Bézier loops anywhere in Sources/Browse/.
all_swift = "\n".join(p.read_text(encoding="utf-8") for p in SRC.glob("*.swift"))
check(
    "GooeyTabBridge" not in all_swift,
    "No GooeyTabBridge gutter artifact present in Sources/Browse/",
)

# 4. AgentColumn ScrollView must not apply full-view .mask(...) (120 FPS guard).
agent_col = read("Sources/Browse/AgentColumn.swift")
said_match = re.search(r"private var said: some View \{.*?\n    \}", agent_col, re.S)
said_code = ""
if said_match is not None:
    said_code = "\n".join(
        line for line in said_match.group(0).splitlines()
        if not line.lstrip().startswith("//")
    )
check(
    said_match is not None and ".mask(" not in said_code and ".mask {" not in said_code,
    "AgentColumn.said avoids offscreen ScrollView .mask(...) for 120 FPS chat scrolling",
)

# 5. AgentColumn.head must not render a wrapped 'harness' pill next to graff.
head_match = re.search(r"private var head: some View \{.*?\n    \}", agent_col, re.S)
check(
    head_match is not None and 'Text("harness")' not in head_match.group(0),
    "AgentColumn.head has no narrow-width-wrapping harness badge",
)

# 6. TabPaletteView must clip its card container and bound its preview height.
tab_overview = read("Sources/Browse/TabOverview.swift")
check(
    ".clipShape(cardShape)" in tab_overview and ".frame(height: 234)" in tab_overview,
    "TabPaletteView clips its card cleanly and bounds sneak-peek height",
)

# 7. CHANGELOG.md structure check: has Unreleased + valid dated version headers + no duplicates.
changelog = read("CHANGELOG.md")
check("## Unreleased" in changelog, "CHANGELOG.md contains ## Unreleased section")
versions = re.findall(r"^## (\d+\.\d+\.\d+) — \d{1,2} [A-Z][a-z]+ \d{4}$", changelog, re.M)
check(len(versions) >= 5, f"CHANGELOG.md lists dated release sections (found {len(versions)})")
check(len(versions) == len(set(versions)), "CHANGELOG.md has no duplicate release version headings")

# 8. ⌘; / ⇧⌘; agent shortcuts must supersede Edit › Spelling and Grammar & web pages.
shortcuts_src = read("Sources/Browse/Shortcuts.swift")
app_src = read("Sources/Browse/App.swift")
tab_src = read("Sources/Browse/Tab.swift")
composer_src = read("Sources/Browse/NanoComposerField.swift")
check(
    "class MenuKeySanitizer" in shortcuts_src
    and "checkSpelling:" in shortcuts_src
    and "showGuessPanel:" in shortcuts_src
    and "MenuKeySanitizer.shared.start()" in app_src,
    "MenuKeySanitizer strips conflicting macOS Edit › Spelling (⌘; / ⌘:) shortcuts",
)
check(
    "isAgentToggle(event)" in tab_src and "isAgentToggle(event)" in composer_src,
    "PageView and NanoTextView intercept performKeyEquivalent for ⌘; / ⇧⌘;",
)

# 9. Full Disk Access flow auto-registers browse in SystemPolicyAllFiles list.
browser_src = read("Sources/Browse/Browser.swift")
import_panel_src = read("Sources/Browse/ImportPanel.swift")
check(
    "func registerForFullDiskAccessList()" in browser_src
    and "Browser.registerForFullDiskAccessList()" in import_panel_src,
    "Full Disk Access flow auto-registers browse in System Settings list",
)

if failures:
    print(f"\n{len(failures)} source guardrail check(s) failed.", file=sys.stderr)
    sys.exit(1)

print("\nAll static UI & changelog guardrails passed.")
