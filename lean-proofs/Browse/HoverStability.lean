/-
  Formal specification and proof for UI Hover Stability (`TabOverview.swift`,
  `Recall.swift`, `Passwords.swift`, `Browser.swift`).

  Prevents two classic SwiftUI/macOS UI shaking antipatterns:
  1. Hover ↔ ScrollTo feedback loops: hovering a row updates selection/highlight
     without advancing `keyboardScrollTick` or mutating `scrollOffset`, so a
     stationary pointer over a scrollable list can NEVER trigger an oscillation.
  2. Hover-induced row layout reflow: using fixed-slot opacity-gated controls
     (`SlotMode.fixedOpacity`) guarantees row height and cumulative list height
     stay strictly invariant across every hover event (contrasted with a proved
     counterexample showing that conditional insertion `SlotMode.conditional`
     mutates row height and causes vertical list jitter).
-/

namespace Browse.HoverStability

/-- How hover-revealed trailing controls (close/split/remove/show buttons) are
    laid out inside a list or card row. -/
inductive SlotMode where
  | fixedOpacity   -- always laid out in ZStack/HStack, visibility via .opacity(...)
  | conditional    -- antipattern: `if hovering { Button(...) }` inserted on hover
deriving DecidableEq, Repr, BEq

/-- Height of a single list row given its base text height, hover control height,
    slot mode, and whether the pointer is hovering it. -/
def rowHeight (mode : SlotMode) (baseH controlH : Nat) (hovering : Bool) : Nat :=
  match mode with
  | .fixedOpacity => max baseH controlH
  | .conditional  => if hovering then max baseH controlH else baseH

/-- A single row with fixed-slot opacity has IDENTICAL height whether hovered or not. -/
theorem fixedOpacity_row_height_invariant (baseH controlH : Nat) (h1 h2 : Bool) :
    rowHeight .fixedOpacity baseH controlH h1 = rowHeight .fixedOpacity baseH controlH h2 := by
  rfl

/-- Total vertical height of an entire list of `n` rows where row `hoverIdx` is hovered. -/
def totalListHeight (mode : SlotMode) (baseH controlH : Nat) (hoverIdx : Option Nat) : Nat → Nat
  | 0     => 0
  | n + 1 =>
      let isHov := decide (hoverIdx = some n)
      rowHeight mode baseH controlH isHov + totalListHeight mode baseH controlH hoverIdx n

/-- Under `fixedOpacity`, moving the pointer between ANY two rows leaves the
    entire list's total height strictly unchanged (zero vertical list shake). -/
theorem fixedOpacity_list_height_invariant (baseH controlH n : Nat) (h1 h2 : Option Nat) :
    totalListHeight .fixedOpacity baseH controlH h1 n =
    totalListHeight .fixedOpacity baseH controlH h2 n := by
  induction n with
  | zero => rfl
  | succ k ih =>
    simp only [totalListHeight, rowHeight]
    omega

/-- Counterexample proving why the `if hovering { Quick(...) }` antipattern shakes:
    when a Quick button (30pt) is taller than a timestamp (14pt), hovering a row
    mutates its height from 14pt to 30pt, shifting every row underneath it. -/
theorem conditional_slot_reflows_counterexample :
    rowHeight .conditional 14 30 false ≠ rowHeight .conditional 14 30 true := by
  decide

/-! ### Part 2: Zero Hover ↔ ScrollTo Feedback Loop -/

structure ListState where
  scrollOffset       : Nat
  selectedIdx        : Nat
  keyboardScrollTick : Nat
deriving DecidableEq, Repr, BEq

inductive PointerEvent where
  | hover (idx : Nat)
  | keyStep (nextIdx : Nat) (targetScroll : Nat)
deriving DecidableEq, Repr, BEq

/-- Models `TabSwitcherState` + `TabOverview.swift`:
    - Pointer `.hover` updates `selectedIdx` ONLY; it NEVER increments
      `keyboardScrollTick` and NEVER changes `scrollOffset`.
    - Keyboard `.keyStep` advances `keyboardScrollTick` and scrolls if needed. -/
def stepList (s : ListState) : PointerEvent → ListState
  | .hover idx =>
      { s with selectedIdx := idx }
  | .keyStep nextIdx targetScroll =>
      { scrollOffset := targetScroll
        selectedIdx := nextIdx
        keyboardScrollTick := s.keyboardScrollTick + 1 }

/-- Hovering a row NEVER changes `scrollOffset` or `keyboardScrollTick`. -/
theorem hover_never_scrolls (s : ListState) (idx : Nat) :
    (stepList s (.hover idx)).scrollOffset = s.scrollOffset ∧
    (stepList s (.hover idx)).keyboardScrollTick = s.keyboardScrollTick := by
  simp [stepList]

/-- Under a stationary pointer at viewport row `rowAtPointer(scrollOffset)`,
    hovering immediately reaches a fixed point in 1 step (no 60–120 Hz oscillation). -/
theorem hover_reaches_immediate_fixed_point (s : ListState) (rowAtPointer : Nat → Nat) :
    let s1 := stepList s (.hover (rowAtPointer s.scrollOffset))
    let s2 := stepList s1 (.hover (rowAtPointer s1.scrollOffset))
    s2 = s1 := by
  simp [stepList]

/-- Any arbitrary sequence of pure pointer hovers leaves `scrollOffset` strictly invariant. -/
def runHovers (s : ListState) : List Nat → ListState
  | []       => s
  | i :: is  => runHovers (stepList s (.hover i)) is

theorem hover_sequence_preserves_scroll (s : ListState) (hovers : List Nat) :
    (runHovers s hovers).scrollOffset = s.scrollOffset := by
  induction hovers generalizing s with
  | nil => rfl
  | cons i rest ih =>
    simpa [runHovers, stepList] using ih { s with selectedIdx := i }

end Browse.HoverStability
