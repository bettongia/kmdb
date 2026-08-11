# Unlock policy — close SC-1 with a wrapped-copy DEK model and re-auth

> The CLI session agent originally in this plan is split into
> `plan_0_10_01_cli_session_agent.md` (reviewer round 2). This plan is the
> SC-1-closing unit: wrapped-copy DEK + native biometric + headless opt-out.

**Status**: **Implementing** (2026-08-11) — Q1–Q7 resolved and verified against the code; no open design decisions remain. See "Reviewer re-check (round 3)" for the sign-off and two non-blocking test-coverage directives the implementer must honour.

**PR link**: _(none yet)_

> **Provenance.** Implements finding **SC-1** from the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md),
> under the [0.10.01 hardening track](../roadmap/0_10_01.md) as **WI-5**. Derived
> from [docs/proposals/unlock_policy.md](../proposals/unlock_policy.md), whose §9
> open questions were all resolved in a maintainer design session (2026-08-10 —
> recorded in that proposal). Read the proposal first: this plan executes its
> design, it does not re-argue it.

## Resumability — commit per stage (read first)

This is a large, multi-package plan and implementation sessions on this account
are being interrupted by token-quota limits. The implementer **must** treat each
phase below as an independently green, independently committable checkpoint, so
an interruption always resumes from the last commit rather than a pile of
uncommitted work:

- **One green commit per phase.** Finish a phase, get its tests + `make
  pre_commit` green, commit it (`WI-5 Phase N: …`), *then* start the next phase.
  Do not batch multiple phases into one commit.
- **Update this plan's checkboxes as you go** — the checklist is the source of
  truth for "what is done" on resume. Never leave a box checked whose tests are
  not actually green.
- **If interrupted mid-phase**, leave a one-line `RESUME HERE:` note in that
  phase naming the exact next step and any half-written files.
- Phases are ordered so each compiles and tests green on its own; later phases
  build on earlier ones but no phase depends on a *later* one.

