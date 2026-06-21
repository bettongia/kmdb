# Document Versioning

**Status:** Implemented (v0.02.02, PR pending)

## Overview

KMDB uses Last-Write-Wins (LWW) via HLC timestamps to resolve sync conflicts.
This is deterministic and correct, but silent: when two devices independently
edit the same document, the lower-timestamp write is discarded with no record of
it ever existing. Document versioning retains every write as a numbered version
entry, providing a full audit trail and the ability to promote any prior version
to become the new latest.

Every write to a collection document is retained as a version entry in the
`$ver:{namespace}` system namespace. The API exposes the full version history
for a document and allows the user or application to nominate any prior version
as the current latest via `KmdbCollection.promoteVersion`. A configurable
per-collection maximum version count (`VersionConfig`) bounds storage growth;
old entries are trimmed at compaction time.

## Storage layout

Version entries live in the `$ver:{namespace}` system namespace, one entry per
historical write, keyed by the binary doc key (same 16-byte UUIDv7 used for the
document). The internal key's HLC differentiates versions:

```
namespace: $ver:{userNamespace}
userKey:   16-byte binary doc key  (same as in the user namespace)
hlc:       write HLC               (unique per version — differentiates entries)
value:     VersionEntry { hlc, encodedValue, promotedFrom? }
```

This is a **history-bearing** namespace. The `ReclamationPolicyRegistry` assigns
a `ReclamationPolicy` per namespace whose `collapseVersions` is `false` for
`$ver:` namespaces, so multiple versions of the same key are never collapsed by
ordinary compaction. For a configured `$ver:{collection}` namespace the registry
selects a `VersionRetentionPolicy` (which performs the keep-N / retentionDays
trim); any other `$ver:` namespace falls through to `RetainAllVersionsPolicy`,
which retains every version (its `filterGroup` is a no-op). See
[Compaction trimming](#compaction-trimming) for how the registry is built at
compaction time.

### Key grouping in compaction

The internal key format is:

```
[nsLen 1B][ns bytes][userKey 16B][hlc 8B][type 1B]
```

The `groupPrefix` in `CompactionJob` is `key[0 .. len-9]` — i.e. the full
content minus the trailing HLC+type bytes. All versions of the same document in
the same collection therefore form a **single contiguous group** in the merge
iterator, sorted HLC ascending. This structural fact is what makes the
`filterGroup` trim recipe work without any changes to the merge iterator.

## VersionConfig

`VersionConfig` controls per-collection versioning behaviour:

| Field           | Type   | Default | Meaning                                                                                                          |
| --------------- | ------ | ------- | ---------------------------------------------------------------------------------------------------------------- |
| `maxVersions`   | `int?` | `4`     | Keep at most this many versions (counted from newest). `null` means unlimited. `0` disables versioning entirely. |
| `retentionDays` | `int?` | `90`    | Keep versions written within this many calendar days. `null` means no time limit.                                |

Both knobs are independent and optional. At compaction time a version entry is
**retained** if _either_ condition is satisfied — i.e. the policy keeps
whichever is larger. If neither knob is set, only the defaults apply.

Setting `maxVersions: 0` with no `retentionDays` disables versioning for the
collection entirely; no `$ver:` entries are written. This is useful for
high-churn collections (e.g. telemetry) where history is irrelevant.

`VersionConfig` is stored in the collection's metadata entry in `$meta` (as part
of the `KmdbCollection` open metadata), so it propagates via normal sync and is
consistent across all devices automatically.

## VersionEntry

Each `$ver:` entry stores a `VersionEntry` value encoded by `ValueCodec`:

```dart
{
  'hlc': int,           // 64-bit encoded HLC (physicalMs<<16 | logical)
  'encodedValue': Uint8List, // ValueCodec-encoded document bytes (CBOR)
                             // null for a delete-version
  'promotedFrom': int?, // hlc.encoded of the source version, if this is a
                        //  promoted write; null otherwise
  'isDelete': bool,     // true for a delete-version entry
}
```

