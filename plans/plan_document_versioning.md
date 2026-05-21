# Document Versioning

**Status**: Investigated

**PR link**: _pending_

**Proposal**: [docs/proposals/test_harness.md](../docs/proposals/test_harness.md) (sync testing
context that informed the priority of this work)

**Spec**: _to be created as `docs/spec/26_document_versioning.md`_

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

## Open questions

- [x] **Max version count semantics:** `VersionConfig` supports both `maxVersions`
  (integer count) and `retentionDays` (time window) as independent, optional
  knobs. At compaction time, a version entry is retained if _either_ condition
  is satisfied — i.e. keep whichever is larger. If neither knob is set, only the
  defaults apply. **Defaults: `maxVersions: 4`, `retentionDays: 90`.**
  Setting `maxVersions: 0` with no `retentionDays` disables versioning for the
  collection entirely.

## Investigation

### Architecture overview

Version entries live in a `$ver:{namespace}:{docKey}` system namespace, one entry
per historical write, keyed by the HLC hex of the write. Because they are stored
in regular KV namespaces they flow through the standard SSTable write/sync/compaction
path with no special-casing required.

```
$ver:{ns}:{docKey}:{hlcHex}  →  VersionEntry { hlc, encodedValue, promotedFrom? }
```

Each collection holds a `VersionConfig` (max count, retention policy) stored in
its collection metadata entry in `$meta`. Since `$meta` syncs, the config is
consistent across all devices automatically.

### Write path

Every `KmdbCollection.put()` or `WriteBatch` write that targets a user namespace
produces a companion `$ver:` entry in the same `WriteBatch`. This keeps the
document write and its version record atomic — a crash that prevents one will
prevent both.

The version entry stores the encoded value (post-`KmdbCodec`) so that decoding
is symmetric with the normal read path.

### Promote to latest

`KmdbCollection.promoteVersion(String docKey, HlcTimestamp fromVersion)`:

1. Reads the `$ver:` entry for `fromVersion`.
2. Writes the stored encoded value as a new `put()` with a fresh HLC — from the
   perspective of other devices this is a normal LWW-eligible update.
3. The new write produces its own `$ver:` entry with `promotedFrom` set to
   `fromVersion`, providing a clear audit trail.

No special sync handling is required; the promoted write propagates as any other.

### Version trimming at compaction

During compaction, for each document key the merge iterator collects all `$ver:`
entries sorted by HLC descending. Entries beyond the configured limit are dropped
from the output SSTable. Trimming happens on every device independently after
sync, so all devices converge to the same retained set (assuming the same config,
which is guaranteed since config is in `$meta`).

### Vault GC integration

The vault ref-counter (`$vault:{sha256}`) currently derives its count by scanning
live document values. With versioning, `$ver:` entries must also be treated as
ref sources. The `KmdbCollection` write-interception logic (which diffs old/new
vault URIs and adjusts counters) must be extended to:

1. Increment the ref counter for vault URIs introduced by a version entry write.
2. Decrement the ref counter for vault URIs dropped when a version entry is
   trimmed at compaction.

Because `$ver:` namespaces sync, every device's GC sees the same set of refs —
eliminating the "surprise deletion" failure mode where one device GC's a blob
still referenced by versions on another device.

### Sync inclusion

`$ver:` namespaces are **included in sync**, unlike `$fts:` and `$vec:` which
are explicitly excluded. No changes to the sync filter are needed beyond ensuring
`$ver:` is not inadvertently added to the exclusion list.

### Key design decisions

- **Atomic writes:** version entries are always written in the same `WriteBatch`
  as the document write — consistency is guaranteed by the existing batch
  atomicity.
- **Config in `$meta`:** `VersionConfig` is stored alongside the collection
  definition so it propagates via normal sync; no out-of-band config channel.
- **Promote = new write:** promotion generates a standard LWW-eligible write, not
  a special merge operation. This keeps the sync protocol simple.
- **Trim at compaction:** trimming is a compaction-time operation, not a
  background sweep. Consistent with KMDB's synchronous-on-write-path model.
- **No cross-device trim coordination:** each device trims independently using
  the same config. Because config is synced, the outcome is the same on every
  device.
- **Delete behaviour:** deleting a document marks it deleted via a tombstone in
  the normal LSM path. The `$ver:` entries for the deleted document are retained
  until trimmed by compaction; this allows a delete to be "undone" by promoting a
  prior version within the retention window.

### Key files to modify / create

