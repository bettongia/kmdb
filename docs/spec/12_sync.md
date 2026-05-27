# Sync Protocol

KMDB syncs across devices using a peer-to-peer protocol with no central server.
The sync transport is a shared cloud storage folder (Google Drive, iCloud, or
equivalent). The primary sync unit is the immutable SSTable file.

## Design Principles

- **File creation is the atomic primitive.** Never mutate a synced file after
  writing it. Cloud sync achieves consistency by making file existence binary: a
  file either exists completely or not at all.

- **SSTable-based primary sync.** For a single-user application, one device is
  typically active at a time. SSTable exchange provides efficient catch-up sync
  when switching devices.

- **WAL files are never synced.** WAL files are a local crash-recovery mechanism
  and are never written to or read from shared cloud storage. The sync layer
  operates exclusively on immutable SSTables.

- **WAL segment fast-path (future v2).** For the rare scenario of
  near-simultaneous multi-device use, WAL segment exchange can provide
  lower-latency sync. This is deferrable without architectural compromise.

- **Per-field last-write-wins.** Conflict resolution uses HLC timestamps at the
  document level. The entry with the higher HLC wins. CRDTs are reserved for
  specific data types that demand merge semantics.

- **Idempotent ingestion.** Replaying a previously-ingested SSTable produces
  identical results. This makes the protocol tolerant of interrupted sync
  cycles.

## Sync Folder Structure

```
/sync/
  highwater/
    {deviceA-id}.hwm                                    # Device A's sync progress
    {deviceB-id}.hwm                                    # Device B's sync progress
  sstables/
    {deviceA-id}-{minHlc}-{maxHlc}.sst                 # Regular flush (3 segments)
    {deviceB-id}-{minHlc}-{maxHlc}.sst                 # Regular flush (3 segments)
    {deviceA-id}-{epoch}-{minHlc}-{maxHlc}.sst         # Consolidation output (4 segments)
  .consolidation-lease                                  # Coordinator lock
  .consolidation-manifest                               # Coordinator output record
  vault/
    sha256/
      {2-char-prefix}/
        {62-char-suffix}/
          manifest.json                                 # first-writer-wins
          blob                                          # content-identical across devices
          tombstone.json                                # present if zero-ref on any device
```

For SSTables and `.hwm` files, each device writes only to its own files —
no two devices ever write to the same file. Vault objects are the exception:
vault files are content-addressed and identical across all devices, so the
vault directory is shared. Conflicts are avoided by content-identity (`blob`)
and first-writer-wins (`manifest.json`). See §24 for the full vault sync
design and `VaultStorageAdapter` interface.

## Per-Device High-Water Mark Files

Each device maintains a .hwm file recording the highest HLC timestamp it has
fully processed from every peer. This file is the one file each device mutates
repeatedly, but since only one device writes to its own .hwm file, cloud sync
will never produce a conflict.

Example: `deviceA.hwm`:

```jsonc
{
  "deviceId": "a1b2c3d4",
  "currentHlc": "017F8A0B3000",
  "lastUpdated": "2026-03-27T10:30:00Z",
  "peers": {
    "f9e8d7c6": "017F8A0B2FFF",
    // highest HLC processed from device B
    "1a2b3c4d": "017F8A0A0000",
    // highest HLC processed from device C
  },
}
```

