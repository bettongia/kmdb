# SSTable metadata tracking through the level map

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Sonnet — mechanical threading of an existing type
plus one new derivation helper. Medium review.

**Sequencing**: Depends on M1 (`TableCache`) being complete (it is — #28) so
that an ingested file's reader is already cached when its metadata is derived.
Independent of all other open items.

## Problem statement

`_doManifestRotation` in `LsmEngine` writes a snapshot `VersionEdit` with empty
`minKey`/`maxKey` and `entryCount: 0` for every SSTable in `_levels`, because the
in-memory level map holds only filenames (`Map<int, List<String>>`), not
`SstableMeta`. These fields are currently diagnostic-only (not used for
correctness), but after any manifest rotation the real values are permanently
lost — making tooling, observability, and future use of these fields unreliable.

Surfaced during the §6 code/doc tidy-up
([plans/plan_code_doc_tidyup.md](plan_code_doc_tidyup.md)), where it was
documented as a limitation and deferred here.

## Investigation

The level map is `final Map<int, List<String>> _levels` on `LsmEngine`
(`lsm_engine.dart:98`). It is the single source of truth for which files are
live at each level, and it is mutated at every flush, compaction, ingest,
rotation, drop, and device-ID-rename site. Carrying `SstableMeta` requires
changing this type and every mutation site, plus the two upstream sources that
*populate* it on open.

### Where metadata is currently lost (three distinct losses)

There are **three** places that destroy or never-capture `SstableMeta`, not one:

1. **`_doManifestRotation` (`lsm_engine.dart:935`) — the motivating bug.**
   Builds snapshot `SstableMeta` from `_levels`, which only has filenames, so it
   hard-codes `minKey: ''`, `maxKey: ''`, `entryCount: 0`.

2. **`ingestAt0` (`lsm_engine.dart:1040`).** Writes `minKey: ''`, `maxKey: ''`
   into the manifest for peer-ingested files. It *does* already have a real
   `entryCount` (read from `reader.entryCount`, line 1014) — only the keys are
   zeroed.

3. **`reassignDeviceId` (`lsm_engine.dart:1212`).** Writes `minKey: ''`,
   `maxKey: ''`, `entryCount: 0` for the renamed (added) files, even though the
   pre-rename file's metadata was known.

In addition — and this is the load-bearing discovery the original stub missed —
the on-disk `VersionEdit` records *do* carry full `SstableMeta` for flush and
compaction outputs, but that metadata is **discarded on replay**:

4. **`ManifestState._fromEdits` (`manifest_reader.dart:158`)** collapses replayed
   edits into `Map<int, Set<String>>` → `Map<int, List<String>>` — **filenames
   only**. `CrashRecovery.open` (`crash_recovery.dart:117-119`) then copies that
   filename-only map into the `levels` it passes to `LsmEngine.create`
   (`lsm_engine.dart:149`). So on every open, the real per-file metadata that was
   correctly persisted by flush/compaction is dropped on the floor before the
   engine ever sees it.

Implication: **the level map cannot be made metadata-bearing without also making
`ManifestState` metadata-bearing.** Threading only `_levels` would mean every
file looks metadata-less immediately after any open. This widens the change
beyond the original stub's "scope of change" list.

### Where the metadata is actually available (corrects the stub's premise)

The stub asserted ingest-time metadata "can be read from the SSTable footer
(cheap via the `TableCache`)". That is **incorrect** and must not be implemented
as written:

- `SstableFooter` (`sstable_writer.dart:260`, `sstable_reader.dart` footer
  parse) stores `entryCount` and block offsets/sizes — it does **not** store the
  file's min or max key.
- The index block (`SstableReader.index`, a `List<BlockRef>`) stores each data
  block's **`lastKey`**. So `maxKey == reader.index.last.lastKey` is available
  cheaply (index is already loaded on open).
- The file's **`minKey` is not stored anywhere in the index or footer.** The
  only way to obtain it is to read the first data block and take its first key
  (one `readFileRange` of ≤4 KiB).

Where real metadata genuinely exists today:

| Site | minKey | maxKey | entryCount |
| :--- | :----- | :----- | :--------- |
| flush (`flush`, line 650) | real (`minKeyBytes`) | real (`maxKeyBytes`) | real |
| compaction (`CompactionJob.run`, job line 297) | real | real | real |
| ingest (`ingestAt0`) | not stored — needs first-block read | `index.last.lastKey` | real (`reader.entryCount`) |
| reassign (`reassignDeviceId`) | known from source meta | known from source meta | known from source meta |
| replay (`ManifestState`) | on disk in the edit, discarded | on disk, discarded | on disk, discarded |

`reassignDeviceId` is the easy case once the level map carries meta: the renamed
file is byte-identical to the source, so the new `SstableMeta` is the source
entry with only `filename` (and `level`, unchanged) updated. No file read is
needed.

### D3 — Are `minKey`/`maxKey` used by the read or compaction paths?

**No. They are purely diagnostic today.** Confirmed by reading the code:

- The point-lookup path (`_getInternal`, `lsm_engine.dart:392-416`) iterates
  files by filename and delegates to `SstableReader.get`; it never consults
  `SstableMeta`.
- The scan path (`scan`, line 448+) is the same — filename iteration only.
- `CompactionJob` takes `SstableRef` (level + filename only), not `SstableMeta`.
- Compaction triggers use file **counts** and **byte sizes**
  (`_compactIfNeeded`), not key ranges.

This is what makes the change safe and mechanical: we are populating
diagnostic fields with their true values; no correctness path reads them, so
there is no behavioural risk from getting a value subtly wrong. (It also means
the fields stay diagnostic after this work — this plan does **not** introduce
range-based read pruning; that would be a separate plan.)

### Scope of change (final)

The level map type changes from `Map<int, List<String>>` to
`Map<int, List<SstableMeta>>`. `SstableMeta` already exists
(`version_edit.dart:28`) and already carries `level`, `filename`, `minKey`,
`maxKey`, `entryCount`, `walSequence` — it is exactly the right shape, so **no
new type is introduced** (this resolves D1). Threading touches:

- `LsmEngine._levels` field + the `create` factory `levels` parameter +
  `LsmEngine._` constructor parameter (`lsm_engine.dart:64,98,155,167`).
- All read-path iteration that currently reads filenames out of `_levels`
  (`_getInternal`, `scan`, `count`/range helpers) — change `f` →
  `entry.filename`.
- All mutation sites: `flush` (667), `_compactL0ToL1` (771-775),
  `_compactL1ToL2` (807-809), `_compactAll` (882-887), `ingestAt0` (1059),
  `_doManifestRotation` (945-957), `dropAllSstables` (1094-1098),
  `reassignDeviceId` (1182-1228), `_levelsSummary` (1270), `_totalSstBytes` /
  `_levelBytes` (1422, 1437).
- `ManifestState` (`manifest_reader.dart`): carry `SstableMeta` through replay
  instead of bare filenames.
- `CrashRecovery.open` (`crash_recovery.dart:117-119,292`): pass the
  metadata-bearing levels to `LsmEngine.create`.

### Edge cases

- **Pre-fix manifests (backward compat).** An existing database opened after
  this change will replay edits whose flush/compaction records already have real
  metadata, but whose *rotation-snapshot* records have `''`/`''`/`0`. Replay
  must faithfully carry whatever the edit said — so files last written by a
  pre-fix rotation will surface with empty meta until the next rotation
  re-writes them (still empty, because we only know what `_levels` holds). See
  D2 for how we close this.
- **Empty-string min/max in `SstableMeta.fromMap`.** Already tolerated — the
  fields are plain strings with no validation. No format change to the CBOR
  schema; `toMap`/`fromMap` are unchanged.
- **`walSequence` preservation.** `SstableMeta.walSequence` is non-null only for
  flush outputs. When carrying meta through the level map and back into the
  rotation snapshot, `walSequence` will now be *preserved* into the snapshot
  edit (previously snapshots never set it). This is harmless — recovery does not
  read `walSequence` from snapshot edits for correctness (it uses `logNumber`) —
  but note it as a benign observable change in the manifest dump.
- **Ingest first-block read failure.** If deriving `minKey` requires reading the
  first data block and that read fails, ingest must not be aborted for a
  diagnostic field. The derivation helper must fall back to `''` on any error,
  never throw (the file has already been validated by the reader open above).
- **Single-file-shortcut / `_compactAll`.** Output meta comes from
  `edit.added`, which already has real values — just store them instead of
  re-deriving.

### Open questions

All resolved — see **Decisions** below.

## Decisions

- [x] **D1 — Level map entry type.** Use the existing `SstableMeta`
  (`version_edit.dart:28`). It already carries exactly the needed fields
  (`level`, `filename`, `minKey`, `maxKey`, `entryCount`, `walSequence`). Do not
  introduce a new `SstableEntry` type or a Dart record — that would duplicate
  `SstableMeta` and require conversion at every manifest boundary. The level map
  becomes `Map<int, List<SstableMeta>>`.

- [x] **D2 — Recovery repair for pre-fix manifests.** Do **not** add retroactive
  footer re-reading on open. Rationale: (a) opening N files to repair a
  diagnostic-only field adds startup I/O proportional to file count for zero
  correctness benefit; (b) the next rotation already re-writes the snapshot, and
  once *this* fix ships, every newly written flush/compaction/ingest/reassign
  edit carries real metadata, so stale zeros are transient and self-healing for
  any actively written database; (c) a one-shot offline repair, if ever wanted,
  belongs in a `kmdb util` command, not in the open path. Replay carries
  whatever the edit recorded verbatim. Document the transient-stale behaviour in
  the `_doManifestRotation` doc comment (replacing the current "limitation"
  note).

- [x] **D3 — Current use of minKey/maxKey.** Confirmed **purely diagnostic** —
  no read-path or compaction-path code consults `SstableMeta.minKey/maxKey` (see
  Investigation §D3). This work keeps them diagnostic; it does not add
  range-based pruning.

- [x] **D4 — Ingest minKey derivation.** Derive `maxKey` from
  `reader.index.last.lastKey` (already loaded, no extra I/O). Derive `minKey` by
  reading the first data block via the cached reader and taking its first key.
  Wrap the whole derivation in try/catch returning `''` on failure — `minKey`
  must never abort an ingest. (The footer does **not** carry min/max key; the
  original stub's "read from footer" premise was wrong.)

## Implementation plan

Work on a dated branch/worktree per `docs/plans/README.md`
(e.g. `20260530_plan_sstable_meta_tracking`). Keep this checklist current.

### Step 1 — Add a min-key accessor to `SstableReader`

- [ ] In `sstable_reader.dart`, add a method `Future<Uint8List?> firstKey()`
  that reads the first block (`_index.first`) and returns its first entry's key,
  or `null` if the file has no blocks. Reuse the existing `_readBlock` helper.
  Add a doc comment noting it is for diagnostic metadata derivation.
- [ ] `maxKey` needs no new accessor — `reader.index.last.lastKey` is already
  public via the `index` getter.

### Step 2 — Make `ManifestState` metadata-bearing

- [ ] In `manifest_reader.dart`, change the live-set tracking in
  `_fromEdits` from `Map<int, Set<String>>` (filenames) to a structure keyed by
  filename that retains the **last** `SstableMeta` seen for each live file
  (an `add` re-adds/updates; a `remove` drops it). A
  `Map<int, Map<String, SstableMeta>>` (level → filename → meta), converted to
  sorted `List<SstableMeta>` at the end (sort by `filename` for deterministic
  L1/L2 order, matching today's behaviour), preserves current ordering
  semantics.
- [ ] Change `ManifestState.levels` type to `Map<int, List<SstableMeta>>`.
- [ ] Update `allFiles` getter to map `.filename` out of the meta list (it is
  consumed by orphan-sweep as filenames — keep returning `Iterable<String>`).
- [ ] Grep for all `ManifestState.levels` / `state.levels` consumers and update
  them (`crash_recovery.dart`, any manifest tooling/tests).

### Step 3 — Thread `SstableMeta` through `LsmEngine._levels`

- [ ] Change the field type (`lsm_engine.dart:98`) to
  `Map<int, List<SstableMeta>>`, and the `create` factory + `_` constructor
  `levels` parameter types to match.
- [ ] Read-path sites (`_getInternal`, `scan`, and any range/count helpers):
  iterate `entry.filename` instead of the bare string. The level lists stay in
  the same order, so L0 newest-first reverse iteration is unchanged.
- [ ] `flush` (line ~667): store the `meta` already constructed at line 650
  into `_levels[0]` instead of `filename`.
- [ ] `_compactL0ToL1`, `_compactL1ToL2`, `_compactAll`: build inputs from
  `entry.filename` (compaction still takes `SstableRef`); when repopulating
  `_levels` from `edit.added`, store the `SstableMeta` objects directly (they
  already carry real values) instead of `added.filename`.
- [ ] `ingestAt0` (line ~1040): build `meta` with real `entryCount`
  (`reader.entryCount`), `maxKey` from `reader.index.last.lastKey` (hex via the
  existing `_bytesToHex`), and `minKey` from the new `firstKey()` accessor
  wrapped in try/catch → `''`. Store that `meta` into `_levels[0]`.
- [ ] `reassignDeviceId` (line ~1182): the source `SstableMeta` is now in
  `_levels`. For each renamed file, construct the new `SstableMeta` by copying
  the source entry and replacing only `filename` (level unchanged). Add a
  `copyWith({String? filename})` to `SstableMeta`, or construct directly with
  the source fields. Store into `newLevels`.
- [ ] `_doManifestRotation` (line ~945): build the snapshot `added` list
  directly from the `SstableMeta` values now in `_levels` (drop the
  empty-string construction entirely). Update the doc comment per D2.
- [ ] `dropAllSstables` (line ~1094): build `SstableRef` from `entry.level` /
  `entry.filename`.
- [ ] `_levelsSummary`, `_totalSstBytes`, `_levelBytes`, and any other
  `_levels`-reading helper: read `.filename` where they currently use the
  string.

### Step 4 — Update `CrashRecovery.open`

- [ ] `crash_recovery.dart:117-119`: copy `state.levels` (now
  `Map<int, List<SstableMeta>>`) into the `levels` passed to
  `LsmEngine.create`, preserving the meta. Update the local `levels` variable
  type and the `create` call (line 292).

### Step 5 — Tests

- [ ] **Rotation preserves metadata (the motivating bug).** Drive enough
  flushes/compactions to force a manifest rotation
  (`ManifestWriter.shouldRotate` / `kManifestRotationThreshold`), then read the
  rotated manifest back and assert the snapshot edit's entries carry the real
  `minKey`/`maxKey`/`entryCount` (non-empty, non-zero) for every live file.
  Add to `manifest_test.dart` or `lsm_engine_test.dart`.
- [ ] **Replay round-trips metadata.** Write flush + compaction edits with known
  meta, run `ManifestReader.replay`, and assert `state.levels` entries expose
  the same `minKey`/`maxKey`/`entryCount` (proves Step 2 stopped discarding it).
- [ ] **Ingest populates metadata.** Ingest a peer SSTable via `ingestAt0` and
  assert the manifest edit records real `entryCount`, real `maxKey`, and a
  non-empty `minKey` matching the file's first key.
- [ ] **Ingest minKey-derivation failure is non-fatal.** Using the
  `FaultyStorageAdapter` fault-injection harness, fail the first-block read
  during ingest metadata derivation and assert the ingest still succeeds with
  `minKey == ''` (and `maxKey`/`entryCount` still populated). This exercises the
  D4 fallback — a failure path, not the golden path, per CLAUDE.md.
- [ ] **`reassignDeviceId` carries metadata.** After a device-ID rename, assert
  the added entries in the manifest edit carry the source file's
  `minKey`/`maxKey`/`entryCount` (not zeros), with only the filename changed.
- [ ] **Open-after-rotation surfaces real meta in `_levels`.** Open a database
  that has rotated post-fix and assert (via a manifest dump or a test hook) the
  in-memory levels carry real metadata — guards against a future regression that
  re-drops it at the `CrashRecovery` boundary.
- [ ] **Backward compat.** Construct a manifest containing a pre-fix
  rotation-snapshot edit (empty meta) plus later real edits; assert replay does
  not crash and surfaces empty meta only for the files the snapshot zeroed
  (confirms D2's "carry verbatim, self-heal on next write" behaviour).
- [ ] Run `make pre_commit` and the full `kmdb` suite; maintain ≥90% coverage.
  No new uncovered branches (the try/catch fallback in Step 3 ingest must be
  covered by the fault-injection test).

### Step 6 — Docs

- [ ] Update the `_doManifestRotation` doc comment: replace the "Diagnostic
  metadata limitation" paragraph with a statement that snapshots now carry real
  metadata, and a note that pre-fix manifests surface empty meta until rewritten
  (D2).
- [ ] Update the `_levels` field doc comment (`lsm_engine.dart:53,97`) to say it
  now carries `SstableMeta`, not bare filenames.
- [ ] Review `docs/spec/10_manifest.md` and `docs/spec/08_sstable.md` for any
  wording implying the level map / replay is filename-only; update to match.
  (Consult `kmdb-architect` if a spec edit is needed — spec maintenance is its
  domain.)
- [ ] No release-checklist (`docs/spec/28_release_checklist.md`) entry is
  required: all behaviour is exercisable in the automated suite, including the
  fault-injection failure path.

### Out of scope (explicitly)

- Range-based read pruning using `minKey`/`maxKey` (the fields stay diagnostic).
- Storing min/max key in the SSTable footer (not needed; derivable as above).
- An offline `kmdb util` repair command for pre-fix manifests (D2 — possible
  future follow-up, not part of this work).

## Summary

{To be completed during implementation.}
