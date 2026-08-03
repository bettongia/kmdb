# Watch / Reactivity

See §13 for the full `KmdbQuery<T>` terminal-method API, of which `watch()` is
one; this section covers only its debounce and invalidation semantics.

watch() returns a broadcast Stream that re-emits query results when relevant
writes occur. The implementation uses debounced re-execution:

- **On any write to the watched namespace:** schedule a re-query after the
  debounce window (default 50ms).

- **Debouncing:** A putMany of 10 documents triggers one re-query, not 10\.

- **Namespace scoping:** A write to the "tasks" namespace does not trigger
  re-query on a "notes" watcher.

- **Cross-device reactivity.** A peer's data arriving via sync (ingested as an
  SSTable, not written locally) also re-fires `watch()`/`stream()` for any
  namespace present in the ingested data. `LsmEngine.ingestAt0` scans each
  ingested SSTable once for its distinct namespaces and emits a `writeEvent`
  for exactly that set (0.10.01 WI-13) — the same precise, per-namespace
  semantics as a local `writeBatch`. Before this fix, ingest emitted only a
  generic `$sync` event that no query terminal consumed, so a `watch('tasks')`
  never re-fired when a peer's `tasks` data arrived until this device made its
  own subsequent local write to `tasks`.

## Scaling Watch at 100K+ Documents

At the revised scale, re-running a filtered query over 100K documents on every
write (even debounced) can consume meaningful CPU. Mitigations:

- **Namespace-level dirty tracking:** If the write does not touch the namespace
  being watched, skip the re-query entirely.

- **Key-range filtering:** If the write's key falls outside the watched query's
  key range (for range-bounded queries), skip.

- **Future: field-level indexing.** For commonly-watched fields, a lightweight
  in-memory index can answer orderBy and equality filters without full-scan. The
  query API is designed so orderBy is clearly separated from the scan path,
  making index slot-in straightforward.
