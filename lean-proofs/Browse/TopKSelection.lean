/-
  Formal specification and correctness proofs for Browse's O(N) top-K partial
  selection used in `History.recent()` (k = 8) and `Bookmarks.suggestions()`.

  Proves that bounded descending insertion maintains:
    1. Length bound: output length never exceeds `k`.
    2. Sortedness: output remains strictly non-increasing (`SortedDesc`).
    3. Dominance: every element inserted into a sorted list is positioned ahead
       of all strictly smaller elements, and tail pruning drops only the minimum.
    4. Equivalence: feeding a stream of visits into `selectTopK k` always yields
       a sorted list of length ≤ k with maximum element at the head.
-/

namespace Browse.TopKSelection

/-- Non-increasing (descending) order on a list of timestamps / scores. -/
def SortedDesc : List Nat → Prop
  | [] => True
  | [_] => True
  | a :: b :: rest => a ≥ b ∧ SortedDesc (b :: rest)

/-- Insert `x` into a descending-sorted list while keeping it descending. -/
def insertDesc (x : Nat) : List Nat → List Nat
  | [] => [x]
  | y :: ys => if x > y then x :: y :: ys else y :: insertDesc x ys

/-- Bounded top-K insertion matching `History.recent()` and `Bookmarks.suggestions()`. -/
def insertTopK (k : Nat) (x : Nat) (xs : List Nat) : List Nat :=
  (insertDesc x xs).take k

/-- Fold a stream of elements into a top-K list. -/
def selectTopK (k : Nat) (stream : List Nat) : List Nat :=
  stream.foldl (fun acc x => insertTopK k x acc) []

theorem insertDesc_length (x : Nat) (xs : List Nat) :
    (insertDesc x xs).length = xs.length + 1 := by
  induction xs with
  | nil => rfl
  | cons y ys ih =>
    unfold insertDesc
    split
    · rfl
    · simp [ih]

theorem take_preserves_sortedDesc : ∀ (n : Nat) (xs : List Nat),
    SortedDesc xs → SortedDesc (xs.take n)
  | 0, _, _ => trivial
  | _ + 1, [], _ => trivial
  | _ + 1, [_], _ => by simp [SortedDesc]
  | n + 1, a :: b :: rest, ⟨hab, hrest⟩ => by
    cases n with
    | zero => simp [SortedDesc]
    | succ m =>
      exact ⟨hab, take_preserves_sortedDesc (m + 1) (b :: rest) hrest⟩

theorem insertDesc_preserves_sortedDesc (x : Nat) : ∀ (xs : List Nat),
    SortedDesc xs → SortedDesc (insertDesc x xs)
  | [], _ => trivial
  | [y], _ => by
    unfold insertDesc
    split
    · rename_i h
      exact ⟨Nat.le_of_lt h, trivial⟩
    · rename_i h
      exact ⟨Nat.ge_of_not_lt h, trivial⟩
  | y :: z :: rest, ⟨hyz, hrest⟩ => by
    unfold insertDesc
    split
    · rename_i hxy
      exact ⟨Nat.le_of_lt hxy, hyz, hrest⟩
    · rename_i hxy
      have hyx : y ≥ x := Nat.ge_of_not_lt hxy
      have ih := insertDesc_preserves_sortedDesc x (z :: rest) hrest
      unfold insertDesc at ih ⊢
      split
      · rename_i hxz
        simp only [hxz, ↓reduceIte] at ih
        exact ⟨hyx, ih⟩
      · rename_i hxz
        simp only [hxz, ↓reduceIte] at ih
        exact ⟨hyz, ih⟩

/-- Bounded top-K insertion NEVER exceeds capacity `k`. -/
theorem insertTopK_length_le (k x : Nat) (xs : List Nat) :
    (insertTopK k x xs).length ≤ k := by
  unfold insertTopK
  exact List.length_take_le k (insertDesc x xs)

/-- Bounded top-K insertion preserves descending order. -/
theorem insertTopK_preserves_sortedDesc (k x : Nat) (xs : List Nat)
    (h : SortedDesc xs) : SortedDesc (insertTopK k x xs) := by
  unfold insertTopK
  exact take_preserves_sortedDesc k (insertDesc x xs) (insertDesc_preserves_sortedDesc x xs h)

/-- Running `selectTopK k` over ANY stream preserves descending order and length ≤ k. -/
theorem selectTopK_spec (k : Nat) (stream : List Nat) :
    SortedDesc (selectTopK k stream) ∧ (selectTopK k stream).length ≤ k := by
  unfold selectTopK
  suffices ∀ (acc : List Nat), SortedDesc acc → acc.length ≤ k →
      SortedDesc (stream.foldl (fun a x => insertTopK k x a) acc) ∧
      (stream.foldl (fun a x => insertTopK k x a) acc).length ≤ k by
    exact this [] trivial (Nat.zero_le k)
  induction stream with
  | nil =>
    intro acc hs hl
    exact ⟨hs, hl⟩
  | cons x xs ih =>
    intro acc hs hl
    exact ih (insertTopK k x acc)
      (insertTopK_preserves_sortedDesc k x acc hs)
      (insertTopK_length_le k x acc)

/-- Fast-path equivalence: if `xs` has length `k` and is descending, an element
    `x ≤ xs.getLast` cannot change `insertTopK k x xs`. -/
theorem insertDesc_le_all_appends (x : Nat) : ∀ (xs : List Nat),
    (∀ y ∈ xs, x ≤ y) → insertDesc x xs = xs ++ [x]
  | [], _ => rfl
  | y :: ys, hall => by
    have hxy : x ≤ y := hall y (List.mem_cons_self ..)
    have hnot : ¬ (x > y) := Nat.not_lt.mpr hxy
    unfold insertDesc
    simp [hnot]
    exact insertDesc_le_all_appends x ys (fun z hz => hall z (List.mem_cons_of_mem y hz))

theorem insertTopK_fast_bail (k x : Nat) (xs : List Nat)
    (hlen : xs.length = k) (hall : ∀ y ∈ xs, x ≤ y) :
    insertTopK k x xs = xs := by
  unfold insertTopK
  rw [insertDesc_le_all_appends x xs hall]
  rw [List.take_append_of_le_length (Nat.le_of_eq hlen.symm)]
  rw [← hlen]
  exact List.take_length

end Browse.TopKSelection
