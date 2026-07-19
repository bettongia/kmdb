# Harden the sync trust boundary: validate untrusted input

**Status**: Investigated

> **Scope narrowed 2026-07-19** following the plan review. Authentication (T1)
> and value AAD (E-2) moved to sibling plans — see "Plan split" below. This plan
> is now **validation and robustness only**, and every finding in it is worth
> fixing regardless of how the threat model lands.

**PR link**: _(none yet)_

> **Provenance.** This plan implements Groups **A**, **B**, and **C** of the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md)
> (§10), under the [0.10.01 hardening track](../roadmap/0_10_01.md). The review
> is the authoritative record of the findings; this plan does not restate their
> evidence, only what to do about them.
>
> **This plan does not close the review.** W1 (spec conformance) and W4
> (concurrency/durability) were never executed — see the review's §9 and the
> callback in the roadmap. Completing this plan is a prerequisite for the rest
> of the track, not the end of it.

## Problem statement

KMDB treats everything inside the sync folder as trustworthy **because it is in
the sync folder**. SSTables, vault blobs, vault manifests, and consolidation
leases are parsed, obeyed, and acted upon as though this codebase wrote them.

That assumption is coherent under the threat model `docs/spec/31_encryption.md`
actually documents — a provider who *reads* your data — and indefensible under
the model `0.1.0` is committing to, in which the provider or a compromised
account can also *write*. The realistic threat is not the provider turning evil;
it is **a phished account or a stolen OAuth token**, against which neither
full-disk encryption nor the provider's own at-rest encryption offers anything.

Five critical findings follow from this one assumption:

| Finding | Effect today |
| :--- | :--- |
| **S-1** | Crafted SSTable length/offset fields abort `SyncEngine.pull()` **permanently** — the HWM never advances, so the poisoned file is re-fetched every cycle. `OutOfMemoryError` on the native adapter. |
| **S-2** | A Zstd frame declares its own decompressed size; ~32,000× amplification measured, no cap anywhere. Detonates on read, rendering a collection permanently unreadable. |
| **S-4** | The content-addressable vault never verifies content against its address, and the `encrypted` flag gating decryption is itself attacker-supplied. |
| **S-6** | `commit()` deletes every path named in an unauthenticated lease, using the victim's own credentials — a confused deputy. |
| **E-2** | AES-GCM with no AAD: ciphertext is not bound to its key, namespace, or version. |

The tests cannot catch any of this, and the reason is structural: **every parser
test feeds the parser well-formed output this codebase produced**, and
`MemoryStorageAdapter` bounds-checks `readFileRange` where
`StorageAdapterNative` does not — so the sync tests, which run on memory, hide
the most severe failures. The one negative test uploads 64 bytes of `0xAB`,
exercising the single path that is already handled correctly.

## Goals

1. **Validate** every length, offset, and size read from a file before use.
2. **Verify** vault blob content against its content address.
3. **Bound** decompression and extraction so untrusted input cannot exhaust
   memory or hang a close.
4. Make the test suite **structurally capable** of catching this class.

> Authenticating sync artefacts (T1) is the sibling
> [plan_0_10_01_sync_authentication.md](plan_0_10_01_sync_authentication.md).
> The two are complementary: authentication stops a forged artefact being
> *accepted*; this plan stops a malformed one *doing damage*. Neither replaces
> the other — a legitimately-authenticated peer can still upload a file this
> codebase mis-parses.

## Non-goals

- **T3 (malicious peer).** Deferred to
  [proposals/device_identity.md](../proposals/device_identity.md).
- **Extracting `betto_secret_store`.** This plan ships a KMDB-local
  implementation behind an interface; extraction is
  [its own proposal](../proposals/betto_secret_store.md).
- **Making encryption mandatory.** Encryption stays optional and orthogonal.
- **Any migration or backward-compatibility path.** See below.

> ### No migration path — decided 2026-07-19
>
> **KMDB has never been released.** There is no published package, no stable
> tag, and therefore no user who can hold a compatibility expectation. This
> plan makes **breaking format and protocol changes freely** and ships **no**
> migration code:
>
> - Sync authentication is **required from the outset** — there is no window in
>   which unauthenticated artefacts are tolerated, and no downgrade path an
>   attacker could exploit.
> - The AAD format change simply changes the format. Databases written before it
>   are not readable after it, and that is acceptable.
> - Credentials are **not** migrated out of `{dbDir}/local/`; developers re-run
>   `remote add` once.
> - **Existing sync folders are not migrated either (R-5).** Once artefacts are
>   authenticated, everything already in a sync root is unverifiable — there is
>   no key it was ever MAC'd under. The operation is therefore **"wipe the sync
>   root and re-push from one device"**, not "re-run `remote add`". This is a
>   materially bigger ask than the credential case and must be stated plainly in
>   the release notes and the sibling authentication plan.
>
> This is the same standing position recorded in the
> [2026-06-05 roadmap review](../reviews/roadmap-review-2026-06-05.md):
> *"Format decisions can be made for correctness and simplicity rather than
> compatibility."* It will never be cheaper to make these changes than now —
> which is a positive argument for doing the AAD work **before** `0.1.0`, not
> merely a licence to skip migration code.
>
> The one thing this does **not** licence: silently misreading old data. A
> database in an older format must fail to open with a clear diagnostic, never
> decode garbage — so any change to the layout must bump the format version too.
> That obligation now falls on
> [plan_0_10_01_value_aad.md](plan_0_10_01_value_aad.md), which owns the format
> change; this plan makes no format changes of its own.

