# Target Workload Profile

Every architectural constant in this document is derived from the following
workload assumptions. If actual deployment diverges significantly, the tier
constants in [LSM Tier Constants](#lsm-tier-constants) should be revisited.

| Parameter                | Typical         | Upper Bound | Notes                                      |
| :----------------------- | :-------------- | :---------- | :----------------------------------------- |
| Documents per namespace  | 500–5,000       | 50,000      | A namespace maps to a document collection. |
| Namespaces per database  | 3–10            | 50          | e.g. contacts, notes, tasks, settings.     |
| Total documents per user | 2,000–20,000    | 500,000     | Across all namespaces.                     |
| Average document size    | 1–4 KB          | 64 KB       | JSON-encoded application documents.        |
| Total working set        | 5–80 MB         | 500 MB      | Sum of all live document bytes.            |
| Write rate               | 1–10 puts/sec   | 100/sec     | User-driven interactions, not bulk import. |
| Read rate                | 10–100 gets/sec | 500/sec     | UI rendering of document lists.            |
| Devices per user         | 1–3             | 5           | Phone \+ tablet \+ desktop.                |
| Sync frequency           | On focus/resume | Continuous  | Triggered on app foreground.               |

## Design boundary

This engine is not designed for bulk import (tens of thousands of documents in a
single session), streaming time-series data, or shared multi-user write access.
The design boundary is the single-user personal document store operating across
multiple devices.
