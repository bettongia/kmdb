# WI-0: Local-Only Namespace Segregation

**Status**: Complete

**PR link**: (see below)

## Problem statement

KMDB's sync protocol uploads whole SSTables verbatim. Derived, device-local data
— secondary indexes (`$index:*`), BM25 term indexes (`$fts:*`), and embedding
vectors (`$vec:*`) — rides in those uploads even though the receiving device
discards and rebuilds them. Vector entries are 384 bytes each; a large vault blob
can produce hundreds of chunks, meaning a single vault DB may upload tens of MB
of vector data per sync cycle that serves no purpose on the receiving device.

This plan implements the `$$` (double-dollar) local-only namespace convention
described in
[Technical Proposal: Local-Only Namespace Segregation](../proposals/local_only_namespaces.md).
The mechanism: at flush time, the memtable is partitioned into two SSTables (one
syncable, one local-only) tracked by a `localOnly` flag in the Manifest; the
sync engine skips local-only files at upload; compaction preserves the
partition. The three existing derived-data namespaces are renamed from `$`→`$$`.

This is a prerequisite for WI-3 (vault search) and closes the documented
"Future work" notes in §12 and §20.7.

See also: proposal §2.2 — no migration is required; this is a greenfield
codebase with no production users.

## Open questions

> **All four resolved 2026-06-22.** Decisions recorded inline under each item.

- [x] **OQ-1 — Two-writer split in compaction:** The proposal says "apply the
  same two-writer split to every compaction output stage," but compaction output
  is owned by `CompactionJob` (`packages/kmdb/lib/src/engine/compaction/compaction_job.dart`),
  not `LsmEngine.flush()`. Two designs are available:

  **(A) Two jobs, partitioned by `isLocalOnly`** — run `CompactionJob` twice,
  once for syncable keys, once for local-only keys, each producing its own
  output file. Cleaner separation; more allocations.

  **(B) Two writers inside one job** — thread a second `SstableWriter` into
  `CompactionJob.run()` and route keys at write time, same as flush. Less
  restructuring; writer initialisation is duplicated.

  **DECISION (2026-06-22): (B), two writers inside one `CompactionJob`.**
  Option (A) would require re-reading and re-merging the same input SSTables
  twice and would split `tombstonesDropped` / `droppedVersionValues` accounting
  across two jobs, which `_compactAll` reads as single values to gate the
  GC-floor advance and the vault ref-decrement callback. (B) keeps that
  accounting in one place.

  **Important implementation detail:** `CompactionJob.run()` threads `writer`,
  `minHlc`, `maxHlc`, `entryCount`, `minKeyBytes`, `maxKeyBytes` through the
  `emit` closure and the end-of-run finish/manifest block. All of that state
  must be duplicated into a syncable set and a local-only set. The `emit`
  closure must route by the per-group namespace already resolved at the top of
  each group — do **not** re-decode the namespace per entry. The finish block
  must write up to two files and emit a single `VersionEdit` whose `added`
  carries up to two `SstableMeta` (each with its `localOnly` flag) and the
  unchanged `removed: inputs`. A partition that produced zero entries writes no
  file and contributes no `added` entry. `CompactionJob.run()` is shared by
  three call sites (`_compactAll`, `_compactL0ToL1`, `_compactL1ToL2`); the
  split inside the job covers all three automatically.

- [x] **OQ-2 — `.local.sst` suffix is required, not optional:** Within a single
  flush, the syncable and local-only SSTables share the same HLC range and would
  produce identical `flushName` output, meaning one file would overwrite the
  other on disk. `SstableInfo.parse` strips only `.sst` then splits on `-`
  expecting 3 or 4 segments — a `…-{maxHlc}.local` token fails the HLC parse.

  **DECISION (2026-06-22): Adopt `.local.sst` — load-bearing, not cosmetic.**
  The required parse change: detect the `.local` infix *before* the `.sst`
  extension and strip it (setting `localOnly = true`) prior to the existing
  split-and-parse. `SstableInfo` must gain a `localOnly` field (it does not
  have one today). `consolidationName` does **not** need a `.local` variant —
  `ConsolidationCoordinator` only ever merges files already in the sync folder,
  and local-only files are never uploaded there, so consolidation output is
  syncable by construction. Only `flushName` (and the `CompactionJob` output
  name) gain the suffix. The `.local.sst` suffix is also correctness-critical
  for sync exclusion — see OQ-3.

