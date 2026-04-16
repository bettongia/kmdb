# Vault — Content-Addressable Object Store

**Status**: Investigated

**PR link**: _pending_

**Proposal**: [docs/proposals/vault.md](../docs/proposals/vault.md)

**Spec**: [docs/spec/24_vault.md](../docs/spec/24_vault.md)

## Problem statement

kmdb currently has no mechanism for storing binary file attachments alongside
documents. Users wishing to associate a file with a record must manage that
file externally and store only a path or URL in the document — a fragile
approach that breaks deduplication, sync, and portability.

This plan implements the vault: a content-addressable binary object store that
lives in the database directory alongside the LSM store. Documents reference
vault objects via `kmdb-vault://sha256/{hex}` URIs. The vault provides
deduplication, reference-counted GC, crash-safe writes, and a first-class
distributed sync model.

## Open questions

_None — all design decisions resolved in the proposal (docs/proposals/vault.md)
and spec (docs/spec/24_vault.md)._

## Investigation

### Architecture

The vault is a standalone subsystem alongside the LSM engine. It does not go
through the KV store write path — blobs are written directly to the filesystem.
Only the reference counts (`$vault:{sha256}`) and document fields travel through
the KV store. The two are joined in the same `WriteBatch` for atomicity (§24).

### Key design decisions

- **CAS with ISS pattern:** SHA-256 primary, CRC32C secondary, byte count for
  early rejection. Two files with the same SHA-256 but different CRC32C are
  distinct; the second is rejected.
- **Immutable manifest:** `manifest.json` is written once at ingestion and never
  mutated. GC state is signalled by `tombstone.json` presence.
- **Crash-safe write ordering:** stage → verify hash → rename blob → write
  manifest → WriteBatch. See §24 crash table.
- **Stub model:** `manifest.json` present + `blob` absent = stub. Stubs always
  have a KV ref (they come from `syncVaultMetadata`). An incomplete local write
  (no KV ref) is deleted by recovery, never treated as a stub.
- **Reference counting in `$vault`:** the Query Layer intercepts every
  `put`/`delete` via `writeBatchInternal`, diffs old and new vault URIs, and
  adjusts counters in the same `WriteBatch`.
- **Tombstone GC:** when `$vault:{sha256}` reaches zero, `tombstone.json` is
  created. GC sweep deletes the hash directory on its next pass. No grace
  period.
- **Sync:** `VaultStorageAdapter` (separate from `SyncStorageAdapter`). FWW for
  `manifest.json`; `blob` is content-identical across devices.
- **Zstandard packaging:** the `kmdb_zstd` package (already in the workspace)
  is used for archive creation and extraction in `vault_package.dart`. Add
  `kmdb_zstd` as a dependency to `packages/kmdb/pubspec.yaml` in Phase 4.

### Key files to create

| Package | Action | Path |
| :------ | :----- | :--- |
| kmdb | Create | `lib/src/vault/vault_manifest.dart` |
| kmdb | Create | `lib/src/vault/vault_ref.dart` |
| kmdb | Create | `lib/src/vault/vault_store.dart` |
| kmdb | Create | `lib/src/vault/vault_gc.dart` |
| kmdb | Create | `lib/src/vault/vault_package.dart` |
| kmdb | Create | `lib/src/vault/vault_storage_adapter.dart` |
| kmdb | Create | `lib/src/vault/media_type_detector.dart` |
| kmdb | Create | `lib/src/vault/vault_recovery.dart` |
| kmdb | Modify | `lib/src/query/kmdb_collection.dart` |
| kmdb | Modify | `lib/src/query/kmdb_database.dart` |
| kmdb | Modify | `lib/src/engine/kvstore/crash_recovery.dart` |
| kmdb | Modify | `lib/kmdb.dart` |
| kmdb_cli | Create | `lib/src/commands/vault/vault_command.dart` |
| kmdb_cli | Create | `lib/src/commands/vault/vault_get_command.dart` |
| kmdb_cli | Modify | `lib/src/commands/insert_command.dart` |
| kmdb_cli | Modify | `lib/src/commands/update_command.dart` |
| kmdb_cli | Modify | `lib/src/commands/backup_command.dart` |
| kmdb_cli | Modify | `lib/src/commands/export_command.dart` |
| kmdb_cli | Modify | `lib/src/kmdb_cli.dart` |

### Edge cases

- **Deduplication on insert:** if the vault already contains the SHA-256, skip
  all file I/O and only increment the ref count in the `WriteBatch`. Verify
  CRC32C matches before skipping.
- **CRC32C collision:** same SHA-256 and size but different CRC32C — reject the
  incoming file with a descriptive error. Do not overwrite.
- **Large file write to staging:** write must be streamed in chunks; do not
  buffer the entire file in memory.
- **Recovery: blob without manifest (no KV ref):** delete hash directory. This
  is an incomplete write, not a stub.
- **Recovery: manifest without KV ref:** delete hash directory. This is an
  orphaned vault object.
