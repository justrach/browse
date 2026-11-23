/-
  Formal specification and proof for Browse's Calmer Memory & Tab-Sleep Policy
  (`Prefs.swift`, `Sleep.swift`, `Browser.swift`).

  Models the three memory profiles (`relaxed`, `balanced`, `low`), active/media/
  agent/pinned protection predicates, pressure debouncing (`60 s` warning,
  `15 s` critical), and critical-pressure protection for recently left tabs,
  and proves:
  1. `balanced_more_generous_than_low` & `relaxed_more_generous_than_balanced`:
     Every profile step strictly increases `awakeMost`, `crowdedAfterSec`, and
     `sleepAfterSec`.
  2. `active_or_split_never_evicted`, `agent_attached_never_evicted`,
     `pinned_never_evicted_in_balanced_or_relaxed`, and
     `unsaved_or_media_never_evicted`:
     Protected tabs are never evicted under either normal sweeps or memory
     pressure.
  3. `working_set_not_crowd_evicted`:
     Background tabs inside the `awakeMost` working set and under
     `sleepAfterSec` are never crowd-evicted.
  4. `warning_cooldown_prevents_thrash` & `critical_cooldown_prevents_thrash`:
     Repeated pressure signals within cooldown (`< 60 s` warning, `< 15 s`
     critical) cannot re-evict tabs.
  5. `critical_protects_recently_left_tab`:
     Any tab touched within `< 60 s` is never evicted even under `.critical`
     memory pressure.
-/

namespace Browse.MemoryPolicy

inductive MemoryMode where
  | low
  | balanced
  | relaxed
deriving DecidableEq, Repr, BEq

def awakeMost : MemoryMode → Nat
  | .low      => 3
  | .balanced => 6
  | .relaxed  => 12

def crowdedAfterSec : MemoryMode → Nat
  | .low      => 120
  | .balanced => 300
  | .relaxed  => 900

def sleepAfterSec : MemoryMode → Nat
  | .low      => 600
  | .balanced => 1800
  | .relaxed  => 7200

def pinnedSleepSec : Nat := 2700

structure TabFlags where
  isActive       : Bool
  inSplit        : Bool
  isPinned       : Bool
  isBench        : Bool
  isBlank        : Bool
  isAsleep       : Bool
  isSleeping     : Bool
  isLoading      : Bool
  isNoisy        : Bool
  isFloating     : Bool
  onCall         : Bool
  downloading    : Bool
  hasDialog      : Bool
  isOpener       : Bool
  agentPinned    : Bool
  agentMentioned : Bool
  agentWorking   : Bool
  isAgentTab     : Bool
  unsavedDraft   : Bool
deriving DecidableEq, Repr, BEq

def isProtected (mode : MemoryMode) (allowIdlePinned : Bool) (t : TabFlags) : Bool :=
  t.isActive || t.inSplit ||
  (t.isPinned && !(allowIdlePinned && decide (mode = .low))) ||
  t.isBench || t.isBlank || t.isAsleep || t.isSleeping || t.isLoading ||
  t.isNoisy || t.isFloating || t.onCall || t.downloading || t.hasDialog ||
  t.isOpener || t.agentPinned || t.agentMentioned ||
  (t.agentWorking && t.isAgentTab) || t.unsavedDraft

def pressureCooldownBlocks (isCritical : Bool) (elapsedSec : Nat) : Bool :=
  if isCritical then decide (elapsedSec < 15) else decide (elapsedSec < 60)

def pressureWaitSec (mode : MemoryMode) (isCritical : Bool) : Nat :=
  if isCritical then 60 else max 300 (sleepAfterSec mode / 2)

def shouldEvictNormal (mode : MemoryMode) (t : TabFlags) (idleSec recencyRank : Nat) : Bool :=
  if isProtected mode true t then
    false
  else if t.isPinned then
    decide (idleSec ≥ max (sleepAfterSec mode) pinnedSleepSec)
  else
    decide (idleSec ≥ sleepAfterSec mode) ||
    (decide (recencyRank ≥ awakeMost mode) && decide (idleSec ≥ crowdedAfterSec mode))

def shouldEvictPressure (mode : MemoryMode) (isCritical : Bool)
    (elapsedSinceLastSec : Nat) (t : TabFlags) (idleSec : Nat) (inRecentProtected : Bool) : Bool :=
  if pressureCooldownBlocks isCritical elapsedSinceLastSec then
    false
  else if isProtected mode true t then
    false
  else if inRecentProtected then
    false
  else
    let wait := pressureWaitSec mode isCritical
    let threshold := if t.isPinned && decide (mode = .low) then max wait pinnedSleepSec else wait
    decide (idleSec ≥ threshold)

theorem balanced_more_generous_than_low :
    awakeMost .low < awakeMost .balanced ∧
    crowdedAfterSec .low < crowdedAfterSec .balanced ∧
    sleepAfterSec .low < sleepAfterSec .balanced := by
  decide

theorem relaxed_more_generous_than_balanced :
    awakeMost .balanced < awakeMost .relaxed ∧
    crowdedAfterSec .balanced < crowdedAfterSec .relaxed ∧
    sleepAfterSec .balanced < sleepAfterSec .relaxed := by
  decide

