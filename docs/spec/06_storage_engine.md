# Storage Engine (LSM)

## Write Path

1. Encode the mutation as a WAL record and append it to the active WAL file.
2. fsync the WAL file (and directory entry on Linux). Write is durable at this
   point.
3. Insert the key into the in-memory memtable (skip list).
4. If the memtable has reached the flush threshold (64KB): flush synchronously
   to **up to two L0 SSTables** (see *Flush Partitioning* below), update the
   Manifest with a single atomic VersionEdit, rotate the WAL, check the
   single-file shortcut, trigger L0 compaction if needed.
5. Return success to the caller.

All operations are synchronous on the calling isolate. At the target scale
(200–2,000 typical documents, up to 100,000 upper bound), flush and compaction
complete in single-digit milliseconds.

## Read Path

1. Check the active memtable (in-memory, O(log n) skip list lookup).
2. If a flush is in progress, check the immutable memtable snapshot.
3. Check L0 SSTables newest-first. Each check: Bloom filter query → if
   positive, binary search in index block → read data block.
4. Check L1 and L2 SSTables using range metadata to identify candidates.
   L1 and L2 have non-overlapping key ranges, so at most one file per level
   needs to be checked.

In single-file mode (see below), steps 3–4 collapse to a single Bloom check
and at most one file read — the dominant case for most users.

## LSM Tier Constants

| Parameter                | Value    | Derivation                                                                   |
| :----------------------- | :------- | :--------------------------------------------------------------------------- |
| Memtable flush threshold | 64 KB    | ~30 docs at 2KB avg. Keeps WAL replay bounded; no background scheduler needed. |
| L0 file count trigger    | 2 files  | 128KB total L0 before compaction. Compaction completes in < 50ms at this scale. |
| L1 max size              | 2 MB     | ~10x L0 total. Covers 1K–2K documents.                                       |
| L2 max size              | 20 MB    | ~10x L1. Covers up to ~20K documents. Tunable via `KvStoreConfig.l2MaxBytes`. |
| Size ratio               | 10       | Standard LevelDB ratio. Bounds read amplification at O(levels).              |
| Bloom filter bits/key    | 10       | 0.8% FPR. At 100K keys: ~125KB total filter memory.                          |
| Max SSTable file size    | 2 MB     | Bounds individual compaction I/O and sync upload size.                       |
| Block restart interval   | 16       | Every 16th key is a restart point for prefix-compressed key blocks.          |

For deployments approaching the 100K document upper bound, increase
`l2MaxBytes` to 100MB in `KvStoreConfig`.

## Single-File Shortcut

When total live bytes across all levels is 512KB or less, the engine collapses
the entire database into a single SSTable placed at L2. This is the dominant
state for the majority of users (< ~300 documents at 2KB avg):

- One Bloom filter check for any `get()`
- At most one file read for any `get()`
- Sequential read through one file for any `scan()`

The shortcut is evaluated after every flush and compaction and engages silently
— no API or behaviour change for the caller.

## Flush Partitioning (local-only namespace segregation)

At flush time the frozen memtable is **partitioned into two writers** by the
`isLocalOnly(namespace)` predicate (`namespace.startsWith(r'$$')`):

- **Syncable writer** — receives entries from user namespaces and non-`$$`
  system namespaces (`$meta`, `$cache`, `$ver:`, etc.). Produces
  `{deviceId}-{minHlc}-{maxHlc}.sst` if non-empty.
- **Local-only writer** — receives entries from `$$`-prefixed derived-data
  namespaces (`$$fts:*`, `$$vec:*`, `$$index:*`). Produces
  `{deviceId}-{minHlc}-{maxHlc}.local.sst` if non-empty.

**Empty-partition rule.** If a partition has zero entries, its writer is
discarded — no file is created and no `SstableMeta` entry is added for it.

**Single atomic Manifest append.** A single `VersionEdit` carrying up to two
`SstableMeta` entries (each with its `localOnly` flag) is appended after both
files are written and fsynced. This preserves the crash-atomicity guarantee: a
crash between the two file writes leaves both files on disk but neither
referenced by the Manifest; crash recovery discards them as orphans.

The same two-writer split is applied inside `CompactionJob.run()`, so all three
call sites (`_compactAll`, `_compactL0ToL1`, `_compactL1ToL2`) partition their
output without further changes to `LsmEngine`.

