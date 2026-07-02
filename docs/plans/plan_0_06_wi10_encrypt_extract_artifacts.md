# WI-10: Encrypt `extract/` Filesystem Artifacts

**Status**: Investigated

**PR link**: —

## Problem statement

When database encryption is enabled (§31), `VaultStore` encrypts vault blob
bytes at rest before writing them to disk. However, the derived artifacts
written by the vault search indexer (WI-3, `VaultSearchManager`) into each
blob's `extract/` subdirectory are written as plaintext regardless of the
database's encryption state:

- `extract/text.txt` — the full UTF-8 extracted text of the blob
- `extract/chunks_v1.json` — chunk byte-offset metadata
- `extract/vectors_{modelId}_sq8.bin` — SQ8-quantised embedding vectors

`text.txt` in particular is a significant information leak: it contains the
complete extracted plaintext of a blob whose ciphertext on disk is otherwise
opaque, entirely defeating blob encryption for any indexed document. This gap
is explicitly documented in §31 ("Known gaps and unprotected surfaces", gap
#6) and tracked as roadmap work item WI-10, dependent on WI-3 (vault search
core), which shipped in PR #52. WI-10 is therefore now unblocked.

This plan encrypts those filesystem artifacts using the database's DEK
(AES-256-GCM via the existing `EncryptionProvider`), consistent with the
pattern `VaultStore` already uses for blob bytes. When encryption is not
configured, artifacts remain plaintext, preserving today's behaviour.

**Correction to the roadmap's stated scope.** The roadmap entry and §31 gap #6
both describe **four** artifacts, including `extract_status.json`. Investigation
(below) confirms the shipped WI-3 implementation does **not** write this file —
extraction status is persisted only to the `$$vault:extract:{sha256}` KV entry.
This plan scopes encryption to the **three** artifacts that actually exist on
disk and corrects the stale documentation (roadmap, proposal, §31, §32) rather
than introducing a file nobody reads.

**Explicitly out of scope.** The `$$vault:fts:`, `$$vault:vec:`, and
`$$vault:extract:` KV *values* are also unencrypted today — they are written
via raw `cbor.encode()`, not `ValueCodec.encode(encryption:)` — but that is a
different defect (the same class as `$$fts:`/`$$vec:` in `FtsManager`/
`VecManager`) already tracked as v0.08 Gap 1 (`docs/roadmap/0_08.md`), whose
wording was updated ahead of this plan (2026-07-02) to confirm the finding.
This plan does not touch KV-value encoding; see the Investigation section for
why.

## Open questions

- [x] **Q1 — Confirm scope boundary (filesystem artifacts only, not
      `extract_status.json`, not KV values). (RESOLVED — 2026-07-02, review
      round 1: verified against the code, no `writeFile` call ever writes
      `extract_status.json`.)** Investigation confirms
      `extract_status.json` is never written as a file (see Investigation §
      "Current state") and that `$$vault:*` KV values are a separate,
      already-tracked defect (v0.08 Gap 1, wording already corrected
      2026-07-02 to confirm the vault namespaces share it). Recommendation:
      proceed with the three-file scope described above; correct the stale
      "four files" framing in the roadmap/proposal/§31 rather than
      implementing a phantom debug file.
- [x] **Q2 — Per-file self-describing encryption flag (RESOLVED — 2026-07-02,
      review round 1).** The blob-encryption pattern (`VaultStore`) relies on
      `manifest.json`'s `encrypted: bool` field to know whether to decrypt —
      but `extract/` files have no manifest, and encryption can be toggled on
      for a database that already has plaintext `extract/` artifacts from
      before the toggle (per the roadmap's stated transition behaviour, old
      artifacts stay plaintext until `reindexVault()` re-processes them). A
      global `encryption != null` gate is therefore unsafe — it would try to
      AES-GCM-decrypt a genuinely plaintext file. Decision: prefix each of the
      three artifact files with the existing `EncryptionFlag` enum's byte
      (`lib/src/encryption/encryption_flag.dart` — `EncryptionFlag.none.byte`
      (`0x00`) for plaintext, `EncryptionFlag.aesGcm.byte` (`0x01`) followed by
      `nonce(12B) || ciphertext || tag(16B)`), parsed on read via
      `EncryptionFlag.fromByte()`. **Correction (review round 1): reuse the
      existing enum rather than hand-coding `0x00`/`0x01` literals** — per
      CLAUDE.md's primitive-reuse requirement, and because `EncryptionFlag`
      already encodes exactly this byte semantics for the `ValueCodec` wire
      format. This makes every file independently readable regardless of the
      current database encryption state or when it was written, and note the
      corollary: `EncryptionFlag.fromByte()` throws `ArgumentError` (not
      `FormatException`) on an unrecognised byte — see Q-B2 note below and the
      corrected Design/edge-case table/Step 1 tests.
