# Unlock policy — close SC-1 with a wrapped-copy DEK model, re-auth, and a CLI agent

**Status**: Questions — reviewer Q1–Q6 resolved 2026-08-11 (see "Design resolutions (round 2)"); ready for re-review → Investigated

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
  `kmdb_cli` deletes its local copy and consumes the core export. Adds the
  `crypto` dependency to `kmdb` (already a transitive dep).
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
(`Future<Uint8List> obtainKek()`) implemented in `kmdb_flutter`.

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

## Implementation plan

> Each phase is a green checkpoint — see **Resumability** above.

### Phase 1 — Core: remove `DekCache`, add the authenticated wrapped-DEK unwrap

- [ ] Remove `DekCache` / `InMemoryDekCache` and every reference (core + the
      `FlutterSecureDekCache` in `kmdb_flutter`, deferring the *replacement*
      platform impl to Phase 3 — Phase 1 leaves native hosts on the passphrase
      path, which is correct and green).
- [ ] Refactor the `kmdb_database.dart` open path so **every** branch obtains the
      DEK by an authenticated unwrap (passphrase, recovery, or — once Phase 3
      lands — biometric); delete the raw-DEK cache-hit return at `:751-753`.
- [ ] Add `EncryptionConfig.tryUnwrapWithBiometric` (thin `unwrapDek` wrapper)
      and a `KEKSource` abstraction the open path consults, so a wrong passphrase
      is **always** rejected regardless of prior unlock state.
- [ ] Define the **per-device local** store for the biometric-wrapped DEK (see
      the design decision above) — `SecretStore`-backed on native, keyed per db.
      Nothing biometric is written to `enc:blob`.
- [ ] `KmdbDatabase.lock()` — discard the in-memory DEK, force a fresh unwrap.
- [ ] **Checkpoint:** commit `WI-5 Phase 1: remove DekCache, authenticated
      wrapped-DEK unwrap, lock()` (green).

### Phase 2 — Re-authentication policy (default-on, 14-day, enforced)

- [ ] Store a **per-device, local-only** "passphrase last used" timestamp (NOT
      `$meta` — see the design decision; same store as Phase 1's biometric wrap).
- [ ] Enforce in `KmdbDatabase.open()`: once the interval lapses, refuse the
      biometric path and require the passphrase. Host-configurable interval +
      "always require passphrase".
- [ ] **Suppressible** opt-out for headless deployments — an explicit, documented
      API naming the deployment shape (not a bare boolean), per proposal §4.6.
- [ ] **Checkpoint:** commit `WI-5 Phase 2: default-on periodic re-auth policy`.

### Phase 3 — Platform KEK: native biometric (`kmdb_flutter`)

- [ ] Implement `BiometricKekProvider` (the `kmdb_flutter` impl of the core
      interface) for iOS/Android/macOS/Windows: generate a random 32-byte KEK,
      store it in `flutter_secure_storage` under `accessControlFlags:
      biometryCurrentSet` (reading requires a fresh biometric auth), and return
      it from `obtainKek()` for core to `unwrapDek` — the achievable
      biometric-gated-KEK shape, not a use-but-cannot-extract handle (Q6). KEK in
      secure storage; wrap in the per-device `SecretStore`. Linux → passphrase
      path in practice.
- [ ] Enrolment-invalidation semantics: adding a finger/face invalidates the KEK;
      biometric auto-disables and the passphrase is required to reconfigure.
- [ ] **Checkpoint:** commit `WI-5 Phase 3: kmdb_flutter biometric KEK`. *(Run
      `kmdb_flutter`'s own tests — `make pre_commit` is `kmdb`-scoped only.)*

### Phase 4 — Server / headless handling

- [ ] Session = process lifetime; the Phase 2 policy is suppressed via the
      documented `ReauthPolicy.headlessSession()` opt-out; passphrase injected
      non-interactively through the `SecretStore` directory backend
      (`$CREDENTIALS_DIRECTORY`, `/run/secrets`, k8s mounts). Library-side hook
      only — `kmdb_server` is a separate proposal.
- [ ] **Checkpoint:** commit `WI-5 Phase 4: headless/server unlock hook`.

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

## Open questions

**All resolved 2026-08-11** — see "Design resolutions (round 2)" above, which
pins each API seam and folds the non-blocking observations. The phases have been
updated to match (CLI agent removed, phases renumbered). Ready for the reviewer's
re-check.

- [x] **Q1 — Core `SecretStore` seam.** What is the exact `open()` change? Confirm a
      new `SecretStore? secretStore` parameter (default `InMemorySecretStore`),
      state where the per-db key scheme lives (promote `dbScopedSecretKey` to core
      vs restate), and give the storage-key literal(s) for `wrappedDekBiometric` and
      the "last used" timestamp.
- [x] **Q2 — Biometric path selection.** How does a host ask `open()` to use the
      biometric `KEKSource` instead of a passphrase? New `EncryptionConfig`
      constructor/field, or a separate parameter? Name the `KEKSource` interface
      (does it return a KEK for core to `unwrapDek`, or the DEK directly? — the
      Investigation implies the former; make it explicit).
- [x] **Q3 — Re-auth policy + headless opt-out API.** Name the concrete type and its
      constructors (interval, always-require-passphrase, headless-session opt-out).
      Confirm it is a named deployment-shape API, not a boolean, per proposal §4.6.
- [x] **Q4 — Clock injection.** Add an injectable `now`/`Clock` seam to the re-auth
      enforcement in `open()` so the interval-lapse test is writable.
- [x] **Q5 — Split the CLI session agent (Phase 4) into its own plan?** Reviewer
      recommends yes. Maintainer to confirm; if yes, remove Phase 4 here and drop a
      pointer to the new plan.
- [x] **Q6 — Phase 3 KEK mechanics.** Reword the "non-extractable KEK" language to
      the achievable `flutter_secure_storage` shape and state which store holds the
      KEK vs the wrap.

## Summary

_To be completed when the work is done._