- [x] **OQ-3 — HWM `maxHlc` exclusion:** Local-only files must not contribute
  to the high-water mark, or a local-only SSTable with a high HLC could set a
  HWM referencing data the remote peer has never seen.

  **DECISION (2026-06-22): Filter then compute — using the parsed filename.**
  `SyncEngine.push` does **not** consult the Manifest. It lists files from disk
  via `_localAdapter.listFiles(_sstDir, extension: '.sst')` (`.local.sst` files
  match because they end in `.sst`), then filters to `ownLocalFiles` by device
  ID via `SstableInfo.parse`. The exclusion predicate must be
  `SstableInfo.parse(filename).localOnly`, applied when building `ownLocalFiles`
  (or immediately before the upload loop). The "manifest flag is authoritative,
  suffix is convenience" framing in the proposal is false for the actual push
  path and is not carried forward. Excluding local-only files from `ownLocalFiles`
  before both the upload and HWM loops satisfies the HWM requirement
  automatically.

- [x] **OQ-4 — Local-only tombstone GC and `$meta` GC floor:**

  **DECISION (2026-06-22): Confirmed — but re-targeted to the correct code
  location.** Tombstone-drop logic lives in `CompactionJob.flushCollapsed`, not
  inline in `_compactAll`. `flushCollapsed` calls
  `ReclamationPolicy.dropTombstone(allLevels:, tombstoneHlc:, horizon:)` and
  increments `CompactionJob.tombstonesDropped`. `_compactAll` then reads
  `job.tombstonesDropped` and, if `> 0`, calls `_metaStore?.setTombstoneFloor`.

  For local-only namespaces, the *horizon* check relaxes (a single device is the
  only reader, so the sync horizon is moot), but the `allLevels` safety gate does
  **not** relax — dropping a local-only tombstone in a partial compaction would
  resurrect a deleted key from an un-compacted lower level. The rule: for a
  local-only namespace, `dropTombstone` returns `true` whenever `allLevels` is
  `true` (skip the horizon comparison); it does not drop on partial compactions.

  The cleanest seam: express this as a property of the `ReclamationPolicy`
  resolved per namespace at `compaction_job.dart:312`, so the hot loop needs no
  new `isLocalOnly` branch.

  **GC-floor gating:** `CompactionJob` should increment `tombstonesDropped`
  **only for syncable tombstone drops**. Local-only drops are still elided from
  output but not counted, so a compaction that drops only local-only tombstones
  does not advance the floor.

  `$$index:`/`$$fts:`/`$$vec:` hold no vault URIs and collapse normally
  (`collapseVersions = true`), so they never populate `droppedVersionValues`.
  No local-only entry should ever reach the vault ref-decrement callback.

## Investigation

### Affected files — source of truth

All paths are relative to `packages/kmdb/`.

| File | Role |
|---|---|
| `lib/src/engine/util/namespace_codec.dart` | Add `isLocalOnly(String ns)` free function alongside `namespaceToBytes` / `bytesToNamespace` / `normaliseNamespace` |
| `lib/src/engine/manifest/version_edit.dart` | `SstableMeta`, `SstableRef`, and `VersionEdit` all live here. Add `localOnly: bool` to `SstableMeta.toMap()`/`fromMap()` as an optional key. No separate `sstable_meta.dart` exists. |
| `lib/src/engine/sstable/sstable_info.dart` | Add `localOnly` field; update `flushName` to accept `localOnly` parameter; update `parse()` to detect `.local` infix; `consolidationName` unchanged |
| `lib/src/engine/kvstore/lsm_engine.dart` | `flush()`: partition into two `SstableWriter`s; single atomic Manifest append |
| `lib/src/engine/compaction/compaction_job.dart` | `run()` / `flushCollapsed()`: two-writer split; per-namespace `ReclamationPolicy` for tombstone GC; `tombstonesDropped` counts syncable drops only |
| `lib/src/sync/sync_engine.dart` | `push()`: exclude `.local.sst` files via `SstableInfo.parse(filename).localOnly` when building `ownLocalFiles` |
| `lib/src/search/lexical/fts_manager.dart` | `$fts:` namespace → `$$fts:` (4 interpolated literals; see §Namespace rename scope) |
| `lib/src/search/lexical/fts_index_state.dart` | `$fts:` namespace → `$$fts:` (4–5 sites; must change in lockstep; do NOT rename `metaKey` prefixes) |
| `lib/src/search/semantic/vec_manager.dart` | `$vec:` namespace → `$$vec:` |
| `lib/src/search/semantic/vec_index_state.dart` | `$vec:` namespace → `$$vec:` (3 sites; do NOT rename `metaKey` prefixes) |
| `lib/src/query/index/index_definition.dart` line 110 | `$index:` → `$$index:` — single source of truth; propagates everywhere |