| Package   | Action | Path                                                              |
| :-------- | :----- | :---------------------------------------------------------------- |
| kmdb      | Create | `lib/src/versioning/version_entry.dart`                           |
| kmdb      | Create | `lib/src/versioning/version_config.dart`                          |
| kmdb      | Create | `lib/src/versioning/version_manager.dart`                         |
| kmdb      | Modify | `lib/src/query/kmdb_collection.dart` — write interception, new API|
| kmdb      | Modify | `lib/src/query/kmdb_database.dart` — version config at open()     |
| kmdb      | Modify | `lib/src/engine/compaction/compaction_job.dart` — trim logic       |
| kmdb      | Modify | `lib/src/vault/vault_gc.dart` — scan `$ver:` for refs             |
| kmdb      | Modify | `lib/kmdb.dart` — export new public types                         |
| kmdb_cli  | Create | `lib/src/commands/versions_command.dart`                          |
| kmdb_cli  | Modify | `lib/src/commands/promote_command.dart` (new)                     |
| docs/spec | Create | `docs/spec/26_document_versioning.md`                             |

### Edge cases and failure scenarios

- **Compaction with zero max versions:** if `maxVersions: 0`, version tracking is
  disabled for the collection; no `$ver:` entries are written. Useful for
  high-churn collections (e.g. telemetry) where history is irrelevant.
- **Promote a version that has been trimmed:** the version entry no longer exists;
  the API returns a typed error (`VersionNotFoundError`), not a silent no-op.
- **Promote on a deleted document:** the promotion write effectively un-deletes
  the document (the promoted value becomes the live write, superseding the
  tombstone via LWW). This is the intended behaviour.
- **Vault URI in the promoted version:** the ref-counter must be adjusted when
  the promotion write is issued, not deferred — handled by the existing
  write-interception logic since promote is a normal `put()`.
- **Version entry size bloat:** for documents with large values (or large vault
  URI lists), every version retains a full copy of the encoded value. This is
  acceptable for KMDB's single-user scale but the spec should note it explicitly.

## Implementation plan

### Phase 1 — Core types and storage

- [ ] Write spec `docs/spec/26_document_versioning.md`
- [ ] Implement `VersionEntry` (`hlc`, `encodedValue`, `promotedFrom?`)
- [ ] Implement `VersionConfig` (`maxVersions: 4`, `retentionDays: 90`, both
  nullable/optional; `maxVersions: 0` + no `retentionDays` = versioning
  disabled)
- [ ] Implement `VersionManager` — write a version entry, list versions for a
  key (sorted HLC descending), delete a version entry

### Phase 2 — Write path and query API

- [ ] Extend `KmdbCollection` write interception to emit a `$ver:` entry in the
  same `WriteBatch` as every document write (skip if versioning disabled for the
  collection)
- [ ] Add `KmdbCollection.getVersions(String docKey)` → `List<DocumentVersion>`
- [ ] Add `KmdbCollection.promoteVersion(String docKey, HlcTimestamp version)` →
  `Future<void>` (errors with `VersionNotFoundError` if the entry has been
  trimmed)
- [ ] Extend `KmdbDatabase.open()` to accept a `VersionConfig` per collection
  (stored in collection metadata in `$meta` so it syncs)
- [ ] Export `DocumentVersion`, `VersionConfig`, `VersionNotFoundError` from
  `lib/kmdb.dart`

### Phase 3 — Compaction trimming

- [ ] Extend `CompactionJob` merge iterator: for each document key collect all
  `$ver:` entries, sort HLC descending, drop any entry that satisfies neither
  the count limit nor the retention window
- [ ] Ensure dropped version entries trigger vault ref-counter decrements in the
  same compaction output (extend `VaultGc` to scan `$ver:` namespaces as ref
  sources)

### Phase 4 — CLI

- [ ] Add `kmdb versions <collection> <docKey>` command — tabular output of
  version HLC, wall-clock time, `promotedFrom` if set
- [ ] Add `kmdb promote <collection> <docKey> <hlc>` command

### Phase 5 — Tests and docs

- [ ] Unit tests: `VersionEntry` serialisation, `VersionConfig` trim predicate
  (count, window, combined, disabled)
- [ ] Integration tests: write → list versions; promote → new version appears,
  old value retrievable; compaction trims beyond count; compaction trims beyond
  window; compaction keeps entries satisfying either condition; vault ref held
  by version is not GC'd; vault ref released when version trimmed; promote
  deleted document un-deletes it; promote trimmed version returns
  `VersionNotFoundError`
- [ ] CLI tests: `versions`, `promote`
- [ ] Update `CLAUDE.md` implementation status table

## Summary

_To be completed post-implementation._
