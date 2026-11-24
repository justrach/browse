/-
  Browse.UserTabGroups — Formal Specification & Kernel Proofs

  Models general user-created Tab Groups alongside Pinned and Agent tabs
  (Sources/Browse/TabGroup.swift, Tab.swift, Browser.swift):
  1. Four-way mutual exclusion: every tab is in at most one of
     {Pinned, AgentGroup, UserGroup, Ungrouped}; pinning clears both group
     fields, moving to Agent clears pin and userGroup, adding to a user group
     clears pin and agentGroup.
  2. Tab conservation under ungroup and isolated group close: ungrouping
     preserves all tabs (`length` unchanged) and closing a group leaves every
     non-member tab untouched.
  3. Group extension ID mapping (`groupNumber`): deterministic and strictly
     non-zero (`>= 1`) for Chrome `chrome.tabGroups` compatibility.
  4. Dangling-group pruning: after filtering `userGroupID` against valid
     space group IDs, no orphaned group references remain.
-/

namespace Browse.UserTabGroups

inductive TabLane where
  | pinned
  | agent
  | userGroup (gid : Nat)
  | ungrouped
  deriving DecidableEq, Repr

structure TabModel where
  id : Nat
  pinned : Bool
  agent : Bool
  userGroup : Option Nat
  deriving DecidableEq, Repr

/-- Mutual-exclusion invariant matching `Tab.pin`, `Tab.isAgentTab`, and `Tab.userGroupID`. -/
def wfTab (t : TabModel) : Prop :=
  (t.pinned = true -> t.agent = false /\ t.userGroup = none) /\
  (t.agent = true -> t.pinned = false /\ t.userGroup = none)

def lane (t : TabModel) : TabLane :=
  if t.pinned then .pinned
  else if t.agent then .agent
  else match t.userGroup with
    | some g => .userGroup g
    | none => .ungrouped

theorem pin_exclusivity (t : TabModel) :
    wfTab { t with pinned := true, agent := false, userGroup := none } := by
  simp [wfTab]

theorem agent_exclusivity (t : TabModel) :
    wfTab { t with pinned := false, agent := true, userGroup := none } := by
  simp [wfTab]

theorem userGroup_exclusivity (t : TabModel) (gid : Nat) :
    wfTab { t with pinned := false, agent := false, userGroup := some gid } := by
  simp [wfTab]

theorem userGroup_lane (t : TabModel) (gid : Nat) :
    lane { t with pinned := false, agent := false, userGroup := some gid } = .userGroup gid := by
  simp [lane]

/-- Ungrouping strips only matching `userGroup` tags, conserving every tab. -/
def ungroupTabs (gid : Nat) (tabs : List TabModel) : List TabModel :=
  tabs.map fun t => if t.userGroup == some gid then { t with userGroup := none } else t

theorem ungroup_preserves_count (gid : Nat) (tabs : List TabModel) :
    (ungroupTabs gid tabs).length = tabs.length := by
  simp [ungroupTabs]

theorem ungroup_clears_target (gid : Nat) (tabs : List TabModel) :
    forall t, t ∈ ungroupTabs gid tabs -> t.userGroup ≠ some gid := by
  intro t ht
  simp only [ungroupTabs, List.mem_map] at ht
  rcases ht with ⟨s, _, rfl⟩
  by_cases h : (s.userGroup == some gid) = true
  · simp [h]
  · simp [h]
    intro heq
    apply h
    simp [heq]

/-- Closing a group removes only members of that group and leaves all others intact. -/
def closeGroupTabs (gid : Nat) (tabs : List TabModel) : List TabModel :=
  tabs.filter fun t => t.userGroup != some gid

theorem closeGroup_preserves_others (gid : Nat) (tabs : List TabModel) (t : TabModel) :
    t ∈ tabs -> t.userGroup ≠ some gid -> t ∈ closeGroupTabs gid tabs := by
  intro ht hne
  simp only [closeGroupTabs, List.mem_filter]
  refine ⟨ht, ?_⟩
  simp [hne]

/-- Models `TabGroup.number(_:)` fallback when the first 31 bits equal 0. -/
def groupNumber (raw31 : Nat) : Nat :=
  if raw31 == 0 then 1 else raw31

theorem groupNumber_nonzero (raw31 : Nat) : groupNumber raw31 >= 1 := by
  unfold groupNumber
  split
  · omega
  · next h =>
    have hne : raw31 ≠ 0 := by simpa using h
    omega

/-- Strips any dangling `userGroup` IDs not present in `validGroups`. -/
def pruneOrphans (validGroups : List Nat) (tabs : List TabModel) : List TabModel :=
  tabs.map fun t =>
    match t.userGroup with
    | some g => if g ∈ validGroups then t else { t with userGroup := none }
    | none => t

theorem pruneOrphans_valid (validGroups : List Nat) (tabs : List TabModel) :
    forall t, t ∈ pruneOrphans validGroups tabs ->
      forall g, t.userGroup = some g -> g ∈ validGroups := by
  intro t ht g hg
  simp only [pruneOrphans, List.mem_map] at ht
  rcases ht with ⟨s, _, rfl⟩
  cases hs : s.userGroup with
  | none =>
    simp [hs] at hg
  | some g0 =>
    by_cases hmem : g0 ∈ validGroups
    · simp [hs, hmem] at hg
      subst hg
      exact hmem
    · simp [hs, hmem] at hg

end Browse.UserTabGroups