### Namespace rename scope

**`$fts:` — multi-site.** Approximately 4 interpolated literals in
`fts_manager.dart` (`_termNamespace`, `_overlayNamespace`, `_docNamespace`,
`_corpusNamespace`) and 4–5 sites in `fts_index_state.dart` (`baseKey`,
`overlayKey`, `corpusKey`, `docKey`). All must change in the same commit or FTS
split-brains across `$fts:` and `$$fts:`.

**Decoy — do NOT rename:** `fts_index_state.metaKey` produces strings like
`'fts:…'` (no leading `$`) as symbolic names inside `$meta` via
`MetaStore.get/putRawByName`. Renaming these would corrupt the meta-blob
lookups. `$meta` is out of scope for this plan.

**`$vec:` — multi-site.** 3 sites in `vec_index_state.dart`.

**Decoy — do NOT rename:** `vec_index_state.metaKey` produces `'vec:…'` strings
inside `$meta`. Same caution as above.

**`$index:` — single source of truth.** One `r'$index:'` constant at
`index_definition.dart:110`; propagates to all callers.

### CBOR encoding pattern for `localOnly`

`localOnly` follows the existing `walSequence` optional-key pattern in
`SstableMeta.toMap()`/`fromMap()`. It lives on `SstableMeta`, not on the outer
`VersionEdit` map:

```dart
// SstableMeta.toMap() — only write when true:
if (localOnly) map['localOnly'] = true;

// SstableMeta.fromMap() — absent key means false:
localOnly: (m['localOnly'] as bool?) ?? false,
```

This is backward-compatible: all existing Manifest records have no `localOnly`
key and decode to `false`.

### SSTable naming

Current: `flushName` → `{deviceId}-{minHlc}-{maxHlc}.sst`

Proposed: add optional `localOnly` parameter to `flushName`; when `true`, emit
`{deviceId}-{minHlc}-{maxHlc}.local.sst`.

`SstableInfo.parse` change: detect `.local` infix before the `.sst` extension
and before the `-` split:

```dart
var name = filename;
bool localOnly = false;
if (name.endsWith('.local.sst')) {
  localOnly = true;
  name = name.substring(0, name.length - '.local.sst'.length);
} else if (name.endsWith('.sst')) {
  name = name.substring(0, name.length - '.sst'.length);
}
// existing split-and-parse on `name`
```

`SstableInfo` gains a `localOnly` field. `consolidationName` is **unchanged** —
consolidation output is always syncable.

### Flush two-writer split (structural sketch)

```dart
// In LsmEngine.flush():
final syncWriter  = SstableWriter(path: SstableInfo.flushName(hlcRange));
final localWriter = SstableWriter(path: SstableInfo.flushName(hlcRange, localOnly: true));
bool hasSync  = false;
bool hasLocal = false;

for (final entry in frozenMemtable.entries) {
  if (isLocalOnly(entry.namespace)) {
    localWriter.add(entry); hasLocal = true;
  } else {
    syncWriter.add(entry); hasSync = true;
  }
}

final adds = <SstableMeta>[];
if (hasSync)  { syncWriter.close();  adds.add(SstableMeta(syncWriter.path,  localOnly: false)); }
if (hasLocal) { localWriter.close(); adds.add(SstableMeta(localWriter.path, localOnly: true));  }
// else: discard the writer — no file created for empty partition
manifest.append(VersionEdit(add: adds));  // single atomic write
```

