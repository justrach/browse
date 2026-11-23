/-
  Formal specification and proof for Browse's universal 120 Hz Scroll Fast Path
  (`Swipe.swift`, `AutoScroll.swift`, `StatusLine.swift`, `Forms.swift`,
  `SelectionBar.swift`, `Tab.swift`).

  Models the injected page-script listener registry and `HoveredLink` synthetic
  mouseover filter, and proves:
  1. Zero permanent `wheel` listeners exist on any webpage while browsing
     (keeping WebKit's GPU `ScrollingThread` off the WebContent main thread).
  2. Zero idle capture `scroll` listeners exist on `window` while no popup or
     selection pill is visible (dynamic attach/detach only).
  3. During scrolling with a stationary pointer `(x, y)`, synthetic `mouseover`
     events emit ZERO IPC messages to Swift (preventing per-frame `LinkBubble`
     SwiftUI redraws on link-dense sites like GitHub, HN, Reddit, and X).
-/

namespace Browse.ScrollFastPath

/-! ### Part 1: Injected User-Script Listener Discipline -/

inductive AttachPolicy where
  | never            -- no listener at all (e.g. Swipe uses on-demand probe)
  | dynamicWhileOpen -- attached only while a popup/pill/mode is active, removed on close
  | permanent        -- antipattern: always attached at document_start/end
deriving DecidableEq, Repr, BEq

structure ScriptSpec where
  name                : String
  wheelPolicy         : AttachPolicy
  captureScrollPolicy : AttachPolicy
deriving DecidableEq, Repr, BEq

def isActiveOnIdleScroll (p : AttachPolicy) : Bool :=
  match p with
  | .permanent => true
  | .dynamicWhileOpen | .never => false

/-- The audited registry of Browse's injected webpage scripts. -/
def browseScripts : List ScriptSpec :=
  [ { name := "Swipe",        wheelPolicy := .never,            captureScrollPolicy := .never }
  , { name := "AutoScroll",   wheelPolicy := .dynamicWhileOpen, captureScrollPolicy := .never }
  , { name := "SelectionBar", wheelPolicy := .never,            captureScrollPolicy := .dynamicWhileOpen }
  , { name := "Forms",        wheelPolicy := .never,            captureScrollPolicy := .dynamicWhileOpen }
  , { name := "ScrollRelay",  wheelPolicy := .never,            captureScrollPolicy := .never }
  , { name := "HoveredLink",  wheelPolicy := .never,            captureScrollPolicy := .never }
  ]

def idleWheelListenerCount (scripts : List ScriptSpec) : Nat :=
  scripts.foldl (fun acc s => acc + if isActiveOnIdleScroll s.wheelPolicy then 1 else 0) 0

def idleCaptureScrollCount (scripts : List ScriptSpec) : Nat :=
  scripts.foldl (fun acc s => acc + if isActiveOnIdleScroll s.captureScrollPolicy then 1 else 0) 0

/-- Theorem: Browse injects ZERO permanent `wheel` listeners across all page scripts. -/
theorem zero_idle_wheel_listeners :
    idleWheelListenerCount browseScripts = 0 := by
  decide

/-- Theorem: Browse injects ZERO permanent capture `scroll` listeners while idle. -/
theorem zero_idle_capture_scroll_listeners :
    idleCaptureScrollCount browseScripts = 0 := by
  decide

/-! ### Part 2: Zero Scroll-Induced Synthetic Mouseover IPC (`StatusLine.swift`) -/

structure HoverFilterState where
  lastX : Int
  lastY : Int
  ipcCount : Nat
deriving DecidableEq, Repr, BEq

structure MouseoverEvent where
  clientX : Int
  clientY : Int
  linkHash : Nat
deriving DecidableEq, Repr, BEq

/-- Models `HoveredLink.script`'s coordinate-change gate in `StatusLine.swift`. -/
def handleMouseover (s : HoverFilterState) (ev : MouseoverEvent) : HoverFilterState :=
  if ev.clientX = s.lastX ∧ ev.clientY = s.lastY then
    s
  else
    { lastX := ev.clientX, lastY := ev.clientY, ipcCount := s.ipcCount + 1 }

def runMouseovers (s : HoverFilterState) : List MouseoverEvent → HoverFilterState
  | []       => s
  | e :: es  => runMouseovers (handleMouseover s e) es

/-- A single synthetic scroll-induced mouseover at the same `(x, y)` emits 0 IPC. -/
theorem stationary_mouseover_zero_ipc (s : HoverFilterState) (h : Nat) :
    (handleMouseover s { clientX := s.lastX, clientY := s.lastY, linkHash := h }).ipcCount = s.ipcCount := by
  simp [handleMouseover]

/-- Across ANY number of links scrolling under a stationary cursor `(s.lastX, s.lastY)`,
    `HoveredLink` emits strictly ZERO IPC messages (0 `LinkBubble` redraws). -/
theorem scroll_stream_stationary_cursor_zero_ipc (s : HoverFilterState) (links : List Nat) :
    let events := links.map (fun h => { clientX := s.lastX, clientY := s.lastY, linkHash := h : MouseoverEvent })
    (runMouseovers s events).ipcCount = s.ipcCount := by
  induction links with
  | nil => rfl
  | cons h rest ih =>
    simpa [runMouseovers, handleMouseover] using ih

/-- Moving the cursor to a new coordinate DOES immediately emit a link update. -/
theorem moved_cursor_updates_immediately (s : HoverFilterState) (x y : Int) (h : Nat)
    (hmoved : x ≠ s.lastX ∨ y ≠ s.lastY) :
    (handleMouseover s { clientX := x, clientY := y, linkHash := h }).ipcCount = s.ipcCount + 1 := by
  unfold handleMouseover
  have hnot : ¬ (x = s.lastX ∧ y = s.lastY) := by
    intro ⟨hx, hy⟩
    cases hmoved with
    | inl hnx => exact hnx hx
    | inr hny => exact hny hy
  simp [hnot]

end Browse.ScrollFastPath