The `encodedValue` field stores the same bytes that the main namespace holds for
this version — using `ValueCodec` encoding so decoding is symmetric with the
normal read path. For a delete-version, `encodedValue` is `null` and `isDelete`
is `true`.

## Write path

Every `KmdbCollection.put()` or `delete()` call produces a companion `$ver:`
entry in the **same `WriteBatch`** as the document write. This is guaranteed by
the `VersionManager` augmentor registered in `KmdbDatabase`. The single batch
contains:

```
document write  ← main namespace put (or delete tombstone)
$ver: entry     ← VersionEntry for this write
$index: entries ← secondary index augmentor
vault refs      ← VaultRefInterceptor augmentor
meta updates    ← dirty flag, gen counter, namespace registry
```

Because H2 (`plan_writebatch_atomicity.md`) encodes the entire batch as one
`WalBatchFrame` under a single XXH64 checksum and one fsync, a crash that
prevents one write prevents all — no partial state is possible after recovery.

If versioning is **disabled** for a collection (`maxVersions: 0` and no
`retentionDays`), the `VersionManager` augmentor emits no `$ver:` entries and
the behaviour is identical to unversioned KMDB.

## Delete semantics (soft delete)

A delete records both the main-namespace tombstone (so reads return absent
immediately) **and** a `$ver:` delete-version:

```
batch {
  main namespace:  delete(ns, docKey)          ← makes doc absent
  $ver:{ns}:       put($ver:{ns}, docKey,
                       VersionEntry(isDelete: true))  ← records deletion
}
```

This means:

- `getVersions(docKey)` includes the delete-version at the top of the list.
- `promoteVersion(docKey, hlc)` of a prior put-version **un-deletes** the
  document: the promoted value becomes the new latest write (with a new HLC),
  superseding the tombstone via LWW.

## Query API

### `getVersions(String docKey) → Future<List<DocumentVersion>>`

Returns all `$ver:` entries for [docKey] in this collection, sorted by HLC
**descending** (newest first). Includes the delete-version if the document was
deleted.

A `DocumentVersion` carries:

```dart
class DocumentVersion {
  final String id;             // docKey
  final Hlc hlc;               // the version's HLC timestamp
  final DateTime timestamp;    // wall-clock time derived from hlc.physicalMs
  final Map<String, dynamic>? value; // decoded document (null for delete-version)
  final Hlc? promotedFrom;     // source HLC if this was a promotion
  final bool isDelete;         // true for delete-versions
}
```

### `promoteVersion(String docKey, Hlc fromVersion) → Future<void>`

1. Reads the `$ver:` entry for `fromVersion`.
2. Throws `VersionNotFoundError` if the entry no longer exists (e.g. trimmed by
   compaction or was never written for this collection).
3. Writes the stored `encodedValue` as a new put with a fresh HLC — from the
   perspective of other devices this is a normal LWW-eligible update.
4. The new write produces its own `$ver:` entry with `promotedFrom` set to
   `fromVersion`, providing an audit trail.

No special sync handling is required; the promoted write propagates as any
other.

**Promotion of a delete-version** is valid: the delete-version stores
`encodedValue: null`, so promoting it writes a tombstone for the main namespace
(effectively re-deleting the document). Because a new HLC is assigned, this
tombstone always wins LWW.

**Promotion on a deleted document** is the un-delete path: promote a prior
put-version, which writes a new put that supersedes the tombstone via LWW. The
vault blobs referenced by the promoted value are re-acquired (ref count
incremented via `interceptWrite`). This is the intended behaviour.

## Sync inclusion

`$ver:` namespaces are **included in sync**, unlike `$fts:` and `$vec:` which
are explicitly excluded. The sync filter must not exclude `$ver:` prefixes.

Because `$ver:` entries are treated like any user-namespace data by the sync
engine (they are just entries in an SSTable), version history propagates to all
devices automatically on the next sync.

## Compaction trimming

### `ReclamationPolicy.filterGroup`

A new `filterGroup` method is added to the `ReclamationPolicy` interface:

