---
title: KMDB Feature Roadmap
subtitle: Ideas, unfilfilled
toc-title: "Contents"
...

# Command line interface (CLI) (High priority)

Implement a CLI that allows users to interact with the KMDB database via either batch operations or in an interactive REPL. The CLI should be its own package and may require the current codebase to move to a monorepo that utilises Pub Workspaces.

# SAHPool OPFS (High priority)

Migrate `StorageAdapterWeb` from async File System API to
  Sync Access Handles in a dedicated Web Worker for 3–4× throughput.

# Performance Benchmarks (High priority)

Create a performance benchmarking suite that can measure the performance of single- and multi-device use of KMDB.

`benchmark/` directory validating P99 targets from
  §18 (Concurrency):
  - Put / Delete (no flush): P99 < 5ms
  - Put (flush + compact): P99 < 200ms
  - Get (memtable): P99 < 1ms
  - Get (single-file mode): P99 < 2ms
  - Scan (100 results): P99 < 10ms
  - Database open: P99 < 100ms

# Encryption (medium priority)

Look at encryption options for the local and shared data.

Consider Per-platform secure storage (iOS Keychain, Android SharedPreferences, web `localStorage`, desktop app-data dir) injectable via a `PlatformIdStore` interface; default falls back to `$meta`.

Consider encryption at the value level in the KV store. This will need to be very user-friendly and could follow an approach of the user selecting their own salt rather than approaches such as managing PGP keys. The approach needs to work in the environment where the user understands little about encryption and won't store things like private keys right next to the KMDB data in their chosen storage location (e.g. local directory or Google Drive)

# Cloud Adapter: Google Drive (medium priority)

Directly connect to Google Drive for storing sync objects such as the SSTables etc. It's likely that the Encryption roadmap item should be combined with this.

- Drive REST API + `If-Match` ETag
- `GcsAdapter` (GCS JSON API), implements `CloudAdapter`
- Each adapter lives under `lib/src/sync/cloud/`.

# Cloud Adapter: Apple iCloud (low priority)

Directly connect to iCloud for storing sync objects such as the SSTables etc.

- Each adapter lives under `lib/src/sync/cloud/`.
- `ICloudAdapter` (CloudKit record change tags)

# Cloud Adapter: Google Cloud Storage (low priority)

GCS will be the first object store adapter.

# Document version history & conflict resolution (low priority)

KMDB currently uses Last-Write-Wins (LWW) via HLC timestamps to resolve
conflicts during sync compaction. This is correct and deterministic, but silent:
when two devices independently edit the same document, the lower-timestamp write
is discarded without the application being informed.

A future version could maintain a lightweight version lineage per document —
similar to CouchDB's revision model — so that a "fork" (two writes both
descended from the same base version) is detectable rather than silently
resolved. This would enable:

- **Conflict surfacing:** an `onConflict` callback or `conflicts()` query that
  exposes document pairs where LWW had to choose, letting the application decide
  whether the outcome is correct.
- **Version inspection:** access to the discarded version for a configurable
  retention window, so the user or application can cherry-pick fields from the
  losing write.
- **Guided merge UI:** for applications like note-taking or contact management,
  the ability to present both versions to the user and let them accept, reject,
  or hand-merge changes field by field.

The implementation would likely store a compact ancestry token (e.g. a
`{deviceId, hlc}` pair) alongside each document write. The merge iterator during
compaction could detect a fork when two entries for the same key have ancestry
tokens that share a common ancestor but diverge, rather than one being a direct
descendant of the other.

This is complementary to (not a replacement for) the `MergeOperator` escape
hatch, which is better suited to programmable CRDT-style merges (counters,
sets).

References:

- [CouchDB conflict model](https://docs.couchdb.org/en/stable/replication/conflicts.html)
- [Vector clocks (Lamport)](https://en.wikipedia.org/wiki/Vector_clock)

# Full-text search (medium priority)

Support traditional full-text search and vector-based searches.

References:

- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [Postgres Full Text Search](https://www.postgresql.org/docs/current/textsearch.html)

---

<!-- prettier-ignore-start -->
KMDB Documentation © 2026 by The KMDB Authors is licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
![](https://mirrors.creativecommons.org/presskit/icons/cc.svg){width=1em height=1em}
![](https://mirrors.creativecommons.org/presskit/icons/by.svg){width=1em height=1em}
<!-- prettier-ignore-end -->