## Open questions

All resolved in design discussion 2026-07-19; recorded here so the
`kmdb-plan-reviewer` can audit the reasoning rather than re-litigate it.

- [x] **Close the T1 gap before `0.1.0`, or narrow the documented claim?**
      → **Close it, scoped to T1.** T3 is designed and deferred.
- [x] **Derive the MAC key from the DEK, or use an independent key?**
      → **Independent.** A DEK-derived MAC would force encryption on as a
      prerequisite for authentication. Since KMDB-level encryption is marginal
      for a user with full-disk encryption and a reputable provider, that trades
      a low-value requirement for a high-value guarantee. It would also be
      thrown away when T3 lands, whereas an independent key with device
      enrollment is a down payment on that work.
- [x] **Does a separate key cost the same provisioning UX as encryption?**
      → **No**, and this was the decisive point. Lose the DEK and your data is
      gone forever — hence passphrase, recovery code, careful recovery. Lose the
      sync-auth key and you **re-provision it**; the data is untouched. A
      re-provisionable secret can be auto-generated, needs no passphrase, and
      has no catastrophic-loss path.
- [x] **Where does the sync-auth key live?**
      → A **controlled location** we own (`%APPDATA%\kmdb`, `~/.config/kmdb`),
      not `{dbDir}/local/`. This is what makes the `gcloud` precedent actually
      hold: profile-ACL inheritance is guaranteed only when *we* own the path
      (review C-1). Bonus: copying a DB directory no longer carries its secrets,
      so a copied instance must be explicitly enrolled.
- [x] **Keyed by `deviceId` or database identity?**
      → **Database identity.** `deviceId` is unstable by design — `new-device-id`
      exists specifically to support copy-pasting a DB directory — and the
      sync-auth key is a property of the *sync set*, so it must survive
      regeneration.
- [x] **Interface shape: get-key or sign/verify?**
      → **`SecretStore` is byte-oriented; `SyncAuthenticator` sits above it.**
      Most keychains (Credential Manager, Secret Service, Security.framework)
      allow readback, so forcing every backend to implement `mac()`/`verify()`
      burdens the common case. The exceptions — WebCrypto non-extractable keys,
      StrongBox, Secure Enclave — are handled by a `SyncAuthenticator`
      implementation that bypasses `SecretStore` entirely.

### Raised by review 2026-07-19 — all resolved 2026-07-19

- [x] **Q-A — Where does the MAC live on the wire?** (R-1)
      → **Transport envelope.** `upload()` writes `[magic][mac][bytes]`;
      `download()` verifies and strips. Authenticity is a property of the *sync
      channel*, not the file format — SSTables are immutable and locally
      identical across devices. Generalises cleanly to HWM and lease files
      (already JSON blobs through the same adapter) and keeps Phase 1's parser
      hardening independent of authentication.
      **Now in [plan_0_10_01_sync_authentication.md](plan_0_10_01_sync_authentication.md).**
- [x] **Q-B — What identity keys the sync-auth secret?** (R-3)
      → **A sync-set identity minted with the remote**, carried in the pairing
      payload — *not* a database identity minted at `init`. The reviewer's
      objection is correct and was verified: `isLocalOnly(r'$meta')` is `false`
      (documented in `namespace_codec.dart`) and `DeviceId` persists there, so
      two independently-minted identities LWW-collide on first pull. Delivering
      the identity *with* the key removes the ordering problem entirely.
      **Supersedes the earlier "keyed by database identity" answer above.**
- [x] **Q-C — Key scope, minting point, enrollment surface?** (R-2)
      → **One key per remote**, minted at `remote add`. The key protects a sync
      folder's contents and each remote is a folder; a database syncing to both
      Drive and a NAS holds two independent keys. Minting at `remote add` rather
      than `init` avoids creating keys for databases that never sync.
      The pairing code carries **the key itself**, base32-encoded with a
      checksum — a PAKE would be over-engineering for a re-provisionable secret
      whose loss costs nothing.
      **Now in [plan_0_10_01_sync_authentication.md](plan_0_10_01_sync_authentication.md).**
