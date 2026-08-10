# Authenticate sync artefacts against an untrusted provider (T1)

**Status**: Implementing

**PR link**: _(none yet)_

> **Provenance.** Closes the **T1** half of finding **E-1** in the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md),
> under the [0.10.01 hardening track](../roadmap/0_10_01.md). Split out of
> `plan_0_10_01_sync_trust_boundary.md` on 2026-07-19 (Q-E) — it is the largest
> and least-specified part of that plan, and it introduces a new subsystem plus
> a new user-facing UX.

## Problem statement

`docs/spec/31_encryption.md` documents a **passive-only** threat model: a
provider who *reads* your data. It never claims the synced data is *authentic*.
Everything in the sync folder is trusted because it is in the sync folder.

The realistic threat is not the provider turning evil — it is **a compromised
cloud account**: a phished password, a stolen OAuth token, a third-party app
with Drive scope. That attacker gets write access to the sync folder, and
neither full-disk encryption nor the provider's own at-rest encryption helps,
because the attacker is authenticated as the user.

Without artefact authentication, such an attacker can forge SSTables, vault
blobs, high-water marks, and consolidation leases. Findings S-1, S-4 and S-6
are all reachable that way.

## Goals

Authenticate every artefact KMDB reads from the sync folder, such that a party
who can write the folder but does not hold the sync-auth key cannot forge one.

## Non-goals

- **T3 — the malicious peer.** A peer *holds* the key, so a shared-key MAC
  cannot distinguish it. Deferred to
  [proposals/device_identity.md](../proposals/device_identity.md).
- **Confidentiality.** That is encryption's job and stays optional (§31).
  Authentication and encryption are deliberately decoupled.
- **Extracting `betto_secret_store`** — see
  [the proposal](../proposals/betto_secret_store.md). This plan ships a
  KMDB-local implementation behind the interface.

## Settled design decisions

Resolved with the maintainer 2026-07-19. Recorded with reasoning so the
reviewer can audit rather than re-derive.

- **An independent key, not DEK-derived.** A DEK-derived MAC would force
  encryption on as a prerequisite for authentication — trading a low-value
  requirement (KMDB-level encryption is marginal for a user with full-disk
  encryption and a reputable provider) for a high-value guarantee. It would also
  be discarded when T3 lands.
- **The key is re-provisionable, so it needs no passphrase or recovery code.**
  Lose the DEK and the data is gone forever; lose the sync-auth key and you
  simply re-provision. This asymmetry is what makes auto-generation defensible.
- **One key per remote (Q-C)**, minted at `remote add`. The key protects a sync
  folder's contents and each remote is a folder. A database syncing to both
  Drive and a NAS holds two independent keys. Minting at `remote add` rather
  than `init` avoids creating keys for databases that never sync.
- **Transport envelope for the MAC (Q-A).** `upload()` writes
  `[magic][mac][bytes]`; `download()` verifies and strips. Authenticity is a
  property of the *sync channel*, not the file format — SSTables are immutable
  and locally identical across devices. Generalises to HWM and lease files, and
  keeps the sibling hardening plan independent.
- **A sync-set identity minted with the remote (Q-B)**, carried in the pairing
  payload — **not** a database identity minted at `init`. Verified: `$meta`
  syncs (`isLocalOnly(r'$meta')` is `false`) and `DeviceId` persists there, so
  two independently-minted identities LWW-collide on first pull. Delivering the
  identity *with* the key removes the ordering problem.
- **The pairing code carries the key itself**, base32 with a checksum. A PAKE
  would be over-engineering for a re-provisionable secret whose loss costs
  nothing.
- **`SecretStore` interface in core, implementations outside (Q-G)** — mirroring
  `DekCache`. Core never chooses a filesystem path; the host does. This is what
  makes the design work on mobile, where `~/.config/kmdb` is simply wrong.

## Design decisions (resolved 2026-08-10)

All eight open questions were closed in a maintainer design session. Grounded in
the existing crypto seams: `indexToken`'s 128-bit truncated HMAC
(`encryption_provider.dart:289-297`), `_indexTokenSubKey`'s `Hkdf.deriveKey`
info-label pattern (`:279-287`), and `EncryptionEnvelope`'s self-describing
`[flag][payload]` frame.

- [x] **Envelope byte layout.** `[magic "KSA" (3B)][version 0x01 (1B)][MAC
      (16B)][payload]` — self-describing like `EncryptionEnvelope`; magic+version
      lets the frame evolve unambiguously. `download()` recomputes and verifies
      the MAC over `path ‖ payload` (see below), then strips the 20-byte header
      and returns `payload`. `upload()` prepends it.