This is the same discipline that carried WI-4 (PR #74) through two quota deaths
with zero lost work.

## Problem statement

`kmdb_database.dart` (the cache-hit path at ~`:751`) reads a raw DEK from the
`DekCache` and returns a provider **without checking the passphrase**:

```dart
final cachedDek = await encryptionConfig!.dekCache.read(dbId);
if (cachedDek != null) {
  return encryptionConfig.buildProvider(cachedDek);   // passphrase never checked
}
```

So **a deliberately wrong passphrase opens an encrypted database whenever the
cache is warm** — which is the *recommended* mobile configuration (§31 tells
Flutter hosts to inject `FlutterSecureDekCache` precisely so the prompt happens
once). This silently defeats the coerced-unlock posture the passphrase exists
for (*"I'll unlock my phone, but not give you the app passphrase"*).

The root constraint is structural, not a coding slip: **you cannot both skip
Argon2id and verify a passphrase** — the cache exists to skip the KDF, and a
warm cache therefore bypasses the passphrase by construction. §31's stated
remedy (confirm the cached DEK by decrypting `enc:blob`) only proves the *DEK*
is valid; the passphrase still never enters the cache-hit path. **This must not
be resolved by editing §31 to describe the current code.**

## Goals

Make it structurally impossible to obtain a DEK without authenticating
something, on every platform KMDB targets for 0.1.0, while keeping routine use
frictionless and not regressing the CLI/scripting ergonomics.

## Non-goals (explicit follow-ups, per the proposal's resolved §9)

- **Web WebAuthn-PRF.** Deferred to a follow-up plan — needs browser-support
  verification and web is already a reduced platform. WI-5 ships native + CLI +
  server only. (The wrapped-DEK model is designed so the web PRF path slots in
  later as just another KEK source.)
- **Per-operation escalation (proposal §7).** A later refinement; the
  "always require passphrase" policy toggle covers the coercion case bluntly
  for now.
- **MDM / enterprise policy override.** Out of scope for a library.
- **The CLI session agent.** Split into its own plan
  `plan_0_10_01_cli_session_agent.md` (reviewer round 2) — it addresses the
  separate CLI-Argon2id ergonomics finding, not SC-1, and is a substantial
  subsystem (IPC, Windows named-pipe/ACL, lifecycle). Sequenced after WI-5.

## Settled design decisions

From the proposal (§4) and its resolved §9. Recorded so the reviewer audits
rather than re-derives:

- **A third *wrapped* DEK, not a cache.** `DekCache` (raw-DEK store) is
  **removed**, not patched. A KEK held non-extractably by a platform
  authenticator wraps a third copy of the DEK; unwrapping requires
  authenticating. This makes SC-1 structurally impossible — no path returns a
  DEK unauthenticated.
- **Periodic passphrase re-authentication is on by default (14-day interval),
  enforced in the library.** `KmdbDatabase.open()` refuses the biometric path
  once the interval lapses. Host-overridable (lengthen, shorten, "always require
  passphrase"). Framed as a *data-loss control* (a user who never re-types their
  passphrase and then hits a biometric invalidation has lost the database).
- **CLI session agent** (ssh-agent / `op signin` shape): DEK in **agent process
  memory** (never on disk), bounded by an **idle timeout *and* an absolute cap**,
  `kmdb … lock` ends it immediately, never outlives the login session.
  Single-database first.
- **Server = headless session = process lifetime.** Unlock once at worker start,
  re-authenticate on restart; no timer, no periodic prompt. Same mechanism as
  the CLI agent. The re-auth policy must therefore be **suppressible**, via an
  explicit, documented opt-out that names the deployment shape (not a silent
  flag) — this is the honest weakening of "enforcement lives in the library".
- **Auto-lock is the host's job.** KMDB provides `KmdbDatabase.lock()`; the host
  decides when to call it. The library must not observe OS lifecycle events.
- **No migration.** KMDB is unreleased; `DekCache` is simply removed.

### New design decision this plan adds (surface for reviewer/architect confirmation)

**The biometric-wrapped DEK is per-device *local* state, NOT a new field in the
synced `enc:blob`.** `EncryptionBlob` (`lib/src/encryption/encryption_blob.dart`)
is persisted in `$meta` under `enc:blob`, and **`$meta` syncs**
(`isLocalOnly(r'$meta')` is `false`). `wrappedDekPassphrase` (`wdekP`) and
`wrappedDekRecovery` (`wdekR`) belong there because their KEKs derive from
user-held secrets that are identical on every device. The **biometric KEK is
device-bound** (a non-extractable Secure Enclave / Keystore / Credential Manager
key), so `wrappedDekBiometric` is meaningful only on the device that created it.
Putting it in the synced blob would (a) be useless on every other device, (b)
leak per-device enrolment state across the sync set, and (c) reopen the exact
`$meta`-LWW hazard that sank the sync-auth device-identity design and that §4.3
of the proposal flags for the re-auth timestamp. **Resolution:** store the
per-device biometric-wrapped DEK (and the "passphrase last used" timestamp) in
per-device local state — reuse the `SecretStore` seam landed in PR #73 on
native, keyed per database — never in `enc:blob`. This refines the proposal's
"third entry in `enc:blob`" framing; confirm with the reviewer.

## Investigation — seams to reuse

- **`DekCache`** (`lib/src/encryption/dek_cache.dart`) — `abstract interface`
  with `store(dbId, dek)` / `read(dbId)` / `clear`, `InMemoryDekCache` default.
  This is what gets removed; every reference (incl. `FlutterSecureDekCache` in
  `kmdb_flutter`, and the §31 DEK-cache docs) must go with it.
- **`EncryptionBlob`** (`lib/src/encryption/encryption_blob.dart`) — CBOR blob
  in `$meta` under `enc:blob`, fields `wdekP` / `wdekR` (+ salt/int params),
  with `toBytes` / `fromCbor` and field validation. Format touch point — but see
  the per-device decision above (the biometric wrap does **not** go here).
- **`EncryptionConfig`** (`lib/src/encryption/encryption_config.dart`) —
  `tryUnwrapWithPassphrase`, `tryUnwrapWithRecovery`, `buildProvider`. Add
  `tryUnwrapWithBiometric(wrappedDek, kek)` alongside; it is a thin wrapper over
  `KeyDerivation.unwrapDek`.
- **`KeyDerivation`** (`lib/src/encryption/key_derivation.dart`) — `wrapDek` /
  `unwrapDek(wrappedDek, kek)`. The biometric path reuses `unwrapDek` with a KEK
  released by the platform authenticator; no new crypto primitive.
- **The SC-1 site** — `kmdb_database.dart:751-753` (cache-hit) and the
  passphrase path at `:759`/`:775`, plus the second unwrap site at `:1306`
  (change-passphrase). All raw-DEK-cache reads are replaced by an authenticated
  unwrap.
- **`SecretStore`** (`packages/kmdb`, PR #73) — the per-device local store for
  the biometric-wrapped DEK and the re-auth timestamp on native hosts.
- **Platform KEK** — `flutter_secure_storage` ≥10.3 already exposes
  `accessControlFlags` (`biometryCurrentSet`); **no new dependency** in
  `kmdb_flutter`. Enrolment invalidation (`biometryCurrentSet`) defeats the
  "attacker enrols their own finger" case.

## Design resolutions (round 2 — 2026-08-11, reviewer Q1–Q6)

The reviewer's six questions are resolved here; the phases below are updated to
match. Grounded against the code (`open()` at `kmdb_database.dart:298`,
`EncryptionConfig`, `KeyDerivation.unwrapDek`).

**Q1 — Core `SecretStore` seam (the central integration point).**

- `KmdbDatabase.open()` gains `SecretStore? secretStore` (default
  `InMemorySecretStore()`) — mirroring how encryption defaulted to an in-memory
  cache, so existing callers/tests are unaffected and a host wanting persistent
  biometric unlock passes a real store.
- **Promote `dbScopedSecretKey`/`isSecretKeyForDb` from `kmdb_cli` to core**
  (`packages/kmdb/lib/src/secret/secret_key.dart`), re-exported from `kmdb.dart`;
  `kmdb_cli` deletes its local copy and consumes the core export. This adds
  `crypto: ^3.0.0` as a **genuine new direct dependency** of `kmdb` (only
  `cryptography` is present today; `crypto` is currently CLI-only), and the
  function's doc comment must be rewritten **CLI-agnostic** (drop its
  `credentials prune` / Google Drive / `RemoteConfig` references).
- Per-device, per-db storage-key literals (bytes in the `SecretStore`, never in
  `enc:blob`/`$meta`): biometric wrap → `dbScopedSecretKey(dbDir,
  'dek.wrap.biometric')`; last-used timestamp → `dbScopedSecretKey(dbDir,
  'passphrase.lastused')`. The wrap **must** live outside the encrypted DB
  (chicken-and-egg: it is needed to derive the DEK that opens the DB) — which is
  exactly why the per-device local `SecretStore` is its home.

**Q2 — Biometric path selection + the `KEKSource` contract.** A sealed
`KEKSource` on `EncryptionConfig` selects the unwrap path:
`KEKSource.passphrase(String)` / `KEKSource.recoveryCode(String)` /
`KEKSource.biometric(BiometricKekProvider)`. **`biometric` returns a KEK, not
the DEK** — core then calls the existing
`KeyDerivation.unwrapDek(wrappedDekBiometric, kek)`, preserving the single
authenticated-unwrap chokepoint (platform code never sees the DEK).
`BiometricKekProvider` is a core-defined interface
(`Future<Uint8List> obtainKek()`) implemented in `kmdb_flutter`, with an
**idempotent get-or-create contract** and a paired enrolment path — see Q7.

**Q3 — `ReauthPolicy` (named deployment-shape API, not a boolean).** A
`ReauthPolicy` on `EncryptionConfig`, default
`ReauthPolicy.interval(Duration(days: 14))`: `.interval(Duration)` (biometric
refused once the interval since last passphrase use lapses),
`.alwaysRequirePassphrase()`, and `.headlessSession()` (the explicit
server opt-out — no periodic re-auth; session = process lifetime). Enforced in
`open()`; `headlessSession()` suppresses the check.

**Q4 — Clock injection.** `open()` gains `DateTime Function()? now` (default
`DateTime.now`), threaded into the re-auth comparison so the interval-lapse test
sets a fake clock instead of sleeping 14 days.

**Q5 — CLI session agent split: CONFIRMED.** Phase 4 (CLI session agent) is
removed and becomes `plan_0_10_01_cli_session_agent.md`, sequenced after WI-5.

**Q6 — Phase 3 KEK mechanics (achievable shape).** Not a use-but-cannot-extract
handle: generate a random 32-byte KEK, store it in `flutter_secure_storage`
under `accessControlFlags: biometryCurrentSet` (reading requires a fresh
biometric auth), return it from `obtainKek()`, and `unwrapDek` the DEK in core.
**KEK in platform secure storage (biometric-gated); wrap in the per-device
`SecretStore`.**

**Non-blocking observations folded in:** the Phase 1→3 intermediate state is a
valid green checkpoint (native/CLI run full Argon2id per open until Phase 3) —
Phase 1 must also drop `kmdb_flutter`'s `export
'src/flutter_secure_dek_cache.dart'`, the library-doc example, and
`flutter_secure_dek_cache_test.dart`; release-checklist entries use **RC-28+**;
§34 (`sync_authentication`) already exists, so Phase 6 takes the next free
section number.

**Q7 — Biometric enrolment + idempotent `obtainKek()` (round 3, 2026-08-11).**

- **Enrolment is a new core API.** `Future<void>
  KmdbDatabase.enableBiometricUnlock(BiometricKekProvider provider)`, callable
  only on an **already-unlocked** database (DEK in memory): obtain the KEK via
  the provider, `KeyDerivation.wrapDek(dek, kek)`, and persist the wrap to
  `SecretStore` under `dbScopedSecretKey(dbDir, 'dek.wrap.biometric')`. A paired
  `disableBiometricUnlock()` deletes the wrap. "Reconfigure after invalidation"
  = the KEK item is gone → biometric fails → passphrase required → a fresh
  `enableBiometricUnlock` re-enrols.
- **`obtainKek()` is idempotent per db-scoped key.** It creates the
  `flutter_secure_storage` item (under `biometryCurrentSet`) on first use
  (enrol) and **returns the existing one** thereafter (unlock), so enrol and
  unlock derive the *same* KEK and `unwrapDek` succeeds. Enrolment-invalidation
  destroys the item — the auto-disable semantics fall out for free. The provider
  is bound to the db-scoped key identity.
- **Unlock gates on wrap presence, fail-closed.** The biometric branch runs only
  if a wrap exists in `SecretStore`; absent wrap — or an absent/missing last-used
  timestamp — → **require the passphrase**. The timestamp is written on every
  successful *passphrase* unlock (and at provision), never by a biometric unlock,
  so it genuinely tracks passphrase recency.
- **`EncryptionConfig` refactor is additive.** Keep `EncryptionConfig(passphrase:)`
  / `(recoveryCode:)` as convenience constructors that build the corresponding
  `KEKSource` internally; add `EncryptionConfig.biometric(...)`. This drops the
  breaking fallout from ~30 `EncryptionConfig(` call sites to just the 5 `dekCache:`
  sites + the `kmdb.dart` export — **all absorbed in Phase 1's one green commit**.

## Implementation plan

> Each phase is a green checkpoint — see **Resumability** above.

### Phase 1 — Core: remove `DekCache`, add the authenticated wrapped-DEK unwrap

- [x] Remove `DekCache` / `InMemoryDekCache` and every reference (core + the
      `FlutterSecureDekCache` in `kmdb_flutter`, deferring the *replacement*
      platform impl to Phase 3 — Phase 1 leaves native hosts on the passphrase
      path, which is correct and green). Also removed `dek_cache_test.dart`
      and `flutter_secure_dek_cache_test.dart`.
- [x] Refactor the `kmdb_database.dart` open path so **every** branch obtains the
      DEK by an authenticated unwrap (passphrase, recovery, or — once Phase 3
      lands — biometric); delete the raw-DEK cache-hit return at `:751-753`.
- [x] Add `EncryptionConfig.tryUnwrapWithBiometric` (thin `unwrapDek` wrapper)
      and a `KEKSource` abstraction the open path consults, so a wrong passphrase
      is **always** rejected regardless of prior unlock state.
- [x] Define the **per-device local** store for the biometric-wrapped DEK (see
      the design decision above) — `SecretStore`-backed on native, keyed per db.
      Nothing biometric is written to `enc:blob`. `dbScopedSecretKey`/
      `isSecretKeyForDb` promoted from `kmdb_cli` to
      `packages/kmdb/lib/src/secret/secret_key.dart` (CLI-agnostic doc
      comment), re-exported from `kmdb.dart`; `crypto: ^3.0.0` and
      `path: ^1.9.0` added as genuine new direct deps of `kmdb`.
- [x] `KmdbDatabase.lock()` — discard the in-memory DEK, force a fresh unwrap.
      Implemented via a new `EncryptionProvider.lock()` on the interface;
      `AesGcmEncryptionProvider.lock()` zeroes the DEK bytes in place and
      gates `encrypt`/`decrypt`/`indexToken`/`dek` behind a `_locked` flag
      that throws the new `EncryptionErrorCode.databaseLocked`.
- [x] Core enrolment API `enableBiometricUnlock(BiometricKekProvider)` /
      `disableBiometricUnlock()` (Q7) — write/delete the biometric wrap in
      `SecretStore` from an unlocked session. (The real provider lands in Phase 3;
      Phase 1 exercises it with a fake `BiometricKekProvider` in
      `kmdb_database_encryption_test.dart`.)
- [x] **Additive `EncryptionConfig` refactor** (Q7): retain `passphrase:` /
      `recoveryCode:` constructors, add `KEKSource` + `.biometric(...)` +
      `ReauthPolicy`; **absorb all fallout in this one commit** — the 5 `dekCache:`
      sites and the `kmdb.dart` `DekCache` export removed here, ~30 other
      `EncryptionConfig(` sites unaffected by staying additive. Also added
      `EncryptionErrorCode.biometricUnavailable` (fail-closed: no enrolled
      wrap, or the re-auth interval has lapsed) alongside `databaseLocked`.
- [x] **Checkpoint:** commit `WI-5 Phase 1: remove DekCache, authenticated
      wrapped-DEK unwrap, lock()` (green). `dart analyze` clean across all 7
      workspace packages; `kmdb` (2620 tests), `kmdb_cli` (1228 tests), and
      `kmdb_flutter` (4 tests, via `flutter test`) all green.

### Phase 2 — Re-authentication policy (default-on, 14-day, enforced)

> **Note:** the mechanism (timestamp storage, `open()` enforcement,
> `ReauthPolicy` variants) was necessarily built together with Phase 1's
> `KEKSource`/fail-closed biometric branch — the branch cannot exist without
> something to enforce. Phase 2's own work is verifying the *policy
> semantics* with dedicated tests (below), confirming per-checklist-item that
> each behaviour Phase 1 implemented is actually correct.

- [x] Store a **per-device, local-only** "passphrase last used" timestamp (NOT
      `$meta` — see the design decision; same store as Phase 1's biometric wrap).
      (Landed in Phase 1: `_kPassphraseLastUsedSecretName`.)
- [x] Enforce in `KmdbDatabase.open()`: once the interval lapses, refuse the
      biometric path and require the passphrase. Host-configurable interval +
      "always require passphrase". (Landed in Phase 1: `ReauthPolicy.interval`/
      `.alwaysRequirePassphrase`, enforced in `_unwrapBiometric`.) Verified in
      Phase 2 by `reauth_policy_test.dart`'s injected-clock integration tests:
      within-interval succeeds, 15-day-lapsed interval throws
      `EncryptionErrorCode.biometricUnavailable` (and the passphrase path still
      works afterward — not bricked), `alwaysRequirePassphrase` refuses even
      immediately post-enrolment.
- [x] **Suppressible** opt-out for headless deployments — an explicit, documented
      API naming the deployment shape (not a bare boolean), per proposal §4.6.
      (Landed in Phase 1: `ReauthPolicy.headlessSession()`.) Verified in Phase 2:
      biometric unlock succeeds even ~10 years after the recorded passphrase use.
- [x] **Checkpoint:** commit `WI-5 Phase 2: default-on periodic re-auth policy`.
      New `test/encryption/reauth_policy_test.dart` (12 tests: 8 pure
      `ReauthPolicy.permitsBiometric` unit tests + 4 `KmdbDatabase.open`
      integration tests with an injected clock) — all green; `dart analyze`
      clean.

### Phase 3 — Platform KEK: native biometric (`kmdb_flutter`)

- [x] Implement `BiometricKekProvider` (the `kmdb_flutter` impl of the core
      interface) for iOS/Android/macOS/Windows with an **idempotent get-or-create**
      `obtainKek()` (Q7): create a random 32-byte KEK in `flutter_secure_storage`
      under `accessControlFlags: biometryCurrentSet` on first use, and return the
      **same** KEK (fresh biometric auth) on every call thereafter, for core to
      `unwrapDek` — the achievable
      biometric-gated-KEK shape, not a use-but-cannot-extract handle (Q6). KEK in
      secure storage; wrap in the per-device `SecretStore`. Linux → passphrase
      path in practice. `FlutterBiometricKekProvider` in
      `lib/src/flutter_biometric_kek_provider.dart`: iOS/macOS use
      `accessControlFlags: [AccessControlFlag.biometryCurrentSet]`; Android uses
      `AndroidOptions.biometric(enforceBiometrics: true, biometricType:
      strongBiometricOnly)`; Windows/Linux have no biometric-gating option in
      `flutter_secure_storage` at all (not just Linux) — documented as an
      explicit limitation in the class doc comment (both fall back to
      OS-login-gated-only storage, no real biometric prompt). Storage key
      derived via the promoted `dbScopedSecretKey(dbDir, 'kek.biometric')`.
- [x] Enrolment-invalidation semantics: adding a finger/face invalidates the KEK;
      biometric auto-disables and the passphrase is required to reconfigure.
      (Falls out automatically from the OS access-control policy — no explicit
      handling needed in `FlutterBiometricKekProvider`; see its doc comment.
      Not independently testable without real hardware — flagged for §28
      RC-28+ in Phase 6.)
- [x] **Checkpoint:** commit `WI-5 Phase 3: kmdb_flutter biometric KEK`. *(Run
      `kmdb_flutter`'s own tests — `make pre_commit` is `kmdb`-scoped only.)*
      New `test/flutter_biometric_kek_provider_test.dart` (5 tests, via
      `FlutterSecureStorage.setMockInitialValues`): idempotent get-or-create
      across repeated calls *and* across fresh provider instances (simulating
      a process restart), 32-byte KEK length, per-database key scoping,
      randomness smoke check. `flutter analyze` clean; all 9 `kmdb_flutter`
      tests green (4 pre-existing + 5 new).

### Phase 4 — Server / headless handling

- [x] Session = process lifetime; the Phase 2 policy is suppressed via the
      documented `ReauthPolicy.headlessSession()` opt-out; passphrase injected
      non-interactively through the `SecretStore` directory backend
      (`$CREDENTIALS_DIRECTORY`, `/run/secrets`, k8s mounts). Library-side hook
      only — `kmdb_server` is a separate proposal. Two patterns documented on
      `ReauthPolicy.headlessSession()`'s doc comment: (1) plain passphrase read
      non-interactively from a mounted secret (no `KEKSource.biometric`
      involved — `ReauthPolicy` is moot for that path, already covered by the
      State-5 unlock tests); (2) a machine-bound `BiometricKekProvider` (KMS/
      HSM/mounted-secret analogue of a real biometric prompt) paired with
      `headlessSession()`.
- [x] **Checkpoint:** commit `WI-5 Phase 4: headless/server unlock hook`. New
      `test/encryption/headless_server_unlock_test.dart` (2 tests): a single
      "worker start" unlock survives 5 simulated restarts spanning ~10 years of
      injected clock time with no passphrase re-entry; a control test proving
      `headlessSession()` is load-bearing (the same setup *without* it is
      refused once the default interval lapses). `dart analyze` clean.

### Phase 5 — Tests (edge/fault, not golden-path)

- [ ] **The SC-1 regression (headline):** a wrong passphrase is **rejected**
      even with a prior successful unlock / warm platform key. This test must
      fail on `main` today.
- [ ] Biometric enrolment-invalidation forces passphrase re-config.
- [ ] Re-auth interval lapse → biometric path refused, passphrase required
      (drives the injected `now` clock — Q4 — not a real 14-day wait).
- [ ] `lock()` discards the DEK; the next open re-authenticates.
- [ ] **The "last used" timestamp is local-only** — a device idle for a month is
      not fast-forwarded by a peer's recent timestamp (the `$meta`-LWW
      regression; assert it would fail if the field were synced).
- [ ] Headless opt-out (`ReauthPolicy.headlessSession()`) suppresses the policy;
      without it, the policy applies.
- [ ] **Checkpoint:** commit `WI-5 Phase 5: test matrix`.

### Phase 6 — Spec & docs

- [ ] **§31** — replace the DEK-cache section with the wrapped-copy model; add
      the policy, the platform matrix, and the honest §6 limitations (coercion,
      compromised host, root/jailbreak). **Must not be reconciled by describing
      the current code.**
- [ ] **§19** (platform) — the platform matrix.
- [ ] **§33** (CLI credential store) — note the session agent is specified in
      `plan_0_10_01_cli_session_agent.md` (split out).
- [ ] **§28** — release-checklist entries (**RC-28+**) for what CI cannot cover:
      biometric enrolment invalidation, coerced re-auth behaviour.
- [ ] New spec section (next free `NN` — §34 `sync_authentication` already
      exists) for the unlock/wrapped-copy model, or fold into §31.
- [ ] Roadmap WI-5 row updated in-branch (moves with the PR).
- [ ] **Checkpoint:** commit `WI-5 Phase 6: spec + docs`.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm ≥95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off. Do not open a PR until
      sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests green.
- [ ] Verify licence headers (2026) on all new files.

> This plan touches **`kmdb`, `kmdb_flutter`, and `kmdb_cli`**. `make pre_commit`
> is `packages/kmdb`-scoped only — run `kmdb_flutter` and `kmdb_cli` suites
> explicitly (`cd packages/<pkg> && dart test`).

## Reviewer feedback (2026-08-11)

### Verdict: strong design, not yet mechanically implementable — split the CLI agent out

The problem is real and correctly diagnosed, the wrapped-copy approach is the
right shape, and the one new design decision this plan adds is **correct and I
endorse it**. But there are several load-bearing API seams the plan asserts
"reuse X" without pinning the actual interface change, plus one phase (the CLI
session agent) that is a substantial new subsystem underspecified for mechanical
execution. Those must close before `Investigated`.

### What I verified in the code (all confirmed)

- **`$meta` syncs.** `isLocalOnly` (`lib/src/engine/util/namespace_codec.dart:148`)
  returns true **only** for the `$$` prefix; `$meta` is single-`$`, so it is *not*
  local-only. `enc:blob` therefore rides the sync channel. The core premise holds.
- **`enc:blob` fields.** `EncryptionBlob` (`encryption_blob.dart`) carries exactly
  `salt` / `wdekP` / `wdekR` (+ informational `m`/`t`/`p`). Passphrase and recovery
  wraps derive from user-held secrets (`KeyDerivation.deriveKekFromPassphrase` /
  `deriveKekFromRecoveryEntropy`) that are device-independent, so they *correctly
  stay* in the synced blob. Nothing device-bound is in there today.
- **The SC-1 site is exactly as described.** `kmdb_database.dart:751-753` returns
  `buildProvider(cachedDek)` on a warm-cache hit with no passphrase check. The
  passphrase/recovery unwrap only runs on the cache *miss* (`:759`/`:765`).
- **Every raw-DEK path routes through `dekCache`**: bootstrap `:735` (store after
  provision), `:751` (the bug), `:774` (store after unwrap); `changePassphrase`
  `:1358`/`:1360`. `KeyDerivation.unwrapDek` is the sole authenticated unwrap and
  is what `tryUnwrapWithBiometric` will wrap. So removing `DekCache` wholesale does
  close every unauthenticated path — **SC-1 removal completeness checks out**, and
  `changePassphrase` (`:1306`/`:1358`/`:1360`) is correctly in the investigation.

### Design decision #1 (biometric wrap = per-device local): CONFIRMED, endorsed

Storing `wrappedDekBiometric` and the "passphrase last used" timestamp in
per-device local state rather than `enc:blob` is correct and well-reasoned. A
device-bound KEK's wrap is useless on every other device, and putting *any*
device-specific field in `$meta` reopens exactly the LWW-collision class that WI-11
(SC-10) and WI-14 spent this whole track eliminating (both moved state out of
`$meta` into `$$`-local namespaces for this reason). This refinement of the
proposal's "third entry in `enc:blob`" framing is right. No change needed to the
decision itself — but it creates the API gap in Q1 below.

### Blocking gaps (why this is `Questions`, not `Investigated`)

1. **The core `open()` → `SecretStore` seam is asserted but never specified — this
   is the single biggest gap.** `KmdbDatabase.open()` (signature at `:298-351`)
   has **no** `secretStore` parameter today, and there is **no native
   keychain-backed `SecretStore` anywhere** — the only concrete impls are
   `InMemorySecretStore` (core) and `DirectorySecretStore` (`kmdb_cli`).
   `dbScopedSecretKey` also lives in `kmdb_cli`, not core. So "reuse the
   `SecretStore` seam from PR #73, keyed per db" is under-defined: the plan must
   state the *new* `open()` parameter (e.g. `SecretStore? secretStore` defaulting
   to `InMemorySecretStore`), where the per-db key scheme lives now that core needs
   it (promote `dbScopedSecretKey` to core, or restate it), and what the biometric
   wrap's key literal is. Without this an implementer is inventing the central
   integration point. (See Q1.)

2. **How a host *requests* the biometric path, and how the re-auth policy is
   configured, is unspecified.** `EncryptionConfig` today only carries
   `passphrase`/`recoveryCode`. Phase 1 adds "a `KEKSource` abstraction the open
   path consults," but nothing says how a caller selects biometric-vs-passphrase at
   `open()`, nor where the interval / "always require passphrase" / headless
   opt-out are passed. These are new public API surfaces (a `KEKSource` type, a
   re-auth-policy type). The plan must name them concretely — an implementer must
   not invent the public API of a security feature on the fly. (See Q2, Q3.)

3. **The re-auth interval test needs an injectable clock.** Phase 2 enforces a
   14-day lapse in `open()` and Phase 6 tests "interval lapse → biometric refused,"
   but there is no wall-clock seam in `open()` today and the plan adds none. Pin a
   `DateTime Function()? now` (or `Clock`) injection point, or the lapse test is
   unwritable without sleeping 14 days. (See Q4.)

4. **The CLI session agent (Phase 4) is a whole subsystem, underspecified, and
   should be its own plan.** The requirements list (memory-resident DEK, owner-only
   socket, idle+absolute cap, `lock` immediacy, no-outlive-login) restates the
   proposal's *goals* but leaves every mechanical decision open: IPC transport and
   **Windows** story (the "credential-store permission model" is POSIX
   `chmod`/`SecretPermissionException` — there is no Windows named-pipe ACL design
   here, and Windows is a supported CLI/CI target), the wire protocol, how a
   command discovers/spawns the agent, and how "never outlives the login session"
   is actually enforced per-OS (`$XDG_RUNTIME_DIR` on Linux; macOS/Windows have no
   equivalent stated). This is the highest-risk component (a new place a DEK lives)
   and it does **not** close SC-1 — it solves the *separate* CLI-Argon2id-ergonomics
   finding. **Recommendation: cut Phase 4 into its own `Investigated`-gated plan**
   (`plan_0_10_01_cli_session_agent.md`). Doing so shrinks this plan to the SC-1
   fix + biometric + headless opt-out + tests + docs, which holds together cleanly,
   and de-risks the quota-death resumability concern that motivated the
   commit-per-phase discipline. (See Q5.)

5. **The headless opt-out API is intent-only.** Phase 2/5 correctly say "explicit,
   documented API naming the deployment shape, not a bare boolean" — but do not name
   the type. Pin it (e.g. `ReauthPolicy.headlessSession()` vs
   `ReauthPolicy.interval(Duration)` vs `ReauthPolicy.alwaysRequirePassphrase()`),
   since Phase 6 asserts "without it, the policy applies" and needs a concrete API
   to test. Folds into Q3.

### Non-blocking observations (address in-plan, do not need a decision from the maintainer)

- **Phase 1 ↔ Phase 3 coherence is fine, but state the intermediate shape.**
  Removing `FlutterSecureDekCache` in Phase 1 does **not** break `kmdb_flutter`'s
  compilation — but the implementer must also drop the
  `export 'src/flutter_secure_dek_cache.dart';` line and the library-doc example in
  `kmdb_flutter.dart`, delete `flutter_secure_dek_cache_test.dart`, and accept that
  between Phase 1 and Phase 3 `kmdb_flutter` exposes only `KmdbFlutter.initialize()`
  and every native/CLI `open()` runs full Argon2id (~200 ms) per open. That is an
  acceptable green intermediate — say so explicitly so it is not mistaken for a
  regression at review time.
- **"Non-extractable KEK" over-claims `flutter_secure_storage`.** That API stores
  and *returns* bytes gated behind an access-control policy; it does not hand back a
  use-but-cannot-extract key handle (unlike a raw Keystore/SE key). The real Phase 3
  shape is: a random KEK stored under `accessControlFlags: biometryCurrentSet` (read
  requires biometric auth, i.e. extractable-only-after-auth), used to
  `unwrapDek(wrappedDekBiometric, kek)`. Structurally still sound (no path yields a
  DEK without auth) — but reword Phase 3 so the implementer builds the achievable
  thing, and decide which store holds the KEK vs the wrap (KEK in secure storage
  gated; wrap in the per-device `SecretStore`).
- **RC numbering.** Next free release-checklist entry is **RC-28** (latest on
  `main` is RC-27), not implied elsewhere — use RC-28+ in Phase 7.
- **§34 already exists** (`sync_authentication`) — the "sank the device-identity
  design" reference the plan leans on is `docs/spec/34` / the WI-11/WI-14 history;
  cite it so §31's new limitations section can point at the precedent.
- **`changePassphrase` keys the cache by `info.dbDir` while `open()` keys by
  `path`** (`:1358`/`:1360` vs `:735`/`:751`/`:774`). Pre-existing latent
  inconsistency; since Phase 1 deletes both, just make sure the replacement
  per-device store uses **one** canonical db key on both paths.

### Scope call

Hold Phases 1–3, 5, 6, 7 as one plan (the SC-1 fix + biometric + headless opt-out
+ tests + spec — a coherent, shippable unit that fully closes SC-1). **Split Phase
4 (CLI session agent) into its own plan.** It is separable (SC-1 is closed without
it), it is the least-specified and highest-risk piece, and the proposal already
treats "the agent ships inside `kmdb_cli`" as a packaging note rather than a reason
to co-plan it.

## Reviewer re-check (round 2 — 2026-08-11)

The round-2 design resolutions are a big improvement — five of the six original
questions are now pinned well enough to implement, and I re-verified each against
the code. One new blocking gap (**Q7**) surfaced while validating the KEKSource
chokepoint the coordinator asked me to scrutinise, plus three small
clarifications that the authors can fold in without a maintainer decision.

### Q1–Q6: re-verified, resolved

- **Q1 (SecretStore seam) — holds, with two factual corrections.** The new
  `SecretStore? secretStore` param (default `InMemorySecretStore()`) is the right
  shape and mirrors the existing default-to-in-memory pattern. `dbScopedSecretKey`
  is a pure leaf function (`kmdb_cli/.../secret_key.dart` — hashes a canonicalised
  path via `package:crypto` + `package:path`) with **no** coupling back to CLI, so
  promoting it to core is clean and introduces no layering problem. Corrections the
  implementer must not skip:
  - **`crypto` is NOT already a transitive dep of `kmdb`.** Only `cryptography`
    (`^2.9.0`) is a direct dep; `crypto` is a direct dep of `kmdb_cli` only and does
    not appear in `kmdb`'s resolved `package_config.json`. Adding
    `crypto: ^3.0.0` to `packages/kmdb/pubspec.yaml` is a genuine **new** direct
    dependency, not a formality. (The action in the plan is right; the parenthetical
    "already a transitive dep" is wrong — delete it so the implementer actually adds
    the dep.)
  - The current `dbScopedSecretKey` doc comment is saturated with CLI concepts
    (`kmdb credentials prune`, Google-Drive `credentialsPath`, `RemoteConfig`). When
    it lands in core it must be **rewritten CLI-agnostic** — core must not reference
    `kmdb_cli` commands. The `crypto`/`path` imports and the logic move verbatim; only
    the prose changes.
- **Q2 (KEKSource) — holds.** Sealed `KEKSource` with `biometric` returning a KEK
  (not the DEK) preserves the single `KeyDerivation.unwrapDek` chokepoint; I traced
  the three unlock branches and confirmed all funnel through `unwrapDek`, and that
  removing `DekCache` deletes the only raw-DEK-return path (`:751-753`). No bypass —
  **subject to Q7**, which is about the *write* side of the biometric wrap, not the
  read side.
- **Q3 (`ReauthPolicy`) — holds.** Named deployment-shape API, `headlessSession()`
  as the explicit opt-out. Good. One semantics detail to pin (non-blocking, below):
  what a **missing** timestamp means.
- **Q4 (clock) — holds.** `DateTime Function()? now` on `open()` is exactly the
  seam the lapse test needs.
- **Q5 (CLI agent split) — confirmed and correctly executed.** Phase 4 removed,
  non-goal added, phases renumbered 1–6. Good.
- **Q6 (Phase 3 KEK mechanics) — holds** as reworded (biometric-gated KEK read from
  `flutter_secure_storage`, not a use-but-cannot-extract handle) — **but the reword
  introduced the Q7 correctness gap.**

### Q7 (NEW, blocking) — the biometric *enrolment* path and `obtainKek()` idempotency are unspecified

> **✅ Resolved (round 3, 2026-08-11)** — see the **Q7** block under "Design
> resolutions" above: `enableBiometricUnlock`/`disableBiometricUnlock` core
> enrolment API (from an unlocked session), idempotent get-or-create
> `obtainKek()`, unlock fail-closed on absent wrap/timestamp, and the additive
> `EncryptionConfig` refactor absorbed in Phase 1.

The round-2 text specifies how biometric **unlock** reads a KEK, but never
specifies how the biometric wrap is first **created**, and the `obtainKek()`
contract as written would break unlock. Two linked problems:

1. **No enrolment entry point.** `wrappedDekBiometric` lives in the per-device
   `SecretStore` under `dbScopedSecretKey(dbDir, 'dek.wrap.biometric')`, but nothing
   in the plan *writes* it. Creating it requires an authenticated (DEK-in-memory)
   session to: obtain/establish the biometric KEK, `wrapDek(dek, kek)`, and persist
   the result to `SecretStore`. That is a new **core-side public API** (e.g.
   `Future<void> KmdbDatabase.enableBiometricUnlock(BiometricKekProvider)`, requiring
   the db to be currently unlocked) — the same class of unspecified security-API seam
   that Q1/Q2 pinned. Phase 3 cannot be implemented mechanically without it; an
   implementer would be inventing the enrol API on the fly. (The plan even implies a
   reconfigure flow — "biometric auto-disables and the passphrase is required to
   reconfigure" — without defining it.)
2. **`obtainKek()` must be get-or-create, and the plan says "generate."** Phase 3
   currently says "*generate* a random 32-byte KEK, store it … return it from
   `obtainKek()`." If `obtainKek()` generates a fresh KEK on every call, the *unlock*
   call produces a different KEK than the one the wrap was created with, and
   `unwrapDek` fails every time — the biometric path never works. The contract must
   be explicit: `obtainKek()` is **idempotent per db-scoped key** — it creates the
   `flutter_secure_storage` item under `biometryCurrentSet` on first use (enrol) and
   **returns the existing one** thereafter (unlock). Enrolment-invalidation
   (`biometryCurrentSet`) then naturally destroys the item, which is exactly the
   auto-disable semantics Phase 3 wants. State this on the `BiometricKekProvider`
   interface, and decide whether enrol vs unlock is one idempotent method or two.

Note SC-1 itself (the headline) is closed by Phases 1–2 + tests regardless of Q7 —
Q7 blocks the **biometric feature (Phase 3)**, which this plan ships as part of the
same unit. So it must be resolved before `Investigated`.

### Clarifications to fold in (no maintainer decision needed)

- **State whether `EncryptionConfig` keeps its `passphrase:`/`recoveryCode:` named
  constructors (additive) or replaces them with `KEKSource` (breaking).** There are
  **30** `EncryptionConfig(` call sites (23 `kmdb`, 5 `kmdb_cli`, 2 `kmdb_flutter`)
  plus **5** that pass `dekCache:` and the `kmdb.dart` `DekCache` export. **Strong
  recommendation: additive** — retain `EncryptionConfig(passphrase:)` /
  `(recoveryCode:)` as convenience constructors that build the corresponding
  `KEKSource` internally, and add `EncryptionConfig.biometric(...)`. That drops the
  breaking fallout from ~30 sites to just the 5 `dekCache:` sites + the export.
  Whatever is chosen, **Phase 1 must absorb all of it in its one green commit** —
  say so, since removing `DekCache` + changing the constructor + deleting the export
  are what make Phase 1 compile-green.
- **Pin the missing-timestamp semantics (Q3/Q4):** when no `passphrase.lastused`
  entry exists (fresh `InMemorySecretStore`, or first ever biometric open), the
  re-auth check must **fail closed** — treat as lapsed, require the passphrase. Note
  this so an implementer does not default it to "just authenticated."
- **Per-phase greenness otherwise holds.** Phases 2–6 each compile and test on their
  own given Phase 1's seams; the `BiometricKekProvider` interface (core, Phase 1) with
  a fake impl lets Phase 1/2/5 tests exercise the biometric branch before the real
  `kmdb_flutter` impl lands in Phase 3.

### Verdict

Q1–Q6 are genuinely resolved; the seams hold. **Q7 is the one remaining blocker**
and it is squarely inside the "is the KEKSource chokepoint complete" question I was
asked to scrutinise — the read side is closed, the write (enrol) side is not, and
the `obtainKek()` contract as written would break unlock. Resolve Q7 (enrol API +
idempotent `obtainKek()`) and fold the two clarifications, and this promotes to
`Investigated` — no further maintainer decisions remain beyond Q7.

## Open questions

Q1–Q6 resolved (see "Design resolutions (round 2)" and "Reviewer re-check
(round 2)"). One blocker remains.

- [ ] **Q7 — Biometric enrolment API + `obtainKek()` idempotency.** (a) Name the
      core-side enrol entry point that writes `wrappedDekBiometric` to `SecretStore`
      from an unlocked session (e.g. `KmdbDatabase.enableBiometricUnlock(provider)`,
      requires DEK in memory) and where reconfigure/disable lives. (b) State on
      `BiometricKekProvider` that `obtainKek()` is **get-or-create / idempotent per
      db-scoped key** (creates the `biometryCurrentSet` item on enrol, returns the
      existing one on unlock) — the current "generate a random KEK" wording would
      make every unlock fail. (c) Decide enrol-vs-unlock: one idempotent method or
      two. Then update Phase 1 (interface) and Phase 3 (impl + enrol flow).

<details>
<summary>Round 1 questions (all resolved — kept for history)</summary>

- [x] **Q1 — Core `SecretStore` seam.** Resolved: `open()` gains `SecretStore?`;
      `dbScopedSecretKey` promoted to core; key literals pinned.
- [x] **Q2 — Biometric path selection.** Resolved: sealed `KEKSource`, biometric
      returns a KEK, `unwrapDek` chokepoint preserved.
- [x] **Q3 — Re-auth policy + headless opt-out API.** Resolved: `ReauthPolicy`.
- [x] **Q4 — Clock injection.** Resolved: `DateTime Function()? now`.
- [x] **Q5 — Split the CLI session agent.** Resolved: split confirmed.
- [x] **Q6 — Phase 3 KEK mechanics.** Resolved: biometric-gated-KEK shape (but see
      Q7 — the reword exposed the enrol/idempotency gap).

</details>

## Reviewer re-check (round 3 — 2026-08-11): SIGN-OFF → `Investigated`

Q7 and the two corrections close cleanly. The plan now clears the
implementation-readiness bar: a Sonnet implementer could execute it without
making a significant design decision.

**Q7 (biometric enrolment + `obtainKek()`) — resolved.**
- The write side is now a named core API: `enableBiometricUnlock(BiometricKekProvider)`
  (unlocked-DB precondition, `wrapDek` → `SecretStore` under
  `dbScopedSecretKey(dbDir, 'dek.wrap.biometric')`) with a paired
  `disableBiometricUnlock()`. Added to Phase 1's checklist, exercised in Phase 1
  with a fake provider. That was the missing entry point — it exists now.
- The `obtainKek()` correctness bug is fixed: the contract is **idempotent
  get-or-create per db-scoped key**, stated on the interface (Q2/Q7) *and* in the
  Phase 3 checklist, which is reworded from "generate" to "create on first use,
  return the same KEK thereafter." Enrol and unlock now derive the same KEK, so
  `unwrapDek` succeeds; `biometryCurrentSet` invalidation destroying the item gives
  auto-disable for free. Internally consistent.
- Fail-closed gating is explicit: biometric branch runs only if a wrap exists;
  absent wrap or absent/stale timestamp → passphrase. Timestamp written on
  passphrase unlock + provision only, never by biometric — so it tracks passphrase
  recency correctly.

**Corrections — folded correctly.** `crypto` is now stated as a genuine new direct
dep of `kmdb`; the promoted `dbScopedSecretKey` doc comment is flagged for a
CLI-agnostic rewrite; the `EncryptionConfig` refactor is pinned **additive** (5
`dekCache:` sites + the `kmdb.dart` export, all in Phase 1's one commit), which is
the low-churn, greenness-preserving choice.

**Two non-blocking directives for the implementer** (design fully determines the
expected behaviour; the ≥95% coverage gate will force them anyway — named here so
they are not missed):
1. **Extend the Phase 5 matrix** with (a) an enrol→close→reopen-with-biometric
   happy round-trip (proves enrol and unlock derive the same KEK — the exact bug
   Q7 fixed), (b) `disableBiometricUnlock()` → subsequent biometric open refused,
   passphrase required, and (c) fail-closed: a biometric `KEKSource` with **no**
   wrap present in `SecretStore` falls back to requiring the passphrase (never
   silently opens).
2. **The Q6 standalone paragraph predates Q7** and still reads "generate … return
   it from `obtainKek()`" without the idempotency qualifier. The **Phase 3
   checklist (lines ~297–305) is authoritative**; if the two ever conflict during
   implementation, follow the Phase 3 checklist + Q7, not the Q6 prose.

Everything else verified in rounds 1–2 still holds (SC-1 removal completeness, the
`$meta`-syncs premise behind the per-device-local decision, the single-`unwrapDek`
chokepoint, per-phase greenness). **Promoted to `Investigated`.**

## Summary

_To be completed when the work is done._