- [x] **Q-D — How does AAD reach `ValueCodec`?** (R-7)
      → **A required `ValueContext` parameter.** `encode`/`decode` already take
      an optional named `encryption:`, so the shape is identical — but the
      context must be **required**, not optional: an omitted optional parameter
      silently produces unbound ciphertext, which is precisely the E-2 bug.
      Required makes the compiler enumerate all call sites. Cases with no natural
      context get explicit constructors (`ValueContext.meta(name)`,
      `.version(key, hlc)`, `.vaultBlob(sha256)`) so "no binding" is a deliberate
      choice rather than an omission.
      **Now in [plan_0_10_01_value_aad.md](plan_0_10_01_value_aad.md).**
- [x] **Q-E — Split the plan?** (R-11)
      → **Yes, into three** — one more than the reviewer proposed, because
      Phase 7 (AAD) depends on neither the secret store nor the authenticator
      (it uses the existing DEK) and is the breaking format change that most
      wants to land early. Bundling it with sync authentication would block it
      behind enrollment UX it does not need. See "Plan split" below.
- [x] **Q-F — Maximum decoded-value size?** (R-6)
      → **Derived from §02, not invented.** The target workload profile
      documents an average document of 1–4 KB with a **64 KB upper bound**, and a
      working set of 1–8 MB (50 MB upper). A **1 MiB** decoded-value cap gives
      16× headroom over the documented maximum while stopping a 256 MB bomb
      dead. Configurable via `KvStoreConfig`. **Vault blobs get a separate,
      much larger, configurable bound** — they are attachments and a 50 MB PDF is
      legitimate.
- [x] **Q-G — Where does `SecretStore` live?** (R-9)
      → **Mirror `DekCache` exactly**: the interface lives in core `kmdb`,
      concrete implementations live outside it. `kmdb_cli` keeps its directory
      store, refactored to implement the interface; `kmdb_flutter` supplies a
      `flutter_secure_storage` + `path_provider` implementation for mobile.
      This resolves the `~/.config/kmdb`-is-wrong-on-mobile problem structurally
      — **core never chooses a path; the host does.**
      **Now in [plan_0_10_01_sync_authentication.md](plan_0_10_01_sync_authentication.md).**

## Plan split — 2026-07-19

Following Q-E, this document is now **the hardening plan only**. Phases 5–7 were
moved out:

| Plan | Scope | Status |
| :--- | :--- | :--- |
| **This plan** | Parser hardening, decompression bounds, vault integrity, isolate lifecycle, lease validation, tests, spec (Phases 1–4, 3b, 8, 9) | Investigated |
| [plan_0_10_01_value_aad.md](plan_0_10_01_value_aad.md) | E-2 — bind ciphertext to its context (was Phase 7) | Open |
| [plan_0_10_01_sync_authentication.md](plan_0_10_01_sync_authentication.md) | T1 — secret store + authenticated sync (was Phases 5–6) | Open |

The three are independent and may proceed in parallel. **This plan's findings
are worth fixing regardless of how the threat model lands** — corruption, buggy
peers, and malformed PDFs exist without any attacker.

## Investigation

### Existing seams to reuse

- **`DekCache`** (`lib/src/encryption/dek_cache.dart`) is the precedent:
  a pure-Dart seam in core, `InMemoryDekCache` by default, and
  `FlutterSecureDekCache` supplied by `kmdb_flutter`. Its doc comment states the
  architecture — *"concrete platform-backed implementations live outside the
  `kmdb` package"*. `SyncAuthenticator` follows the same shape.
- **HKDF sub-key derivation** already exists in
  `AesGcmEncryptionProvider._indexTokenSubKey` (an `info`-labelled
  `Hkdf.deriveKey`). The same pattern derives per-purpose sub-keys from the
  sync-auth root key.
- **`ManifestReader`** (`lib/src/engine/manifest/manifest_reader.dart`) is the
  reference for correct parsing: validate the declared length against the
  remaining buffer *before* slicing, verify the checksum *before* decoding.
  The SSTable reader should be brought up to this standard, not a new one.

### Key files

| Area | File |
| :--- | :--- |
| SSTable parsing (S-1) | `lib/src/engine/sstable/sstable_reader.dart` |
| Varint sign bug (S-1) | `lib/src/engine/util/varint.dart` |
| Native allocation (S-1) | `lib/src/engine/platform/storage_adapter_native.dart` |
| Ingest catches (S-1) | `lib/src/sync/sync_engine.dart`, `lib/src/engine/kvstore/lsm_engine.dart` |
| Decompression cap (S-2) | `betto_zstd` (separate repo), `lib/src/encoding/value_codec.dart` |
| Vault verification (S-4) | `lib/src/vault/vault_store.dart`, `lib/src/vault/local_directory_vault_adapter.dart` |
| Lease validation (S-6) | `lib/src/sync/consolidation_coordinator.dart` |
| AAD (E-2) | `lib/src/encryption/encryption_provider.dart` |
| Credential store | `packages/kmdb_cli/lib/src/config/credential_store/` |

