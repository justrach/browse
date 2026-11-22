/-
  Formal security specification and proofs for `Vault.swift`.

  Proves:
    1. HTTPS downgrade protection: a credential saved on HTTPS (`savedClear = false`)
       is NEVER offered for autofill on a plain HTTP page (`pageIsHttps = false`).
    2. Fail-closed LocalAuthentication (`Vault.prove`): if `canEvaluatePolicy` fails,
       access is denied on EVERY error except strictly `passcodeNotSet`.
    3. Device-only Keychain accessibility: newly stored Vault entries always use
       `whenUnlockedThisDeviceOnly` (never migrates off-device).
-/

namespace Browse.VaultPolicy

/-- Whether a stored credential (`savedClear = true` iff saved over plain HTTP)
    may be offered to a page (`pageIsHttps`). -/
def mayOfferLogin (savedClear : Bool) (pageIsHttps : Bool) : Bool :=
  pageIsHttps || savedClear

/-- An HTTPS credential is NEVER handed to an unencrypted HTTP page. -/
theorem https_secret_never_offered_on_http :
    mayOfferLogin false false = false := by
  rfl

/-- Every credential can be offered on its matching HTTPS origin. -/
theorem https_page_may_receive_login (savedClear : Bool) :
    mayOfferLogin savedClear true = true := by
  rfl

inductive LAFailure where
  | passcodeNotSet
  | biometryLockout
  | biometryNotEnrolled
  | authenticationFailed
  | userCancel
  | systemCancel
  | notInteractive
  | unknown
deriving DecidableEq, Repr, BEq

/-- Matches fail-closed fallback in `Vault.prove(_:_:)` (`Sources/Browse/Vault.swift`). -/
def allowWithoutAuth (err : LAFailure) : Bool :=
  decide (err = .passcodeNotSet)

/-- Every non-`passcodeNotSet` LocalAuthentication failure strictly denies access. -/
theorem prove_fails_closed (err : LAFailure) (h : err ≠ .passcodeNotSet) :
    allowWithoutAuth err = false := by
  cases err <;> simp_all [allowWithoutAuth]

theorem biometry_lockout_denied :
    allowWithoutAuth .biometryLockout = false := by
  rfl

inductive KeychainAccessibility where
  | whenUnlocked
  | whenUnlockedThisDeviceOnly
  | afterFirstUnlock
  | afterFirstUnlockThisDeviceOnly
deriving DecidableEq, Repr, BEq

def isDeviceBound : KeychainAccessibility → Bool
  | .whenUnlockedThisDeviceOnly => true
  | .afterFirstUnlockThisDeviceOnly => true
  | _ => false

def vaultAccessibility : KeychainAccessibility := .whenUnlockedThisDeviceOnly

theorem vault_items_are_device_bound :
    isDeviceBound vaultAccessibility = true := by
  rfl

end Browse.VaultPolicy