```dart
/// Called with the full version list for one (namespace, userKey) group,
/// sorted HLC ascending (oldest first), when [collapseVersions] is false.
/// Returns the entries to retain (a subset, same order).
/// [nowMs] is wall-clock time injected from the engine — never read inside.
List<MergeEntry> filterGroup(
  List<MergeEntry> entries, {
  required int nowMs,
}) => entries; // default: retain all
```

The default implementation returns all entries unchanged (backward compatible).
Both `CollapseToNewestPolicy` and `RetainAllVersionsPolicy` inherit this no-op
default — neither trims `$ver:` history. Only `VersionRetentionPolicy` overrides
`filterGroup` with the keep-N / retentionDays logic.

### `VersionRetentionPolicy`

`VersionRetentionPolicy` extends `ReclamationPolicy` and applies the trim rules
for `$ver:` namespaces:

- `collapseVersions = false` — versions are never collapsed.
- `dropTombstone` returns `false` — version tombstones are not subject to H4
  tombstone GC (they are history entries, not delete tombstones).
- `filterGroup`: sorts entries HLC descending (newest first); if the newest
  entry is a delete-version whose age exceeds `retentionDays`, returns an empty
  list (full post-delete purge); otherwise retains entries satisfying
  `rank <= maxVersions || (nowMs - hlcMs) <= retentionDays × 86_400_000`, where
  rank 1 is the newest entry. The newest entry is always rank 1 so the current
  state is never accidentally trimmed.

### `CompactionJob` changes

- A new `nowMs` constructor parameter carries wall-clock time injected by
  `LsmEngine._compactAll` at job-construction time
  (`DateTime.now().millisecondsSinceEpoch`).
- A new `droppedVersionValues` field (`List<Uint8List>`) accumulates the raw
  value bytes of every version entry trimmed by `filterGroup`. This is parallel
  to `tombstonesDropped`.
- In the merge loop, the `collapseVersions=false` path buffers entries per group
  instead of emitting immediately; at group-end it calls
  `policy.filterGroup(buffer, nowMs: nowMs)`, emits survivors, and appends
  dropped entries' values to `droppedVersionValues`.

### `ReclamationPolicyRegistry` selection

`ReclamationPolicyRegistry` resolves the `ReclamationPolicy` for each namespace
by, in order:

1. **Exact match** against a map of per-namespace version policies (populated
   via `ReclamationPolicyRegistry.withVersionPolicies`). A configured
   `$ver:{collection}` namespace maps to its `VersionRetentionPolicy`.
2. **Prefix match** against the retain-all prefixes (`$ver:` by default) →
   `RetainAllVersionsPolicy` (retain every version, no-op `filterGroup`).
3. **Default** → `CollapseToNewestPolicy`.

So a `$ver:{collection}` with a configured `VersionConfig` is trimmed by its
`VersionRetentionPolicy`; any other `$ver:` namespace retains all versions via
`RetainAllVersionsPolicy`.

### `LsmEngine` changes

- Reads each collection's `VersionConfig` from `_metaStore` in `_compactAll()`,
  builds a `VersionRetentionPolicy` keyed by exact `$ver:{collection}`
  namespace, and constructs the `ReclamationPolicyRegistry` (via
  `ReclamationPolicyRegistry.withVersionPolicies`) before passing it to the
  `CompactionJob`.
- Adds a `setVersionDropCallback(Future<void> Function(List<Uint8List>)?)`
  injection point (same pattern as `setMetaStore`). After `_compactAll` commits
  and the level maps are updated, if `job.droppedVersionValues.isNotEmpty`, the
  callback is invoked.
- `KvStoreImpl` wires the callback: decodes each dropped value as a
  `VersionEntry`, extracts vault URIs, creates a `WriteBatch`, and calls
  `VaultRefInterceptor.decrementRefs` to release the vault ref counts.

## Vault soft-delete (named behaviour)

Vault blobs referenced by a deleted document are **soft-deleted implicitly
through the ref-count mechanism**:

1. Document delete: main tombstone written; `VaultRefInterceptor` decrements the
   blob's ref count (the live document released its references).
2. `$ver:` delete-version written, containing the full `encodedValue` with vault
   URIs.
3. The `$ver:` write increments each blob's ref count (the version entry holds
   the references).
