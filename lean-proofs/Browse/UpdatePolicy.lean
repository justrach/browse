/-
  Formal specification and proof for Browse's Auto-Updater Cadence & Safety
  Policy (`Updater.swift`, `Settings.swift`).

  Models `Updater`'s 2-hour check interval, monotonic build comparison,
  Developer ID Team signing gate, and per-build banner snooze semantics, and
  proves:
  1. `cadence_due_iff_two_hours`:
     A non-overridden automatic check triggers iff `now - lastChecked ≥ 7200` (2h).
  2. `never_downgrades_or_reinstalls_same_build`:
     Any feed entry with `foundBuild ≤ currentBuild` is strictly rejected (never
     transitions to `.fetching`, `.waiting`, or `.ready`).
  3. `mismatched_team_never_swapped`:
     A downloaded bundle whose Developer ID Team ID does not match the running
     app can NEVER transition to `.ready` (swapped in).
  4. `snooze_never_hides_newer_build`:
     Snoozing the update banner for build `b1` hides it ONLY for `b1`; any
     subsequent build `b2 > b1` strictly re-displays the update banner.
-/

namespace Browse.UpdatePolicy

/-- 2 hours in seconds (`Updater.checkInterval = 60 * 60 * 2`). -/
def checkIntervalSec : Nat := 7200

/-- Whether `checkIfDue` initiates a network appcast fetch. -/
def isCheckDue (overridden : Bool) (lastChecked now : Nat) : Bool :=
  overridden || decide (now - lastChecked ≥ checkIntervalSec)

/-- Theorem: in production (`overridden = false`), checks run iff ≥ 2 hours elapsed. -/
theorem cadence_due_iff_two_hours (lastChecked now : Nat) :
    isCheckDue false lastChecked now = true ↔ now - lastChecked ≥ 7200 := by
  simp [isCheckDue, checkIntervalSec]

/-- Theorem: checking 1 hour 59 minutes after the last check is skipped. -/
theorem skips_before_two_hours (lastChecked : Nat) :
    isCheckDue false lastChecked (lastChecked + 7199) = false := by
  unfold isCheckDue checkIntervalSec
  have h : lastChecked + 7199 - lastChecked = 7199 := by omega
  simp [h]

/-- Theorem: checking at exactly 2 hours triggers a fetch. -/
theorem fires_at_two_hours (lastChecked : Nat) :
    isCheckDue false lastChecked (lastChecked + 7200) = true := by
  unfold isCheckDue checkIntervalSec
  have h : lastChecked + 7200 - lastChecked = 7200 := by omega
  simp [h]

/-! ### Monotonic Upgrade & Code-Signing Safety -/

inductive Stage where
  | none
  | waiting  (build : Nat)
  | fetching (build : Nat)
  | ready    (build : Nat)
  | offered  (build : Nat)
deriving DecidableEq, Repr, BEq

def isActionable : Stage → Bool
  | .none => false
  | _     => true

/-- Models `Updater.check` stage selection (`found.build > Updater.build && found.runsHere`). -/
def evaluateFeed (currentBuild : Nat) (foundBuild : Nat) (runsHere autoInstall : Bool) : Stage :=
  if foundBuild > currentBuild && runsHere then
    if autoInstall then .fetching foundBuild else .waiting foundBuild
  else
    .none

/-- Models `Swap.install` + `Updater.landed`: a bundle is swapped into `.ready`
    ONLY when SHA-256 matches AND Developer ID Team ID matches the running app. -/
def finalizeSwap (build : Nat) (shaMatches teamMatches : Bool) : Stage :=
  if shaMatches && teamMatches then .ready build else .offered build

/-- Theorem: feed entries with `foundBuild ≤ currentBuild` NEVER trigger an upgrade. -/
theorem never_downgrades_or_reinstalls_same_build
    (currentBuild foundBuild : Nat) (runsHere autoInstall : Bool)
    (hle : foundBuild ≤ currentBuild) :
    evaluateFeed currentBuild foundBuild runsHere autoInstall = .none := by
  unfold evaluateFeed
  have hnot : ¬ (foundBuild > currentBuild) := by omega
  simp [hnot]

/-- Theorem: an incompatible OS build (`runsHere = false`) NEVER triggers an upgrade. -/
theorem incompatible_os_never_upgrades (currentBuild foundBuild : Nat) (autoInstall : Bool) :
    evaluateFeed currentBuild foundBuild false autoInstall = .none := by
  simp [evaluateFeed]

/-- Theorem: a bundle failing Developer ID Team verification can NEVER become `.ready`. -/
theorem mismatched_team_never_swapped (build : Nat) (shaMatches : Bool) :
    finalizeSwap build shaMatches false ≠ .ready build := by
  simp [finalizeSwap]

/-- Theorem: a bundle failing SHA-256 verification can NEVER become `.ready`. -/
theorem bad_sha_never_swapped (build : Nat) (teamMatches : Bool) :
    finalizeSwap build false teamMatches ≠ .ready build := by
  simp [finalizeSwap]

/-- Theorem: only a build passing BOTH SHA-256 AND Team ID checks enters `.ready`. -/
theorem ready_implies_sha_and_team_verified (build : Nat) (sha team : Bool)
    (h : finalizeSwap build sha team = .ready build) :
    sha = true ∧ team = true := by
  cases sha <;> cases team <;> simp [finalizeSwap] at h ⊢

/-! ### Banner Snooze Invalidation Semantics -/

def bannerVisible (stage : Stage) (snoozedBuild : Option Nat) : Bool :=
  match stage with
  | .none => false
  | .waiting b | .fetching b | .ready b | .offered b =>
      snoozedBuild != some b

/-- Theorem: snoozing build `b1` hides the banner for `b1`. -/
theorem snooze_hides_same_build (b1 : Nat) :
    bannerVisible (.ready b1) (some b1) = false := by
  simp [bannerVisible]

/-- Theorem: snoozing build `b1` NEVER hides a strictly newer build `b2 > b1`. -/
theorem snooze_never_hides_newer_build (b1 b2 : Nat) (hlt : b1 < b2) :
    bannerVisible (.ready b2) (some b1) = true ∧
    bannerVisible (.waiting b2) (some b1) = true := by
  have hne : b1 ≠ b2 := by omega
  have hne' : (some b1 : Option Nat) ≠ some b2 := by
    intro h; injection h with heq; exact hne heq
  simp [bannerVisible, bne_iff_ne, hne']

end Browse.UpdatePolicy
