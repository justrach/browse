/-
  Formal specification and proofs for `Shield.pruneSlowGlobalCosmetics`
  (`Sources/Browse/Shield.swift`).

  Proves that pruning unindexed global cosmetic CSS rules:
    1. Preserves 100% of domain-scoped rules (`if-domain` present).
    2. Preserves 100% of O(1) hash-indexed global `#id`/`.class` rules.
    3. Eliminates EVERY unindexed global attribute/combinator/pseudo rule
       (`[`, ` `, `>`, `+`, `~`, `:`) that stalls WebKit's StyleResolver on SPAs.
    4. Never increases rule count and is idempotent (`prune (prune rs) = prune rs`).
-/

namespace Browse.ShieldFilter

structure CosmeticRule where
  hasIfDomain : Bool
  hasSlowSelector : Bool
deriving DecidableEq, Repr, BEq

/-- Matches `Shield.pruneSlowGlobalCosmetics` predicate in `Sources/Browse/Shield.swift`. -/
def keepRule (r : CosmeticRule) : Bool :=
  r.hasIfDomain || !r.hasSlowSelector

def prune (rules : List CosmeticRule) : List CosmeticRule :=
  rules.filter keepRule

/-- Every domain-scoped rule (`if-domain`) is unconditionally kept. -/
theorem domain_scoped_always_preserved (r : CosmeticRule) (h : r.hasIfDomain = true) :
    keepRule r = true := by
  unfold keepRule
  simp [h]

/-- Every fast O(1) hash-indexed global `#id`/`.class` rule is kept. -/
theorem fast_global_preserved (r : CosmeticRule) (h : r.hasSlowSelector = false) :
    keepRule r = true := by
  unfold keepRule
  simp [h]

/-- No unindexed global rule can survive pruning. -/
theorem pruned_has_no_slow_global (rules : List CosmeticRule) (r : CosmeticRule)
    (hm : r ∈ prune rules) :
    !(r.hasIfDomain == false && r.hasSlowSelector == true) := by
  unfold prune at hm
  have hk : keepRule r = true := (List.mem_filter.mp hm).2
  unfold keepRule at hk
  cases hd : r.hasIfDomain <;> cases hs : r.hasSlowSelector <;> simp_all

/-- Pruning never grows the rule list. -/
theorem prune_length_le (rules : List CosmeticRule) :
    (prune rules).length ≤ rules.length := by
  unfold prune
  exact List.length_filter_le keepRule rules

/-- Pruning is idempotent: running it twice equals running it once. -/
theorem prune_idempotent (rules : List CosmeticRule) :
    prune (prune rules) = prune rules := by
  unfold prune
  induction rules with
  | nil => rfl
  | cons r rs ih =>
    simp only [List.filter]
    cases hk : keepRule r with
    | true => simp [hk, ih]
    | false => exact ih

end Browse.ShieldFilter