- [x] **Q3 — Decrypt-failure behaviour. (RESOLVED — 2026-07-02, review round
      1: confirmed against the code — the recovery catch site is already
      `catch (_)`, no widening needed.)** Two read call sites need a policy:
      (a) startup recovery (`_recoverExtractingBlob`) — a decrypt failure is
      treated identically to today's "filesystem write/read error" handling,
      i.e. reset the blob to `pending` and re-queue for full re-extraction
      (self-healing, no crash) — the existing handler at
      `vault_search_manager.dart:728` is a bare `catch (_)` and already covers
      this; (b) `searchVault()` snippet retrieval — the `EncryptionError`
      propagates out of `searchVault()` rather than silently dropping the hit
      or returning an empty snippet. A wrong-DEK scenario cannot reach this
      code path (the DEK is validated once at `KmdbDatabase.open()`), so a
      decrypt failure here indicates genuine on-disk corruption the caller
      should learn about, not a routine condition to mask.
- [x] **Q4 — Where do the encrypt/decrypt helpers live? (RESOLVED — 2026-07-02,
      review round 1).** As two methods on `VaultSearchManager`
      (`readExtractArtifact` / `writeExtractArtifact`, not underscore-prefixed
      so a sibling file can call them), not a new standalone wrapper class.
      `VaultSearchManager` already holds the `EncryptionProvider?` (currently
      unused — see Investigation) and already owns every write call site.
      **Correction (review round 1): `VaultSearcher` does *not* already hold a
      `manager` reference.** Its constructor destructures the `manager:`
      argument into three separate fields
      (`_kvStore = manager.kvStore`, `_vaultStore = manager.vaultStore`,
      `_embeddingModel = manager.embeddingModel`, `vault_searcher.dart:83-85`)
      and discards the reference itself; `VaultSearchManager` exposes
      `kvStore`/`vaultStore`/`embeddingModel` getters but no `encryption`
      getter, so there is no existing seam. **Decision: add a fourth field,
      `final VaultSearchManager _manager;`, to `VaultSearcher`, and route reads
      through `_manager.readExtractArtifact(path)`.** This keeps the
      `EncryptionProvider` fully encapsulated inside `VaultSearchManager` (no
      new getter needed) and follows the same "hold what you need, discard the
      rest" pattern already used for the other three fields — the only change
      is that this one field is the manager object itself rather than one of
      its members. Dart privacy is per-*file*, not per-directory, so
      `VaultSearchManager`'s `_encryption` field could never be read directly
      from `vault_searcher.dart` regardless of directory — the manager-owned
      method remains the correct seam, just reached via an explicit field
      rather than an already-existing one.

## Investigation

### Current state

**`EncryptionProvider` (§31, `lib/src/encryption/encryption_provider.dart`).**
Whole-buffer, in-memory API:

```dart
Future<Uint8List> encrypt(Uint8List plaintext);  // -> nonce(12B) || ciphertext || tag(16B)
Future<Uint8List> decrypt(Uint8List ciphertext);
```

`AesGcmEncryptionProvider` is the concrete implementation: AES-256-GCM, 256-bit
DEK, fresh random 96-bit nonce per call, 128-bit tag. `decrypt()` throws
`EncryptionError(EncryptionErrorCode.badCredentials)` on GCM authentication
failure and `EncryptionError(EncryptionErrorCode.decryptionFailed)` for other
failures — both implement `Exception` and propagate normally.

**The pattern to mirror — `VaultStore.ingest()`/`getBytes()`
(`lib/src/vault/vault_store.dart:200-351`).** SHA-256/CRC32C are computed over
plaintext first (preserves dedup); then, if `encryption != null`,
`storedBytes = await enc.encrypt(bytes)`; the `manifest.json` gains
`encrypted: bool` so `getBytes()` knows whether to decrypt on read, throwing
`StateError` if the manifest says encrypted but no provider is configured.
This plan cannot reuse the manifest-flag mechanism directly (no manifest per
artifact) — hence Q2's per-file flag byte, which achieves the same
self-describing property without a side-channel file.

**`VaultSearchManager` already has the hook, unused.** The constructor accepts
`EncryptionProvider? encryption` (`vault_search_manager.dart:104`), stored as
`final EncryptionProvider? _encryption` (`:121`) with the doc comment *"Kept
for potential future use (e.g. per-entry encryption in docref)."* It is never
read anywhere in the class today. `KmdbDatabase.open()`
(`kmdb_database.dart:469-475`) already threads the live `encryption` provider
into the constructor call — **no wiring changes are needed above
`VaultSearchManager`**; this is a self-contained change to the manager, the
searcher, and their tests.

**Exact write call sites — all in `_processNextItem`
(`vault_search_manager.dart:438-615`), on the main isolate:**

| Artifact | Format | Write site |
| --- | --- | --- |
| `extract/text.txt` | UTF-8 bytes of extracted text | `:540-543` |
| `extract/chunks_v1.json` | UTF-8 JSON array `[{index,byteStart,byteEnd,wordCount}]` | `:559-562` |
| `extract/vectors_{safeModelId}_sq8.bin` | packed SQ8, `chunks × dims` bytes | `:574` (only when `embeddings.isNotEmpty`) |

