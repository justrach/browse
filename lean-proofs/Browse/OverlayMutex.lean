/-
  Formal specification and proof for full-window modal overlay mutual exclusion
  (`Browser.ModalOverlay` / `Browser.dismissOverlays(keeping:)` in
  `Sources/Browse/Browser.swift`).

  Models all 12 full-window overlays (`⌘K`/`⇧⌘\` switcher, `⌘Y` history,
  `⌘J` downloads, `⌘,` settings, `⌘⌥B` bookmarks, `⌘/` shortcuts, passwords,
  import, hidden-on-site review, `⌃Tab` MRU HUD, welcome, and `⌘L` address bar)
  and proves that NO arbitrary sequence of open/toggle/close shortcut actions
  can EVER leave two overlays open simultaneously — in particular, `⌘K` and
  `⌘Y` can never both be open at once.
-/

namespace Browse.OverlayMutex

inductive Overlay where
  | switcher     -- ⌘K palette / ⇧⌘\ Tab Overview
  | history      -- ⌘Y History / Clear Data
  | downloads    -- ⇧⌘J Downloads
  | settings     -- ⌘, Settings
  | bookmarks    -- ⌥⌘B Bookmarks
  | shortcuts    -- ⌘/ Shortcut Guide
  | passwords    -- Passwords sheet
  | importing    -- Import sheet
  | reviewing    -- Hidden on This Site popover
  | tabCycle     -- ⌃Tab MRU switcher HUD
  | welcome      -- First-launch Welcome sheet
  | address      -- ⌘L Omnibox editing overlay
deriving DecidableEq, Repr, BEq

structure OverlayState where
  switcher  : Bool
  history   : Bool
  downloads : Bool
  settings  : Bool
  bookmarks : Bool
  shortcuts : Bool
  passwords : Bool
  importing : Bool
  reviewing : Bool
  tabCycle  : Bool
  welcome   : Bool
  address   : Bool
deriving DecidableEq, Repr, BEq

def b2n (b : Bool) : Nat := if b then 1 else 0

def emptyState : OverlayState :=
  { switcher := false, history := false, downloads := false, settings := false,
    bookmarks := false, shortcuts := false, passwords := false, importing := false,
    reviewing := false, tabCycle := false, welcome := false, address := false }

def isOpen (s : OverlayState) : Overlay → Bool
  | .switcher  => s.switcher
  | .history   => s.history
  | .downloads => s.downloads
  | .settings  => s.settings
  | .bookmarks => s.bookmarks
  | .shortcuts => s.shortcuts
  | .passwords => s.passwords
  | .importing => s.importing
  | .reviewing => s.reviewing
  | .tabCycle  => s.tabCycle
  | .welcome   => s.welcome
  | .address   => s.address

def activeCount (s : OverlayState) : Nat :=
  b2n s.switcher + b2n s.history + b2n s.downloads + b2n s.settings +
  b2n s.bookmarks + b2n s.shortcuts + b2n s.passwords + b2n s.importing +
  b2n s.reviewing + b2n s.tabCycle + b2n s.welcome + b2n s.address

/-- State produced by setting overlay `o` to open and immediately running
    `Browser.dismissOverlays(keeping: o)`. -/
def exclusiveState (o : Overlay) : OverlayState :=
  { switcher  := decide (o = .switcher)
    history   := decide (o = .history)
    downloads := decide (o = .downloads)
    settings  := decide (o = .settings)
    bookmarks := decide (o = .bookmarks)
    shortcuts := decide (o = .shortcuts)
    passwords := decide (o = .passwords)
    importing := decide (o = .importing)
    reviewing := decide (o = .reviewing)
    tabCycle  := decide (o = .tabCycle)
    welcome   := decide (o = .welcome)
    address   := decide (o = .address) }

def clearOverlay (s : OverlayState) : Overlay → OverlayState
  | .switcher  => { s with switcher := false }
  | .history   => { s with history := false }
  | .downloads => { s with downloads := false }
  | .settings  => { s with settings := false }
  | .bookmarks => { s with bookmarks := false }
  | .shortcuts => { s with shortcuts := false }
  | .passwords => { s with passwords := false }
  | .importing => { s with importing := false }
  | .reviewing => { s with reviewing := false }
  | .tabCycle  => { s with tabCycle := false }
  | .welcome   => { s with welcome := false }
  | .address   => { s with address := false }

inductive Action where
  | openOverlay   (o : Overlay)
  | toggleOverlay (o : Overlay)
  | closeOverlay  (o : Overlay)
  | closeAll
deriving DecidableEq, Repr, BEq

def step (s : OverlayState) : Action → OverlayState
  | .openOverlay o   => exclusiveState o
  | .toggleOverlay o => if isOpen s o then clearOverlay s o else exclusiveState o
  | .closeOverlay o  => clearOverlay s o
  | .closeAll        => emptyState

def runTrace (s : OverlayState) : List Action → OverlayState
  | []      => s
  | a :: as => runTrace (step s a) as

private theorem b2n_false_le (b : Bool) : b2n false ≤ b2n b := by
  cases b <;> decide

/-- Opening any overlay yields an exact active overlay count of 1. -/
theorem exclusiveState_activeCount_one (o : Overlay) :
    activeCount (exclusiveState o) = 1 := by
  cases o <;> decide

/-- Opening overlay `o` leaves `o` open and every distinct overlay `o' ≠ o` closed. -/
theorem exclusiveState_only_self (o o' : Overlay) :
    isOpen (exclusiveState o) o' = decide (o' = o) := by
  cases o <;> cases o' <;> decide

/-- Closing an overlay never increases the number of active overlays. -/
theorem clearOverlay_le (s : OverlayState) (o : Overlay) :
    activeCount (clearOverlay s o) ≤ activeCount s := by
  cases s with
  | mk sw hi dl se bm sh pw im rv tc wl ad =>
    have hsw := b2n_false_le sw; have hhi := b2n_false_le hi
    have hdl := b2n_false_le dl; have hse := b2n_false_le se
    have hbm := b2n_false_le bm; have hsh := b2n_false_le sh
    have hpw := b2n_false_le pw; have him := b2n_false_le im
    have hrv := b2n_false_le rv; have htc := b2n_false_le tc
    have hwl := b2n_false_le wl; have had := b2n_false_le ad
    cases o <;> simp only [clearOverlay, activeCount] <;> omega

/-- Every single overlay action preserves the mutex invariant `activeCount ≤ 1`. -/
theorem step_preserves_mutex (s : OverlayState) (a : Action)
    (h : activeCount s ≤ 1) :
    activeCount (step s a) ≤ 1 := by
  cases a with
  | openOverlay o =>
    simp [step, exclusiveState_activeCount_one]
  | toggleOverlay o =>
    simp only [step]
    split
    · exact Nat.le_trans (clearOverlay_le s o) h
    · simp [exclusiveState_activeCount_one]
  | closeOverlay o =>
    exact Nat.le_trans (clearOverlay_le s o) h
  | closeAll =>
    simp [step]; decide

/-- No arbitrary sequence of shortcut actions can ever reach a state with more
    than one active overlay. -/
theorem trace_preserves_mutex_from (s : OverlayState) (trace : List Action)
    (h : activeCount s ≤ 1) :
    activeCount (runTrace s trace) ≤ 1 := by
  induction trace generalizing s with
  | nil => exact h
  | cons a rest ih =>
    exact ih (step s a) (step_preserves_mutex s a h)

theorem trace_preserves_mutex (trace : List Action) :
    activeCount (runTrace emptyState trace) ≤ 1 :=
  trace_preserves_mutex_from emptyState trace (by decide)

/-- Helper: if two distinct overlays are both open, then `activeCount ≥ 2`. -/
private theorem two_open_ge_two (s : OverlayState) (o1 o2 : Overlay)
    (hne : o1 ≠ o2) (h1 : isOpen s o1 = true) (h2 : isOpen s o2 = true) :
    activeCount s ≥ 2 := by
  cases s with
  | mk sw hi dl se bm sh pw im rv tc wl ad =>
    cases o1 <;> cases o2
    all_goals first
      | exact absurd rfl hne
      | (simp [isOpen] at h1 h2; simp [activeCount, h1, h2, b2n]; try omega)

/-- If `activeCount s ≤ 1`, no two distinct overlays can be open at once. -/
theorem mutex_no_pair (s : OverlayState) (h : activeCount s ≤ 1)
    (o1 o2 : Overlay) (hne : o1 ≠ o2) :
    ¬ (isOpen s o1 = true ∧ isOpen s o2 = true) := by
  intro ⟨h1, h2⟩
  have hge := two_open_ge_two s o1 o2 hne h1 h2
  omega

/-- Universal safety theorem: across ANY sequence of overlay shortcuts, no two
    distinct overlays can ever be open simultaneously. -/
theorem no_two_overlays_reachable (trace : List Action)
    (o1 o2 : Overlay) (hne : o1 ≠ o2) :
    ¬ (isOpen (runTrace emptyState trace) o1 = true ∧
       isOpen (runTrace emptyState trace) o2 = true) :=
  mutex_no_pair (runTrace emptyState trace) (trace_preserves_mutex trace) o1 o2 hne

/-- Specifically, `⌘K` (switcher) and `⌘Y` (history) can NEVER both be open. -/
theorem cmdK_and_cmdY_never_both_open (trace : List Action) :
    ¬ (isOpen (runTrace emptyState trace) .switcher = true ∧
       isOpen (runTrace emptyState trace) .history = true) :=
  no_two_overlays_reachable trace .switcher .history (by decide)

/-- Concrete witness: pressing `⌘K` then `⌘Y` dismisses `⌘K` and leaves only `⌘Y`. -/
theorem cmdK_then_cmdY_exclusive :
    let s := runTrace emptyState [.openOverlay .switcher, .toggleOverlay .history]
    isOpen s .switcher = false ∧ isOpen s .history = true ∧ activeCount s = 1 := by
  decide

/-- Concrete witness: pressing `⌘Y` then `⌘K` dismisses `⌘Y` and leaves only `⌘K`. -/
theorem cmdY_then_cmdK_exclusive :
    let s := runTrace emptyState [.toggleOverlay .history, .openOverlay .switcher]
    isOpen s .history = false ∧ isOpen s .switcher = true ∧ activeCount s = 1 := by
  decide

end Browse.OverlayMutex