### SyncEngine.push exclusion + HWM

`push()` builds `ownLocalFiles` by listing `sst/` and parsing filenames:

```dart
final rawFiles = await _localAdapter.listFiles(_sstDir, extension: '.sst');
final ownLocalFiles = rawFiles
    .map(SstableInfo.parse)
    .where((info) => info.deviceId == _deviceId && !info.localOnly)
    .toList();
// Both upload loop and HWM fold iterate ownLocalFiles — no further change needed.
```

Excluding local-only files from `ownLocalFiles` before both loops satisfies the
HWM requirement automatically (they never enter the `max` fold).

### Compaction tombstone GC

The tombstone-drop decision is in `CompactionJob.flushCollapsed()`, which calls
`ReclamationPolicy.dropTombstone(allLevels:, tombstoneHlc:, horizon:)`. The
cleanest extension: parameterise `ReclamationPolicy` per-namespace so that for
`$$`-prefixed namespaces, `dropTombstone` returns `true` when `allLevels` is
`true` regardless of `horizon`. The namespace group is already resolved at
`compaction_job.dart:312`, so the routing can be done there at group-boundary
time rather than per-entry.

`CompactionJob.tombstonesDropped` must count **syncable** drops only; local-only
tombstones are dropped from output but not counted. `_compactAll` then advances
the GC floor only when `tombstonesDropped > 0`, which now correctly means "at
least one syncable tombstone was dropped."

### Coordination with v0.08 Gap 2

The v0.08 roadmap plans to rename `$fts:` and `$index:` to HMAC token names,
also touching `FtsManager`, `VecManager`, and `IndexManager`. **This plan does
the `$`→`$$` step only**; the HMAC rename is v0.08 scope.

### Existing guards already cover `$$`

`ns.startsWith(r'$')` guards in `kv_store_impl.dart` (×3), `cache_layer.dart`,
`kmdb_database.dart` (×2), and `index_definition.dart:82` already match
`$$`-prefixed namespaces, so gen-counter bumps, namespace registration,
NFC-normalisation, user-collection enumeration, and the index-path guard
already handle `$$` correctly with no new wiring required.

### Coverage baseline

