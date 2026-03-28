# Watch / Reactivity

watch() returns a broadcast Stream that re-emits query results when relevant
writes occur. The implementation uses debounced re-execution:

- **On any write to the watched namespace:** schedule a re-query after the
  debounce window (default 50ms).

- **Debouncing:** A putMany of 10 documents triggers one re-query, not 10\.

- **Namespace scoping:** A write to the "tasks" namespace does not trigger
  re-query on a "notes" watcher.

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
