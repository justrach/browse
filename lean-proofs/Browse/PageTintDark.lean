/-
  Formal specification and proof for `PageTint` (`Sources/Browse/Design.swift`).

  Models the exact luminance / dark-mode chrome decision in fixed-point permille
  (0..1000) and proves that in Dark Mode (`scheme = .dark`), `PageTint` can NEVER
  return a light-mode chrome (`dark = false`), preventing dark SPAs whose WebKit
  `underPageBackgroundColor` defaults to `#FFFFFF` from flashing white chrome.
-/

namespace Browse.PageTintDark

inductive ColorScheme where
  | light
  | dark
deriving DecidableEq, Repr, BEq

structure TintResult where
  seenPermille : Nat
  dark : Bool
deriving DecidableEq, Repr, BEq

/-- Fixed-point permille model of `PageTint.init?(_:over:)` in `Sources/Browse/Design.swift`.
    `seen` is the composited luminance in `[0, 1000]`. -/
def computeTint (scheme : ColorScheme) (seen : Nat) : Option TintResult :=
  if scheme = .dark ∧ seen ≥ 500 then
    none
  else
    some { seenPermille := seen, dark := decide (seen < 500) }

/-- In Dark Mode, `PageTint` NEVER flips the window chrome into Light Mode (`dark = false`). -/
theorem dark_mode_never_flips_light (seen : Nat) (res : TintResult)
    (h : computeTint .dark seen = some res) :
    res.dark = true := by
  unfold computeTint at h
  by_cases hge : seen ≥ 500
  · simp [hge] at h
  · have hlt : seen < 500 := Nat.lt_of_not_ge hge
    simp [hge] at h
    rw [← h]
    simp [hlt]

/-- Unpainted `#FFFFFF` (`seen = 877`) in Dark Mode always returns `none`. -/
theorem white_underpage_rejected_in_dark :
    computeTint .dark 877 = none := by
  decide

/-- Genuine dark tint (`seen = 120`) in Dark Mode is accepted with `dark = true`. -/
theorem dark_spa_tint_accepted :
    computeTint .dark 120 = some { seenPermille := 120, dark := true } := by
  decide

end Browse.PageTintDark