- [x] **MAC algorithm and length.** HMAC-SHA256 **truncated to 128 bits (16
      bytes)**, matching `indexToken` exactly (`mac.bytes.sublist(0, 16)`).
      Verify with a constant-time compare. 128-bit forgery resistance is far
      beyond any practical attack and halves per-file overhead vs. 256.
- [x] **The MAC covers the remote path.** The HMAC message is
      `lenPrefixed(relativeRemotePath) ‖ payload`, so a valid artefact cannot be
      relocated to another path (E-2 one level up). The path is sync-root-relative,
      normalised to forward slashes for cross-platform stability.
- [x] **HKDF per-artefact-class sub-keys.** One root key → five sub-keys via
      `Hkdf(hmac: Hmac(Sha256()), outputLength: 32)` with distinct `info` labels —
      `kmdb-sync-auth-sstable`, `kmdb-sync-auth-vault-blob`,
      `kmdb-sync-auth-vault-manifest`, `kmdb-sync-auth-hwm`,
      `kmdb-sync-auth-lease` — so a MAC valid for one class cannot be replayed as
      another. Mirrors `_kIndexTokenInfo`.
- [x] **CLI surface.** `kmdb remote pair show <remote>` prints the pairing code;
      `kmdb remote pair import <remote> <code>` enrolls a second device. Nested
      under `remote`, consistent with `remote add`. The code is a `KSA1-`-prefixed
      base32 grouping with a checksum.
- [x] **Key length / generation / at-rest.** 256-bit root key from
      `Random.secure()` (32 bytes), stored as raw bytes in `SecretStore`. base32
      appears only in the pairing code (which carries its own checksum), never at
      rest.
- [x] **Pre-existing remotes (R-5).** Wipe the sync root and re-push from one
      device — no in-place upgrade. An un-enveloped or bad-MAC artefact raises a
      distinct `SyncAuthException` whose message points the user at
      re-provisioning (`remote pair`).
- [x] **`providesAtomicCas = false` adapters.** No special interaction: those
      adapters skip consolidation, so the lease is never written or read. The
      envelope applies uniformly to SSTables, HWM, and vault artefacts; lease
      authentication is inert on that path.

## Prerequisites (ordering)

This plan is the crypto core only. Its one **unmet** prerequisite is the
`SecretStore` precursor (item 1); the A3 dependency (item 2) is already merged.