### Edge cases the implementer must handle

- **`Varint.decode` returns negative values.** At `shift == 63`,
  `(byte & 0x7F) << 63` sets the sign bit; the guard is `shift >= 64`. Every
  caller treats the result as a length. The same sign-overflow class exists in
  `_ByteReader.readUint64` (S-3).
- **`OutOfMemoryError` is an `Error`, not an `Exception`.** `on Exception`
  catches will not see it — this is why `ingestAt0`'s `firstKey()` guard fails to
  honour its own doc comment.
- **`ingestSstable` writes attacker bytes to local `sst/` *before* validation.**
  Validation must move earlier, or the file must be written to quarantine first.
- **Compaction never decodes values** (verified) — only keys. A size cap must
  therefore not assume compaction will surface a bad value.
- **A database that predates this work has no sync-auth key.** Per the
  no-migration decision it is **not** upgraded — but the failure must be scoped
  correctly (**R-4**): **sync operations refuse; `open()` must still succeed.**
  An earlier draft of this plan said such a database must fail to *open*, which
  contradicted the track's own decision to keep authentication decoupled from
  local use. A local-only database has no sync-auth key by definition and is
  perfectly valid. Only `push`/`pull` may refuse, with a diagnostic pointing at
  enrollment — and never with a tolerated-fallback path, which would be a
  downgrade attack in waiting.
- **`providesAtomicCas = false` adapters** skip consolidation entirely; lease
  validation must not assume the lease path is always exercised.

## Implementation plan

### Phase 1 — Parser hardening (S-1, S-3)

- [ ] Validate every `SstableFooter` field on parse: offsets and sizes
      non-negative, and `offset + size <= fileSize`. Reject with
      `CorruptedSstableException`.
- [ ] Bounds-check `keyLen`, `blockOffset`, `blockSize` in `_parseIndex` against
      the enclosing buffer before use.
- [ ] Bounds-check `shared`, `unsharedLen`, `valueLen` in `_decodeBlock`; cap
      `shared` at `currentKey.length` **before** it sizes the allocation.
- [ ] `Varint.decode`: reject values that do not fit a non-negative 64-bit int.
- [ ] `_ByteReader.readUint64`: reject negative/absurd lengths (S-3).
- [ ] Wrap the whole SSTable parse so any structural failure surfaces as
      `CorruptedSstableException` — callers already handle that type.
- [ ] Bound `readFileRange` allocations by actual file size in
      `StorageAdapterNative`.
- [ ] Broaden `SyncEngine.pull()` and `LsmEngine.ingestAt0` catches to match what
      can actually be thrown; quarantine a bad peer file rather than letting it
      re-poison every subsequent pull.
- [ ] Apply the same to `ConsolidationCoordinator`'s `SstableReader.open`
      (second affected call site).

### Phase 2 — Decompression bounds (S-2)

- [ ] Add a `maxDecompressedSize` parameter to `ZstdSimple.decompress` in
      `betto_zstd`; reject frames whose **declared** size exceeds it *before*
      allocating, and reject negative declared sizes explicitly.
- [ ] Enforce a maximum decoded-value size in `ValueCodec`; surface a violation
      as `CorruptedSstableException` on the ingest path.
- [ ] Handle a decode failure **per document** on the read path so one poisoned
      value cannot abort a whole collection scan.
- [ ] Apply the same bound to vault blob extraction.
- [ ] `betto_zstd` requires its own release; coordinate with the Group D gate.

### Phase 3 — Vault integrity (S-4)

- [ ] Hash blob bytes on hydration; reject if the digest ≠ the requested address.
- [ ] Verify on read for blobs that arrived via sync.
- [ ] Stop trusting the synced manifest's `encrypted` flag — take it from a
      local record, or infer it from the ciphertext envelope.
- [ ] Document `crc32c` as a corruption check only, never an integrity control.

### Phase 3b — Indexing-isolate lifecycle (D-1) — *added 2026-07-19 from W4*

W4 (executed after this plan was drafted) found that a dead vault-indexing
isolate hangs `KmdbDatabase.close()` **before** `_cache.close(flush: flush)`, so
the memtable is never flushed. S-2 and S-8 supply the trigger — an unbounded
extraction OOMs, or PDFium segfaults on a malformed blob — which is why this
belongs in *this* plan rather than the smaller-independents group.

- [ ] Pass `onError:` / `onExit:` ports to `Isolate.spawn`; complete the
      in-flight completer with an error when either fires.
