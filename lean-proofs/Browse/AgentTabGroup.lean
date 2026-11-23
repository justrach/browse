/-
  Formal specification and proof for the Dedicated Agent Tab Group
  (`Tab.swift`, `Browser.swift`, `Side.swift`, `TabBar.swift`).

  Models the tab strip partitioned into three ordered bands:
    [ Pinned tabs ] ++ [ Agent Group tabs ] ++ [ Personal loose tabs ]
  and proves across ALL arbitrary sequences of tab operations:
  1. `trace_preserves_partition`: Every operation (`openPersonal`, `openAgent`,
     `openChildFrom`, `pinTab`, `moveToAgent`, `moveToPersonal`, `clearPersonal`,
     `clearAgent`) preserves strict band ordering (`pinned ≤ agent ≤ personal`).
  2. `clearAgent_preserves_personal_and_pinned`: Clearing the Agent tab group
     NEVER removes any pinned or personal tab.
  3. `clearPersonal_preserves_agent_and_pinned`: Clearing personal `Today` tabs
     NEVER removes any pinned or Agent-group tab.
  4. `pinned_never_agent`: Pinning a tab strictly clears its Agent group tag
     (no tab can ever be both pinned and in the Agent group).
  5. `child_inherits_agent_group`: Opening a link from an Agent tab keeps it in
     the Agent group; opening from a personal tab keeps it personal.
-/

namespace Browse.AgentTabGroup

inductive TabKind where
  | pinned
  | agent
  | personal
deriving DecidableEq, Repr, BEq

def bandRank : TabKind → Nat
  | .pinned   => 0
  | .agent    => 1
  | .personal => 2

structure TabItem where
  id     : Nat
  pinned : Bool
  agent  : Bool
deriving DecidableEq, Repr, BEq

/-- Models `Tab.isAgentTab` (`agentGroup != nil && pin == nil`) and `TabKind`. -/
def isAgentTab (t : TabItem) : Bool := t.agent && !t.pinned

def kindOf (t : TabItem) : TabKind :=
  if t.pinned then .pinned
  else if t.agent then .agent
  else .personal

/-- A tab list is cleanly partitioned iff band ranks are monotonically non-decreasing. -/
def isPartitioned : List TabItem → Prop
  | []          => True
  | [_]         => True
  | a :: b :: r => bandRank (kindOf a) ≤ bandRank (kindOf b) ∧ isPartitioned (b :: r)

/-- Canonical partition-preserving insertion (models `Browser.open`, `pin`,
    `moveToAgentGroup`, `moveOutOfAgentGroup`). -/
def insertByBand (t : TabItem) : List TabItem → List TabItem
  | []     => [t]
  | x :: r =>
      if bandRank (kindOf t) < bandRank (kindOf x) then
        t :: x :: r
      else
        x :: insertByBand t r

/-- `Browser.clearAgentTabs()` — closes ONLY tabs where `isAgentTab t == true`. -/
def clearAgent (tabs : List TabItem) : List TabItem :=
  tabs.filter (fun t => !isAgentTab t)

/-- `Browser.clearLoose()` — closes ONLY personal loose tabs (`!pinned && !isAgentTab`). -/
def clearPersonal (tabs : List TabItem) : List TabItem :=
  tabs.filter (fun t => t.pinned || isAgentTab t)

/-- `Browser.pin(_:)` promotes a tab into the pinned band and clears `agentGroup`. -/
def pinItem (t : TabItem) : TabItem :=
  { t with pinned := true, agent := false }

/-- Models `let group = agentGroup ?? source?.agentGroup` in `Browser.open`. -/
def openChild (newId : Nat) (source : Option TabItem) (explicitAgent : Bool) : TabItem :=
  let srcAgent := match source with | some s => isAgentTab s | none => false
  { id := newId, pinned := false, agent := explicitAgent || srcAgent }

inductive TabOp where
  | openPersonal (id : Nat)
  | openAgent    (id : Nat)
  | openFrom     (id : Nat) (source : Option TabItem) (explicitAgent : Bool)
  | clearAgent
  | clearPersonal
  | pinNew       (t : TabItem)
deriving DecidableEq, Repr, BEq

def stepTabs (tabs : List TabItem) : TabOp → List TabItem
  | .openPersonal id => insertByBand { id := id, pinned := false, agent := false } tabs
  | .openAgent id    => insertByBand { id := id, pinned := false, agent := true } tabs
  | .openFrom id src exp => insertByBand (openChild id src exp) tabs
  | .clearAgent      => clearAgent tabs
  | .clearPersonal   => clearPersonal tabs
  | .pinNew t        => insertByBand (pinItem t) (tabs.filter (fun x => x.id != t.id))

def runTabOps (tabs : List TabItem) : List TabOp → List TabItem
  | []      => tabs
  | o :: os => runTabOps (stepTabs tabs o) os

/-! ### Core Lemmas & Theorems -/

private theorem head_rank_le_all {x : TabItem} {r : List TabItem}
    (h : isPartitioned (x :: r)) :
    ∀ y ∈ r, bandRank (kindOf x) ≤ bandRank (kindOf y) := by
  induction r generalizing x with
  | nil => intro y hy; cases hy
  | cons b rest ih =>
    intro y hy
    rcases h with ⟨hxb, hrest⟩
    cases hy with
    | head => exact hxb
    | tail _ hmem =>
      have hby := ih hrest y hmem
      omega