- **GC: tombstone.json present but KV ref is non-zero:** this should never
  happen (the ref count and tombstone creation are in the same `WriteBatch`),
  but the GC sweep must validate the ref count before deleting.
- **Package with unreferenced vault objects:** if `document.json` does not
  reference every vault object in the package, the import must fail with a
  clear error.
- **Package missing a referenced vault object:** if `document.json` references
  a vault URI not present in the package and not already in the local vault,
  the import must fail.
- **Stub hydration with no remote configured:** `getBlob()` on a stub when no
  `VaultStorageAdapter` is set must throw a descriptive error.
- **`VAULT_OFFLINE` cleanup during GC:** when GC deletes a hash directory, the
  corresponding line must be removed from `VAULT_OFFLINE` atomically (read →
  filter → write).
- **Export/backup with stubs:** stubs are silently skipped; only locally-present
  blobs are included. The output should note how many stubs were skipped.
- **Concurrent open (single writer):** the LOCK file guarantees exclusivity.
  The vault inherits this guarantee — no separate vault lock is needed.

## Implementation plan

### Phase 1 — Core vault storage

_Foundational types and write path. No KV store integration yet._

- [ ] Create `vault_manifest.dart`: `VaultManifest` class with JSON
      serialisation/deserialisation; schema validation on read
- [ ] Create `vault_ref.dart`: `VaultRef` with eager URI format validation
      (`FormatException` on malformed input), `toString()`, `getBlob()` stub,
      `getMetadata()` stub
- [ ] Create `media_type_detector.dart`: `MediaTypeDetector` abstract interface
      with a `detect(Uint8List bytes, String? fileName) → MatchList` method
      (returns the full `MatchList` from `kmdb_mediatype`, giving callers access
      to both `bestMatch` and the prioritised `candidates` iterable); provide a
      `FreedesktopMediaTypeDetector` concrete implementation that delegates to
      `detect()` from `package:kmdb_mediatype/kmdb_mediatype.dart`. Add
      `kmdb_mediatype` as a dependency to `packages/kmdb/pubspec.yaml`.
      — When storing the detected media type in `VaultManifest`, use
        `matchList.bestMatch` as the canonical value.
      — When validating a caller-supplied media type (e.g. an explicit MIME type
        passed to `ingest()`), accept it if it appears anywhere in
        `matchList.candidates`; reject with a descriptive error only if it is
        absent from `candidates` entirely. This allows a valid subtype or
        alternative match to be used even when it is not the highest-priority
        detection result.
- [ ] Create `vault_store.dart`: `VaultStore` with:
  - `ingest(File file, String hlcTimestamp)` — full write path (stage →
    verify SHA-256 → verify CRC32C → rename → write manifest)
  - `get(String sha256)` — returns `Uint8List` or triggers hydration
  - `getManifest(String sha256)` — returns `VaultManifest`
  - `exists(String sha256)` — checks local hash directory
  - `isHydrated(String sha256)` — checks blob presence
  - Path resolution helpers (`hashDir`, `blobPath`, `manifestPath`,
    `tombstonePath`, `stagingPath`)
- [ ] Create `vault_recovery.dart`: staging sweep + hash directory sweep
      (see §24 crash table); returns a `VaultRecoveryResult`
- [ ] Add vault recovery call to `crash_recovery.dart` after the existing
      LSM recovery (step 9)
- [ ] Write tests:
  - `vault_manifest_test.dart` — serialisation, validation, round-trip
  - `vault_ref_test.dart` — valid URIs, malformed URIs, toString
  - `vault_store_test.dart` — ingest (new file, duplicate, CRC32C clash),
    get, exists, isHydrated
  - `vault_recovery_test.dart` — each crash scenario from the §24 table

### Phase 2 — Reference counting & GC

_`$vault` namespace integration and tombstone-based GC._

- [ ] Add `$vault` system namespace constant alongside existing `$meta`,
      `$index`, `$cache` constants
- [ ] Create `vault_gc.dart`: `VaultGc` with:
  - `onZeroRefs(String sha256)` — creates `tombstone.json`
  - `onRefRestored(String sha256)` — deletes `tombstone.json`
  - `sweep()` — scans for `tombstone.json` files, verifies KV ref count is
    still zero, deletes hash directory, cleans `VAULT_OFFLINE`
- [ ] Write tests:
  - `vault_gc_test.dart` — zero-ref tombstoning, un-tombstoning, sweep
    (including the guard: tombstone present but ref count restored before sweep)

### Phase 3 — Query Layer integration

_Write interception, `VaultRef` in codec pipeline._

- [ ] Modify `kmdb_collection.dart` `writeBatchInternal`:
  - After encoding the document, scan the map for `VaultRef` values (or
    strings matching the `kmdb-vault://` pattern)
  - Diff old document vault URIs vs new document vault URIs
  - Increment ref counts for added URIs, decrement for removed URIs
  - Call `VaultGc.onZeroRefs` / `VaultGc.onRefRestored` as appropriate
  - All changes land in the same `WriteBatch` as the document write