All three go through `_vaultStore.adapter.writeFile(path, bytes)`, where
`adapter` is the plain `StorageAdapter`
(`lib/src/engine/platform/storage_adapter_interface.dart`) — whole-file,
non-streaming (`readFile`/`writeFile`; there is a `readFileRange` on the
interface but nothing in vault search uses it today, so whole-file encryption
introduces no regression).

**Exact read call sites needing decryption:**

- **Recovery** (`_recoverExtractingBlob`, `:623-750`): `chunks_v1.json`
  (`:647`), `text.txt` (`:654`), `vectors_*.bin` reload branch (`:674`, only
  taken when the file exists — the alternate branch re-embeds from `text.txt`
  instead of reading the vector file). Runs on the main isolate, after the
  encryption bootstrap has already run (recovery is invoked from
  `KmdbDatabase.open()` after `VaultSearchManager` construction, which is
  itself after the encryption bootstrap per §31's stated ordering), so
  `_encryption` is populated correctly by the time recovery runs.
- **Query** (`vault_searcher.dart`): `_loadChunkWordCounts` (`:369-390`,
  reads `chunks_v1.json` for BM25 length normalisation) and the snippet
  builder (`:593-644`, reads `chunks_v1.json` + `text.txt`).

**No other read/write sites exist.** Confirmed by grepping for the three
filenames across `packages/` outside `test/`: only `vault_gc.dart` (doc
comment + directory deletion, no file I/O), `vault_store.dart` (doc comment
on `deleteExtractDir`), `vault_chunker.dart`/`vault_chunk.dart`/
`vault_extraction_state.dart` (constants/doc comments), and the two files
above. `VaultGc.sweep()` only deletes the `extract/` directory
(`store.deleteExtractDir(sha256)`, `vault_gc.dart:248`) — no read, so no
change needed there. KVLT export/import (`vault_package.dart`) does not
reference `extract/` at all — it packages only `blob` + `manifest.json`, so
no change needed there either (the `extract/` directory is a per-device
rebuildable cache and correctly excluded from portable archives).

**The `extract_status.json` file does not exist.** Grepping
`extract_status.json` across `lib/` finds only doc comments (`vault_gc.dart`,
`vault_store.dart`, `vault_extraction_state.dart`) — no `writeFile` call
writes it. Status is persisted **solely** to the `$$vault:extract:{sha256}` KV
entry via `_writeExtractStatusToKv`/`_writeExtractStatusToBatch`
(`vault_search_manager.dart:771-791`), which calls
`VaultExtractionState.encode()` — confirmed to be **bare CBOR**
(`vault_extraction_state.dart:236`, `cbor.encode(_mapToCbor(toMap()))`,
doc comment: *"Uses bare CBOR (no `ValueCodec` wrapper) consistent with the
other vault [namespaces]"*), **not** `ValueCodec.encode(encryption:)`. This
confirms the KV-value gap described below and rules out the "already encrypted
via ValueCodec" assumption that might otherwise justify skipping it — it is
simply out of scope for *this* plan (filesystem artifacts), not already
solved.

**§32 (`docs/spec/32_vault_search.md:52-76`) and §24
(`docs/spec/24_vault.md:532-553`) both describe `extract_status.json` as a
real "secondary human-readable copy" file.** This is stale relative to the
shipped implementation and should be corrected alongside this plan's spec
updates (Step 7 below) regardless of the encryption work, since an
implementer or operator reading §32 today would go looking for a file that
was never written.

**The adjacent KV-value gap (out of scope, but flag it).** `VaultBm25Writer`
(`vault_bm25_writer.dart:174-182`, doc comment: *"...these are internal index
entries that never need compression or encryption at this layer..."*) and
(by the same pattern) `VaultVecWriter` write `$$vault:fts:`/`$$vault:vec:`
values via raw `cbor.encode()`, not `ValueCodec.encode(encryption:)`. This
is the exact defect already tracked as **v0.08 Gap 1**
(`docs/roadmap/0_08.md:16-40`), which explicitly anticipated this risk for
vault search ("The same audit confirmed that `$vfts:`/`$vvec:idx` entries...
will have the same problem unless they are written through
`ValueCodec.encode(encryption:)` from the start... verify it is correctly
implemented"). That verification now has a definitive answer: **it was not
implemented**, for `$$vault:fts:`, `$$vault:vec:`, and `$$vault:extract:`
alike. `docs/roadmap/0_08.md` was already corrected to record that finding
(2026-07-02, ahead of this plan's implementation) — see Step 6. This plan
does not fix the KV-value encoding itself — that is a distinct, larger change
(affects `FtsManager`/`VecManager` too) with its own roadmap item and should
not be bundled into a plan titled "filesystem artifacts."

### Design

**Wire format** (each of the three artifact files), reusing the existing
`EncryptionFlag` enum (`lib/src/encryption/encryption_flag.dart`):

```
[EncryptionFlag.none.byte (0x00)]
  → plaintext body follows verbatim (today's format, byte-identical)
[EncryptionFlag.aesGcm.byte (0x01)]
  → nonce(12B) || AES-256-GCM ciphertext || tag(16B) follows
      (i.e. exactly the output of EncryptionProvider.encrypt(plaintext))
```

This mirrors §31's existing `[EncryptionFlag][...]` convention for the
`ValueCodec` wire format, applied here to whole files instead of KV values —
using the *same enum*, not a re-hand-coded copy of its byte values. Any other
flag byte is rejected by `EncryptionFlag.fromByte()`, which throws
`ArgumentError` — the same posture `ValueCodec`/`CompressionFlag` already use
for an unrecognised flag, so this plan follows that precedent rather than
introducing a `FormatException` for the same condition.

**Write path.** `VaultSearchManager` gains:

```dart
Future<void> writeExtractArtifact(String path, Uint8List plaintext) async {
  final enc = _encryption;
  final Uint8List payload;
  if (enc != null) {
    final ciphertext = await enc.encrypt(plaintext);
    payload = Uint8List(1 + ciphertext.length)
      ..[0] = EncryptionFlag.aesGcm.byte
      ..setAll(1, ciphertext);
  } else {
    payload = Uint8List(1 + plaintext.length)
      ..[0] = EncryptionFlag.none.byte
      ..setAll(1, plaintext);
  }
  await _vaultStore.adapter.writeFile(path, payload);
}
```

The three write call sites in `_processNextItem` (`:540`, `:559`, `:574`)
switch from `_vaultStore.adapter.writeFile(path, bytes)` to
`writeExtractArtifact(path, bytes)`.

**Read path.**

```dart
Future<Uint8List> readExtractArtifact(String path) async {
  final raw = await _vaultStore.adapter.readFile(path);
  if (raw.isEmpty) {
    throw FormatException('Extract artifact at "$path" is empty');
  }
  final flag = EncryptionFlag.fromByte(raw[0]); // throws ArgumentError on unknown byte
  final body = Uint8List.sublistView(raw, 1);
  switch (flag) {
    case EncryptionFlag.none:
      return body;
    case EncryptionFlag.aesGcm:
      final enc = _encryption;
      if (enc == null) {
        throw StateError(
          'Extract artifact at "$path" is encrypted but no EncryptionProvider '
          'is configured. Open the database with an EncryptionConfig.',
        );
      }
      return enc.decrypt(body);
  }
}
```

Note these files are read/written whole-file only — an encrypted artifact
cannot be range-read (AES-GCM requires the whole ciphertext for authentication
before any plaintext is released). Say so explicitly in the doc comment so a
future optimisation isn't tempted to add `readFileRange` support on top of
this format, since nothing in vault search uses ranged reads today anyway.

- The three recovery read sites (`_recoverExtractingBlob:647,654,674`) switch
  to `readExtractArtifact`. Per Q3(a), a thrown `EncryptionError`/
  `FormatException`/`ArgumentError` here is already caught by the existing
  surrounding handler (`vault_search_manager.dart:728`, a bare `catch (_)`) —
  **no catch-widening is required**, this already falls back to `pending`.
- `VaultSearcher`'s two read sites (`:380`, `:613`, `:629`) switch from
  `adapter.readFile(path)` to `_manager.readExtractArtifact(path)`, using a
  new `final VaultSearchManager _manager;` field added to `VaultSearcher`
  specifically for this (see Q4 — the class does not already hold one). Per
  Q3(b), no additional try/catch is added here — the exception propagates out
  of `searchVault()`.

**Toggle-on transition — no extra code needed.** Because the flag byte is
self-describing per file, the existing `reindexVault()` mechanism (which
resets blobs to `pending` and re-runs `_processNextItem`) is sufficient to
transition a blob's artifacts from plaintext (`0x00`) to encrypted (`0x01`):
once encryption is provisioned and the affected blobs are reindexed, the next
`_processNextItem` write naturally produces `0x01` files. Old, un-reindexed
blobs keep their `0x00` files and remain readable by
`readExtractArtifact` without any migration step. This is exactly the
transition behaviour the roadmap entry specifies.

**Isolate boundary — unaffected.** The `VaultIndexingIsolate` still receives
only plaintext blob bytes and returns plaintext extraction results
(`VaultIndexResult`); it never sees the `EncryptionProvider` or the DEK. All
new encrypt/decrypt calls happen on the main isolate, immediately before
`writeFile`/after `readFile`, identical in spirit to how `VaultStore.getBytes`
already decrypts blob bytes on the main isolate before handing them to the
isolate (RQ-5 from the WI-3 plan). No isolate-related code changes.

### Edge cases and failure scenarios for tests

| Scenario | Expected behaviour |
| --- | --- |
| Encryption off, full lifecycle | Files carry `0x00` flag; byte-identical to pre-WI-10 behaviour |
| Encryption on, full lifecycle | Files carry `0x01` flag; round-trip via `readExtractArtifact` returns original plaintext |
| Encryption on, blob indexed, DB closed and reopened | Recovery/query paths decrypt correctly with the re-derived DEK |
| Encryption provisioned on a DB with pre-existing plaintext `extract/` files | Old files remain `0x00` and readable; new/reindexed blobs write `0x01`; both coexist and are individually correct |
| `reindexVault()` after encryption toggle-on | Reindexed blob's artifacts transition from `0x00` to `0x01` |
| Crash mid-write of an encrypted artifact (`FaultyStorageAdapter`, each of the three write points) | Startup recovery detects incomplete artifacts (existing `fileExists` check in `_recoverExtractingBlob`) and resets to `pending` — unchanged from today's crash-recovery behaviour, now exercised with encryption on |
| Corrupted/truncated encrypted artifact on disk | `readExtractArtifact` throws (`EncryptionError.badCredentials` from a bad GCM tag, or `FormatException` for a too-short buffer); recovery path resets to `pending`; query path propagates the error out of `searchVault()` |
| Unknown flag byte (e.g. future format version) | `EncryptionFlag.fromByte()` throws `ArgumentError`, same handling as corruption |
| Database opened without an `EncryptionConfig` but files carry `0x01` (DB previously encrypted, config removed) | `readExtractArtifact` throws `StateError` — mirrors `VaultStore.getBytes()`'s existing behaviour for encrypted blobs with no provider |

### Spec impact

- **§31** (`docs/spec/31_encryption.md`): update gap #6 ("Vault `extract/`
  filesystem artifacts will be plaintext") to reflect that it is now
  addressed for `text.txt`/`chunks_v1.json`/`vectors_*.bin`, correct the
  "four files" framing to three, and add the toggle-on transition behaviour.
  Update the "Vault Encryption" section or add a new subsection documenting
  the per-file `EncryptionFlag` convention for `extract/` artifacts (distinct
  from — but modelled on — the `ValueCodec` wire format).
- **§32** (`docs/spec/32_vault_search.md:52-76`): correct the filesystem
  layout diagram and the "Filesystem Artifacts" prose to remove
  `extract_status.json` (does not exist) and document the encryption flag
  byte format for the three real files, with a cross-reference to §31.
- **§24** (`docs/spec/24_vault.md:532-553`): same `extract_status.json`
  correction in the "Vault Search Integration" directory-tree diagram.
- **`docs/roadmap/0_06.md`**: update the WI-10 row and the WI-10 section text
  to reflect the three-artifact scope and mark status per the implementation
  outcome.
- **`docs/roadmap/0_08.md`** Gap 1: **already updated** (2026-07-02, ahead of
  this plan) to confirm that `$$vault:fts:`/`$$vault:vec:`/`$$vault:extract:`
  share the unencrypted-KV-value defect. No further edit needed — see Step 6.
- **`docs/proposals/vault_search.md`**: proposals are historical/frozen
  exploration documents (per `docs/plans/README.md` intent) — no edit
  required, but the plan's Investigation section here supersedes its
  `extract_status.json` design for anyone consulting it later.
- **Doc comments**: `vault_extraction_state.dart:81` and any other doc
  comment referencing `extract/extract_status.json` as a file should be
  corrected to describe the KV-only reality.
- **`docs/spec/28_release_checklist.md`**: RC-21 ("Vault search isolate crash
  recovery") already covers process-kill-at-each-write-step testing; its
  description should be updated to note the write/read steps now include
  encryption, so the real-OS verification also exercises encrypted artifacts.
  No new RC entry is required if RC-21's scope note is broadened, since the
  crash points didn't change — only what's written at them did.

## Implementation plan

**Step 1 — Encrypt/decrypt helpers on `VaultSearchManager`:**

- [ ] Add `Future<void> writeExtractArtifact(String path, Uint8List plaintext)`
      and `Future<Uint8List> readExtractArtifact(String path)` to
      `vault_search_manager.dart`, implementing the flag-byte wire format from
      the Design section using the existing `EncryptionFlag` enum (import
      `lib/src/encryption/encryption_flag.dart`) — do not hand-roll `0x00`/
      `0x01` literals. Add doc comments describing the wire format, that reads
      are whole-file only (no `readFileRange` support), and cross-referencing
      §31.
- [ ] Write unit tests in `test/vault/search/vault_search_manager_test.dart`
      (or a new `vault_extract_artifact_codec_test.dart`) covering: plaintext
      round-trip (`EncryptionFlag.none`), encrypted round-trip
      (`EncryptionFlag.aesGcm`), empty file (`FormatException`), corrupted
      ciphertext (`EncryptionError.badCredentials`, bad GCM tag), unknown flag
      byte (`ArgumentError` via `EncryptionFlag.fromByte()`), encrypted file
      read with no provider configured (`StateError`).

**Step 2 — Wire the write path:**

- [ ] In `_processNextItem`, replace the three `_vaultStore.adapter.writeFile`
      calls (`:540`, `:559`, `:574`) with `writeExtractArtifact`.
- [ ] Update/extend existing crash-injection tests in
      `vault_search_manager_test.dart` (using `FaultyStorageAdapter`) to run
      with encryption configured, confirming the existing crash-recovery
      behaviour (reset to `pending` on incomplete artifacts) is unaffected
      when the artifacts being written are encrypted.

**Step 3 — Wire the recovery read path:**

- [ ] In `_recoverExtractingBlob`, replace the three
      `_vaultStore.adapter.readFile` calls (`:647`, `:654`, `:674`) with
      `readExtractArtifact`.
- [ ] Confirm the surrounding try/catch (`:646-751`) correctly falls back to
      `pending` for `EncryptionError`/`FormatException`/`StateError` raised by
      `readExtractArtifact`, in addition to the I/O errors it already
      handles. Widen the catch clause if needed.
- [ ] Add a recovery test: write an encrypted artifact, corrupt it, restart
      recovery, assert the blob resets to `pending` rather than crashing
      `KmdbDatabase.open()`.

**Step 4 — Wire `VaultSearcher`'s read path:**

- [ ] Add a `final VaultSearchManager _manager;` field to `VaultSearcher`,
      set from the constructor's `manager` argument (alongside the existing
      `_kvStore`/`_vaultStore`/`_embeddingModel` destructuring at
      `vault_searcher.dart:83-85` — `VaultSearcher` does not already hold a
      `manager` reference; see Q4).
- [ ] In `vault_searcher.dart`, replace the `adapter.readFile` calls at
      `:380`, `:613`, `:629` with `_manager.readExtractArtifact(path)`.
- [ ] Add tests in `vault_searcher_test.dart` covering: `searchVault()`
      against an encrypted database returns correct snippets and BM25 scores
      (i.e. the length-normalisation read at `:380` also works encrypted);
      `searchVault()` against a corrupted encrypted artifact propagates the
      decryption error rather than silently dropping the hit (per Q3(b)).

**Step 5 — Toggle-on / mixed-state integration test:**

- [ ] Add a test (new file `test/vault/search/vault_extract_encryption_test.dart`
      or extend `vault_search_manager_test.dart`): ingest and index a blob
      with no encryption configured (`EncryptionFlag.none` artifacts); reopen
      the database with a freshly provisioned `EncryptionConfig`; ingest and
      index a second blob (`EncryptionFlag.aesGcm` artifacts); assert both
      blobs' `searchVault()` results are correct simultaneously; call
      `reindexVault()`; assert the first blob's artifacts are now
      `EncryptionFlag.aesGcm` and still correct.

**Step 6 — Spec and documentation corrections:**

- [ ] Update `docs/spec/31_encryption.md`: gap #6 text (three files, not
      four; describe the flag-byte format and toggle-on behaviour as
      resolved).
- [ ] Update `docs/spec/32_vault_search.md:52-76`: remove
      `extract_status.json` from the filesystem diagram; document the
      encryption flag byte format for the three real files.
- [ ] Update `docs/spec/24_vault.md:532-553`: same `extract_status.json`
      correction in the directory-tree diagram.
- [ ] Update `docs/roadmap/0_06.md`: WI-10 row/section — scope correction and
      status.
- [ ] `docs/roadmap/0_08.md` Gap 1 — **already updated** (2026-07-02, ahead of
      implementation) to record that `$$vault:fts:`/`$$vault:vec:`/
      `$$vault:extract:` are confirmed to share the unencrypted-KV-value
      defect. Just verify the note is still present and accurate at
      implementation time; do not duplicate the edit.
- [ ] Correct doc comments referencing `extract_status.json` as a file
      (`vault_extraction_state.dart:81` and any others found by grep).
- [ ] Update RC-21 in `docs/spec/28_release_checklist.md` to note the
      crash-kill verification now also covers encrypted artifact writes.
- [ ] Run `make site` after spec edits.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new/changed files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Review (kmdb-plan-reviewer, 2026-07-02, first pass)

**Overall.** This is a strong, well-grounded plan. The problem is real and worth
solving: `extract/text.txt` is a full-plaintext leak that defeats blob
encryption for any indexed document, and the gap is a documented §31 item. The
scope is correctly narrow, the self-describing per-file flag byte (Q2) is the
right call for the toggle-on/mixed-state problem, and the Q3 failure policy
(self-heal on recovery, propagate on query) is well reasoned. The investigation
is unusually thorough and the read/write surface enumeration is complete —
verified against the code (KVLT export and `VaultGc` genuinely don't
read/write these artifacts). Most factual claims check out. However, **one
load-bearing claim is wrong** and forces an unresolved design decision, and
there is one primitive-reuse correction. These block `Investigated`.

### Verified against the code (accurate)

- **Q1 — `extract_status.json` does not exist as a file.** Confirmed. Every
  reference in `lib/` is a doc comment; no `writeFile` writes it. Status is
  persisted solely to `$$vault:extract:{sha256}` via
  `VaultExtractionState.encode()` = bare CBOR (`vault_extraction_state.dart:236`).
  The three-artifact scope correction is correct, and the stale §32 (lines 65,
  74) / §24 (line 547) file references are real and worth fixing.
- **`_encryption` is a genuinely-unused hook.** Set at construction
  (`vault_search_manager.dart:121`), read nowhere. Constructor already receives
  the live provider from `KmdbDatabase.open()` (`kmdb_database.dart:469-475`).
  No wiring above the manager is needed. Correct.
- **Write call sites** `:540/559/574` and **recovery read sites** `:647/654/674`
  match the code exactly.
- **Q3(a) — recovery self-heal needs no catch-widening.** The surrounding
  handler at `vault_search_manager.dart:728` is `catch (_)`, which already
  catches `EncryptionError`/`FormatException`/`StateError`. The plan's
  hedged "widen the catch clause if needed" (Step 3) can be firmed up: no
  widening is required. Note the recovery path also re-embeds from `textBytes`
  at `:689` — ensure `readExtractArtifact` returns *decrypted* bytes there so
  the re-embed slice is plaintext (it does, per the design).
- **Out-of-scope KV-value gap belongs to 0_08 Gap 1.** Confirmed against the
  just-updated `docs/roadmap/0_08.md:43-54`, which already records the
  "confirmed not implemented" finding for `$$vault:fts:`/`$$vault:vec:`/
  `$$vault:extract:` and explicitly states WI-10 does not fix it. The plan's
  Investigation is consistent with that roadmap update. Step 6's instruction to
  further edit 0_08 Gap 1 wording is now largely redundant — that edit has
  already been made; the implementer should reconcile rather than duplicate it.

### Blocking issues

- [x] **B1 — RESOLVED (2026-07-02, plan author response).** Chose option (a):
      added `final VaultSearchManager _manager;` field to `VaultSearcher` (Q4,
      Design, Step 4 updated accordingly). **Original finding:** Q4's
      `manager` field claim is factually wrong; the codec's home is
      an unresolved design decision. The plan states (Q4 line 89 and Step 4)
      that `VaultSearcher` "already holds a `manager` reference" it can call
      `readExtractArtifact` through. It does not. `VaultSearcher`'s constructor
      destructures `manager` into `_kvStore`/`_vaultStore`/`_embeddingModel` in
      its initializer list (`vault_searcher.dart:83-85`) and **discards** the
      reference; there is no `manager` field. The `manager:` at
      `kmdb_collection.dart:728` is the constructor *argument*, not a field on
      the searcher. `VaultSearchManager` exposes `kvStore`/`vaultStore`/
      `embeddingModel` getters but **no `encryption` getter**, so
      `VaultSearcher` cannot reach the codec through any existing seam. Step 4 is
      therefore unactionable as written, and the implementer would have to invent
      the plumbing — exactly the kind of design decision that must be resolved
      before `Investigated`. **Decide and specify one:** (a) add a
      `final VaultSearchManager _manager;` field to `VaultSearcher` and route
      reads through `_manager.readExtractArtifact(path)`; or (b) make the codec a
      free function / static taking an `EncryptionProvider?`, and add an
      `EncryptionProvider? get encryption` getter to `VaultSearchManager` (or
      pass it into `VaultSearcher`'s constructor like the other three fields).
      Q4's stated preference (manager-owned method) is reasonable and I'd lean
      to (a), but the plan must pick one and update Q4 + Step 4 with the correct
      mechanics, because the premise it currently rests on is false.

- [x] **B2 — RESOLVED (2026-07-02, plan author response).** Design, edge-case
      table, and Step 1 now use `EncryptionFlag.none`/`EncryptionFlag.aesGcm`/
      `EncryptionFlag.fromByte()` throughout, with `ArgumentError` (not
      `FormatException`) as the unknown-flag error, consistent across the
      whole plan. **Original finding:** reuse the existing `EncryptionFlag`
      enum; resolve the exception-type contradiction. The Design section hand-codes `0x00`/`0x01` literals and a
      bespoke `FormatException` on an unknown flag. An `EncryptionFlag` enum
      already exists (`encryption_flag.dart`) with `none(0x00)`, `aesGcm(0x01)`,
      and `fromByte()` — the exact byte semantics this plan needs. CLAUDE.md
      explicitly requires preferring existing primitives over re-rolling them
      (the 2026-05-22 review had to clean up hand-rolled CBOR parsers for this
      reason). Reuse `EncryptionFlag.fromByte()`. Note the divergence this
      forces: `EncryptionFlag.fromByte()` throws **`ArgumentError`**, but the
      plan's Design, edge-case table, and Step 1 tests all assert
      **`FormatException`** for the unknown-flag case. Pick the enum's
      `ArgumentError` (recommended, for consistency with the `ValueCodec` wire
      format the plan explicitly models itself on) and update the design text,
      the edge-case table ("Unknown flag byte" row), and the Step 1 test
      expectation accordingly. The empty-file case can stay a `FormatException`
      (or a `StateError`) — just make the plan internally consistent.

### Non-blocking notes

- **Step 6 / 0_08 edit is stale.** As above, the 0_08 Gap 1 wording update the
  plan asks for has already landed. Downgrade Step 6's 0_08 bullet to "verify
  0_08 Gap 1 already records the confirmed-not-implemented finding; no edit if
  so" to avoid a duplicate/conflicting edit.
- **RC-21 scope-broadening (not a new RC).** Agreed — the crash points are
  unchanged, only the bytes written at them differ, so broadening RC-21's scope
  note rather than adding a new entry is correct. Good judgement.
- **`readFileRange` note.** The plan correctly observes nothing in vault search
  uses `readFileRange` today, so whole-file encryption introduces no regression.
  Worth keeping the doc comment on `readExtractArtifact` explicit that these
  files are now whole-file-only (an encrypted artifact cannot be range-read),
  in case a future optimisation is tempted to add ranged reads over a
  now-encrypted file.

### Path to Investigated

Resolve **B1** (choose and specify the codec's home + the `VaultSearcher`
plumbing) and **B2** (reuse `EncryptionFlag`, fix the exception-type
contradiction across design/table/tests). Reconcile the stale Step 6 0_08 bullet.
Once B1 and B2 are settled in the plan text — no new investigation is required,
both are self-contained decisions — this clears the implementation-readiness bar
and can move to `Investigated`.

## Review (kmdb-plan-reviewer, 2026-07-02, second pass — sign-off)

**Status set to `Investigated`.** Both blocking issues from the first pass are
resolved in the plan text, verified directly against the file and the source —
not taken on the author's word.

**B1 (VaultSearcher manager reference) — confirmed fixed.** Q4 (lines 97-121),
the Design read-path bullet (lines 326-328), and Step 4 (lines 446-450) are now
mutually consistent on the decision: add a **new** `final VaultSearchManager
_manager;` field to `VaultSearcher` and route reads through
`_manager.readExtractArtifact(path)`. Step 4's checklist orders the field
addition before the call-site rewiring, so the plumbing exists before it is
used. Grepping `VaultSearcher`/`_manager`/`manager` across the whole file found
no stale claim that the searcher "already holds a manager reference" outside the
`[x] RESOLVED` B1 history entry, which correctly quotes the original (now
superseded) finding. Verified the underlying code fact: `VaultSearcher`'s
constructor still destructures `manager` into `_kvStore`/`_vaultStore`/
`_embeddingModel` and keeps no manager field, so the new field is genuinely
required.

**B2 (EncryptionFlag reuse + exception type) — confirmed fixed.** The Design
code blocks use `EncryptionFlag.none.byte`/`EncryptionFlag.aesGcm.byte` on write
and `EncryptionFlag.fromByte()` + an enum `switch` on read; no hand-rolled byte
literals remain in code (the surviving `0x00`/`0x01` occurrences are all
annotations on the enum members or prose shorthand for "the 0x00/0x01 file").
The unknown-flag error is now `ArgumentError` in every relevant place — the
"Unknown flag byte" edge-case row (line 362) and the Step 1 test list (line 418)
— matching the real `EncryptionFlag.fromByte()`, which I confirmed throws
`ArgumentError.value` on an unrecognised byte (`encryption_flag.dart:61-67`).
The remaining `FormatException` references are all the empty/too-short-buffer
case, which the first pass explicitly permitted to stay a `FormatException`;
they are internally consistent across Design (line 295), the edge-case table
(line 361), and Step 1 (line 416).

**Non-blocking residue (does not gate implementation):**

- Step 3's "Widen the catch clause if needed" (line 439) is a leftover hedge;
  Q3(a) and the Design bullet (lines 321-324) already state definitively that no
  widening is required (`vault_search_manager.dart:728` is a bare `catch (_)`).
  The implementer has the correct instruction from the definitive statements;
  worth tightening opportunistically.
- The Design bullet (line 326) and Step 4 (line 452) say "two read sites" while
  enumerating three line numbers (`:380`, `:613`, `:629`) — "two" refers to the
  two read *methods* (`_loadChunkWordCounts` + the snippet builder), consistent
  with the Investigation (lines 187-189). The explicit line numbers remove any
  ambiguity for the implementer.

Both notes are cosmetic and self-resolving from context; neither forces a design
decision. No open questions remain and the plan clears the implementation-
readiness bar. Ready for the **`kmdb-plan-implement`** agent.

**Addendum (independent re-check) — RESOLVED (2026-07-02).** The "Spec impact"
section's `docs/roadmap/0_08.md` bullet has been tightened to match Step 6:
it now reads "already updated ... no further edit needed" instead of the
stale "append a note ..." phrasing. No remaining inconsistency.

## Summary

{To be completed after implementation.}
