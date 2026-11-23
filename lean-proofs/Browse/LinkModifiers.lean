/-
  Formal specification and proof for Link Click Modifier Policy
  (`Browser.swift`: `decidePolicyFor` & `createWebViewWith`).

  Proves consistent, unambiguous modifier-click semantics across BOTH normal
  same-frame links and `target="_blank"` links:
  1. `cmd_click_always_foreground_new_tab`:
     `⌘+click` (without `⇧`) ALWAYS opens a new foreground tab.
  2. `cmd_shift_click_always_background_new_tab`:
     `⌘⇧+click` ALWAYS opens a new background tab (even on `target="_blank"`).
  3. `shift_click_peeks_iff_enabled`:
     Plain `⇧+click` on a normal link opens a Peek overlay iff `peeksEnabled ∧ ¬inPeek`.
  4. `plain_same_frame_navigates_in_place`:
     Plain click on a normal link always navigates in place.
-/

namespace Browse.LinkModifiers

structure Modifiers where
  cmd   : Bool
  shift : Bool
  opt   : Bool
  ctrl  : Bool
deriving DecidableEq, Repr, BEq

inductive LinkTarget where
  | sameFrame
  | blankTarget
deriving DecidableEq, Repr, BEq

inductive LinkOutcome where
  | navigateInPlace
  | peekOverlay
  | newTabForeground
  | newTabBackground
deriving DecidableEq, Repr, BEq

/-- Exact model of `Browser.swift`'s `decidePolicyFor` (sameFrame) and
    `createWebViewWith` (blankTarget). -/
def decideLink (m : Modifiers) (target : LinkTarget) (peeksEnabled inPeek : Bool) : LinkOutcome :=
  match target with
  | .blankTarget =>
      if m.cmd && m.shift then .newTabBackground
      else .newTabForeground
  | .sameFrame =>
      if peeksEnabled && !inPeek && m.shift && !m.cmd && !m.opt && !m.ctrl then
        .peekOverlay
      else if m.cmd then
        if m.shift then .newTabBackground else .newTabForeground
      else
        .navigateInPlace

/-- `⌘+click` (without `⇧`) ALWAYS opens a new foreground tab for every target
    and regardless of Peek settings or extra modifiers. -/
theorem cmd_click_always_foreground_new_tab
    (opt ctrl peeks inPeek : Bool) (target : LinkTarget) :
    decideLink { cmd := true, shift := false, opt := opt, ctrl := ctrl } target peeks inPeek
      = .newTabForeground := by
  cases target <;> simp [decideLink]

/-- `⌘⇧+click` ALWAYS opens a new background tab — consistently across BOTH
    same-frame links AND `target="_blank"` links. -/
theorem cmd_shift_click_always_background_new_tab
    (opt ctrl peeks inPeek : Bool) (target : LinkTarget) :
    decideLink { cmd := true, shift := true, opt := opt, ctrl := ctrl } target peeks inPeek
      = .newTabBackground := by
  cases target <;> simp [decideLink]

/-- Plain `⇧+click` opens a Peek overlay iff Peek is enabled and not already inside a Peek. -/
theorem shift_click_peeks_iff (peeks inPeek : Bool) :
    decideLink { cmd := false, shift := true, opt := false, ctrl := false } .sameFrame peeks inPeek = .peekOverlay
    ↔ (peeks = true ∧ inPeek = false) := by
  cases peeks <;> cases inPeek <;> simp [decideLink]

/-- Plain left-click on a normal link ALWAYS navigates in place. -/
theorem plain_click_navigates_in_place (peeks inPeek : Bool) :
    decideLink { cmd := false, shift := false, opt := false, ctrl := false } .sameFrame peeks inPeek
      = .navigateInPlace := by
  simp [decideLink]

/-- Plain `target="_blank"` click opens a new foreground tab. -/
theorem blank_target_plain_click_foreground (peeks inPeek : Bool) :
    decideLink { cmd := false, shift := false, opt := false, ctrl := false } .blankTarget peeks inPeek
      = .newTabForeground := by
  simp [decideLink]

end Browse.LinkModifiers