- [ ] Modify `kmdb_database.dart`:
  - Accept an optional `VaultStore` at `open()` time
  - Pass `VaultStore` and `VaultGc` to collections that need them
  - Include vault recovery in the open sequence
- [ ] Ensure `$vault` namespace entries are excluded from the session object
      cache and materialised view cache (same `$`-prefix exclusion already
      applied to `$meta`, `$index`, `$cache`)
- [ ] Wire `VaultRef.getBlob()` and `VaultRef.getMetadata()` to `VaultStore`
- [ ] Write tests:
  - `vault_write_interception_test.dart` — insert document with vault ref
    (ref count = 1), update (old ref decremented, new ref incremented),
    delete (ref count = 0, tombstone created)
  - `vault_integration_test.dart` — end-to-end: ingest file, insert document
    referencing it, verify ref count, delete document, verify tombstone,
    run GC sweep, verify hash directory deleted

### Phase 4 — Packaging format

_Zstandard archive for insert/update/export/backup with attachments._

- [ ] Create `vault_package.dart`: `VaultPackage` with:
  - `read(File archive)` — parse Zstandard archive; extract `document.json`
    and resolve vault subdirectories per the §24 file resolution rules
  - `write(Map<String, dynamic> document, List<VaultAttachment> attachments)`
    — produce a Zstandard archive
  - `validate(Map<String, dynamic> document, List<VaultAttachment> attachments)`
    — verify all vault URIs in document are covered; fail if unreferenced
    objects exist in the package
- [ ] Validate upload `manifest.json` fields when present (schema version,
      SHA-256 match, CRC32C match, size match, media type match,
      originalName file existence)
- [ ] Write tests:
  - `vault_package_test.dart` — read valid package, missing blob, extra
    files (should fail), unreferenced vault objects (should fail), missing
    referenced vault object (should fail), minimal manifest (schemaVersion
    only), no manifest (blob fallback)

### Phase 5 — CLI

_`vault get`, `--import` for insert/update, `--vault` for backup/export._

- [ ] Create `vault_command.dart` and `vault_get_command.dart`:
  - `kmdb {db} vault get {uri}` — fetch vault object (hydrating if stub);
    write to stdout or `--output` file
- [ ] Modify `insert_command.dart`: add `--import` flag (mutually exclusive
      with `--value` and `--file`; error if combined)
- [ ] Modify `update_command.dart`: add `--import` flag with the same
      mutual exclusion; handle all six update scenarios from §24
- [ ] Modify `backup_command.dart`: add `--vault` flag; produce Zstandard
      archive with `documents.bak` + `vault/` when set
- [ ] Modify `export_command.dart`: add `--vault` flag; produce Zstandard
      archive with `documents.ndjson` + `vault/` (collection-scoped) when set
- [ ] Register `vault` command in `kmdb_cli.dart`
- [ ] Write CLI tests for all new commands and flags:
  - `vault_get_command_test.dart`
  - `insert_import_test.dart`
  - `update_import_test.dart`
  - `backup_vault_test.dart`
  - `export_vault_test.dart`

### Phase 6 — Distributed sync

_`VaultStorageAdapter` and stub hydration._

- [ ] Create `vault_storage_adapter.dart`: `VaultStorageAdapter` abstract
      interface with `uploadVaultObject`, `syncVaultMetadata`,
      `hydrateVaultBlob`, `vaultObjectExists`
- [ ] Implement `LocalDirectoryVaultAdapter` (mirrors the existing
      `LocalDirectoryAdapter` for SSTables) for integration testing
- [ ] Wire `VaultStore.get()` to call `hydrateVaultBlob` when blob is absent
      and a `VaultStorageAdapter` is configured
- [ ] Write tests:
  - `vault_storage_adapter_test.dart` — upload, syncMetadata (creates stub),
    hydrateBlob (resolves stub), exists check, FWW (manifest already present,
    upload skipped)
  - `vault_sync_integration_test.dart` — two-device scenario using
    `LocalDirectoryVaultAdapter`: device A ingests file, syncs metadata to
    device B (stub), device B hydrates on demand

### Phase 7 — Documentation & housekeeping

- [ ] Update `packages/kmdb/lib/kmdb.dart` to export vault public API
      (`VaultRef`, `VaultManifest`, `VaultStore`, `VaultStorageAdapter`)
- [ ] Verify all public classes, methods, and properties have doc comments
- [ ] Add license headers to all new `.dart` files
- [ ] Run `dart analyze packages/kmdb` and `dart analyze packages/kmdb_cli`
      with zero errors
- [ ] Run full test suite (`dart test packages/kmdb` and
      `dart test packages/kmdb_cli`); confirm ≥ 90% coverage
- [ ] Update `CLAUDE.md` implementation status table (Phase 10: Vault)

## Summary

_To be completed after implementation._