private theorem eviction_false_when_protected
    (mode : MemoryMode) (isCritical : Bool) (elapsed idleSec rank : Nat)
    (inRecent : Bool) (t : TabFlags)
    (hprot : isProtected mode true t = true) :
    shouldEvictNormal mode t idleSec rank = false ∧
    shouldEvictPressure mode isCritical elapsed t idleSec inRecent = false := by
  constructor
  · simp [shouldEvictNormal, hprot]
  · simp [shouldEvictPressure, hprot]

theorem active_or_split_never_evicted
    (mode : MemoryMode) (isCritical : Bool) (elapsed idleSec rank : Nat)
    (inRecent : Bool) (t : TabFlags)
    (h : t.isActive = true ∨ t.inSplit = true) :
    shouldEvictNormal mode t idleSec rank = false ∧
    shouldEvictPressure mode isCritical elapsed t idleSec inRecent = false := by
  apply eviction_false_when_protected
  rcases h with ha | hs
  · simp [isProtected, ha]
  · simp [isProtected, hs]

theorem agent_attached_never_evicted
    (mode : MemoryMode) (isCritical : Bool) (elapsed idleSec rank : Nat)
    (inRecent : Bool) (t : TabFlags)
    (h : t.agentPinned = true ∨ t.agentMentioned = true ∨ (t.agentWorking = true ∧ t.isAgentTab = true)) :
    shouldEvictNormal mode t idleSec rank = false ∧
    shouldEvictPressure mode isCritical elapsed t idleSec inRecent = false := by
  apply eviction_false_when_protected
  rcases h with hp | hm | ⟨hw, ha⟩
  · simp [isProtected, hp]
  · simp [isProtected, hm]
  · simp [isProtected, hw, ha]

theorem pinned_never_evicted_in_balanced_or_relaxed
    (mode : MemoryMode) (isCritical : Bool) (elapsed idleSec rank : Nat)
    (inRecent : Bool) (t : TabFlags)
    (hmode : mode ≠ .low) (hpin : t.isPinned = true) :
    shouldEvictNormal mode t idleSec rank = false ∧
    shouldEvictPressure mode isCritical elapsed t idleSec inRecent = false := by
  apply eviction_false_when_protected
  simp [isProtected, hmode, hpin]

theorem unsaved_or_media_never_evicted
    (mode : MemoryMode) (isCritical : Bool) (elapsed idleSec rank : Nat)
    (inRecent : Bool) (t : TabFlags)
    (h : t.unsavedDraft = true ∨ t.isNoisy = true ∨ t.onCall = true ∨
         t.downloading = true ∨ t.isFloating = true) :
    shouldEvictNormal mode t idleSec rank = false ∧
    shouldEvictPressure mode isCritical elapsed t idleSec inRecent = false := by
  apply eviction_false_when_protected
  rcases h with hu | hn | hc | hd | hf
  · simp [isProtected, hu]
  · simp [isProtected, hn]
  · simp [isProtected, hc]
  · simp [isProtected, hd]
  · simp [isProtected, hf]

theorem working_set_not_crowd_evicted
    (mode : MemoryMode) (t : TabFlags) (idleSec recencyRank : Nat)
    (hunpinned : t.isPinned = false)
    (hrank : recencyRank < awakeMost mode)
    (hidle : idleSec < sleepAfterSec mode) :
    shouldEvictNormal mode t idleSec recencyRank = false := by
  unfold shouldEvictNormal
  split
  · rfl
  · have hn1 : ¬ (idleSec ≥ sleepAfterSec mode) := by omega
    have hn2 : ¬ (recencyRank ≥ awakeMost mode) := by omega
    simp [hunpinned, hn1, hn2]

theorem warning_cooldown_prevents_thrash
    (mode : MemoryMode) (elapsedSinceLastSec idleSec : Nat)
    (inRecent : Bool) (t : TabFlags)
    (hlt : elapsedSinceLastSec < 60) :
    shouldEvictPressure mode false elapsedSinceLastSec t idleSec inRecent = false := by
  simp [shouldEvictPressure, pressureCooldownBlocks, hlt]

theorem critical_cooldown_prevents_thrash
    (mode : MemoryMode) (elapsedSinceLastSec idleSec : Nat)
    (inRecent : Bool) (t : TabFlags)
    (hlt : elapsedSinceLastSec < 15) :
    shouldEvictPressure mode true elapsedSinceLastSec t idleSec inRecent = false := by
  simp [shouldEvictPressure, pressureCooldownBlocks, hlt]

theorem critical_protects_recently_left_tab
    (mode : MemoryMode) (elapsedSinceLastSec idleSec : Nat)
    (inRecent : Bool) (t : TabFlags)
    (hlt : idleSec < 60) :
    shouldEvictPressure mode true elapsedSinceLastSec t idleSec inRecent = false := by
  unfold shouldEvictPressure
  split
  · rfl
  · split
    · rfl
    · split
      · rfl
      · by_cases hpinLow : (t.isPinned = true ∧ mode = .low)
        · obtain ⟨hp, rfl⟩ := hpinLow
          simp [hp, pressureWaitSec, pinnedSleepSec]
          omega
        · have hwait : pressureWaitSec mode true = 60 := rfl
          have hn : ¬ (idleSec ≥ pressureWaitSec mode true) := by rw [hwait]; omega
          have hcond : (t.isPinned && decide (mode = .low)) = false := by
            cases hp : t.isPinned <;> cases hm : mode <;> simp_all
          simp [hcond, hn]

end Browse.MemoryPolicy
