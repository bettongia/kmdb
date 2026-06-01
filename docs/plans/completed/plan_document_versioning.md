# Document Versioning

**Status**: Implemented

**PR link**: _pending_

**Implementation model:** Sonnet, moderate review of the soft-delete,
full-drain, and compaction-trimming semantics.

**Proposal**: [docs/proposals/test_harness.md](../docs/proposals/test_harness.md) (sync testing
context that informed the priority of this work)

**Spec**: `docs/spec/26_document_versioning.md` (created during Phase 1 — section
26 was the next available number when the file was created).

**Dependencies** (fixes from the 2026-05-22 code review this plan builds on —
**all three have landed as of v0.02.01, 2026-06-01**):

- `plan_writebatch_atomicity.md` (H2) — **COMPLETE (PR #23).** Atomic batches
  now exist: a multi-entry `WriteBatch` is written as one WAL frame
  (`WalBatchFrame`, type `0x04`) under a single checksum + single fsync, applied
  to the memtable synchronously. This plan's core atomicity guarantee ("the
  version entry is written in the same `WriteBatch` as the document, so a crash
  that prevents one prevents both") now holds.
- `plan_compaction_reclamation.md` (H4) — **COMPLETE (PR #24).** The landed
  `ReclamationPolicy` interface exposes `collapseVersions` and
  `dropTombstone(int horizonHlcMs)`. `$ver:` defaults to
  `RetainAllVersionsPolicy`. This plan **extends** the framework by adding a
  `filterGroup` method (see RQ1).
- `plan_vault_gc_failsafe.md` (H3) — **COMPLETE (PR #22).** The single
  fail-safe reader is `VaultRefCount.read(KvStore, sha256)`.

## Problem statement

KMDB uses Last-Write-Wins (LWW) via HLC timestamps to resolve sync conflicts.
This is deterministic and correct, but silent: when two devices independently
edit the same document, the lower-timestamp write is discarded with no record of
it ever existing. In a single-user multi-device scenario this is a real risk —
the user may not notice that a meaningful edit was lost.

This plan adds automatic version tracking to KMDB collections. Every write to a
collection document is retained as a numbered version entry. The API exposes the
full version history for a document and allows the user or application to
nominate any prior version as the current latest. A configurable per-collection
maximum version count bounds storage growth; old entries are trimmed at
compaction time. Because version history syncs across devices and vault GC
respects version refs, no data is silently discarded on any device.

## Open questions (all resolved)

- [x] **Max version count semantics** — defaults `maxVersions: 4, retentionDays: 90`.
  Constructor accepts `null` for either field (no constraint). `VersionConfig.defaults`
  provides the recommended production values.

- [x] **Delete is a soft delete (Option B)** — a delete records a `$ver:`
  delete-version (a tombstone version) in addition to the main-namespace tombstone.

- [x] **Deleted documents are fully reclaimed** — the `maxVersions` keep-N count is a
  floor for **live** documents only. Once deleted, the chain purges once the
  delete-version ages past `retentionDays`.

- [x] **RQ1–RQ6** resolved: see the original `Investigated` plan in the main repo.

## Implementation plan

### Phase 1 — Core types and storage

- [x] Write spec `docs/spec/26_document_versioning.md`
- [x] Implement `VersionEntry` (`hlc`, `encodedValue`, `promotedFrom?`) with CBOR
  round-trip; handles BigInt decode from cbor library for large HLC values
- [x] Implement `VersionConfig` (`maxVersions`, `retentionDays`, both optional/nullable;
  `maxVersions: 0` + no `retentionDays` = versioning disabled). Constructor defaults to
  `null`; `VersionConfig.defaults` provides `maxVersions: 4, retentionDays: 90`
- [x] Implement `VersionManager` — `VersionWriteAugmentor`, `readVersions`,
  `readVersionAt`, `VersionConfigStore`; `versionNamespace()` helper

### Phase 2 — Write path and query API

- [x] Extend `KmdbCollection` write interception via `VersionWriteAugmentor` to emit
  a `$ver:` entry in the **same** `WriteBatch` as every document write and every delete
- [x] Add `KmdbCollection.getVersions(String docKey)` → `List<DocumentVersion>`
- [x] Add `KmdbCollection.promoteVersion(String docKey, Hlc version)` → `Future<void>`
  (errors with `VersionNotFoundError`); handles both put-version promotion (un-delete)
  and delete-version promotion (re-delete)
- [x] Extend `KmdbDatabase.open()` to accept `versionConfigs` per collection (stored
  in `$meta` via `VersionConfigStore` so it syncs)
- [x] Export `DocumentVersion`, `VersionConfig`, `VersionNotFoundError` from
  `lib/kmdb.dart`

### Phase 3 — Compaction trimming

- [x] Add `filterGroup` method to `ReclamationPolicy` with default no-op; update
  `RetainAllVersionsPolicy` to inherit the default
- [x] Implement `VersionRetentionPolicy` with keep-N / retentionDays trim, post-delete
  full purge, correct `null` vs zero semantics for each constraint
- [x] Add `nowMs` to `CompactionJob` constructor; add `droppedVersionValues` field
- [x] Modify `CompactionJob.run()` to buffer `collapseVersions=false` groups,
  call `filterGroup` at group-end, emit survivors, append dropped values
- [x] In `LsmEngine._compactAll()`: read `VersionConfig` per collection from
  `_metaStore` via `versionRegistryProvider`; pass `nowMs` to job
- [x] Add `setVersionDropCallback` to `LsmEngine` (mirrors `setMetaStore` pattern);
  invoke callback with `droppedVersionValues` after compaction commits
- [x] Add public `VaultRefInterceptor.decrementVersionRefs` method; wire callback in
  `KvStoreImpl`/`KmdbDatabase` for vault ref release

### Phase 4 — CLI

- [x] Add `kmdb versions <collection> <docKey>` command (`VersionsCommand`)
- [x] Add `kmdb promote <collection> <docKey> <hlc>` command (`PromoteCommand`)
- [x] Register both commands in `CliRunner`

### Phase 5 — Tests and docs

- [x] Unit tests: `VersionEntry` serialisation (incl. BigInt decode for large HLCs),
  `VersionConfig` constructor/fromMap/disabled semantics, `VersionRetentionPolicy.filterGroup`
  (keep-N boundary, retentionDays boundary, combined, post-delete purge, null constraints)
- [x] Integration tests: write → list versions; promote → new version appears,
  old value retrievable; promote creates new version with `promotedFrom`;
  promote deleted document un-deletes it; promote delete-version re-deletes;
  promote trimmed/unknown → `VersionNotFoundError`; disabled versioning no-op
- [x] Delete records a `$ver:` delete-version; document is absent but versions remain
- [x] Compaction trimming: maxVersions trim, retentionDays window, deleted-document
  post-delete purge, live document floor preserved
- [x] RQ4 crash atomicity: truncated WAL batch drops document AND version entry
- [x] CLI tests: `versions`, `promote` commands
- [x] Spec created at `docs/spec/26_document_versioning.md`
- [x] Update `CLAUDE.md` implementation status table (Phase 11 added)
- [x] Phase 6 (harness): `getVersions` assertions for fork-record losers in
  `kmdb_harness`

### Phase 6 — Harness update

- [x] Add `getVersions` assertions to `kmdb_harness` for every recorded
  fork-record loser: `Device.getVersions` + `Device.syncForVerification`;
  `TestManager._verifyVersionForks` forces a final sync then checks both
  participating devices have the loser's value in their `$ver:` history
- [x] Update `HarnessReport` to include `versionForksPassed` and
  `versionForksChecked` counts; updated `diffReports` and tests

## Implementation notes

### BigInt decode issue in cbor 6.5.1

The cbor library's `toObject()` returns `BigInt` for integers encoded as uint64
(> 2^32 bits). HLC values encoded as `(physicalMs << 16) | logical` for dates in
2026 are approximately 10^17, which exceeds 2^32, so they are encoded as uint64.
When `VersionEntry.fromMap` decodes the `promotedFrom` field, it now accepts
both `int` and `BigInt` to handle this correctly. Similarly for the `hlc` field.

### VersionConfig constructor semantics

The `VersionConfig()` constructor has both fields defaulting to `null` (no
constraint). `VersionConfig.defaults` is a named constant with
`maxVersions: 4, retentionDays: 90`. `VersionConfig.fromMap` uses `containsKey`
to avoid applying default values when a key is absent, enabling correct round-trip
of disabled configs (where `retentionDays` is intentionally `null`).

### VersionRetentionPolicy.filterGroup semantics

- `null maxVersions` means "no count ceiling" — only the window constraint applies.
- `null retentionDays` means "no window" — only the count constraint applies.
- Both `null` means "no constraints" — all entries retained.
- The newest entry (rank 1) is always retained regardless.

## Summary

All six phases implemented on branch `20260601_plan_document_versioning`:

- **Phase 1 (Core types):** `VersionEntry` (CBOR round-trip, BigInt decode for
  large HLCs), `VersionConfig` (maxVersions/retentionDays, null = no constraint,
  disabled = maxVersions:0 only), `VersionManager` / `VersionWriteAugmentor` /
  `VersionConfigStore` / `versionNamespace()`.
- **Phase 2 (Write path + API):** `KmdbCollection.getVersions` /
  `promoteVersion`; atomic `$ver:` entries in the same `WriteBatch` as every
  put/delete; `KmdbDatabase.open()` accepts `versionConfigs`; public exports
  from `lib/kmdb.dart`.
- **Phase 3 (Compaction trimming):** `ReclamationPolicy.filterGroup` default
  no-op; `VersionRetentionPolicy` (keep-N, retentionDays, post-delete purge);
  `CompactionJob` buffers groups and calls `filterGroup`; `LsmEngine`
  `setVersionDropCallback`; `VaultRefInterceptor.decrementVersionRefs`.
- **Phase 4 (CLI):** `kmdb versions` and `kmdb promote` commands registered in
  `CliRunner`.
- **Phase 5 (Tests + docs):** unit tests for `VersionEntry`, `VersionConfig`,
  `VersionRetentionPolicy`; integration tests covering write→list, promote,
  delete, compaction trim, crash atomicity; CLI tests; spec at
  `docs/spec/26_document_versioning.md`; CLAUDE.md Phase 11 row added.
- **Phase 6 (Harness):** `Device.getVersions` / `syncForVerification`;
  `TestManager._verifyVersionForks` checks loser values in `$ver:` history on
  both devices after final sync; `HarnessReport.versionForksPassed` /
  `versionForksChecked` fields; updated `diffReports` and tests.