- [ ] Add a timeout to `VaultIndexingIsolate.sendWork`. Indexing is best-effort;
      no blob is worth blocking a close.
- [ ] Bound `shutdown()` — drain in-flight work, but abandon after a deadline
      and kill the isolate.
- [ ] **Reorder `KmdbDatabase.close()` so the flush is not sequenced behind
      best-effort index work**, or isolate the vault-search close so a hang
      cannot reach the durability path. Derived indexes are rebuildable; the
      memtable is not. *This is the load-bearing fix — the others reduce the
      likelihood, this one removes the data-durability consequence.*
- [ ] Test: kill the isolate mid-work, assert `close()` still returns and the
      flush still happens.

### Phase 4 — Lease validation and staging (S-6, S-7)

- [ ] Validate every `inputFiles` entry with `SstableInfo.parse` before use;
      reject the whole lease if any entry fails.
- [ ] Reject entries containing a path separator or `..`; join via a helper that
      refuses to escape `sstablesDir`.
- [ ] Cross-check each named input against the device's own listing of
      `sstables/` before deleting it.
- [ ] Log deletion failures instead of discarding them.
- [ ] Replace `/tmp/kmdb-consolidation-{filename}` with an adapter-derived,
      unique-per-run staging directory, cleaned up in a `finally`. Fixes Windows.

### Phase 8 — Tests (the point of the exercise, not an afterthought)

- [ ] Build a corpus of **checksum-valid, structurally hostile** SSTables:
      out-of-range footer fields, negative offsets, oversized index `keyLen`,
      huge `shared`, and decompression bombs.
- [ ] Regression tests reproducing the review's confirmed probes (PROBE 1–3,
      PEER-A/B).
- [ ] **Run the sync tests against `StorageAdapterNative`, not only
      `MemoryStorageAdapter`.** Without this the most severe form of S-1 stays
      invisible.
- [ ] Vault substitution test: swap blob bytes, assert rejection.
- [ ] Malicious-lease test: `..` entries, non-SSTable names, assert no deletion.
- [ ] AAD relocation test: move a valid ciphertext to another key, assert
      authentication failure.
- [ ] Sync-auth tests: forged artefact rejected; enrollment round-trip; key
      survives `new-device-id`.

### Phase 9 — Spec and docs

- [ ] Rewrite §31's "Threat Model" for the T1-active adversary; state plainly
      what is and is not covered, and that T3 is out of scope with a pointer to
      the proposal.
- [ ] New spec section for sync authentication (take the next available `NN`).
- [ ] Update §12 (sync), §24 (vault), §33 (credential store).
- [ ] Add release-checklist entries for anything untestable in CI (cross-device
      enrollment, real-provider authenticated sync).
- [ ] Update `CLAUDE.md` if the package layout changes.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

> **Note:** `make pre_commit` is scoped to `packages/kmdb` only. This plan
> touches `kmdb_cli` and `betto_zstd` as well — run those suites explicitly.

## Plan review — 2026-07-19 (`kmdb-plan-reviewer`)

**Verdict: `Questions`.** The diagnosis is right, the settled decisions are
sound, and Phases 1–4 are close to executable. **Phase 6 is not a plan, it is a
heading** — three load-bearing design decisions are missing, and an implementer
would have to invent a wire format to proceed. Phase 7 is materially larger than
its two checklist lines suggest. Recommendation is to **split** (R-11).

### Problem statement assessment

