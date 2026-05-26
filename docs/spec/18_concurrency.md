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
to the highest-HLC entry during the streaming merge (H4 PR1), with
`$ver:` (and any registered history-bearing namespace class) exempt.
Delete-tombstone reclamation is gated by sync-horizon safety and ships
separately as H4 PR2; until then, tombstones grow without GC even after
compaction. See §6 for the full reclamation model.

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

## Performance Targets

| Operation | Target | Notes |
| :-------- | :----- | :---- |
| Put / Delete (no flush) | P99 < 5ms | WAL append + fsync. Dominant case. |
| Put (triggers flush + compact) | P99 < 200ms | Reads 128KB + writes 128KB. Every ~30 writes. |
| Get (in memtable) | P99 < 1ms | In-memory skip list. No I/O. |
| Get (single-file mode) | P99 < 2ms | 1 Bloom check + 1 block read. Common case. |
| Get (multi-level, present) | P99 < 5ms | 1–3 Bloom checks + 1 block read. |
| Get (absent key) | P99 < 3ms | Bloom filters eliminate file reads (~0.8% FPR). |
| Scan (namespace, 100 results) | P99 < 10ms | Sequential block reads across 1–3 files. |
| Database open | P99 < 100ms | Manifest replay + WAL replay (max 64KB). |
| Index build (2,000 docs) | P99 < 500ms | Full namespace scan + batch write. Background. |
| Sync push (single-file mode) | < 2s typical | Dominated by network, not engine. |
