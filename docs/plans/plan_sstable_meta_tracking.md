# SSTable metadata tracking through the level map

**Status**: Open

**PR link**: {pending}

**Implementation model:** Sonnet — mechanical threading of an existing type.
Medium review.

**Sequencing**: Depends on M1 (`TableCache`) being complete (it is — #28) so
that `entryCount` can be read cheaply from the cached reader footer rather than
re-opening every file. Independent of all other open items.

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

{To be completed during investigation.}

### Scope of change

The level map type would change from `Map<int, List<String>>` to something like
`Map<int, List<SstableEntry>>` where `SstableEntry` holds the filename plus
`SstableMeta`. This threads through:

- `LsmEngine._levels` field declaration
- Every flush, compaction, ingest, and rotation site that mutates `_levels`
- `_doManifestRotation` snapshot writes (the motivation)
- `CrashRecovery` / Manifest replay that populates `_levels` on open

`SstableMeta` (`minKey`, `maxKey`, `entryCount`) is already available:
- At **flush** and **compaction** time — the writer returns it.
- At **ingest** time — it can be read from the SSTable footer (cheap via the
  `TableCache` introduced in M1).
- At **recovery** time — manifest `VersionEdit` records already carry it for
  non-rotation edits; rotation snapshots currently zero it out (the bug).

### Open questions

- Should `SstableEntry` be a new named type or a Dart record?
- Should recovery re-read footers for rotation-snapshot entries that have
  `entryCount == 0` (retroactive repair), or accept that pre-fix manifests
  have zeroed metadata until the next rotation?
- Are any `minKey`/`maxKey` values currently used by the read/compaction paths,
  or are they purely diagnostic today?

## Decisions

- [ ] **D1 — Level map entry type.** Named record or a small class?
- [ ] **D2 — Recovery repair.** Re-read footer for zero-count entries, or accept
  stale metadata from old manifests?
- [ ] **D3 — Current use of minKey/maxKey.** Confirm whether any read-path code
  depends on these fields before threading.

## Implementation plan

{To be completed during investigation.}

## Summary

{To be completed during implementation.}