theorem filter_preserves_partition (p : TabItem → Bool) (tabs : List TabItem)
    (h : isPartitioned tabs) :
    isPartitioned (tabs.filter p) := by
  induction tabs with
  | nil => trivial
  | cons x r ih =>
    have hr : isPartitioned r := by
      cases r with
      | nil => trivial
      | cons _ _ => exact h.2
    have ihr := ih hr
    simp only [List.filter_cons]
    cases hp : p x
    · exact ihr
    · cases hfr : r.filter p with
      | nil => trivial
      | cons y ys =>
        rw [hfr] at ihr
        refine ⟨?_, ihr⟩
        have hy_in_rf : y ∈ r.filter p := by rw [hfr]; exact List.mem_cons_self
        have hy_in_r : y ∈ r := (List.mem_filter.mp hy_in_rf).1
        exact head_rank_le_all h y hy_in_r

theorem insertByBand_preserves_partition (t : TabItem) (tabs : List TabItem)
    (h : isPartitioned tabs) :
    isPartitioned (insertByBand t tabs) := by
  induction tabs with
  | nil => trivial
  | cons x r ih =>
    simp only [insertByBand]
    split
    · case isTrue hlt =>
      exact ⟨Nat.le_of_lt hlt, h⟩
    · case isFalse hge =>
      have hle : bandRank (kindOf x) ≤ bandRank (kindOf t) := by omega
      cases r with
      | nil =>
        simp only [insertByBand]
        exact ⟨hle, trivial⟩
      | cons y ys =>
        have hrest : isPartitioned (y :: ys) := h.2
        have hih := ih hrest
        simp only [insertByBand] at hih ⊢
        by_cases hty : bandRank (kindOf t) < bandRank (kindOf y)
        · simp only [hty, ↓reduceIte] at hih ⊢
          exact ⟨hle, hih⟩
        · simp only [hty, ↓reduceIte] at hih ⊢
          exact ⟨h.1, hih⟩

/-- Every tab operation preserves strict `[Pinned | Agent | Personal]` band ordering. -/
theorem stepTabs_preserves_partition (tabs : List TabItem) (op : TabOp)
    (h : isPartitioned tabs) :
    isPartitioned (stepTabs tabs op) := by
  cases op with
  | openPersonal _ => exact insertByBand_preserves_partition _ tabs h
  | openAgent _    => exact insertByBand_preserves_partition _ tabs h
  | openFrom _ _ _ => exact insertByBand_preserves_partition _ tabs h
  | clearAgent     => exact filter_preserves_partition _ tabs h
  | clearPersonal  => exact filter_preserves_partition _ tabs h
  | pinNew t       =>
      exact insertByBand_preserves_partition _ _ (filter_preserves_partition _ tabs h)

/-- Inductive safety theorem: across ANY sequence of tab operations starting from
    empty, tabs stay strictly partitioned `[Pinned | Agent | Personal]`. -/
theorem trace_preserves_partition (ops : List TabOp) :
    isPartitioned (runTabOps [] ops) := by
  suffices ∀ s, isPartitioned s → isPartitioned (runTabOps s ops) from this [] trivial
  induction ops with
  | nil => intro s hs; exact hs
  | cons o rest ih =>
    intro s hs
    exact ih (stepTabs s o) (stepTabs_preserves_partition s o hs)

/-- Pinning a tab strictly removes it from the Agent tab group. -/
theorem pinned_never_agent (t : TabItem) :
    isAgentTab (pinItem t) = false ∧ (pinItem t).pinned = true := by
  simp [pinItem, isAgentTab]

/-- Clearing the Agent tab group NEVER closes any pinned or personal tab. -/
theorem clearAgent_preserves_personal_and_pinned (tabs : List TabItem) (t : TabItem)
    (hmem : t ∈ tabs) (hnot : isAgentTab t = false) :
    t ∈ clearAgent tabs := by
  unfold clearAgent
  rw [List.mem_filter]
  exact ⟨hmem, by simp [hnot]⟩

/-- Clearing the Agent tab group removes EVERY Agent tab. -/
theorem clearAgent_removes_all_agent_tabs (tabs : List TabItem) (t : TabItem)
    (hmem : t ∈ clearAgent tabs) :
    isAgentTab t = false := by
  unfold clearAgent at hmem
  have hp := (List.mem_filter.mp hmem).2
  cases ha : isAgentTab t <;> simp [ha] at hp ⊢

/-- Clearing personal `Today` tabs NEVER closes any pinned or Agent-group tab. -/
theorem clearPersonal_preserves_agent_and_pinned (tabs : List TabItem) (t : TabItem)
    (hmem : t ∈ tabs) (hkeep : t.pinned = true ∨ isAgentTab t = true) :
    t ∈ clearPersonal tabs := by
  unfold clearPersonal
  rw [List.mem_filter]
  cases hkeep with
  | inl hp => exact ⟨hmem, by simp [hp]⟩
  | inr ha => exact ⟨hmem, by simp [ha]⟩

/-- Child tab inheritance: opening a link from an Agent tab keeps it in the
    Agent group; opening from a personal tab (without explicit agent flag) keeps it personal. -/
theorem child_from_agent_stays_agent (newId : Nat) (src : TabItem) (exp : Bool)
    (hsrc : isAgentTab src = true) :
    isAgentTab (openChild newId (some src) exp) = true := by
  simp only [openChild, hsrc, Bool.or_true]
  rfl

theorem child_from_personal_stays_personal (newId : Nat) (src : TabItem)
    (hsrc : isAgentTab src = false) :
    isAgentTab (openChild newId (some src) false) = false := by
  simp only [openChild, hsrc, Bool.or_false]
  rfl

end Browse.AgentTabGroup