4. **Net effect**: each blob's ref count is unchanged from its pre-delete level
   for as long as any `$ver:` entry referencing it survives.

The blob is retained for up to `retentionDays` (default 90 days) after deletion.
If the user promotes a prior version before retention expires, the document
write re-acquires the blob and it stays alive indefinitely. Once the `$ver:`
chain is trimmed, refs drop to zero and the blob is GC'd along with all other
residue for the deleted document.

## Complete reclamation of deleted documents

A hard requirement: a deleted document — and all of its versions — must
eventually disappear entirely, so storage does not creep upward as users delete
content over time.

**Rule: keep-N is a floor for live documents only.** Once a document's newest
version is its delete-version, the keep-N floor is lifted and the whole `$ver:`
chain is purged once the delete-version ages past `retentionDays`.

After a delete, each residue location drains to zero:

| Location                           | Drains via                                                          |
| ---------------------------------- | ------------------------------------------------------------------- |
| Main-namespace value versions      | H4 collapse → only the tombstone remains                            |
| Main-namespace tombstone           | H4 tombstone GC (all-levels + sync horizon)                         |
| `$ver:` put-versions               | retention trim (keep-N while live; age-out once deleted)            |
| `$ver:` delete-version             | post-delete grace: purged once older than `retentionDays`           |
| Vault refs held by `$ver:` entries | decremented via post-compaction batch (RQ5); blob GC'd at zero refs |
| `$index:` entries                  | index tombstones follow the doc; reclaimed by H4                    |
| `$fts:` / `$vec:` postings         | removed when the live doc is deleted (managers handle delete)       |

End state: zero entries for the document in every namespace, and any vault blob
it solely referenced is GC'd.

## Compaction vault-ref crash posture (RQ5)

If the process crashes after `_compactAll` commits (manifest durable) but before
the vault ref-decrement `WriteBatch` commits, the ref count is over-counted: the
blob is retained even though no live entry references it. This is the fail-safe:
blobs are never deleted while possibly referenced, only potentially retained
longer than necessary. The count self-corrects on the next write that touches
the same blob via the normal `interceptWrite` diff.

This posture mirrors the H3 vault GC fail-safe design. The crash window is
narrow (the decrement batch is issued immediately after `_compactAll` returns)
and the only observable effect is a vault blob surviving one extra compaction
cycle.

## Sync interaction (RQ3)

The main-namespace tombstone is the authority for "deleted"; H4 (PR2) retains it
until the sync horizon, so purging `$ver:` history early can never cause a live
resurrection. `$ver:` purge is therefore a storage/recoverability concern, not a
correctness one.

The H4-FU3 ingest floor rejects SSTables with `maxHlc <= floor`. Because `$ver:`
writes for recent docs have HLCs well above the tombstone floor, the floor never
blocks live version history. An old peer SSTable mixing below-floor
main-namespace entries with old `$ver:` history is rejected wholesale — benign,
since those `$ver:` entries belong to docs whose tombstones were already GC'd.

Trim convergence is **eventual and approximate**: `retentionDays` is
wall-clock-gated and devices have skewed clocks and different compaction timing.
No logic may depend on exact cross-device equality of the retained `$ver:` set.

The cross-device purge / floor-interaction scenario is in the release checklist
(`docs/spec/28_release_checklist.md` RC-7).

## VersionNotFoundError

`VersionNotFoundError` is thrown by `promoteVersion` when the specified version
entry no longer exists in the `$ver:` namespace (e.g. trimmed by compaction or
versioning was disabled for the collection):

```dart
class VersionNotFoundError implements Exception {
  final String docKey;
  final Hlc requestedVersion;
  const VersionNotFoundError(this.docKey, this.requestedVersion);
}
```

## Size note

For documents with large values (or large vault URI lists), every version
retains a full copy of the `ValueCodec`-encoded value. This is acceptable for
KMDB's single-user scale but callers should be aware: a collection with large
documents and many versions will accumulate significant storage per document.
Use `maxVersions: 1` or `maxVersions: 0` for high-churn / large-value
collections.
