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

# 10. Password Vault security guardrails: device-only Keychain, fail-closed auth, 0o700 import snapshots.
vault_src = read("Sources/Browse/Vault.swift")
import_src = read("Sources/Browse/Import.swift")
safari_import_src = read("Sources/Browse/SafariImport.swift")
check(
    "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" in vault_src
    and "LAError.passcodeNotSet" in vault_src,
    "Vault stores secrets WhenUnlockedThisDeviceOnly and fails closed on LAError",
)
check(
    "0o700" in import_src and "0o700" in safari_import_src,
    "Browser import temporary directories enforce owner-only 0o700 permissions",
)

# 11. ⌘L must always belong to the browser and focus + select-all reliably on window attach.
omnibox_src = read("Sources/Browse/Omnibox.swift")
check(
    'BrowserCommand(.openAddress, .file, "Open Address…", KeyCombo("l", command: true), alwaysOurs: true)' in shortcuts_src
    and "class FocusableAddressField" in omnibox_src
    and "viewDidMoveToWindow()" in omnibox_src
    and "fulfillPendingFocus" in omnibox_src,
    "⌘L is alwaysOurs and FocusableAddressField reliably focuses & selects all on mount",
)

# 12. Dark Mode PageTint guard, image paste in NanoTextView, and Fast/Ultra Fast service tiers.
design_src = read("Sources/Browse/Design.swift")
agent_src = read("Sources/Browse/Agent.swift")
check(
    "if scheme == .dark, seen >= 0.5 { return nil }" in design_src,
    "PageTint never flips a Dark Mode window frame into bright white chrome",
)
check(
    "override func paste(_ sender: Any?)" in composer_src
    and "struct PastedImage:" in agent_src
    and "enum ServiceTier:" in agent_src
    and "serviceTierBar" in agent_col,
    "graff composer supports image pasting (⌘V) and Standard / Fast / Ultra Fast speed modes",
)

# 13. Universal 120 FPS scroll fast-path guardrails (matches Browse.ScrollFastPath).
forms_src = read("Sources/Browse/Forms.swift")
swipe_src = read("Sources/Browse/Swipe.swift")
shield_src = read("Sources/Browse/Shield.swift")
status_src = read("Sources/Browse/StatusLine.swift")
autoscroll_src = read("Sources/Browse/AutoScroll.swift")
selection_src = read("Sources/Browse/SelectionBar.swift")
stage_src = read("Sources/Browse/Stage.swift")
check(
    "function hasPasswordInput()" in forms_src
    and 'querySelectorAll(\'input[type="password"]\')' not in all_swift,
    "No full-DOM querySelectorAll('input[type=\"password\"]') anywhere in Sources/Browse/",
)
mutation_files = sorted(
    p.name for p in SRC.glob("*.swift")
    if "new MutationObserver" in p.read_text(encoding="utf-8")
)
check(
    mutation_files == ["Forms.swift", "StoreRelay.swift"],
    f"Only audited, fast-bailed MutationObservers exist in Sources/Browse/ (found {mutation_files})",
)
framerate_src = read("Sources/Browse/FrameRate.swift")
tab_scroll_src = read("Sources/Browse/Tab.swift")
check(
    "pruneSlowGlobalCosmetics" in shield_src
    and '"[id^=' not in shield_src
    and "addEventListener('wheel'" not in swipe_src
    and "addEventListener('scroll'" not in swipe_src
    and "removeEventListener('wheel', stop" in autoscroll_src
    and "removeEventListener('scroll', hide" in selection_src
    and "removeEventListener('scroll', moved" in forms_src
    and "event.clientX === lastX && event.clientY === lastY" in status_src
    and "layer?.shadowPath" in stage_src
    and "opaqueOcclusion.isOpaque = true" in stage_src
    and "AcceleratedCompositingForFixedPositionEnabled" in framerate_src
    and "addEventListener('scrollend'" in tab_scroll_src,
    "Universal 120 FPS scroll fast path: zero permanent wheel/capture-scroll listeners, stationary-cursor hover filter, GPU fixed-position compositing, opaque backdrop occlusion, trailing-edge scrollend ScrollRelay",
)

