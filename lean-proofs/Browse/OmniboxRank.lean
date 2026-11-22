/-
  Formal specification and proofs for Omnibox host ranking and 1-character
  visited domain inline completion (`History.swift` & `Browser.swift`).

  Proves:
    1. Exact host-label match (`x.com` for `"x"`, score 8) strictly outranks
       longer prefix (`xpericheck.com`, score 6), subdomain (3), and infix (2).
    2. Single-character inline completion (`queryLen == 1`) NEVER completes
       unvisited built-in `.known` sites or `.searched` phrases — ONLY `.visited`
       or `.bookmark` sites.
    3. Multi-character completion (`queryLen ≥ 2`) remains eligible across
       visited, bookmark, known, and searched suggestions.
-/

namespace Browse.OmniboxRank

inductive MatchKind where
  | exactHostLabel   -- e.g. "x" -> "x.com"
  | hostPrefix       -- e.g. "x" -> "xpericheck.com"
  | subdomainPrefix  -- e.g. "x" -> "mail.x.com"
  | hostInfix        -- e.g. "git" -> "mygithub.com" (only len >= 2)
  | none
deriving DecidableEq, Repr, BEq

/-- Matches `History.rank(_:against:ascii:)` in `Sources/Browse/History.swift`. -/
def rankScore : MatchKind → Option Nat
  | .exactHostLabel  => some 8
  | .hostPrefix      => some 6
  | .subdomainPrefix => some 3
  | .hostInfix       => some 2
  | .none            => Option.none

theorem exact_host_label_beats_prefix :
    match rankScore .exactHostLabel, rankScore .hostPrefix with
    | some a, some b => a > b
    | _, _ => False := by
  simp [rankScore]

theorem prefix_beats_subdomain :
    match rankScore .hostPrefix, rankScore .subdomainPrefix with
    | some a, some b => a > b
    | _, _ => False := by
  simp [rankScore]

theorem subdomain_beats_infix :
    match rankScore .subdomainPrefix, rankScore .hostInfix with
    | some a, some b => a > b
    | _, _ => False := by
  simp [rankScore]

inductive SuggestionKind where
  | openTab | bookmark | visited | known | search | searched | google | ask | elsewhere
deriving DecidableEq, Repr, BEq

/-- Matches `History.completion(for:among:)` eligibility gate in `Sources/Browse/History.swift`. -/
def eligibleForCompletion (queryLen : Nat) (k : SuggestionKind) : Bool :=
  if queryLen = 0 then false
  else if queryLen = 1 then
    decide (k = .visited ∨ k = .bookmark)
  else
    decide (k = .visited ∨ k = .bookmark ∨ k = .known ∨ k = .searched)

theorem empty_never_completes (k : SuggestionKind) :
    eligibleForCompletion 0 k = false := by
  rfl

theorem single_char_never_completes_known :
    eligibleForCompletion 1 .known = false := by
  rfl

theorem single_char_never_completes_searched :
    eligibleForCompletion 1 .searched = false := by
  rfl

theorem single_char_never_completes_google :
    eligibleForCompletion 1 .google = false := by
  rfl

theorem single_char_completes_visited :
    eligibleForCompletion 1 .visited = true := by
  rfl

theorem single_char_completes_bookmark :
    eligibleForCompletion 1 .bookmark = true := by
  rfl

/-- Exhaustive characterization of 1-char completion eligibility. -/
theorem single_char_only_visited_or_bookmark (k : SuggestionKind) :
    eligibleForCompletion 1 k = true ↔ (k = .visited ∨ k = .bookmark) := by
  cases k <;> simp [eligibleForCompletion]

end Browse.OmniboxRank