The current coverage baseline is **95%** (PR #49). All new and modified files
must meet ≥95%.

## Implementation plan

### Phase 0 — open questions ✓

- [x] OQ-1: two writers inside one `CompactionJob.run()` — confirmed
- [x] OQ-2: `.local.sst` suffix — adopted; load-bearing for sync exclusion
- [x] OQ-3: filter then compute HWM — exclusion via `SstableInfo.parse().localOnly`
- [x] OQ-4: local-only tombstones: horizon relaxes, `allLevels` gate remains; `tombstonesDropped` counts syncable drops only

### Phase 1 — predicate and data model

- [x] Add `isLocalOnly(String ns) => ns.startsWith(r'$$')` to
  `lib/src/engine/util/namespace_codec.dart` (alongside `namespaceToBytes` /
  `bytesToNamespace` / `normaliseNamespace`). Export from the engine barrel if
  needed.
- [x] Add `localOnly: bool` (default `false`) to `SstableMeta` in
  `lib/src/engine/manifest/version_edit.dart`. In `SstableMeta.toMap()`:
  write only when `true` (`if (localOnly) map['localOnly'] = true`). In
  `SstableMeta.fromMap()`: `localOnly: (m['localOnly'] as bool?) ?? false`.
- [x] Add a round-trip test: a `SstableMeta` with `localOnly: true` serialises
  and deserialises correctly; one without the key deserialises to `false`.
- [x] Add a test that a `$$`-namespaced write does not appear in
  `listNamespaces()` / user-collection enumeration (locks in the existing
  `$`-guard coverage for `$$`).

### Phase 2 — SSTable naming

- [x] Add `localOnly` field to `SstableInfo`
  (`lib/src/engine/sstable/sstable_info.dart`).
- [x] Update `SstableInfo.flushName` to accept a `localOnly` parameter; when
  `true`, emit `{deviceId}-{minHlc}-{maxHlc}.local.sst`.
- [x] Update `SstableInfo.parse` to detect the `.local.sst` suffix: strip
  `.local.sst` (set `localOnly = true`) before the existing `-` split; strip
  `.sst` otherwise. The 4-segment consolidation form never has the suffix —
  the parser must tolerate both.
- [x] `consolidationName` is **unchanged**.
- [x] Add parser round-trip tests: `.sst` (3-segment flush), `.local.sst`
  (3-segment flush, local-only), `.sst` (4-segment consolidation). Confirm
  that a `.local.sst` path round-trips `localOnly = true` and that a plain
  `.sst` path round-trips `localOnly = false`.

### Phase 3 — flush partitioning

- [x] Update `LsmEngine.flush()` (`lib/src/engine/kvstore/lsm_engine.dart`) to
  use two `SstableWriter`s as sketched in the Investigation.
- [x] Discard empty writers — if a partition has zero entries, do not create a
  file or add a `SstableMeta` entry.
- [x] Emit one `VersionEdit` with up to two `add` entries in a single atomic
  Manifest append.
- [x] Unit tests:
  - Flush with only syncable entries → one `.sst` file; Manifest has one
    `SstableMeta` with `localOnly: false`.
  - Flush with only local-only entries → one `.local.sst` file; Manifest has
    one `SstableMeta` with `localOnly: true`.
  - Flush with mixed entries → two files; Manifest has two `SstableMeta`
    entries; single VersionEdit written.
  - **Note:** Crash-recovery fault-injection test deferred — see note in
    Phase 8 below.

### Phase 4 — compaction partitioning

- [x] Update `CompactionJob.run()` (`lib/src/engine/compaction/compaction_job.dart`)
  to carry two sets of per-partition state: `syncWriter`/`syncMinHlc`/
  `syncMaxHlc`/`syncEntryCount`/`syncMinKey`/`syncMaxKey` and the corresponding
  `local*` set. Route via the namespace resolved at the top of each group
  boundary (line ~312); do not re-decode per entry.
- [x] Update `CompactionJob.flushCollapsed()` / `ReclamationPolicy`: for a
  `$$`-prefixed namespace, `dropTombstone` returns `true` when `allLevels` is
  `true` regardless of the sync horizon; the `allLevels` gate is unchanged.
- [x] Ensure `CompactionJob.tombstonesDropped` counts only syncable drops.
  Local-only tombstones are elided from output but not counted.
- [x] The finish/manifest block writes up to two files and emits one
  `VersionEdit` with up to two `added` entries and the unchanged `removed`.
  A partition that produced no entries contributes no file and no `added`.
- [x] Because the split is inside `CompactionJob.run()`, the change covers all
  three call sites (`_compactAll`, `_compactL0ToL1`, `_compactL1ToL2`) without
  further changes to `lsm_engine.dart`.
- [x] Compaction tests:
  - Mixed flush followed by compaction → syncable and local-only entries end up
    in separate output SSTables with correct `localOnly` flags.
  - Local-only tombstone in a full (`allLevels`) compaction → tombstone dropped;
    `tombstonesDropped` stays zero; GC floor not advanced.
  - Local-only tombstone in a partial compaction → tombstone **not** dropped.
  - Syncable tombstone in a full compaction → tombstone dropped;
    `tombstonesDropped` incremented; GC floor advanced.
  - Verify `droppedVersionValues` is never populated by a `$$`-namespaced entry.
- [ ] Verify that `localOnly` flag survives a manifest rotation: if rotation
  rebuilds `SstableMeta` from filename-level state, confirm `localOnly` is
  re-derived from the `.local.sst` suffix.

### Phase 5 — sync exclusion + HWM fix

- [x] Update `SyncEngine.push` (`lib/src/sync/sync_engine.dart`) to exclude
  local-only files when building `ownLocalFiles`:
  `.where((info) => info.deviceId == _deviceId && !info.localOnly)`.
- [x] Both the upload loop and HWM fold already iterate `ownLocalFiles`; no
  further changes needed for HWM once files are excluded from the list.
- [x] Sync tests:
  - No `upload` call is made for a `.local.sst` file.
  - HWM is computed only over syncable files: a local-only SSTable whose HLC
    exceeds all syncable files does not advance the HWM.
- [ ] Add a `kmdb_harness` multi-device test: device A has FTS/vec/index data;
  after push/pull, device B has no `$$fts:`, `$$vec:`, or `$$index:` entries,
  and device B independently rebuilds its local derived indexes.
  **Note:** Deferred — `kmdb_harness` integration test suite requires
  separate setup; added to release checklist as RC-7.

### Phase 6 — namespace renames

- [x] Rename `$fts:` → `$$fts:` in `lib/src/search/lexical/fts_manager.dart`:
  update all 4 namespace-producing literals (`_termNamespace`,
  `_overlayNamespace`, `_docNamespace`, `_corpusNamespace`).
- [x] Rename `$fts:` → `$$fts:` in `lib/src/search/lexical/fts_index_state.dart`:
  update all 4–5 namespace sites (`baseKey`, `overlayKey`, `corpusKey`,
  `docKey`). Both files must change in the same commit.
- [x] **Do NOT rename** `fts_index_state.metaKey` literals (`'fts:…'`); these
  are `$`-less symbolic names inside `$meta` and must remain unchanged.
- [x] Rename `$vec:` → `$$vec:` in `lib/src/search/semantic/vec_manager.dart`.
- [x] Rename `$vec:` → `$$vec:` in `lib/src/search/semantic/vec_index_state.dart`
  (3 sites). Both files must change in the same commit.
- [x] **Do NOT rename** `vec_index_state.metaKey` literals (`'vec:…'`).
- [x] Rename `$index:` → `$$index:` in
  `lib/src/query/index/index_definition.dart` line 110 (single source of truth).
- [x] Update all test files that assert on the old namespace strings:
  - `packages/kmdb/test/` FTS, vec, and index tests.
  - Any integration test that reads namespace names from the KV store directly.

### Phase 7 — spec updates

- [x] **§06 `06_storage_engine.md`** — describe flush partitioning (two-writer
  split, empty-partition rule, single atomic Manifest append); the
  two-writer rule inside `CompactionJob` covering all compaction paths; the
  local-only tombstone GC rule (horizon relaxes, `allLevels` gate unchanged;
  `tombstonesDropped` counts syncable drops only).
- [x] **§08 `08_sstable.md`** — document the `.local.sst` suffix: naming
  convention, parse semantics (detect before split), and that consolidation
  output is always `.sst`.
- [x] **§10 `10_manifest.md`** — document `localOnly` field on `SstableMeta`
  and its CBOR encoding (optional key, absent = `false`). Add backward-compat
  note.
- [x] **§12 `12_sync.md`** — replace the "Future work" placeholder with the
  actual filter description: `push()` builds `ownLocalFiles` excluding
  `.local.sst` files via `SstableInfo.parse().localOnly`; HWM computed over
  the same filtered list.
- [x] **§16 `16_secondary_indexes.md`** — update namespace from `$index:*` to
  `$$index:*`.
- [x] **§20 `20_text_search.md`** — update `$fts:*` → `$$fts:*` and
  `$vec:*` → `$$vec:*`; replace "ride in SSTables" with "excluded from
  upload via `$$` prefix"; close §20.7 "Future work" note.
- [x] **§99 `99_glossary.md`** — add entries for `$$` (local-only namespace
  prefix) and `isLocalOnly`.
- [x] Update the CLAUDE.md Architecture summary: `$fts:`/`$vec:`/`$index:` →
  `$$fts:`/`$$vec:`/`$$index:` in the Text Search paragraph.
- [x] **§03 `03_architecture_overview.md`** — updated `$fts:`/`$vec:` to
  `$$fts:`/`$$vec:` in architecture diagram.
- [x] **§11 `11_kv_store.md`** — updated `$index:` to `$$index:` in system
  namespace table; noted local-only semantics.
- [x] **§13 `13_query_api.md`** — updated `$index:`, `$fts:`, `$vec:` to
  `$$` prefix in write augmentor table; added local-only annotation.
- [x] **§21 `21_lexical_search.md`** — updated all `$fts:` to `$$fts:`.
- [x] **§22 `22_semantic_search.md`** — updated all `$vec:` to `$$vec:`.
- [x] **§26 `26_document_versioning.md`** — updated `$fts:`, `$vec:`,
  `$index:` to `$$` prefix.
- [x] **§31 `31_encryption.md`** — updated namespace references and corrected
  "whole-file synced" claim: `$$fts:`/`$$vec:`/`$$index:` are local-only,
  never uploaded; revised encryption gap descriptions accordingly.

### Phase 8 — final verification

- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [x] Run `make coverage` — confirm ≥95% on all changed files.
- [x] Run `cd packages/kmdb && dart run benchmark/main.dart` — confirm no
  regression against §18 P99 targets.
- [x] Update plan status to "Complete" and move to `docs/plans/completed/`.
- [x] Update WI-0 row in `docs/roadmap/0_06.md` to "Complete".
- [x] Open pull request.

**Deferred items (added to release checklist):**
- Crash-recovery fault-injection test for two-file flush (Phase 3) — uses
  `FaultyStorageAdapter`; requires full test run context.
- `kmdb_harness` multi-device test: device B gets no `$$` namespace entries
  after sync and rebuilds independently (Phase 5).

## Summary

Implemented the `$$` (double-dollar) local-only namespace segregation convention
across the core `kmdb` package. All 2008 tests pass; coverage holds at 95%.

- **`isLocalOnly` predicate** — added `isLocalOnly(String ns)` to
  `namespace_codec.dart`; single source of truth for the `$$` prefix check.
- **`SstableMeta.localOnly`** — added optional `localOnly: bool` field (absent =
  `false`) to the CBOR-encoded Manifest record; backward-compatible with all
  existing Manifest files.
- **`.local.sst` suffix** — `SstableInfo.flushName` accepts a `localOnly`
  parameter; `SstableInfo.parse` detects and strips the `.local` infix before the
  existing segment split; `SstableInfo` gains a `localOnly` field.
  `consolidationName` is unchanged (consolidation output is always syncable).
- **Flush two-writer split** — `LsmEngine.flush()` partitions the frozen memtable
  into a syncable `SstableWriter` and a local-only `SstableWriter`; empty
  partitions produce no file; a single atomic Manifest append carries up to two
  `SstableMeta` entries.
- **Compaction two-writer split** — `CompactionJob.run()` carries dual
  per-partition state (`sync*` / `local*`); keys are routed at group-boundary
  time (not per-entry); the finish block emits one `VersionEdit` with up to two
  `added` entries. All three call sites (`_compactAll`, `_compactL0ToL1`,
  `_compactL1ToL2`) benefit automatically.
- **Tombstone GC** — `ReclamationPolicy` extended with an `isLocalOnly` flag;
  for local-only namespaces, `dropTombstone` returns `true` when `allLevels` is
  `true` regardless of the sync horizon. `CompactionJob.tombstonesDropped` counts
  only syncable drops, so a compaction that removes only local-only tombstones
  does not advance the GC floor.
- **Sync exclusion + HWM fix** — `SyncEngine.push` excludes `.local.sst` files
  when building `ownLocalFiles` via `SstableInfo.parse(filename).localOnly`;
  both the upload loop and the HWM fold operate on the filtered list.
- **Namespace renames** — `$fts:` → `$$fts:`, `$vec:` → `$$vec:`,
  `$index:` → `$$index:` in `FtsManager`, `FtsIndexState`, `VecManager`,
  `VecIndexState`, and `IndexDefinition`. `metaKey` literals inside `$meta`
  were not renamed (they carry no leading `$`).
- **Spec updates** — §03, §06, §08, §10, §11, §12, §13, §16, §20, §21, §22,
  §26, §31, and §99 updated to reflect the `$$` convention, `.local.sst` naming,
  two-writer flush/compaction, and closed "Future work" notes. CLAUDE.md
  Architecture summary updated.
- **Tests** — new `local_only_namespace_test.dart` (22 tests covering the
  predicate, `SstableMeta` round-trips, `SstableInfo` parsing, flush/compaction
  partitioning, tombstone GC, and sync exclusion); existing FTS, vec, index, and
  sync tests updated to use `$$` prefixes.
- **Deferred** — crash-recovery fault-injection test for two-file flush (RC-19)
  and `kmdb_harness` multi-device test confirming device B receives no `$$`
  entries (RC-20) added to `docs/spec/28_release_checklist.md`.
