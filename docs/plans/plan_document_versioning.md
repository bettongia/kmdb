# Document Versioning

**Status**: Investigated

**PR link**: _pending_

**Implementation model:** Sonnet, after its prerequisites (H2/H3/H4) land;
moderate review of the soft-delete and full-drain semantics.

**Proposal**: [docs/proposals/test_harness.md](../docs/proposals/test_harness.md) (sync testing
context that informed the priority of this work)

**Spec**: _to be created as `docs/spec/NN_document_versioning.md`, where `NN` is
the next available section number assigned when the spec is written (see the
spec-numbering convention in `plans/README.md`)._

**Dependencies** (fixes from the 2026-05-22 code review this plan builds on):
- `plan_writebatch_atomicity.md` (H2) — this plan's core guarantee ("the version
  entry is written in the same `WriteBatch` as the document, so a crash that
  prevents one prevents both") relies on atomic batches, which are **not**
  provided today. H2 must land first, or this plan's atomicity claim is false.
- `plan_compaction_reclamation.md` (H4) — `$ver:` trimming plugs into H4's
  per-namespace reclamation framework: `$ver:` namespaces are **exempt** from
  H4's collapse-to-newest and instead use the keep-N / retention predicate.
- `plan_vault_gc_failsafe.md` (H3) — the vault ref-count interaction below must
  use H3's single fail-safe ref-count helper, not introduce another decoder.

**Spec numbering:** the section number is assigned at creation time (the next
available `NN`), not pre-reserved here — see `plans/README.md`. This avoids
collisions with other in-flight plans (e.g. `plan_google_drive_sync.md`).

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

- [x] **Delete is a soft delete (Option B):** a delete records a `$ver:`
  *delete-version* (a tombstone version) in addition to the main-namespace
  tombstone. The document reads as absent immediately, but its history stays
  promotable until trimmed — the soft-delete behaviour users expect from other
  tools. `getVersions` includes the delete-version; `promoteVersion` of a prior
  put un-deletes the document.

- [x] **Deleted documents are fully reclaimed (no unbounded growth):** the
  `maxVersions` keep-N count is a floor for **live** documents only. Once a
  document is deleted, the keep-N floor is lifted and the **entire** `$ver:`
  chain — every put-version *and* the delete-version — is purged once the
  delete-version is older than `retentionDays` (the post-delete grace). Combined
  with H4's GC of the main-namespace tombstone and release of the vault refs held
  by trimmed versions, a deleted document drains to **zero** residue across all
  namespaces. See "Complete reclamation of deleted documents".

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

Trimming is implemented as a `$ver:`-specific reclamation policy registered in
the compaction framework from `plan_compaction_reclamation.md` (H4). H4 collapses
ordinary namespaces to the newest version per key; `$ver:` namespaces are exempt
from that collapse and instead use the policy below.

During compaction, for each document key the merge iterator collects all `$ver:`
entries sorted by HLC descending. Entries beyond the configured limit are dropped
from the output SSTable. Trimming happens on every device independently after
sync, so all devices converge to the same retained set (assuming the same config,
which is guaranteed since config is in `$meta`).

### Complete reclamation of deleted documents

A hard requirement: a deleted document — and all of its versions — must
eventually disappear entirely, so storage does not creep upward as users delete
content over time. A naive keep-N would pin up to N `$ver:` entries per deleted
document **forever**; that is the leak this design must avoid.

**Rule: keep-N is a floor for live documents only.** Once a document's newest
version is its delete-version, the keep-N floor no longer applies and the whole
`$ver:` chain is purged once the delete-version ages past `retentionDays`.

After a delete, each residue location drains to zero:

| Location | Drains via |
| -------- | ---------- |
| Main-namespace value versions | H4 collapse → only the tombstone remains |
| Main-namespace tombstone | H4 tombstone GC (all-levels + sync horizon) |
| `$ver:` put-versions | retention trim (keep-N while live; age-out once deleted) |
| `$ver:` delete-version | post-delete grace: purged once older than `retentionDays` |
| Vault refs held by `$ver:` entries | decremented as entries trim (H3); blob GC'd at zero refs |
| `$index:` entries | index tombstones follow the doc; reclaimed by H4 |
| `$fts:` / `$vec:` postings | removed when the live doc is deleted (managers handle delete) |

End state: zero entries for the document in every namespace, and any vault blob
it solely referenced is GC'd.