# 14. Strict modal overlay mutual exclusion (⌘K + ⌘Y can never stack; matches Browse.OverlayMutex).
browser_src = read("Sources/Browse/Browser.swift")
app_src = read("Sources/Browse/App.swift")
required_overlay_guards = [
    "dismissOverlays(keeping: .switcher)",
    "dismissOverlays(keeping: .history)",
    "dismissOverlays(keeping: .downloads)",
    "dismissOverlays(keeping: .settings)",
    "dismissOverlays(keeping: .bookmarks)",
    "dismissOverlays(keeping: .shortcuts)",
    "dismissOverlays(keeping: .passwords)",
    "dismissOverlays(keeping: .importing)",
    "dismissOverlays(keeping: .reviewing)",
    "dismissOverlays(keeping: .tabCycle)",
    "dismissOverlays(keeping: .welcome)",
    "dismissOverlays(keeping: .address)",
]
missing_guards = [g for g in required_overlay_guards if g not in browser_src]
check(
    not missing_guards and "!browser.hasModalOverlay" in app_src,
    f"All 12 modal overlays enforce mutual exclusion via dismissOverlays(keeping:) (missing: {missing_guards})",
)

# 15. Hover stability (matches Browse.HoverStability): no hover↔scrollTo feedback
# loops, no bouncy anchor: .center on selection change, and no hover row-height reflow.
recall_src = read("Sources/Browse/Recall.swift")
passwords_src = read("Sources/Browse/Passwords.swift")
check(
    "proxy.scrollTo(id, anchor: .center)" not in tab_overview
    and ".onChange(of: state.keyboardScrollTick)" in tab_overview
    and not re.search(r"(?m)^\s*if hovering\b", tab_overview)
    and not re.search(r"(?m)^\s*if hovering\b", recall_src)
    and not re.search(r"(?m)^\s*if hovering\b", passwords_src),
    "Hover stability: keyboard-only scrollTo (no hover↔scrollTo loop) and fixed-slot opacity rows in TabOverview, Recall, and Passwords",
)

# 16. Escape-key termination (matches Browse.EscapeTermination): no modal traps.
check(
    "if browser.bookmarksOpen {" in app_src
    and "if browser.welcoming {" in app_src
    and "if !browser.recallHunt.isEmpty {" in app_src
    and "!browser.hasModalOverlay" in app_src,
    "Escape-key termination: Escape dismisses bookmarksOpen, welcoming, and History search query before closing",
)

# 17. Agent Tab Group isolation, ⌘+click foreground policy, and 2-hour UpdatePolicy.
tab_src = read("Sources/Browse/Tab.swift")
updater_src = read("Sources/Browse/Updater.swift")
check(
    "var isAgentTab: Bool { agentGroup != nil && pin == nil }" in tab_src
    and "func clearAgentTabs()" in browser_src
    and "!$0.isAgentTab" in browser_src
    and "tab.agentGroup = nil" in browser_src,
    "AgentTabGroup: pinned promotion, clearLoose/clearAgentTabs isolation, and child inheritance",
)
check(
    "foreground: !action.modifierFlags.contains(.shift)" in browser_src
    and "let background = action.modifierFlags.contains(.command) && action.modifierFlags.contains(.shift)" in browser_src,
    "LinkModifiers: ⌘+click opens foreground tab and ⌘⇧+click opens background tab across normal & target=_blank links",
)
check(
    "static let checkInterval: TimeInterval = 60 * 60 * 2" in updater_src
    and "found.build > Updater.build" in updater_src
    and "snoozedBuild != release.build" in updater_src,
    "UpdatePolicy: 2-hour cadence, strict monotonic build check, and per-build banner snooze",
)

if failures:
    print(f"\n{len(failures)} source guardrail check(s) failed.", file=sys.stderr)
    sys.exit(1)

print("\nAll static UI & changelog guardrails passed.")
