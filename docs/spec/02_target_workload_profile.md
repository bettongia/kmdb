# Target Workload Profile

KMDB is designed for the single-user personal application workload: collections
of hundreds to low thousands of documents, written by user interaction rather
than batch processes, read frequently for UI rendering, and occasionally
synchronised across two to five personal devices.

Every architectural constant in this document is derived from the following
workload assumptions. If actual deployment diverges significantly, the tier
constants in [LSM Tier Constants](#lsm-tier-constants) should be revisited.

| Parameter                | Typical        | Upper Bound | Notes                                          |
| :----------------------- | :------------- | :---------- | :--------------------------------------------- |
| Documents per namespace  | 50–500         | 5,000       | A namespace maps to a document collection.     |
| Namespaces per database  | 3–10           | 50          | e.g. contacts, notes, tasks, settings.         |
| Total documents per user | 200–2,000      | 100,000     | Across all namespaces.                         |
| Average document size    | 1–4 KB         | 64 KB       | CBOR-encoded. ~20–30% smaller than equivalent JSON. |
| Total working set        | 1–8 MB         | 50 MB       | Sum of all live document bytes after encoding. |
| Write rate               | 1–10 puts/sec  | 100/sec     | User-driven interactions, not bulk import.     |
| Read rate                | 10–100 gets/sec| 500/sec     | UI rendering of document lists.                |
| Devices per user         | 1–3            | 5           | Phone + tablet + desktop.                      |
| Sync frequency           | On focus/resume | Continuous | Triggered on app foreground.                   |

## Design Boundary

KMDB is not designed for:
- **Bulk import** — tens of thousands of documents in a single session
- **Streaming time-series data** — high-frequency append-only workloads
- **Multi-user concurrent write access** — all writes are single-user
- **Server-side deployments** — KMDB runs inside a Flutter application

The upper bound of 100,000 total documents is supported but not the primary
target. At this scale all operations remain synchronous on the calling isolate —
no background scheduler is required. The `KvStoreConfig` class exposes level
size parameters for tuning if a deployment consistently approaches the upper
bound.