**Sync interaction.** The main-namespace tombstone is the authority for
"deleted"; H4 retains it until the sync horizon, so purging `$ver:` history early
can never cause a live resurrection (a late peer's old put loses LWW to the
tombstone). `$ver:` purge is therefore a storage/recoverability concern, not a
correctness one. Because `retentionDays` (default 90) far exceeds normal sync
lag, the purge converges across devices; a peer re-sending not-yet-trimmed
history causes only transient, self-correcting churn.

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
  as the document write. **This requires atomic batches from H2
  (`plan_writebatch_atomicity.md`)** — batches are not crash-atomic today, so this
  guarantee holds only once H2 lands.
- **Config in `$meta`:** `VersionConfig` is stored alongside the collection
  definition so it propagates via normal sync; no out-of-band config channel.
- **Promote = new write:** promotion generates a standard LWW-eligible write, not
  a special merge operation. This keeps the sync protocol simple.
- **Trim at compaction:** trimming is a compaction-time operation, not a
  background sweep. Consistent with KMDB's synchronous-on-write-path model.
- **No cross-device trim coordination:** each device trims independently using
  the same config. Because config is synced, the outcome is the same on every
  device.
- **Delete behaviour (soft delete, Option B):** a delete writes a main-namespace
  tombstone (live reads return absent) **and** a `$ver:` delete-version (the
  history records the deletion). The document is recoverable via `promoteVersion`
  of a prior put until retention trims it. The delete-version, being newest, is
  retained longest; once it is the last remaining version and ages past
  `retentionDays`, the post-delete grace purges it too, so the document drains to
  zero — see "Complete reclamation of deleted documents".

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
| docs/spec | Create | `docs/spec/NN_document_versioning.md` (next available)                             |

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

- [ ] Write spec `docs/spec/NN_document_versioning.md` (take the next available
  section number at this point)
- [ ] Implement `VersionEntry` (`hlc`, `encodedValue`, `promotedFrom?`)
- [ ] Implement `VersionConfig` (`maxVersions: 4`, `retentionDays: 90`, both
  nullable/optional; `maxVersions: 0` + no `retentionDays` = versioning disabled).
  keep-N is a floor for **live** documents only; for a deleted document the floor
  is lifted so the chain fully purges after the post-delete grace
- [ ] Implement `VersionManager` — write a version entry, list versions for a
  key (sorted HLC descending), delete a version entry

### Phase 2 — Write path and query API

- [ ] Extend `KmdbCollection` write interception to emit a `$ver:` entry in the
  same `WriteBatch` as every document write **and every delete** (a delete writes
  a `$ver:` delete-version); skip if versioning is disabled for the collection
- [ ] Add `KmdbCollection.getVersions(String docKey)` → `List<DocumentVersion>`
- [ ] Add `KmdbCollection.promoteVersion(String docKey, HlcTimestamp version)` →
  `Future<void>` (errors with `VersionNotFoundError` if the entry has been
  trimmed)
- [ ] Extend `KmdbDatabase.open()` to accept a `VersionConfig` per collection
  (stored in collection metadata in `$meta` so it syncs)
- [ ] Export `DocumentVersion`, `VersionConfig`, `VersionNotFoundError` from
  `lib/kmdb.dart`

### Phase 3 — Compaction trimming

- [ ] Register a `$ver:` reclamation policy in the H4 framework
  (`plan_compaction_reclamation.md`): `$ver:` is exempt from collapse-to-newest;
  instead, per document key, collect all `$ver:` entries sorted by HLC descending
  and drop any that satisfies neither the count limit nor the retention window
- [ ] Implement the **post-delete purge**: when the newest `$ver:` entry for a
  key is a delete-version, lift the keep-N floor and drop the **entire** chain
  (all puts and the delete-version) once the delete-version is older than
  `retentionDays`, so deleted documents leave zero residue
- [ ] Ensure dropped version entries trigger vault ref-counter **decrements** in
  the same compaction output, using H3's single fail-safe ref-count helper
  (`plan_vault_gc_failsafe.md`) — counter-based, not a new live scan

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
- [ ] Delete records a `$ver:` delete-version: after a delete, `getVersions`
  includes the delete-version and `promoteVersion` of a prior put un-deletes it
- [ ] **Deleted-document full drain (anti-leak):** delete a doc, advance past
  `retentionDays`, compact, then assert **zero** entries remain for the doc in the
  main, `$ver:`, and `$index:` namespaces, and that any vault blob it solely
  referenced is GC'd — guards against the keep-N-pins-forever leak
- [ ] Live document retains keep-N history (the floor applies while the doc lives)
- [ ] CLI tests: `versions`, `promote`
- [ ] Update `CLAUDE.md` implementation status table

## Summary

_To be completed post-implementation._