The `.hwm` file also contains the device's own current HLC timestamp and a
wall-clock last-updated time. This enables stale device detection for the
[tombstone retention policy](#tombstone-retention-garbage-collection).

## Sync Cycle (Primary Path)

When a device comes online or returns to foreground:

1. Read all .hwm files in the highwater/ directory to understand overall sync
   state.

1. Read own .hwm file to determine what has already been processed from each
   peer.

1. Scan the sstables/ directory for files from other devices with minHlc greater
   than the recorded high-water mark for that device.

1. Download and ingest each new SSTable at L0. Verify the footer XXH64 checksum
   before use.

1. If L0 count exceeds the trigger threshold after ingestion, run compaction.

1. Update own .hwm file with the new high-water marks for each peer.

1. Upload any locally-produced SSTables that have not yet been uploaded.

1. Upload own updated .hwm file.

Remote SSTables always enter at L0 A file at L2 on the originating device cannot
be placed at L2 locally without violating the non-overlapping range invariant.
Ingesting at L0 ensures the local compaction path runs with full visibility of
the local key history.

## Conflict Resolution

Conflicts arise when two devices write to the same key while offline. Resolution
occurs during compaction merge:

- **Default: Last Write Wins by HLC.** The entry with the higher HLC timestamp
  (sequence number) is retained.

- **Same-HLC tiebreaker:** If two entries have identical HLC timestamps (rare
  but possible), the device ID with the higher lexicographic value wins. This
  guarantees a total ordering so merge is deterministic regardless of which
  device performs it.

- **Tombstone vs Put:** A Delete tombstone wins over an older Put. A Put wins
  over an older Delete. At equal HLC, Put wins as a conservative choice.

- **Application-level merge (optional):** A MergeOperator callback can be
  registered at engine open time. When two versions of the same key from
  different devices are encountered during compaction, the callback receives
  both values and returns a merged result. This enables CRDT-style merge without
  changes to the storage layer.

## Tombstone Retention & Garbage Collection

Tombstones must be retained until every known device has processed past the
tombstone's HLC timestamp; dropping them sooner allows a peer holding an
older copy of the deleted key to resurrect it on next sync. The protocol
uses `.hwm` files to compute a **GC horizon** that compaction consults
before dropping a surviving tombstone.

- **GC horizon (synced).** `HighwaterMark.minCurrentHlcAcrossDevices` scans
  every `{syncRoot}/highwater/*.hwm` file and returns
  `min(currentHlc)` — every device has reported syncing past this point.
  A tombstone with HLC strictly below the horizon has been observed
  everywhere and is safe to drop. `SyncEngine`'s constructor registers
  this computation as the store's horizon provider via
  `KvStore.setTombstoneHorizonProvider`.

- **GC horizon (local-only).** When no `SyncEngine` is attached, the engine
  falls back to `now - tombstoneGraceDuration` (default 7 days, see
  `KvStoreConfig`). The grace window is a conservative bound that protects
  the local → synced transition: if sync is enabled within the window,
  every tombstone written before the transition is still present to
  suppress peer values on first sync.

- **Safety conditions.** A surviving tombstone is dropped only when both:
  (a) the compaction covers every level that could hold an older version
  (in practice, the single-file `_compactAll` path — KMDB levels do *not*
  imply recency because sync ingest places old-HLC data into L0; partial
  compactions always retain tombstones); and (b) `tombstone.hlc < horizon`.
  See `docs/spec/06_storage_engine.md#reclamation-tombstone-gc` for the
  engine-side mechanism.

- **Known limitation: slowest-device peg.** The strict `min(currentHlc)`
  horizon is pegged by the slowest device. A peer that goes offline and
  never returns blocks tombstone GC indefinitely. An eviction rule (max
  device staleness) is intentionally deferred — see
  `docs/plans/completed/plan_tombstone_gc.md`. A stale-device policy similar to the
  one historically described here (90-day timeout, requiring full re-sync)
  is the expected follow-up.

- **SSTable garbage collection:** An SSTable can be deleted from the sync
  folder when every device's `.hwm` file shows processing past that
  SSTable's maxHlc. The device that produced the SSTable is responsible
  for deleting it, avoiding race conditions on deletion.

## `KmdbDatabase` Sync API

Sync is exposed as first-class methods on `KmdbDatabase`. Application code never
needs to construct `SyncEngine` directly.

```dart
// Open the database (deviceId is established by ensureDeviceId before sync).
final db = await KmdbDatabase.open(path: '/path/to/db', adapter: adapter);
await db.ensureDeviceId(); // loads or generates stable device identity

// Full push-then-pull cycle against a named remote adapter.
await db.sync(syncAdapter: GoogleDriveAdapter(...));

// Push only.
await db.push(syncAdapter: LocalDirectoryAdapter('/Volumes/NAS/MyApp/sync'));

// Pull only, with consolidation tuned for testing.
await db.pull(
  syncAdapter: MemorySyncAdapter(),
  consolidationConfig: ConsolidationConfig.forTesting(),
);
```

All three methods accept the same named parameters:

| Parameter             | Type                  | Default                      | Description |
| --------------------- | --------------------- | ---------------------------- | ----------- |
| `syncAdapter`         | `SyncStorageAdapter`  | required                     | Remote adapter (cloud folder, NAS, etc.) |
| `syncRoot`            | `String`              | `''`                         | Path prefix within the adapter root |
| `syncNamespaces`      | `Set<String>?`        | all user (non-`$`) namespaces | Restrict sync to a subset of collections |
| `localAdapter`        | `StorageAdapter?`     | `StorageAdapterNative()`     | Local file I/O adapter; override in tests |
| `consolidationConfig` | `ConsolidationConfig` | `ConsolidationConfig()`      | Controls the consolidation threshold and lease TTL |

**Native-only.** These methods use `dart:io` for local SSTable I/O and throw
`UnsupportedError` on web.

### `ensureDeviceId()`

```dart
final deviceId = await db.ensureDeviceId();
```

Loads or generates a stable 8-character lowercase hex device identifier.
Production apps should call this once after opening the database, before the
first `push()`. The default `'00000000'` identifier used by tests is not
suitable for real sync: SSTables named with it will collide across machines.

## Namespace-Scoped Sync

Not all namespaces should sync. A `local_cache` or `settings` namespace
typically contains device-specific data. Pass `syncNamespaces` to restrict sync
to a subset of collections:

```dart
// Sync only 'notes', 'contacts', and 'tasks'; exclude 'settings' and 'cache'.
await db.sync(
  syncAdapter: GoogleDriveAdapter(...),
  syncNamespaces: {'notes', 'contacts', 'tasks'},
);
```

When `syncNamespaces` is omitted, all registered user collections (those without
a `$` prefix) are synced. System namespaces (`$meta`, `$index:*`, `$fts:*`,
`$vec:*`, `$cache`) are never uploaded regardless of this parameter.

During SSTable upload, the sync layer filters to include only entries for
sync-enabled namespaces. This avoids uploading megabytes of device-local cache
data.

## Cross-Device Compaction Coordinator

Each device produces SSTables independently and flushes them to the shared sync
folder. Periodically, the set of on-disk SSTables must be consolidated —
redundant versions merged, tombstones dropped, file count reduced — so that read
performance and storage consumption remain bounded regardless of how many
devices are actively writing.

Because there is no designated primary device, any client may initiate
consolidation. The coordinator design must therefore satisfy three invariants:

- **Safety:** at most one client executes consolidation at any time. Concurrent
  merges of overlapping SSTables produce incorrect output.

- **Liveness:** a crashed or network-partitioned coordinator does not
  permanently block consolidation. Any surviving client can take over after the
  lease expires.

- **Observability:** in-progress, completed, and abandoned consolidation states
  are distinguishable without opening any SSTable. Recovery logic must not
  require the original coordinator.

### Lease File Protocol

Coordination is mediated by a single well-known file in the shared sync folder:

```
<sync-root>/
  {deviceId}-{minHlc}-{maxHlc}.sst           ← regular flush SSTables (3 segments)
  {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst   ← consolidation output (4 segments)
  .consolidation-lease                        ← coordinator lock (this section)
  .consolidation-manifest                     ← output record
```

The lease file is a UTF-8 JSON document written atomically via a
write-to-temp-then-rename sequence. Its presence means consolidation is claimed;
its absence means no client holds the lock. The lease file is never appended to
— it is always replaced wholesale.

#### Lease file schema

```jsonc
{
  "version": 1,
  "coordinatorId": "a3f2b1c9", // deviceId of the claiming client
  "epoch": 7, // monotonically increasing per coordinatorId
  "acquiredAtMs": 1743724800000, // wall-clock ms at acquisition (HLC physical)
  "ttlMs": 120000, // lease duration; coordinator must renew before expiry
  "inputFiles": [
    // SSTables in scope at acquisition time (regular flush format — 3 segments)
    "a3f2b1c9-017F8A0A00000000-017F8A0AFFFF0000.sst",
    "b7e10f44-017F8A0900000000-017F8A09FFFF0000.sst",
  ],
  "fencingToken": "a3f2b1c9-7", // coordinatorId + epoch; embedded in output filenames
}
```

_Why epoch rather than a UUID?_

An ever-increasing epoch per device gives the fencing token a total order for
the same coordinator. If device "a3f2b1c9" crashes and re-acquires, its epoch
increments and any output files from the previous attempt carry a stale token
that is trivially detectable. A random UUID would require a separate registry to
establish ordering.

### Acquiring the Lease

A client wishing to consolidate executes the following steps. The sequence is
designed so that the only non-atomic operation — the rename — is the commit
point.

1. **Check for an existing lease.** Read .consolidation-lease if present. If
   absent, proceed to step 2\. If present, verify the lease has expired
   (currentTimeMs \> acquiredAtMs \+ ttlMs). If not expired, abort — another
   coordinator is active.

2. **Validate the incumbent's output.** If the lease is expired, check whether
   .consolidation-manifest records a completed consolidation whose output files
   all exist on disk. If so, the previous coordinator finished but failed to
   clean up. Adopt the output (§12.6.5) rather than re-consolidating.

3. **Write a candidate lease to a temp file.** Name it
   .consolidation-lease.\<deviceId\>.tmp. Populate all fields. Set epoch \=
   (previous epoch for this deviceId) \+ 1, or 0 if first acquisition.

4. **Rename the temp file to .consolidation-lease.** On POSIX filesystems and
   cloud object stores that support atomic conditional-PUT (GCS, S3 via
   if-none-match), this is the linearisation point. On platforms without atomic
   rename, use the compare-and-swap write pattern described in §12.6.7.

5. **Re-read the lease file.** Confirm that coordinatorId and epoch match what
   was just written. If another client won the race, its data will appear
   instead. In that case, abort.

#### ⚠ Clock skew and TTL selection

The TTL must be long enough to survive the slowest expected consolidation plus a
renewal cycle, but short enough that a crashed coordinator does not hold the
lease for an operationally significant period. The recommended default is 120
seconds. At the target data scale (≤ 20MB total), a full consolidation completes
well under 10 seconds on any supported device, leaving ample headroom for
renewal. Clock skew between devices is bounded at 60 seconds (§Appendix A), so
the effective detection window after a crash is at most 120 \+ 60 \= 180
seconds.

### State Machine

The coordinator transitions through five states. Every state is durable — a
client recovering from a crash can reconstruct the current state entirely from
the lease file and the files present in the sync folder.

| State          | Observable condition                                                                           | Valid next states                           |
| :------------- | :--------------------------------------------------------------------------------------------- | :------------------------------------------ |
| IDLE           | No .consolidation-lease file exists                                                            | LEASE_ACQUIRED                              |
| LEASE_ACQUIRED | Lease file present; no output files with matching fencingToken exist yet                       | CONSOLIDATING, IDLE (on abort)              |
| CONSOLIDATING  | Lease file present and valid; partial or complete output files with fencingToken exist on disk | VERIFYING, LEASE_EXPIRED                    |
| VERIFYING      | All expected output files present; .consolidation-manifest written; lease still valid          | COMPLETE, LEASE_EXPIRED                     |
| COMPLETE       | .consolidation-manifest records success; all input files deleted; lease file deleted           | IDLE                                        |
| LEASE_EXPIRED  | Lease present but currentTimeMs \> acquiredAtMs \+ ttlMs                                       | LEASE_ACQUIRED (new coordinator takes over) |

The state machine is intentionally asymmetric: transitions into COMPLETE require
all three cleanup steps (manifest written, input files deleted, lease deleted)
to have succeeded. A client that completes the merge but crashes before deleting
the lease leaves the system in a recoverable VERIFYING-like state that the next
coordinator can detect and resolve without re-merging.

### Consolidation Manifest

> **Implementation note:** the `.consolidation-manifest` file described in this
> section is not written by the current `ConsolidationCoordinator`
> implementation. Instead, `commit()` deletes input files idempotently
> (non-fatal on missing files) and then releases the lease. This is safe because
> the output SSTable is uploaded before any input is deleted, so a crash mid-
> commit leaves the system with both old inputs and the new output; the next
> coordinator re-runs the threshold check, observes the output is already
> present (lower count), and skips consolidation. The full manifest protocol
> below remains the intended target for implementations that need stronger
> crash-recovery guarantees (e.g. when the input count is very high and re-
> merging would be expensive).

Before deleting any input file, the coordinator writes a consolidation manifest.
This file records what was merged and what the output is, so that any client —
including one that did not perform the merge — can validate and adopt the
result.

```jsonc
{
  "version": 1,
  "fencingToken": "a3f2b1c9-7",
  "completedAtMs": 1743724812345,
  "inputFiles": [
    "a3f2b1c9-017F8A0A00000000-017F8A0AFFFF0000.sst",
    "b7e10f44-017F8A0900000000-017F8A09FFFF0000.sst",
  ],
  "outputFiles": ["a3f2b1c9-7-017F8A090000-017F8A0AFFFF.sst"],
  "inputEntryCount": 1840,
  "outputEntryCount": 1203, // <= inputEntryCount after dedup + tombstone drop
  "status": "complete", // "complete" | "partial"
}
```

#### outputEntryCount as a sanity check

The coordinator verifies outputEntryCount \<= inputEntryCount before committing.
If this invariant is violated, the merge produced more entries than it consumed
— a certain sign of a bug in the deduplication or tombstone-dropping logic. The
coordinator must abort, delete its output files, release the lease, and log a
diagnostic rather than committing corrupt output.

### Cross-Device Sequence Number Ordering

Within a single device, the HLC sequence number is monotonically increasing.
Across devices it is not — two devices may produce identical or inverted HLC
timestamps after a clock adjustment, or simply because they have never
communicated.

The consolidation merge iterator therefore uses a compound sort key rather than
sequence number alone:

```dart
// Internal key ordering for cross-device merge (ascending)
//
// Primary:   userKey ASC
// Secondary: sequenceNumber DESC   (higher seq = more recent, within one device)
// Tertiary:  deviceId DESC         (arbitrary but stable tiebreaker across devices)
//
// The tertiary sort ensures deterministic output when two devices write the same
// key at the same HLC timestamp — a rare but theoretically possible event.
int compareInternalKeys(InternalKey a, InternalKey b) {
  final keyOrd = a.userKey.compareTo(b.userKey);
  if (keyOrd != 0) return keyOrd;
  final seqOrd = b.sequenceNumber.compareTo(a.sequenceNumber); // DESC
  if (seqOrd != 0) return seqOrd;
  return b.deviceId.compareTo(a.deviceId);                     // DESC, stable
}
```

#### ⚠ Application-level conflict semantics

The tiebreaker above makes the merge deterministic and safe, but it does not
implement application-level conflict resolution. If two devices write different
values for the same key at the same HLC timestamp, the higher deviceId wins
silently. Applications requiring last-write-wins with user-visible conflict
notification must record both versions and surface the conflict at read time —
this is out of scope for the storage layer and must be handled by the sync layer
above it.

### Lease Renewal

For consolidations that approach the TTL boundary — possible if the sync folder
is on a slow network mount or if the device is under load — the coordinator must
renew the lease before it expires. Renewal rewrites the lease file with an
updated acquiredAtMs while keeping the same epoch and fencingToken.

```dart
// Renewal is a conditional write: only proceed if the lease on disk
// still matches our fencingToken. If it does not, a competing client
// has taken over and we must abort our merge immediately.

Future<bool> renewLease(ConsolidationLease current) async {
  final onDisk = await readLease();
  if (onDisk == null || onDisk.fencingToken != current.fencingToken) {
    return false; // preempted — abort merge
  }
  final renewed = current.copyWith(acquiredAtMs: DateTime.now().millisecondsSinceEpoch);
  await writeLease(renewed); // atomic rename
  return true;
}
```

The coordinator should schedule renewal at 50% of TTL elapsed (60 seconds with
the default 120s TTL). If renewal fails — either because the write fails or
because the on-disk fencing token does not match — the coordinator must stop
writing output immediately, discard any partial output files it has written, and
exit the CONSOLIDATING state. It must not delete any input files.

### CAS Atomicity Contract and Capability

The lease acquisition protocol calls `SyncStorageAdapter.compareAndSwap`.
For the safety invariant to hold — at most one coordinator executes
consolidation at any time — that method must satisfy the following contract:

> **Contract:** for a given `(path, ifMatchEtag)` precondition, at most one
> concurrent caller observes `true`. Any number of callers may observe `false`;
> exactly zero or one observes `true`.

Not all backends can honour this. A `LocalDirectoryAdapter` pointed at a
cloud-synced folder (Dropbox, OneDrive, iCloud-as-local-FS) operates against
an eventually-consistent replica: the `existsSync()` check and the subsequent
rename are not atomic across devices, so two coordinators on different machines
can both believe they won the lease race.

#### `SyncStorageAdapter.providesAtomicCas`

Every `SyncStorageAdapter` implementation exposes:

```dart
bool get providesAtomicCas;
```

This declares whether the adapter can satisfy the contract above for the
backend it is connected to. It is a **per-instance** property, not a type-level
property, because the same class (`LocalDirectoryAdapter`) can be atomic on a
true local filesystem and non-atomic on a cloud-synced replica of that
filesystem.

| Adapter | `providesAtomicCas` |
| :--- | :--- |
| `MemorySyncAdapter` | `true` — CAS is synchronous and single-threaded within the process |
| `LocalDirectoryAdapter` (default, `atomicCas: false`) | `false` — non-atomic read-check-write; use this for cloud-synced folders |
| `LocalDirectoryAdapter(atomicCas: true)` | `true` — `File.create(exclusive: true)` + advisory lock; use on true local disks |

#### Gating: consolidation requires atomic CAS

`ConsolidationCoordinator.runIfNeeded` checks `providesAtomicCas` before
attempting lease acquisition. If the adapter returns `false`:

- Consolidation is **skipped entirely** — no lease file is touched.
- The coordinator transitions to the `skippedNonAtomicCas` state and records a
  human-readable `skipReason`.
- The skip is **loss-free**: SSTables are still exchanged via normal push/pull;
  they merely accumulate un-consolidated. Consolidation is a storage-shape
  optimisation, not a correctness requirement.

This gating prevents the H5 data-loss hazard: without it, two coordinators on
different devices behind a non-atomic adapter can both believe they hold the
lease and delete each other's input SSTables.

#### `LocalDirectoryAdapter` atomic-CAS implementation

When constructed with `atomicCas: true`, the adapter uses platform primitives
to enforce the contract:

- **Create-if-absent** (`ifMatchEtag == null`): `File.create(exclusive: true)`,
  which maps to `open(O_CREAT | O_EXCL)` on POSIX and `CreateFile(CREATE_NEW)`
  on Windows. This is an atomic kernel call — exactly one caller wins; all
  others get an exception mapped to `false`.
- **Update-if-match** (`ifMatchEtag != null`): an exclusive `fcntl` advisory
  lock (`FileLock.blockingExclusive`) is acquired on the existing file before
  re-reading its ETag, ensuring the read-compare-write sequence is serialised
  against other cooperative processes on the same host.

These primitives are effective for the intra-host, multi-process use case (e.g.
two CLI processes or two app instances sharing a local sync directory). They do
**not** protect against cross-device contention — that is inherently not
achievable via filesystem operations on a locally-synced cloud folder.

### Platform Atomic Write Strategies

The behaviour of `SyncStorageAdapter.compareAndSwap` differs across deployment
targets:

| Platform                                        | Atomic primitive                                         | Implementation                                                                                                                  |
| :---------------------------------------------- | :------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------ |
| True local filesystem (single host, multi-process) | `O_CREAT\|O_EXCL` + `fcntl` advisory lock | `LocalDirectoryAdapter(atomicCas: true)`. Use for local directories shared between processes on the same machine. |
| Cloud-synced folder (Dropbox, OneDrive, iCloud Desktop) | None — eventually-consistent replica | `LocalDirectoryAdapter(atomicCas: false)` (default). `ConsolidationCoordinator` skips consolidation. SSTables accumulate un-consolidated; data is never lost. |
| iOS / Android (local app sandbox)               | Same as true local filesystem                            | `LocalDirectoryAdapter(atomicCas: true)`. Single device, single process — only one coordinator possible. |
| Cloud object storage (GCS)                      | Conditional PUT with if-none-match / if-generation-match | Upload lease JSON with if-generation-match: \<expected-generation\>. HTTP 412 means another client won the race. Adapter must return `providesAtomicCas = true`. |
| Cloud object storage (S3)                       | No native CAS. Use DynamoDB conditional writes as a lock | Acquire a DynamoDB item with a condition expression before writing to S3. Release on completion. Adapter must return `providesAtomicCas = true`.                |
| Web (OPFS)                                      | createSyncAccessHandle is exclusive per-file per-origin  | Acquire a sync access handle on .consolidation-lease. Only one handle can be open at once per origin — enforced by the browser. |

#### OPFS limitation

The OPFS exclusive handle approach only prevents concurrent consolidation within
the same browser origin on the same device. Cross-device coordination still
relies on the cloud storage primitive — OPFS provides only local mutual
exclusion, not distributed mutual exclusion.

### Failure Scenarios and Recovery

Every failure scenario is recoverable without data loss. The recovery action is
determined by reading the lease file and the manifest file, then inspecting
which files exist on disk.

| Failure point                                                 | Observable state                                                                                    | Recovery action                                                                                                                                      |
| :------------------------------------------------------------ | :-------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crash after lease write, before any output files written      | Lease present; no output files with fencingToken; lease expired                                     | New coordinator acquires lease (epoch \+1). All input files intact — perform full consolidation.                                                     |
| Crash mid-merge (partial output files on disk)                | Lease expired; partial output files with stale fencingToken exist; no manifest                      | New coordinator deletes stale output files, acquires fresh lease, re-merges from original input files.                                               |
| Crash after merge complete, before manifest written           | Lease expired; all output files present with fencingToken; no manifest                              | New coordinator can detect output file coverage matches input files. Write manifest, delete inputs, delete lease. No re-merge needed.                |
| Crash after manifest written, before input files deleted      | Manifest present with status=complete; input and output files both present; lease expired or absent | New coordinator reads manifest, verifies output files exist, deletes input files, deletes lease. Safe because manifest is the commit record.         |
| Crash after inputs deleted, before lease deleted              | Manifest present; only output files remain; lease present (expired)                                 | New coordinator reads manifest, confirms output files exist, deletes lease. IDLE state restored.                                                     |
| Coordinator alive but partitioned from sync folder for \> TTL | Lease expired on disk; coordinator still running and writing output                                 | Coordinator must detect renewal failure (§12.6.6) and abort. Output files not yet committed are discarded. A second coordinator may safely take over. |

### Triggering Consolidation

Consolidation is triggered by any client that observes the SSTable count in the
shared sync folder exceeding the threshold, subject to a per-device backoff to
reduce contention on the lease:

```dart
bool shouldAttemptConsolidation({
  required int sharedSstCount,
  required int consolidationThreshold,   // default: 8 cross-device SSTables
  required Duration timeSinceLastAttempt,
  required Duration backoffDuration,     // default: 5 minutes per device
}) {
  if (sharedSstCount < consolidationThreshold) return false;
  if (timeSinceLastAttempt < backoffDuration) return false; return true;
}
```

The backoff is per-device and is not coordinated. It exists solely to reduce the
probability of multiple clients attempting lease acquisition simultaneously.
Because lease acquisition is safe under concurrency — at most one client
succeeds — the backoff affects efficiency only, not correctness.

#### Why 8 SSTables as the default threshold?

At the target write rate of 1–10 puts/second and flush threshold of 64KB
(roughly 30 documents), a single device produces at most one new L0 file every
3–30 seconds under sustained load. With four devices writing concurrently, the
shared folder accumulates 8 L0 files in approximately 6–60 seconds. Triggering
consolidation at 8 files keeps the cross-device file count in the same order of
magnitude as the per-device L0 cap (2 files), preventing unbounded read
amplification when reading across all devices.

### Dart Class Outline

The coordinator is a single Dart class with no persistent state of its own — all
state is derived from the lease file and the manifest on each call:

```dart
/// Coordinates cross-device SSTable consolidation using a lease file
/// in the shared sync folder. All methods are idempotent and safe to
/// call concurrently from multiple devices.
class ConsolidationCoordinator {
  final SyncFolderAdapter _folder; // abstracts POSIX / OPFS / GCS / S3
  final String deviceId;
  final ConsolidationConfig config;

  /// Entry point. Returns ConsolidationResult indicating whether this
  /// device performed consolidation, adopted a prior result, or yielded
  /// to another coordinator.

  Future<ConsolidationResult> runIfNeeded() async {}

  /// Attempts to acquire the lease. Returns the acquired lease on
  /// success, null if another coordinator holds a valid lease.
  Future<ConsolidationLease?> acquireLease() async {}

  /// Performs the N-way merge over inputFiles, writing output files
  /// with the fencingToken embedded in their names. Calls renewLease()
  /// periodically. Returns null if preempted.
  Future<List<SstFile>?> consolidate(ConsolidationLease lease) async {}

  /// Writes the manifest, deletes input files, deletes the lease.
  /// Each step is individually retryable — partial completion is safe.
  Future<void> commit(ConsolidationLease lease, List<SstFile> output) async {}

  /// Inspects current sync folder state and returns a RecoveryAction
  /// describing what, if anything, needs to be cleaned up.
  Future<RecoveryAction> assessRecoveryState() async {}
}

class ConsolidationConfig {
  final int thresholdFileCount; // default: 8
  final int ttlMs; // default: 120 000
  final int renewalIntervalMs; // default: 60 000 (50% of TTL)
  final Duration perDeviceBackoff; // default: 5 minutes

  /// Config suitable for unit tests: tiny threshold, short TTL,
  /// zero backoff — forces every code path with a handful of writes.
  factory ConsolidationConfig.forTesting() => ConsolidationConfig(
    thresholdFileCount: 2,
    ttlMs: 5000,
    renewalIntervalMs: 2000,
    perDeviceBackoff: Duration.zero,
  );
}

```