## Compaction

All compaction uses an N-way merge iterator that yields entries in ascending
internal-key order, where the internal key is
`[nsLen][ns UTF-8][userKey][hlc][type]`. The namespace bytes are UTF-8 (NFC-
normalised at the public boundary); `nsLen` is the UTF-8 byte count (1–255).
Within a single `(namespace, userKey)` group the merge emits versions
**oldest-first** (HLC ascending, because HLC is big-endian and precedes the
trailing record-type byte).

### Reclamation: version collapse

A streaming **reclamation transform** runs after the merge: per
`(namespace, userKey)` group, it keeps **only the highest-HLC entry** (the
last in the group's ascending iteration) and drops every superseded version.
This is safe at any compaction level because reads re-merge all on-disk
levels and apply Last-Write-Wins on HLC — a higher-HLC version that lives in
a level *not* part of the current compaction still wins, and a lower-HLC
version in such a level is correctly superseded by the surviving collapsed
entry. The same argument extends across devices via HLC LWW.

The transform consults a **per-namespace-class reclamation policy** for each
group. The default policy collapses to the newest version (applied to every
user namespace and to KMDB current-state system namespaces — `$meta`,
`$cache`, `$ver:`, `$sync`, and the local-only `$$` class). A namespace whose
policy returns `collapseVersions = false` is exempt and passes every version
through unchanged. The default registry exempts `$ver:` (document-versioning
history); future history-bearing namespace classes can be registered the
same way without touching the compaction code.

`$$`-prefixed namespaces (`$$fts:`, `$$vec:`, `$$index:`) use a specialised
`LocalOnlyCollapsePolicy` that relaxes the sync-horizon check for tombstone GC
(see below).

### Reclamation: tombstone GC

A delete tombstone is the **surviving entry** of its group whenever no later
write follows the delete. The compaction's streaming transform may drop such
a tombstone — eliminating its on-disk footprint — only when **both** safety
conditions hold simultaneously:

(a) **All-levels coverage.** The compaction covers every level that could
    hold an older version of the key. In KMDB this is exclusively the
    single-file `_compactAll` path: KMDB levels do *not* imply recency
    (sync ingest places old-HLC data into L0), so partial compactions
    (`_compactL0ToL1`, `_compactL1ToL2`) must always retain tombstones —
    a lower-HLC value for the same key may live in an excluded level and
    would resurrect.
(b) **Past the sync horizon.** The tombstone's HLC is strictly below the
    GC horizon, past which every device has already observed the delete.

The horizon is computed per compaction:

- **Synced database:** `min(currentHlc)` across every `.hwm` file in the
  sync folder — see §12. `SyncEngine` registers this provider on the store
  at construction time via `KvStore.setTombstoneHorizonProvider`.
- **Local-only database:** `now - tombstoneGraceDuration` (wall-clock,
  configurable via `KvStoreConfig.tombstoneGraceDuration`; default 7 days).
  The grace window protects the local → synced transition: if sync is
  enabled within the window, every tombstone written before the transition
  is still present to suppress peer values on first sync. Setting the
  grace too short risks resurrection on the first post-enable sync.

The compaction itself does not read the sync folder; the horizon is
*injected* into [`CompactionJob`](../../packages/kmdb/lib/src/engine/compaction/compaction_job.dart)
by `LsmEngine._computeTombstoneHorizon`, which consults the registered
provider (synced) or applies the wall-clock fallback (local-only).

The drop decision is made by the active `ReclamationPolicy.dropTombstone`
predicate — see `lib/src/engine/compaction/reclamation_policy.dart`.
`CollapseToNewestPolicy` (the default) drops when `allLevels && hlc <
horizon`; `RetainAllVersionsPolicy` (registered for `$ver:`) never drops.

**Local-only tombstone GC.** `$$`-prefixed namespaces use
`LocalOnlyCollapsePolicy`, which relaxes condition (b) — the sync-horizon
check is irrelevant because local-only data is never synced to other devices.
The rule: a `$$`-namespace tombstone may be dropped whenever `allLevels` is
`true`, regardless of the horizon. Condition (a) (`allLevels`) is **not**
relaxed — dropping a local-only tombstone in a partial compaction would
resurrect a deleted key from an un-compacted lower level, which is a
correctness violation.

**`tombstonesDropped` counts only syncable drops.** `CompactionJob` increments
`tombstonesDropped` only when a tombstone in a *syncable* (non-`$$`) namespace
is dropped. Local-only tombstones are elided from the output but not counted.
`_compactAll` advances the GC floor only when `tombstonesDropped > 0`, which
now correctly means "at least one syncable tombstone was GC'd." A compaction
that drops only local-only tombstones does not advance the floor.

**Stale-device eviction.** A peer whose `.hwm` `lastUpdated` is older than
`KvStoreConfig.staleDeviceEvictionAfter` (default 90 days) is excluded
from the `min(currentHlc)` computation, so the horizon advances past a
permanently absent device. The evaluating device's own `.hwm` is never
self-evicted. A returning evicted device must perform a full re-sync via
`KvStore.dropAllSstables` + redownload before pushing — see §12
"Stale-device eviction" and "Re-admission of an evicted device" for the
distributed safety argument.

**Ingest-side horizon floor.** When `_compactAll` drops at least one
tombstone, it writes the horizon used into the local-only `$$gcstate`
namespace (`MetaStore.kGcStateNamespace`) as the per-device **tombstone GC
floor**. Subsequent calls to
[`KvStore.ingestSstable`](../../packages/kmdb/lib/src/engine/kvstore/kv_store.dart)
read the floor and reject any SSTable whose `maxHlc <= floor` with a
typed `StaleSstableIngestException`. This is the recipient-side guard
against resurrection: a peer that has been excluded from the horizon
and pushes its pre-eviction SSTables (whether through a missing
re-admission check, a bug, or a test) cannot deliver records older
than the GC decision the local device has already made.

- **Comparator is `<=`, not `<`.** The drop predicate is strict
  `tombstoneHlc < horizon`, so the floor equals `horizon`. An SSTable
  with `maxHlc = horizon - 1` carries a record at the highest just-
  dropped HLC and must be rejected; the `<=` predicate is conservative
  at the boundary (an SSTable with `maxHlc == horizon` is rejected even
  though no record inside it was eligible for GC — safer than over-
  accepting).
- **Default on a fresh database is `Hlc(0, 0)`.** No realistic SSTable
  has `maxHlc <= Hlc(0, 0)`, so a never-GC'd database accepts every
  incoming SSTable.
- **Per-device, not synced.** The floor lives in the local-only `$$gcstate`
  namespace (`isLocalOnly` matches any `$$`-prefixed namespace — see §12's
  system-namespace rule), so it is never uploaded to the sync folder. Each
  device's floor reflects its own GC history.

  This was **not always true**: before the 0.10.01 WI-11 hardening pass
  (SC-10, Q-D), the floor lived in synced `$meta` under the
  device-independent key `gc:tombstoneFloor`. `$meta` uses plain
  last-write-wins, not a max-merge, so a peer's *older* floor written with a
  *later* HLC could overwrite (and lower) this device's higher floor — silently
  re-enabling the exact tombstone resurrection the floor exists to prevent.
  Moving the floor into `$$gcstate` makes this structurally impossible: the
  namespace is never uploaded, so no peer's value can ever reach it.
- **Atomicity (Q6 option b).** `CompactionJob.run()` returns a
  `VersionEdit` to `ManifestWriter` *before* control returns to
  `_compactAll`, so the floor write is a separate `$$gcstate` put after the
  manifest commits. A crash between the manifest commit and the floor
  write leaves the floor *behind* reality — pessimistic but safe: the
  engine accepts SSTables it could legitimately reject, never the
  reverse. Folding the floor write into the compaction's atomic unit
  (option c) was considered and rejected on structural grounds.
- **Full re-sync interaction.** `SyncEngine._fullResync` resets the
  floor to `Hlc(0, 0)` before re-ingesting the cloud's consolidated
  set, so a non-zero floor cannot stall the rebuild when consolidation
  has not run since the last GC cycle.

### Triggers

Compaction fires synchronously on the write path:
- **L0→L1**: when L0 reaches 2 files
- **L1→L2**: when L1 total size exceeds 2MB
- **Single-file collapse**: when total live bytes falls to or below 512KB

At the target scale, L0→L1 compaction (merging two 64KB files) completes well
under 50ms on any device capable of running a Flutter application.
