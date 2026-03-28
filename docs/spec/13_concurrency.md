# Concurrency & Performance

## Synchronous Path (Typical Scale)

At the typical workload (2K–20K documents), all operations run synchronously on
the calling isolate. Flush (256KB memtable to SSTable) completes in low
single-digit milliseconds. L0→L1 compaction (merging four 256KB files) completes
well under 50ms on any device capable of running Flutter.

## Background Isolate (Upper Bound Scale)

At 100K+ documents, L2→L3 compaction may involve tens of megabytes of I/O. This
must not block the UI thread. The strategy follows the Drift model:

- **Dedicated background isolate:** A single long-lived isolate owns all
  compaction work.

- **RPC via SendPort:** The main isolate sends compaction requests and receives
  completion notifications.

- **FFI pointer transfer:** DynamicLibrary and Pointer objects cannot cross
  isolate boundaries. Pass raw int addresses via Pointer.fromAddress() on the
  receiving side.

- **Compaction threshold:** Background compaction is enabled when total database
  size exceeds 10MB. Below this, synchronous compaction is used.

## Performance Targets

| Operation             | Typical (20K docs) | Upper Bound (500K docs)        |
| :-------------------- | :----------------- | :----------------------------- |
| Point lookup (get)    | \< 1ms             | \< 5ms (2–3 filter checks)     |
| Insert (single)       | \< 1ms             | \< 2ms                         |
| Scan (full namespace) | \< 50ms            | \< 500ms                       |
| Filtered query        | \< 20ms            | \< 200ms (full scan \+ filter) |
| Memtable flush        | \< 5ms             | \< 10ms                        |
| L0→L1 compaction      | \< 50ms            | \< 200ms                       |
| L2→L3 compaction      | N/A                | \< 5s (background isolate)     |
