# Unlock policy — close SC-1 with a wrapped-copy DEK model, re-auth, and a CLI agent

**Status**: Open (ready for `kmdb-plan-reviewer`)

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
- **Extracting a session-agent package.** The agent ships inside `kmdb_cli`.

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

- [ ] Implement the non-extractable KEK source for iOS/Android/macOS/Windows via
      `flutter_secure_storage` `accessControlFlags` (`biometryCurrentSet`), wiring
      it into Phase 1's `KEKSource`. Linux → passphrase path in practice.
- [ ] Enrolment-invalidation semantics: adding a finger/face invalidates the KEK;
      biometric auto-disables and the passphrase is required to reconfigure.
- [ ] **Checkpoint:** commit `WI-5 Phase 3: kmdb_flutter biometric KEK`. *(Run
      `kmdb_flutter`'s own tests — `make pre_commit` is `kmdb`-scoped only.)*

### Phase 4 — CLI session agent (`kmdb_cli`)

- [ ] ssh-agent-style agent: DEK in **agent process memory**, owner-only socket
      (reuse the credential-store / `SecretStore` permission model), **idle
      timeout + absolute cap**, `kmdb … lock` ends it, never outlives the login
      session. Single-database first (namespace later via `dbScopedSecretKey`).
- [ ] `kmdb … unlock` / `lock` CLI surface; clear diagnostics.
- [ ] **Checkpoint:** commit `WI-5 Phase 4: CLI session agent`. *(Run `kmdb_cli`
      tests explicitly.)*

### Phase 5 — Server / headless handling

- [ ] Session = process lifetime; the Phase 2 policy is suppressed via the
      documented deployment-shape opt-out; passphrase injected non-interactively
      through the `SecretStore` directory backend (`$CREDENTIALS_DIRECTORY`,
      `/run/secrets`, k8s mounts). Library-side hook only — `kmdb_server` is a
      separate proposal.
- [ ] **Checkpoint:** commit `WI-5 Phase 5: headless/server unlock hook`.

### Phase 6 — Tests (edge/fault, not golden-path)

- [ ] **The SC-1 regression (headline):** a wrong passphrase is **rejected**
      even with a prior successful unlock / warm platform key. This test must
      fail on `main` today.
- [ ] Biometric enrolment-invalidation forces passphrase re-config.
- [ ] Re-auth interval lapse → biometric path refused, passphrase required.
- [ ] `lock()` discards the DEK; the next open re-authenticates.
- [ ] **The "last used" timestamp is local-only** — a device idle for a month is
      not fast-forwarded by a peer's recent timestamp (the `$meta`-LWW
      regression; assert it would fail if the field were synced).
- [ ] Agent: idle expiry, absolute-cap expiry, `lock` immediacy, no-outlive-login.
- [ ] Headless opt-out suppresses the policy; without it, the policy applies.
- [ ] **Checkpoint:** commit `WI-5 Phase 6: test matrix`.

### Phase 7 — Spec & docs

- [ ] **§31** — replace the DEK-cache section with the wrapped-copy model; add
      the policy, the platform matrix, and the honest §6 limitations (coercion,
      compromised host, root/jailbreak). **Must not be reconciled by describing
      the current code.**
- [ ] **§19** (platform) — the platform matrix.
- [ ] **§33** (CLI credential store) — the session agent.
- [ ] **§28** — release-checklist entries for what CI cannot cover: biometric
      enrolment invalidation, coerced re-auth behaviour, agent expiry.
- [ ] Roadmap WI-5 row updated in-branch (moves with the PR).
- [ ] **Checkpoint:** commit `WI-5 Phase 7: spec + docs`.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm ≥95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off. Do not open a PR until
      sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests green.
- [ ] Verify licence headers (2026) on all new files.

> This plan touches **`kmdb`, `kmdb_flutter`, and `kmdb_cli`**. `make pre_commit`
> is `packages/kmdb`-scoped only — run `kmdb_flutter` and `kmdb_cli` suites
> explicitly (`cd packages/<pkg> && dart test`).

## Summary

_To be completed when the work is done._
