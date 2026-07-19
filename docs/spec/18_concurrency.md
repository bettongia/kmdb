# Concurrency & Performance

## Synchronous Path

All operations run synchronously on the calling isolate. This is the only
execution model — there is no background compaction scheduler.

### `WriteBatch` atomicity (in-process)

The engine commits a `WriteBatch` in three phases on the calling isolate:

1. Build a single WAL batch frame from every entry (see §7).
2. **One** `await` — the frame is appended and fsynced as one atomic unit.
3. Apply every entry to the memtable in a synchronous block, with no `await`
   between mutations.

Because Dart's single-isolate event loop never context-switches inside a
synchronous block, no concurrent `get()` can interleave with the memtable
mutations: a reader scheduled during the batch either resumes before step 3
(observes none of the batch) or after step 3 (observes the entire batch).
Write events are emitted **after** step 3, so any subscriber that re-reads in
response to the event observes the full batch.

This is the in-process counterpart to the crash-side all-or-nothing guarantee
provided by the batch frame format itself; together they ensure that a batch
is genuinely atomic at both the WAL and memtable levels.

At the target workload (200–2,000 typical documents, up to 100,000 upper bound):

- **Flush** (64KB memtable → L0 SSTable): completes in < 5ms on any device
  capable of running a Flutter application.
- **L0→L1 compaction** (merging two 64KB files): completes in < 50ms.
- **L1→L2 compaction**: completes in < 200ms.

This eliminates dual-memtable complexity, background isolate management, and the
class of bug where a background compaction races with a foreground read during
testing.

Compaction also reclaims space: superseded versions of a key are collapsed
to the highest-HLC entry during the streaming merge (H4 PR1), and surviving
delete tombstones are dropped on the all-levels `_compactAll` path when
their HLC sits strictly below the GC horizon (H4 PR2). `$ver:` (and any
registered history-bearing namespace class) is exempt from both operations.
The horizon is `min(currentHlc)` across HWMs on a synced database and
`now - tombstoneGraceDuration` (default 7 days) on a local-only one. See
§6 for the full reclamation model and §12 for the sync-side horizon
computation.

## Why No Background Isolate

The previous design considered a background isolate for compaction at the upper
bound. This was removed for the following reasons:

1. **Scale is bounded.** At the target upper bound of 100K documents and ~50MB
   working set, L1→L2 compaction reads and writes at most ~20MB. At typical
   mobile I/O speeds this completes in well under one second.

2. **Synchronous compaction on the write path** means compaction fires before
   the triggering `put()` returns. At 64KB flush threshold, compaction occurs
   roughly every 30 writes — infrequently enough that a brief pause is
   acceptable and predictable.

3. **FFI pointer transfer complexity** across isolate boundaries is eliminated.
   This was a meaningful source of implementation risk for marginal gain at
   this scale.

## The Vault Indexing Isolate (a Bounded Exception, D-1)

§20's vault content search (`VaultSearchManager`) is the one genuine
background isolate in the system — text extraction, chunking, and
tokenisation run on `VaultIndexingIsolate`, off the main isolate. This does
**not** violate the synchronous model above: the isolate touches no `KvStore`,
`WriteBatch`, or compaction state; it receives only raw decrypted bytes and
returns only extracted text, chunk metadata, and term-frequency maps.
Embedding, `WriteBatch` commits, and all filesystem artefact writes still
happen synchronously on the main isolate, exactly as every other write does.
The 2026-07-18 release-readiness review's O-4 finding confirmed this boundary
is correctly designed: no code path lets the isolate write storage directly.

**Lifecycle bounds (D-1).** A background isolate introduces one genuine risk
the rest of this model doesn't have: it can die or hang. `VaultIndexingIsolate`
bounds this on three axes:

- `Isolate.spawn` is given `onError`/`onExit` ports; either firing completes
  any in-flight work item with an error rather than leaving it to hang
  forever.
- `sendWork` times out (`kWorkTimeout`, 30s) if the isolate is alive but
  unresponsive — covering the case `onError`/`onExit` cannot observe (e.g. a
  native crash that doesn't propagate as a Dart error on every platform).
- `shutdown()` bounds how long it waits to drain in-flight work
  (`kShutdownDrainTimeout`, 5s) before abandoning it and killing the isolate
  outright.

**The load-bearing guarantee is ordering, not the bounds above.**
`KmdbDatabase.close()` flushes the memtable via `_cache.close(flush: flush)`
**before** shutting down the vault search isolate, not after. Vault-search
indexing is derived state, fully rebuildable via `reindexVault()`; the
memtable is not. A dead or hung indexing isolate can therefore delay or fail
the isolate shutdown step, but it can never prevent — or even delay — the
flush, which has already completed by the time any isolate-shutdown problem
would surface. This ordering is the actual fix for the review's confirmed
finding (a hung isolate previously blocked `close()` *before* the flush ran,
so a forced process kill after that hang lost whatever was still in the
memtable); the bounds above reduce how often a hang happens at all, but do not
by themselves remove the durability consequence of one.

## Read Cost Bound (M1 — TableCache)

Before M1, every `get()` or `scan()` call on an SSTable re-opened the file from
scratch, including re-reading and re-hashing the entire file to validate the
whole-file XXH64 checksum. This made per-read cost O(database size) — a 20 MB
L2 SSTable cost ~20 MB of I/O on every read.

The `TableCache` (see §8 — Table Cache) reduces this to a **one-time** O(file
size) cost per file per process. After the first open the footer, index block,
and Bloom filter are cached in memory; subsequent reads pay only the cost of
a data-block read (~4 KB per block). Per-read cost is now O(block), bounded and
independent of the total database size.

The P99 targets in the table below assume the `TableCache` is warm (the common
steady-state case after the first read of each file). The first read of any
SSTable after process start or after eviction from the cache will be higher.

## Performance Targets

| Operation | Target | Notes |
| :-------- | :----- | :---- |
| Put / Delete (no flush) | P99 < 5ms | WAL append + fsync. Dominant case. |
| Put (triggers flush + compact) | P99 < 200ms | Reads 128KB + writes 128KB. Every ~30 writes. |
| Get (in memtable) | P99 < 1ms | In-memory skip list. No I/O. |
| Get (single-file mode) | P99 < 2ms | 1 Bloom check + 1 block read. Common case. |
| Get (multi-level, present) | P99 < 5ms | 1–3 Bloom checks + 1 block read. Warm cache. |
| Get (warm cache, multi-file) | P99 < 5ms | TableCache hit: O(block), not O(database). |
| Get (absent key) | P99 < 3ms | Bloom filters eliminate file reads (~0.8% FPR). |
| Scan (namespace, 100 results) | P99 < 10ms | Sequential block reads across 1–3 files. |
| Database open | P99 < 100ms | Manifest replay + WAL replay (max 64KB). |
| Index build (2,000 docs) | P99 < 500ms | Full namespace scan + batch write. Background. |
| Sync push (single-file mode) | < 2s typical | Dominated by network, not engine. |