Strong, and unusually well-grounded. The single-root-cause framing ("sync-folder
content is input, not truth") is correct and does real work — it explains why
five findings cluster, and it justifies one coordinated plan over four. The
provenance discipline (pointing at the review rather than restating it) is right.

The **no-migration block is correct and consistently applied** — with one gap, R-5.
Its final paragraph ("must fail with a clear diagnostic, never decode garbage")
is the right guard and matches the RC-22 precedent from the 0.08 format break.

### Audit of the answered open questions

I agree with all six, and two are better reasoned than I expected:

- **Independent MAC key over DEK-derived** — correct, and the "would be thrown
  away when T3 lands" argument is the strongest one. `SyncAuthenticator` as
  `mac()`/`verify()` genuinely does survive the switch to per-device signatures.
- **Re-provisionable secret ≠ DEK provisioning cost** — this is the decisive
  observation and it is right. It is what makes "no passphrase, no recovery code"
  defensible rather than sloppy.
- **Controlled location over `{dbDir}/local/`** — correct, and it closes C-1
  properly rather than papering over it. The "copying a DB no longer carries its
  secrets" bonus is real.
- **Byte-oriented `SecretStore`** — agreed; matches the `DekCache` precedent and
  the proposal's §7.1 reasoning.

**One I am challenging: "keyed by database identity."** The reasoning about
`deviceId` instability is correct, but database identity does not survive
contact with the join case — see R-3. I think the right answer is a **sync-set
identity minted with the remote**, not a database identity minted at `init`.

### Blocking findings

#### R-1 🔴 Phase 6 — the MAC has nowhere to live, and the plan does not say

This is the single biggest gap. `SyncStorageAdapter` is
`upload(path, bytes)` / `download(path) -> bytes` — opaque blobs at paths
(`packages/kmdb/lib/src/sync/sync_storage_adapter.dart`). "Authenticate on
upload and verify on download" therefore has three incompatible realisations,
each with different consequences, and the plan picks none:

| Option | Consequence |
| :--- | :--- |
| **Sidecar object** (`{name}.sst.mac`) | Extra round-trip per artefact; a window where the `.sst` exists without its MAC (is that reject, or retry-later?); deleting the sidecar becomes a fresh DoS; doubles the object count in `list()` and every `list(extension: '.sst')` call site must be audited |
| **Transport envelope** (`upload` writes `[magic][mac][bytes]`) | Local file ≠ remote object, so `SyncEngine.push` at `sync_engine.dart:262` wraps and `pull` unwraps before `ingestSstable`; `hydrateVaultBlob`'s rename-into-place must strip first; `SstableInfo.parse` on remote listings unaffected |
| **In-file footer field** | Changes the SSTable format for *every* file including local-only ones; MAC must be computed at flush time, before the engine knows whether the file will ever sync; couples a sync property to the storage format |

**My recommendation: the transport envelope.** SSTables are immutable and
locally identical across devices; authenticity is a property of *the sync
channel*, not of the file. The envelope also generalises cleanly to HWM files
and the lease (which are already JSON blobs written through the same adapter),
and it keeps Phase 1's parser hardening and Phase 6 independent. But this is a
decision for the maintainer, not the implementer — **Q-A**.

Whatever is chosen, the plan must specify: the envelope/sidecar byte layout, the
MAC algorithm and length (HMAC-SHA256 truncated? full?), what exactly is covered
(bytes only, or bytes + remote path — path binding matters, or an attacker
relocates a valid artefact, which is E-2's own attack one level up), and the
HKDF `info` label per artefact class.

#### R-2 🔴 Phase 6 — key lifecycle and enrollment are unspecified

Confirmed as the user suspected. Four decisions are absent:

1. **When is the key minted?** `init` mints a key on databases that will never
   sync. `remote add` is the natural point but the CLI has multiple remotes per
   database — one key per database or per remote? First push is lazy but means
   `push` can now fail on a provisioning error.
2. **What is the enrollment surface?** "CLI surface for display and entry" is
   not a specification. Name the commands (`kmdb <db> sync-key show` /
   `sync-key import`?), the output format, and where it appears in `--help`.
3. **What does the pairing code carry?** If the key is genuinely
   re-provisionable and low-stakes, the honest answer is *the key itself*,
   base32-encoded with a checksum — a PAKE would be over-engineering for a
   secret whose loss costs nothing. Say so, and say it in the plan, because an
   implementer left to choose will either hand-roll a PAKE or ship something
   worse.
4. **What is the key?** Length, generation source (`Random.secure`?
   `package:cryptography`?), encoding at rest.

#### R-3 🔴 Phases 5+6 — the database-identity bootstrap does not close

`DeviceId.load` stores into `$meta`
(`packages/kmdb/lib/src/engine/kvstore/device_id.dart`), and `$meta` is a
**single-`$` namespace, so it syncs**. Trace the join case:

1. Device A: `init` → mints `dbIdentity = X`, key stored under `X`.
2. Device B: `init` on a fresh directory → mints `dbIdentity = Y`. It has no way
   to know it is about to join A's sync set.
3. Device B: `remote add` + first `pull` → ingests A's `$meta`, including A's
   `dbIdentity` record, which now collides with B's under LWW.

So the identity that keys the secret is decided *after* enrollment must already
have happened, and is then silently mutated by a sync. Either B's secret is
orphaned, or the record must be exempted from LWW — neither is stated.

**The cleaner model:** the sync-auth key is, by the plan's own reasoning, "a
property of the *sync set*." Make the identity a property of the sync set too —
mint a `syncSetId` when the remote is created, and have the pairing code carry
`(syncSetId, key)` together. A joining device learns both at enrollment, has no
ordering problem, and `$meta` never needs to carry it. **Q-B.**

#### R-4 🟠 Phase 6 — "opening ... must fail" over-reaches

The Investigation says a database with no sync-auth key must fail to *open*.
That contradicts the track's own decision that authentication is decoupled from
encryption and that sync is optional: a local-only database has no business
requiring a sync secret. Only **sync operations** (`push`, `pull`, `sync`,
consolidation) should refuse. Correct the wording — as written, an implementer
will put the check in `KmdbDatabase.open()`.

#### R-5 🟠 The no-migration decision misses the sync folder itself

The block covers on-disk format, AAD, and credentials. It does not cover the
thing most likely to bite: **every artefact already sitting in an existing sync
root is unauthenticated and will fail verification after this lands.** The
consequence is not "re-run `remote add` once" — it is "wipe the sync root and
re-push from one device." That is a bigger ask and it needs stating explicitly,
along with what a device does when it pulls a folder of uniformly unverifiable
files (fail loudly with a named remedy, presumably, not quarantine 400 files
one at a time).

#### R-6 🟠 Phase 2 — the value-size cap is under-specified and internally inconsistent

- "Surface a violation as `CorruptedSstableException` **on the ingest path**"
  contradicts the review's own resolved §S-2 finding that **ingest never decodes
  values** — `ingestAt0` and `CompactionJob` touch keys only. The cap fires on
  *read*. As written an implementer will look for an ingest-time decode hook
  that does not exist.
- **No number is given.** Pick one and justify it against the largest legitimate
  document.
- **Where is it configured?** `ValueCodec` is a `final class` with only static
  members and no injection seam; `KvStoreConfig` is the wrong home (it sits
  below `ValueCodec`, which is invoked *above* `KvStore`). A `static const` is
  the honest default — say so if that is the answer.
- **Vault blobs need a different, larger bound.** Bullet 4 says "apply the same
  bound to vault blob extraction" — a shared bound sized for documents will
  break legitimate large attachments, and one sized for attachments is useless
  for documents. Two bounds.
- `betto_zstd` cannot complete inside this plan: per the `betto_*` pattern it is
  a separate repo requiring its own PR, publish, and pin bump. The plan
  acknowledges the Group D gate — make it explicit that Phase 2 lands in two
  pieces and that the KMDB-side cap must degrade sanely against the currently
  published `betto_zstd`.

#### R-7 🟠 Phase 7 — AAD threading is the whole job, and it is not mentioned

`ValueCodec.encode`/`decode` are **static** and take only
`{EncryptionProvider? encryption}` — no namespace, no key, no record type. There
are **66 call sites** across `kmdb` and `kmdb_cli`. Adding AAD means a signature
change threaded through all of them. That is the actual work of Phase 7 and it
appears nowhere in the checklist.

Three specific cases that need an AAD definition and will otherwise be guessed:

- **`$meta` raw values** (`MetaStore.putRawByName`) — these have a *name*, not a
  document key. Encrypted since 0.08.
- **`$ver:` entries** — doubly encrypted: `VersionManager` calls
  `ValueCodec.encode` for the stored value *and* `VersionEntry.encode(encryption:)`
  for the wrapper. Two AAD contexts. Note `promoteVersion` decodes and re-encodes
  rather than copying ciphertext, so it is safe — but only by accident, and the
  plan should record that so nobody "optimises" it into a byte copy later.
- **Vault blobs** — no namespace, no document key. What binds them?

Also: name the version bump concretely. `MetaStore.kCurrentFormatVersion` is
currently `1`; this is `1 → 2`.

**Phase 7 has no dependency on Phases 5 or 6.** It uses the existing DEK. It
could land first, and there is an argument that it should, since it is the
breaking format change that most wants to be in before `0.1.0`.

#### R-8 🟠 Phase 3 — two alternatives offered, neither chosen

"Take it from a local record, **or** infer it from the ciphertext envelope" is a
design decision handed to the implementer. Given the `EncryptionEnvelope`
primitive that landed in the 0.08 reconciliation, **infer from the envelope** is
the right answer — it needs no new local state and cannot drift.

Separately, "verify on read for blobs **that arrived via sync**" assumes blob
provenance is recorded. It is not, as far as I can see. Either add that record
(and say where), or simply verify on every read and measure the cost — SHA-256
over a blob you were about to return anyway is not obviously expensive.

#### R-9 🟠 Phase 5 — package placement and mobile are unaddressed

- **Where does `SecretStore` live?** `SyncAuthenticator` is in core, so the
  interface must be in core. But `DirectoryCredentialStore` — the implementation
  being "carried over" — currently lives in
  `packages/kmdb_cli/lib/src/config/credential_store/`. Is it moved to core,
  reimplemented in core, or does core get only the interface with
  `DirectorySecretStore` staying in the CLI (in which case library consumers who
  sync have no default at all)? Say which, and say what happens to the existing
  `DirectoryCredentialStore` — refactored onto the new interface, or left as a
  second parallel implementation.
- **Mobile is missing entirely.** `~/.config/kmdb` is meaningless on iOS/Android
  sandboxes, and core has no `path_provider`. Either scope `DirectorySecretStore`
  to desktop explicitly and state that Flutter hosts must supply their own via
  `kmdb_flutter` (mirroring `FlutterSecureDekCache`), or address it. Silence
  will produce a default that is wrong on two platforms.
- `kmdb credentials prune` implies CLI ownership of a core concept — worth a
  sentence on where the command reads its list from.

#### R-10 🟡 Phase 8 — right intent, not yet a specification

The framing is correct and this is the most important phase. But as a checklist
it is still aspirational in the places that matter:

- **"Run the sync tests against `StorageAdapterNative`"** — the sync tests
  hardcode `MemoryStorageAdapter` in `setUp`
  (`test/sync/consolidation_coordinator_test.dart:132`, and similarly in
  `sync_engine_test.dart`, ~30 tests). Name the mechanism: parameterised group
  over a `StorageAdapter` factory, shared test body extracted to a helper, or a
  duplicated native-adapter suite. And say *which* suites — all of them, or the
  ingest paths only.
- **The hostile corpus needs a home and a shape.** Name the file (e.g.
  `test/util/hostile_sstable.dart`) and decide generator-vs-fixture. A generator
  that builds a valid SSTable, patches a named field, and recomputes the XXH64
  is the reusable artefact here — checked-in binary fixtures rot silently when
  the format changes.
- **The missing test is the important one.** Every listed test asserts
  *rejection*. The actual S-1 impact is *persistent* denial-of-sync: assert that
  after a hostile file is rejected, **the HWM advances and the next `pull()`
  succeeds**. Without that, the quarantine behaviour in Phase 1 is untested.
- No `FaultyStorageAdapter` angle, despite it being the fault-injection harness
  the 0.02.01 track built for exactly this purpose.
- Add: a test that `Varint.decode` rejects the 10-byte sign-bit case directly
  (unit-level, not only via SSTable parsing).

#### R-11 🟠 Scope and sequencing — split this plan

Answering the user's questions 2 and 3 directly:

- **Sequencing 5→6 is correct** (secret store → authenticator). **7 is
  independent of both** and is mis-grouped as a dependent phase.
- **Scope is too large.** Nine phases, three packages, one external repo, a new
  subsystem, a new user-facing UX, and a breaking format change. A Sonnet
  implementer will drift somewhere around Phase 5.

**Recommended split:**

| Plan | Phases | Character |
| :--- | :--- | :--- |
| **This plan** — *sync trust boundary: validation* | 1, 2, 3, 4, 8, 9 | Bounded, mechanical, no new concepts, fix-regardless-of-threat-model. Nearly `Investigated` once R-6 and R-8 and R-10 are closed. |
| **New** — `plan_0_10_01_sync_authentication.md` | 5, 6 (+7, or 7 standalone) | New subsystem, new secret, new UX, needs its own investigation. Currently a design cycle, not an implementation plan — which is what the review itself said about E-1. |

This also unblocks the release-critical robustness work immediately instead of
holding it behind an enrollment-UX decision.

### Smaller items

- **Phase 9** — "New spec section ... take the next available `NN`": that is
  **§34**. Name it, so the implementer does not have to check.
- **Phase 9** — release-checklist entries: the next free ID is **RC-25**.
- **Phase 1** — "Broaden `SyncEngine.pull()` and `LsmEngine.ingestAt0` catches
  to match what can actually be thrown." Enumerate them: `RangeError`,
  `StorageException`, `FormatException`, `OutOfMemoryError`. Note that catching
  `OutOfMemoryError` requires `on Error` or a bare `catch`, and that a bare
  `catch` here will also swallow `SyncCancelledException` — which the engine
  deliberately does *not* catch. That interaction is a real trap.
- **Phase 4** — "adapter-derived, unique-per-run staging directory": the review
  names the existing precedent (`hydrateVaultBlob`'s
  `stagingPath(microsecondsSinceEpoch)`). Point at it.
- **`providesAtomicCas = false`** is noted in the Investigation as an edge case
  but no phase acts on it. Phase 6 must say whether HWM/lease authentication
  applies on adapters that skip consolidation.
- **Coverage line** says ">95% on all new files" — the project floor is 90% with
  a 95% baseline. Fine, but crypto and parser code should be nearer 100%; and
  per the review's own §9 open question 4, *line* coverage on parser files is
  actively misleading. Phrase the goal as corpus coverage, not line coverage.

### What is genuinely good

Worth saying, because the gaps above are long: the Investigation's "edge cases
the implementer must handle" section is the best part of this plan and exactly
the right artefact — the `OutOfMemoryError`-is-an-`Error` note, the
`ingestSstable`-writes-before-validation note, and the compaction-never-decodes
note are each the kind of detail that turns a two-day debug into a five-minute
one. Keep that section in whichever plans result from the split.

## Summary

_To be completed when the work is done._
