# Authenticate sync artefacts against an untrusted provider (T1)

**Status**: Open

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

## Open questions

- [ ] **Envelope byte layout** — magic value, version byte, MAC length, ordering.
- [ ] **MAC algorithm and length.** HMAC-SHA256 truncated to 128 bits (matching
      the existing `indexToken` precedent), or full 256?
- [ ] **Does the MAC cover the remote path as well as the bytes?** It should —
      otherwise an attacker relocates a valid artefact to a different path,
      which is E-2's attack one level up. Confirm and specify.
- [ ] **HKDF `info` label per artefact class** (SSTable / vault blob / vault
      manifest / HWM / lease) so a MAC valid for one class cannot be replayed as
      another.
- [ ] **CLI surface.** Command names for showing and importing a pairing code,
      output format, `--help` placement.
- [ ] **Key length, generation source** (`Random.secure` vs
      `package:cryptography`), and at-rest encoding.
- [ ] **What happens to a remote configured before this lands?** Per R-5 the
      answer is "wipe the sync root and re-push" — confirm, and specify the
      diagnostic that tells the user so.
- [ ] **`providesAtomicCas = false` adapters** skip consolidation; does lease
      authentication interact with that path at all?

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

### Phase 1 — `SecretStore`

- [ ] Byte-oriented interface in core: `read` / `write` / `delete` / `list`.
- [ ] `DirectorySecretStore` with a **configurable root**, defaulting to
      `%APPDATA%\kmdb` (Windows) and `~/.config/kmdb` (POSIX). A configurable
      root also covers systemd `$CREDENTIALS_DIRECTORY` and container secret
      mounts with the same code.
- [ ] Carry over the existing POSIX permission model unchanged.
- [ ] Windows now genuinely inherits profile ACLs — closes review **C-1**.
- [ ] Refactor `kmdb_cli`'s credential storage onto the interface. **No
      migration**: developers re-run `remote add` once.
- [ ] `kmdb credentials prune` for orphaned entries.

### Phase 2 — `SyncAuthenticator`

- [ ] `Future<Uint8List> mac(Uint8List)` / `Future<bool> verify(...)` in core.
      **Not** get-key shaped — that would foreclose WebCrypto non-extractable
      keys, StrongBox, and Secure Enclave.
- [ ] Default implementation: root key from `SecretStore`, per-artefact-class
      sub-keys via HKDF with distinct `info` labels.
- [ ] Web implementation backed by a non-extractable `CryptoKey`.

### Phase 3 — Key lifecycle and enrollment

- [ ] Generate the sync-set key and identity at `remote add`.
- [ ] Pairing code: base32 + checksum, carrying key and sync-set identity.
- [ ] CLI commands to display and import a pairing code.
- [ ] Clear diagnostics when a remote has no key, pointing at enrollment.

### Phase 4 — Envelope

- [ ] Apply on upload / verify and strip on download for SSTables, vault blobs,
      vault manifests, HWM files, and the lease.
- [ ] Reject unauthenticated or badly-authenticated artefacts. **No
      tolerated-fallback mode** — an "accept unauthenticated for now" switch is
      a downgrade attack.
- [ ] Ensure rejection is *recoverable*: the HWM must still advance past a
      rejected artefact so a single bad file cannot wedge sync forever (this is
      the S-1 lesson).

### Phase 5 — Tests

- [ ] Forged artefact rejected, per artefact class.
- [ ] Cross-class replay rejected (a valid SSTable MAC replayed onto a lease).
- [ ] Path-relocation rejected, if the MAC covers the path.
- [ ] Enrollment round-trip across two simulated devices.
- [ ] Key survives `new-device-id`.
- [ ] **Recovery:** after a rejected artefact, the next `pull()` succeeds.
- [ ] Local-only database opens fine without a key; `push` refuses clearly.

### Phase 6 — Spec and docs

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

## Summary

_To be completed when the work is done._