1. **`plan_0_10_01_secret_store.md`** — the `SecretStore` precursor (split out of
   this plan's former Phase 1). Provides the core `SecretStore` interface + the
   `DirectorySecretStore` the default `SyncAuthenticator` reads its root key from.
2. **A3 quarantine reporting** — ✅ **merged to `main` 2026-08-10** ([PR #72](https://github.com/bettongia/kmdb/pull/72),
   plan in `docs/plans/completed/plan_0_10_01_a3_quarantine_reporting.md`). This
   prerequisite is **satisfied**: Q1's recovery path reuses A3's engine-layer
   `QuarantineReason` enum, the persisted `$$quarantine` log, and its
   `appendQuarantine` interface seam, all now present on `main`. Phase 3 adds the
   sixth `unauthenticated` variant plus the `KvStore.quarantinedFilenames()`
   accessor the pre-download skip-list consult needs.

## Design decisions (resolved 2026-08-10, round 2 — reviewer Q1–Q4 + scope)

Closes the reviewer's four blockers and the scope split. Verified against `main`.

- [x] **Q1 — Verify MAC before the HWM decision; compose with A3 by reason.**
      The pull loop verifies the MAC (in the Q2 decorator) **before** any HWM
      update. Two rejection classes, distinguished by `QuarantineReason`:
      - **MAC failure** (`SyncAuthException`): the filename — hence `maxHlc` — is
        adversarial. Record the file in the A3 quarantine log under a **new
        sixth variant `QuarantineReason.unauthenticated`**, keyed by filename,
        then `continue` **without advancing the peer HWM**.
      - **MAC pass but ingest failure** (the five existing A3 reasons): the
        filename is now authenticated, so A3's existing advance-the-peer-HWM
        behaviour is retained.

      So A3 and sync-auth **share the log but branch the HWM decision on the
      reason**. Two verified wrinkles the implementer must handle:
      - **A3's HWM advance was also the re-fetch gate.** For `unauthenticated`
        there is no advance, so the **filename lookup in the log becomes the
        gate**: at the top of `pull()`, load the quarantined-filename set once
        and skip any listed file **before** download.
      - **`SyncEngine` cannot read the log through its `_store`.**
        `SyncEngine._store` is the `KvStore` *interface*; A3 (D1) puts only
        `appendQuarantine` on it and keeps `listQuarantines()` on `KvStoreImpl`
        (read side is `KmdbDatabase`-only). Add a **narrow read accessor to the
        `KvStore` interface** — `Future<Set<String>> quarantinedFilenames()`
        delegating to `_meta` (same seam pattern as `appendQuarantine` /
        `resetTombstoneFloor`) — for the pre-download consult. `QuarantineReason`
        is an engine-layer enum (A3 D2), so the sixth variant is a clean add and
        does not create an upward dependency.

- [x] **Q2 — Envelope lives in one core `SyncStorageAdapter` decorator.** Adopt a
      single decorator in core (precedent: `QuotaAwareAdapter` /
      `GatedSyncAdapter`), constructed at the adapter-wiring point, wrapping any
      inner adapter:
      - `upload` — prepend the envelope.
      - `download` — verify + strip; **throw `SyncAuthException`** on a bad or
        missing MAC (distinct from a `null` return, which stays "file removed
        between list and download").
      - `compareAndSwap` — envelope the `newBytes` before delegating (lease
        writes, `consolidation_coordinator.dart:391/411`).
      - `getEtag` — delegate unchanged (the etag is over the *stored, enveloped*
        object, which is exactly what CAS compares).
      - `list` — **delegate unchanged; filenames are not enveloped.** This is
        precisely why `SstableInfo.parse` on remote listings is unaffected —
        state that explicitly.

      Because the decorator throws uniformly, **rejection *policy* is per call
      site** (detection is uniform, disposition is not):
      | Site | On `SyncAuthException` |
      | --- | --- |
      | `SyncEngine.pull` SSTable (`:549`) | quarantine `unauthenticated`, `continue`, **no HWM advance** (Q1) |
      | `SyncEngine._fullResync` SSTable (`:454`) | skip + quarantine; safe (fullResync resets local HWM to `Hlc(0,0)`, so no peer-suppression risk) |
      | `ConsolidationCoordinator` input SSTable (`:483`) | skip that input, like the existing `CorruptedSstableException` branch (`:499`) |
      | `HighwaterMark.load` of **own** HWM (`_remoteHwmPath`) | propagate — a tampered own file must not be silently ignored |
      | Peer HWM load in `_checkAndHandleEviction` (`:360`) | `continue` (skip that peer), do not abort the eviction check |
      | Lease download / CAS (`:371/:721/:391/:411`) | propagate — abort this consolidation round rather than act on a forged lease |
      | Consolidated-output upload (`:544`) | n/a — envelope applied on upload |

- [x] **Q3 — Vault threads the authenticator manually at six sites (six
      classes).** `LocalDirectoryVaultAdapter` does remote I/O with raw
      `dart:io File`, so the Q2 decorator cannot reach it. Call
      `SyncAuthenticator.mac`/`verify` directly at: `uploadVaultObject` manifest
      (`:139`), blob (`:151`), tombstone (`:164`); `syncVaultMetadata` manifest
      (`:188`), tombstone (`:203`); `hydrateVaultBlob` blob (`:230`).
      `tombstone.json` becomes its **own sixth artefact class** with sub-key
      label `kmdb-sync-auth-vault-tombstone` (it is forgeable and drives GC, so
      it earns a distinct label rather than folding under `vault-manifest`) —
      **six** HKDF `info` labels total. Two-envelope ordering in
      `hydrateVaultBlob`: strip + verify sync-auth envelope →
      `EncryptionEnvelope.unwrap` (`:240`) → sha256 check (`:245`) → stage the
      still-`EncryptionEnvelope`-wrapped bytes (`:258`) → rename (`:264`). The
      `LocalDirectoryVaultAdapter` constructor gains a `SyncAuthenticator`
      parameter.

- [x] **Q4 — Web ships import-only, with a forward-compat origination seam.**
      Web `SyncAuthenticator` uses a non-extractable WebCrypto `CryptoKey` for
      `mac`/`verify` and HKDF `deriveKey`, **persisted across sessions in
      IndexedDB** (a non-extractable `CryptoKey` is structured-cloneable into
      IndexedDB). The web key-generation path takes an **extractability policy**
      (default: non-extractable / import-only). `remote pair show` on web is
      **gated on the key having been generated extractable** — impossible for a
      default web-originated key, so web is import-only *now*, with the
      origination path left open by design (the maintainer explicitly wants
      "start on web, later originate a sync set" reachable without a rewrite).
      Document this as a deliberate, **not-yet-implemented** forward-compat point;
      the DB-export-then-re-import route stays as the fallback.

- [x] **Scope — Phase 1 split out.** The former Phase 1 (`SecretStore`) is now
      `plan_0_10_01_secret_store.md`. This plan is trimmed to the crypto core
      (phases renumbered below) and depends on that precursor (see Prerequisites).

## Investigation

### Existing seams to reuse

- **`DekCache`** (`lib/src/encryption/dek_cache.dart`) — the architectural
  precedent for `SecretStore`: pure-Dart seam in core, in-memory default,
  platform implementations outside the package.
- **`AesGcmEncryptionProvider._indexTokenSubKey`** — an `info`-labelled
  `Hkdf.deriveKey` already in the codebase; the per-artefact-class sub-key
  derivation should follow it exactly.
- **`DirectoryCredentialStore`** (`kmdb_cli`) — its permission model was
  reviewed and found sound (review C-3). Refactor to implement `SecretStore`
  rather than rewriting: directory `chmod 700` before write, file `chmod 600`
  after, delete-on-chmod-failure, read-side hard refusal.

### Integration points

`SyncEngine.push` / `pull` and the vault adapter's
`uploadVaultObject` / `hydrateVaultBlob` / `syncVaultMetadata` are where the
envelope is applied and stripped. `hydrateVaultBlob`'s rename-into-place must
strip the envelope **before** the rename, or the local blob will contain it.

### Edge cases

- **A local-only database has no sync-auth key and that is valid** (R-4).
  `open()` must succeed; only `push`/`pull` may refuse.
- **`SstableInfo.parse` runs on remote *listings*,** which the envelope does not
  affect — filenames are unchanged. Verify this holds.
- **Web** needs a `SyncAuthenticator` backed by a non-extractable WebCrypto
  `CryptoKey`, bypassing `SecretStore` entirely (the key material is never
  visible to script).

## Implementation plan

> **Former Phase 1 (`SecretStore`) has been split out** into
> `plan_0_10_01_secret_store.md` (see Prerequisites). Phases below are the
> crypto core, renumbered 1–5.

### Phase 1 — `SyncAuthenticator` and the six-class HKDF derivation

- [x] `Future<Uint8List> mac(Uint8List)` / `Future<bool> verify(...)` in core.
      **Not** get-key shaped — that would foreclose WebCrypto non-extractable
      keys, StrongBox, and Secure Enclave. `verify` uses a constant-time compare.
      Implemented as `SyncAuthenticator` (`sync_authenticator.dart`), signature
      widened to `mac(SyncArtifactClass, Uint8List message)`/`verify(..., mac)`
      per the six-class design below — see `sync_artifact_class.dart`,
      `sync_auth_exception.dart`. Tests:
      `test/sync/auth/default_sync_authenticator_test.dart`,
      `sync_auth_envelope_test.dart`.
- [x] Default implementation: root key from `SecretStore`; **six** per-artefact-
      class sub-keys via `Hkdf(hmac: Hmac(Sha256()), outputLength: 32)` with
      distinct `info` labels (`sstable`, `vault-blob`, `vault-manifest`,
      `vault-tombstone`, `hwm`, `lease`), mirroring `_indexTokenSubKey`
      (`encryption_provider.dart:279-287`). MAC = HMAC-SHA256 truncated to 16
      bytes (`mac.bytes.sublist(0, 16)`, matching `indexToken` `:297`) over
      `lenPrefixed(relativeRemotePath) ‖ payload`. Implemented as
      `DefaultSyncAuthenticator` + `SyncAuthEnvelope` (wrap/unwrap the
      transport envelope) + `SyncAuthenticatingAdapter` (the Q2 decorator).
      "Root key from `SecretStore`" is constructed by the caller
      (`kmdb_cli`'s `adapterFor`, Phase 2) — `DefaultSyncAuthenticator` itself
      takes raw bytes, matching `AesGcmEncryptionProvider`'s pattern of not
      knowing about `SecretStore`/`DekCache` directly.
- [x] Web implementation backed by a non-extractable `CryptoKey` (Q4), persisted
      in IndexedDB; extractability-policy seam (default non-extractable) for
      future web origination — **origination itself not implemented now**.
      Implemented as `WebSyncAuthenticator` (`web_sync_authenticator.dart`,
      conditional-exported via `web_sync_authenticator_stub.dart` +
      `if (dart.library.js_interop)`), using `SubtleCrypto.importKey`
      (non-extractable HKDF base key, `usages: ['deriveKey']`) +
      `SubtleCrypto.deriveKey` (per-class non-extractable HMAC sub-keys) +
      `SubtleCrypto.sign`/`verify`, persisted via IndexedDB
      (`persist`/`loadPersisted`). Verified **not hand-waved**: real browser
      test suite `test/sync/auth/web_sync_authenticator_test.dart` (9 tests,
      run via `dart test -p chrome`, wired into `make cicd_web`), including a
      known-answer-vector cross-check against `DefaultSyncAuthenticator`'s
      native derivation (same root key/message/class → identical 16-byte
      MAC), proving HKDF/HMAC interop between the native and web
      implementations.

### Phase 2 — Key lifecycle and enrollment

- [x] Generate the 256-bit sync-set key (`Random.secure()`, 32 raw bytes) and the
      sync-set identity at `remote add`; store raw bytes via `SecretStore`.
      Implemented as `SyncSetKey` (`sync_set_key.dart`, core) —
      `SyncSetKey.generate()`; `remote add` now mints and persists it via
      `kmdb_cli`'s `mintSyncAuthKey`/`sync_auth_key_store.dart`
      (`dbScopedSecretKey(dbDir, 'sync-auth:$remoteName')`). Tests:
      `test/sync/auth/sync_set_key_test.dart` (core),
      `test/commands/remote_command_test.dart` (CLI wiring),
      `test/config/adapter_for_test.dart` (`adapterFor` wrapping).
- [x] Pairing code: `KSA1-`-prefixed base32 + checksum, carrying key and sync-set
      identity. base32 appears **only** in the code, never at rest.
      Implemented as `PairingCode` (`pairing_code.dart`, core) — hand-rolled
      RFC 4648 base32 (no existing pure-Dart primitive in the workspace;
      `crypto`/base32 aren't `kmdb` core deps), checksum via
      `package:cryptography`'s `Sha256` (already a dependency, used for
      HKDF elsewhere — avoids adding a second hashing dependency). Tests:
      `test/sync/auth/pairing_code_test.dart` (round-trip, whitespace/case
      tolerance, corrupted-checksum rejection, truncation).
- [x] `kmdb remote pair show <remote>` / `kmdb remote pair import <remote>
      <code>`. On web, `show` is gated on an extractable key (Q4).
      Implemented in `RemoteCommand._pair`/`_pairShow`/`_pairImport`
      (`remote_command.dart`). The web-gating half of Q4 does not apply to
      `kmdb_cli` itself — the CLI is `dart:io`-only and never runs on web;
      `WebSyncAuthenticator.isExtractable` is the primitive a future web
      host (`kmdb_ui`, a separate repo) would gate its own "show pairing
      code" UI on. `remote pair import` requires the remote to already be
      configured on this device (`remote add` first, with this device's own
      connection details) — the pairing code carries only the shared key,
      never path/credentials. Tests: `test/commands/remote_command_test.dart`
      (`pair` group — show/import validation, a full two-"device" round-trip
      via two independent `FakeSecretStore`s, malformed-code and
      not-yet-configured-remote rejection).
- [x] Clear diagnostics when a remote has no key, pointing at enrollment.
      `adapterFor` throws `SyncAuthException` naming the remote and pointing
      at `remote pair` (R-4); `remote pair show` on an unenrolled remote
      returns a clean CLI error rather than propagating an exception.

### Phase 3 — Envelope, decorator, and integration

- [ ] Envelope frame `[magic "KSA" (3B)][version 0x01 (1B)][MAC (16B)][payload]`.
- [ ] Core `SyncStorageAdapter` **decorator** (Q2) handling
      `upload`/`download`/`compareAndSwap`/`getEtag`/`list` per the Q2 table;
      `download` throws `SyncAuthException` on bad/missing MAC. Constructed at the
      adapter-wiring point.
- [ ] Wire the decorator so it covers **all** channel sites: `SyncEngine.push`
      (`:263`) / `pull` (`:549`) / `_fullResync` (`:454`); `ConsolidationCoordinator`
      input download (`:483`), consolidated upload (`:544`), lease download/CAS
      (`:371/:721/:391/:411`); `HighwaterMark.load` (`:88`) / `save` (`:179`).
- [ ] Apply the **per-site rejection policy** in the Q2 table (pull → quarantine
      `unauthenticated` + `continue`, **no HWM advance**; own-HWM/lease →
      propagate; peer-HWM/consolidation-input → skip).
- [ ] **Q1 recovery wiring:** add `QuarantineReason.unauthenticated` (engine
      layer); add `KvStore.quarantinedFilenames()` delegating to `_meta`; load the
      quarantined set at the top of `pull()` and skip listed files **before**
      download; branch the HWM advance on reason.
- [ ] **Vault manual threading** (Q3): `SyncAuthenticator` at the six
      `LocalDirectoryVaultAdapter` File I/O sites; two-envelope ordering in
      `hydrateVaultBlob`; constructor gains the authenticator.
- [ ] Reject unauthenticated or badly-authenticated artefacts. **No
      tolerated-fallback mode** — an "accept unauthenticated for now" switch is a
      downgrade attack.

### Phase 4 — Tests

- [ ] Forged artefact rejected, per artefact class (all six).
- [ ] Cross-class replay rejected (a valid SSTable MAC replayed onto a lease /
      onto a vault tombstone).
- [ ] Path-relocation rejected (the MAC covers the path).
- [ ] Enrollment round-trip across two simulated devices; key survives
      `new-device-id`.
- [ ] **Q1 peer-suppression regression:** a MAC-failed file naming a real peer
      with a huge `maxHlc` must **not** suppress that peer's subsequent genuine
      SSTables (assert the next real SSTable from that peer still ingests).
- [ ] **Recovery:** after a rejected artefact, the next `pull()` succeeds and the
      bad file is skipped pre-download via the quarantine log.
- [ ] **Fault injection** (`FaultyStorageAdapter`, per CLAUDE.md / 2026-05-22
      review): forged/truncated envelopes against a durability-real adapter, not
      only the in-memory one; include the Q1 regression here.
- [ ] **R-4:** a remote-configured-but-**unenrolled** database — `open()`
      succeeds, but `push`/`pull` raise `SyncAuthException` (not a crash). A
      purely local-only database opens fine with no key at all.
- [ ] Two-envelope ordering in `hydrateVaultBlob` verified (sync-auth strip
      precedes `EncryptionEnvelope.unwrap` and the sha256 check).

### Phase 5 — Spec and docs

- [ ] Rewrite §31's threat model for the T1-active adversary; state plainly that
      T3 is out of scope, with a pointer to the proposal.
- [ ] New spec section for sync authentication (take the next available `NN`).
- [ ] Update §12 (sync), §24 (vault), §33 (credential store).
- [ ] Release-checklist entries for what CI cannot cover: cross-device
      enrollment, real-provider authenticated sync.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off. Do not open a PR until
      sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

> `make pre_commit` is scoped to `packages/kmdb`. This plan also touches
> `kmdb_cli` — run its suite explicitly.

## Reviewer feedback (2026-08-10, kmdb-plan-reviewer)

Verified against `main` (uncommitted planning state). **The cryptographic
grounding is excellent and every cited precedent checks out** — 128-bit
truncation at `encryption_provider.dart:297` (`mac.bytes.sublist(0, 16)`), the
`Hkdf(hmac: _hmacSha256, outputLength: 32).deriveKey(... info:)` sub-key pattern
at `:279-287`, the self-describing `[flag][payload]` envelope frame, and the
`DekCache` core-seam / platform-impl split (`dek_cache.dart`). The
independent-key rationale, the sync-set-identity-with-key bootstrap (matches the
verified `$meta`-syncs LWW-collision hazard), the path-binding, the per-class
`info` labels, and the **no-tolerated-fallback** stance are all sound. The T1
*integrity* goal is genuinely met for the enumerated classes.

The first review pass (2026-08-10, round 1) raised **four blockers** — three
integration-completeness gaps plus one genuine security defect in the
recovery/quarantine composition. **All four, plus the scope split, were resolved
in round 2** (see "Design decisions (resolved 2026-08-10, round 2)" and the
checked "Open questions"). The analysis below is retained as the rationale record;
read it alongside the round-2 resolutions.

### Q1 — [BLOCKER, security] Advancing the HWM on a *MAC failure* hands the T1 attacker a permanent sync-wedging primitive

Phase 4 mandates "the HWM must still advance past a rejected artefact" and frames
sync-auth rejection as *composing* with the A3 quarantine (`sync_engine.dart`
`pull`, `:575-638`). For a **MAC failure this is exactly backwards** and it
defeats the plan's own availability goal.

A3's advance-HWM is safe **only because it runs after the footer checksum, on a
file assumed to originate from a real peer** — i.e. `info.maxHlc`, parsed from
the *filename* (`:628`, `hwm.withPeer(B, info.maxHlc)`), is trustworthy. Under
T1 the filename is **attacker-controlled**, and peer device IDs are not secret
(they are visible in every existing filename in the sync folder the attacker can
read). Concretely:

1. Attacker uploads `sstables/{peerB}-ffffffffffff-ffff-...-.sst` with garbage
   body and no valid MAC (`peerB` = a real peer's device id, HLC = max).
2. Victim `pull()`: not own, not local, `SstableInfo.parse` succeeds,
   `maxHlc = max`, current `peers[B] < max` so **not skipped**, downloads,
   MAC verify **fails**.
3. Under the plan's rule → `rejected = true`, `peerMaxHlc[B] = max`,
   `hwm.withPeer(B, max)` persisted.
4. Forever after, every *genuine* B SSTable has `info.maxHlc <= peers[B]`
   (`:546`) → **skipped**. The victim never ingests peer B's real data again,
   from one unauthenticated file.

So the residual capability sync-auth *should* leave the attacker (waste
bandwidth on garbage that fails the MAC) is instead upgraded to a **permanent,
single-file denial of a peer's entire data stream** — an availability attack
under the precise threat model this plan exists to close.

**The correct composition is order-dependent and must be spelled out:**
- **Verify the MAC first.** On **MAC failure**, the filename (hence `maxHlc`) is
  adversarial → **do NOT advance the shared/peer HWM off it.** Skip the file
  (`continue`, like the `StaleSstableIngestException` branch at `:621`) and, to
  avoid re-downloading it every cycle, record it in a **local** skip-list —
  reuse the A3 quarantine log (a `$$`-namespace record keyed by filename, per
  `[[reference_quarantine_reporting_seams]]`), which is local and cannot be
  poisoned into suppressing real data.
- **MAC pass but ingest fails** (authentic-but-corrupt) → the *existing* A3
  behaviour is correct: the filename is now authenticated, so advancing the HWM
  past `info.maxHlc` is safe.

Decide and document this split, and add a Phase 5 test: a MAC-failed file naming
a real peer with a huge `maxHlc` must **not** suppress that peer's subsequent
genuine SSTables.

### Q2 — [BLOCKER, integration] The envelope injection *mechanism* is unspecified, and the "Integration points" list is incomplete

The plan says "`upload()` writes `[magic][mac][bytes]`; `download()` verifies and
strips" but never says **where** that logic lives. `SyncStorageAdapter` has **8+
implementations** (`memory_sync_adapter`, `local_directory_adapter`,
`cloud_semantics_adapter`, `shared_backend_adapter`, `gated_sync_adapter`,
`google_drive_adapter`, `icloud_adapter`, `partitionable_adapter`, plus test
doubles). Editing `upload`/`download` in each is fragile — one missed
implementation is a silent downgrade. This is an architecture decision an
implementer must not have to invent.

**Recommendation:** specify a single `SyncStorageAdapter` **decorator** in core
that wraps any inner adapter and is constructed at the wiring point (the
`QuotaAwareAdapter`/`GatedSyncAdapter` decorator pattern is the precedent). It
must also handle:
- **`compareAndSwap`** (lease writes at `consolidation_coordinator.dart:391/411`)
  — the `newBytes` must be enveloped before delegation.
- **`getEtag`** — delegate; the etag is over the *stored (enveloped)* object,
  which is exactly what CAS compares, so this stays consistent.
- **`list`** — delegate unchanged; filenames are not enveloped. This is what
  keeps `SstableInfo.parse` on listings unaffected (the plan's Edge-case claim is
  correct **because** `list` is out of band — state that explicitly).

Independently, the "Integration points" enumeration names only `SyncEngine.push`
/`pull` and the three vault methods. It **omits real call sites** that read/write
authenticated artefacts:
- **`ConsolidationCoordinator`**: peer-SSTable download (`:483`) and
  consolidated-output upload (`:544`) — if download does not strip, `SstableReader.open`
  fails on staged bytes; if upload does not envelope, the consolidated file is
  **unauthenticated** (a downgrade). Lease download (`:371`, `:721`) and lease
  CAS-write (`:391`, `:411`).
- **`HighwaterMark.load`/`save`** (`sync/highwater.dart:88` / `:179`) — the HWM
  envelope sites, also reached from `_checkAndHandleEviction` (`:360`) and
  `_fullResync`.
- **`SyncEngine._fullResync`** SSTable download (`:454`): a *second* ingest path
  that today only `continue`s on corruption and has **no** auth-rejection
  handling. Under the decorator it strips/verifies automatically, but the
  rejection semantics here (and their interaction with Q1) must be stated.

A decorator resolves all of these uniformly — which is the strongest argument for
naming it explicitly.

### Q3 — [BLOCKER, integration] Vault artefacts do **not** go through `SyncStorageAdapter`; they use raw `dart:io File` I/O, so the "envelope in upload()/download()" mechanism cannot reach them

`LocalDirectoryVaultAdapter` (`vault/local_directory_vault_adapter.dart`) talks to
the remote side with **`File(...).writeAsBytes` / `readAsBytes` directly**, not
`SyncStorageAdapter`. The Q2 decorator will therefore **not** authenticate any
vault artefact. `SyncAuthenticator.mac`/`verify` must be threaded **manually** at
six sites, and this is a distinct integration from the channel envelope:
- `uploadVaultObject`: manifest write (`:139`), blob write (`:151`), tombstone
  write (`:164`).
- `syncVaultMetadata`: manifest read (`:188`), tombstone read (`:203`).
- `hydrateVaultBlob`: blob read (`:230`).

Two specifics the plan must pin:
- **Ordering in `hydrateVaultBlob`.** There are *two nested envelopes* with
  different lifetimes. The sync-auth envelope is a channel property (stripped on
  arrival); the `EncryptionEnvelope` is stored-at-rest (the staged bytes at
  `:250-258` are deliberately "still envelope-wrapped" — that is the *encryption*
  envelope). Correct order: read remote blob → **strip + verify sync-auth
  envelope** → `EncryptionEnvelope.unwrap` (`:240`) → sha256 check (`:245`) →
  stage the still-`EncryptionEnvelope`-wrapped bytes → rename (`:264`). The
  plan's one-line "strip before the rename" is directionally right but
  under-specifies this stack.
- **`tombstone.json` is a forgeable, deletion-triggering artefact and is not one
  of the five named classes.** A forged/suppressed tombstone drives vault GC.
  Assign it an explicit sub-key `info` label (e.g. `kmdb-sync-auth-vault-tombstone`
  → **six** classes, not five) or justify folding it under `vault-manifest`. The
  blob itself is self-authenticating by sha256, so the envelope's real added
  value here is manifest + tombstone authenticity — worth stating.

Also: `LocalDirectoryVaultAdapter`'s constructor must receive the
`SyncAuthenticator` — a constructor-signature change to note.

### Q4 — [BLOCKER, web] The web `SyncAuthenticator` is hand-waved on two points the plan's own "realisable, not hand-waved" bar requires

Non-extractable WebCrypto `CryptoKey` for `mac`/`verify` + HKDF `deriveKey` is
realisable. But:
- **`remote pair show` is impossible for a web-originated key.** A
  non-extractable key cannot be exported, so a web device that *generated* its
  root key can never print a pairing code. Web can only ever be the *importing*
  device. State this asymmetry as a documented constraint (acceptable for a
  re-provisionable key) — or the UX is under-defined.
- **Persistence across sessions is unspecified.** `SecretStore` is bypassed and
  `DekCache`'s doc says web does not persist. A non-extractable `CryptoKey` is
  structured-cloneable into **IndexedDB** even while non-extractable — that is
  the realisable answer and should be named. Otherwise the web key is lost every
  session and every launch requires re-enrollment.

### Scope — split Phase 1 out

At six phases spanning a new crypto subsystem, a breaking sync-artefact format, a
`kmdb_cli` pairing UX, and spec, this is too much to hold at `Investigated` as one
unit. **Phase 1 (`SecretStore`) is cleanly separable and low-risk**: it is a
refactor of the already-reviewed `DirectoryCredentialStore` behind a new
interface, plus `credentials prune`, touching mostly `kmdb_cli`. It has no
dependency on the crypto core and closes review **C-1** on its own. Landing it as
a precursor plan lets the security core (Phases 2–5) be reviewed, implemented, and
fault-injection-tested in isolation, which is where the risk actually lives.
Recommend splitting Phase 1 into `plan_0_10_01_secret_store.md`.

### Smaller notes (address in-plane, not blockers)

- Phase 5 lists golden-path-ish rejection tests but no **fault-injection** case
  (per CLAUDE.md / the 2026-05-22 review): forge against a `FaultyStorageAdapter`,
  and cover the Q1 HWM-poisoning regression explicitly.
- Confirm `open()` on a synced-but-unenrolled database (R-4 says local-only is
  fine) — the *diagnostics-only* path for "remote configured, no key yet" needs a
  test asserting `push`/`pull` raise `SyncAuthException`, not a crash.

## Open questions

All resolved 2026-08-10 (round 2) — see "Design decisions (resolved 2026-08-10,
round 2)" for the recorded decisions and code verification.

- [x] **Q1** MAC-failure vs ingest-failure HWM composition: verify first;
      MAC-fail ⇒ A3 log under new `QuarantineReason.unauthenticated` + pre-download
      skip via a new `KvStore.quarantinedFilenames()` accessor, **no** peer-HWM
      advance; ingest-fail ⇒ A3 advance retained. Peer-suppression regression
      added to Phase 4.
- [x] **Q2** Envelope injection = one core `SyncStorageAdapter` decorator
      (upload/download/compareAndSwap/getEtag/list; per-site rejection policy
      table). Integration extended to `ConsolidationCoordinator` (SSTable + lease),
      `HighwaterMark.load`/`save`, and `_fullResync`.
- [x] **Q3** Vault manual threading at six File I/O sites; `tombstone.json` is the
      sixth artefact class (`kmdb-sync-auth-vault-tombstone`); two-envelope
      ordering in `hydrateVaultBlob`; constructor gains the authenticator.
- [x] **Q4** Web import-only now (non-extractable `CryptoKey` in IndexedDB);
      extractability-policy seam + `remote pair show` gated on extractable key,
      as a documented, not-yet-implemented forward-compat point.
- [x] **Scope** Phase 1 (`SecretStore`) split into `plan_0_10_01_secret_store.md`;
      this plan trimmed to the crypto core with a Prerequisites dependency note.

## Summary

_To be completed when the work is done._
