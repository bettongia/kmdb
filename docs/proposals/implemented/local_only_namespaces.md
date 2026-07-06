# Technical Proposal: Local-Only Namespace Segregation

## 1. Overview

KMDB's sync protocol operates at the SSTable level: whole files are uploaded
verbatim to cloud storage. There is currently no mechanism to prevent
device-local derived data — secondary indexes, FTS term indexes, embedding
vectors — from riding in those uploads. On a mobile connection with a
non-trivial database, syncing hundreds of megabytes of derived index data that
the receiving device will rebuild anyway is a significant waste of user data.

This proposal introduces a **`$$` (double-dollar) namespace prefix convention**
and a **flush-time segregation mechanism** that routes `$$`-prefixed entries into
local-only SSTables that are never uploaded, with zero changes required to the
sync protocol or the WAL.

This work is a prerequisite for WI-3 (vault search, v0.06), which requires
`$$vault:fts:` and `$$vault:extract:` to be local-only from day one. It also
closes the documented "Future work" gap in §12 and §20.7.

## 2. Problem Statement

### 2.1 Current behaviour

`SyncEngine.push` uploads every local SSTable verbatim. All system namespaces
that write through the `WriteBatch` → memtable → flush path reach cloud storage:

| Namespace | Kind | Should sync? |
|---|---|---|
| `$meta` | Device metadata | Partial (out of scope — see §6) |
| `$ver:*` | Document version history | Yes — authoritative |
| `$vault`, `$vault:docref` | Blob reference graph | Yes — authoritative |
| `$index:*` | Secondary indexes | **No** — derived, device-local |
| `$fts:*` | BM25 term indexes | **No** — derived, device-local |
| `$vec:*` | SQ8 embedding vectors | **No** — derived, device-local; 384 bytes/entry |

The vector namespace is the most costly: a vault blob producing 200 chunks
generates 76 KB of `$vec:` data per blob. A database with 1,000 such blobs
uploads 76 MB of vector data that the receiving device discards and recomputes.

§12 and §20.7 both document this as a known gap with a "Future work" note:

> "If [upload-time filtering] is added, this section must be updated to describe
> the actual filter and which namespaces it excludes."

This proposal delivers that filter.

### 2.2 No migration required

This is a greenfields codebase with no production users. All namespace renames
are applied in place. No backward-compatibility shims, migration paths, or
format-version bumps are needed.

## 3. Design

### 3.1 Naming convention

Extend the existing `$` system-namespace convention with a second sigil:

- **`$` (single dollar)** — system namespace that participates in sync.
  Authoritative data; must reach all devices.
- **`$$` (double dollar)** — system namespace that is **local-only**.
  Derived or device-specific data; never uploaded.

The predicate is a single, allocation-free prefix check:

```dart
bool isLocalOnly(String namespace) => namespace.startsWith(r'$$');
```

This lives in `src/engine/util/namespace_codec.dart` as a top-level function,
following the single-source-of-truth pattern already used for namespace
validation there.

The `$$` sigil is chosen because:
- It is a visually obvious extension of the existing `$` rule.
- It is self-extending: new local-only namespaces inherit the guarantee without
  registering anywhere.
- The engine treats namespace names as opaque length-prefixed byte strings
  (`[nsLen][ns UTF-8]`), so the prefix change is invisible below the query
  layer.

### 3.2 Namespace reclassification

| Old name | New name | Rationale |
|---|---|---|
| `$fts:*` | `$$fts:*` | BM25 indexes derived from documents; rebuilt per device |
| `$vec:*` | `$$vec:*` | Embedding vectors derived from documents; rebuilt per device |
| `$index:*` | `$$index:*` | Secondary indexes derived from documents; rebuilt per device |
| `$vfts:*` | `$$vault:fts:*` | WI-3 vault BM25 terms; derived from blobs |
| `$vault:extract:*` | `$$vault:extract:*` | WI-3 extraction status; device-local filesystem mirror |
| `$ver:*` | unchanged | Authoritative version history |
| `$vault`, `$vault:docref` | unchanged | Authoritative blob reference graph |

`$meta` is deliberately excluded from this work. It contains a mix of
device-local entries (HLC, device identity) and entries that may need to sync
(collection schemas). Its reclassification is left for a separate work item.

Note: vault chunk vectors have no KV namespace at all — they are stored only in
the filesystem `extract/vectors_{modelId}_sq8.bin` and scanned directly at query
time, so there is nothing to rename or exclude.

### 3.3 Filter mechanism: segregate at flush

The filter does not belong at the upload layer (SSTables are immutable; stripping
keys requires rewriting the file and invalidates the footer checksum) or at the
WAL layer (breaking the atomic batch frame that keeps document writes and their
index writes crash-consistent).

The correct insertion point is **flush**, where the memtable's contents are being
written to fresh files and are still mutable bytes:

```
WAL frame (atomic) → memtable (unified) → flush → [syncable.sst, local.sst]
```

During `LsmEngine.flush()`, partition the frozen memtable's sorted entries by
`isLocalOnly(namespace)` into two `SstableWriter`s, producing two output files:

1. A **syncable SSTable** — same naming convention and upload behaviour as today.
2. A **local-only SSTable** — recorded in the Manifest but never uploaded.

The WAL and memtable remain unified. Crash atomicity is fully preserved: WAL
replay reconstructs both streams identically from the same batch frames.

#### 3.3.1 Manifest tracking

Add an optional `localOnly: bool` field to `SstableMeta` and the `add` entry in
`VersionEdit`. CBOR-encoded as an optional key; absent means `false`
(backward-compatible with any existing Manifest written before this change, which
has no `$$` entries anyway since this is greenfields).

A single flush now produces one `VersionEdit` with two `add` entries (one
syncable, one local-only). Both are appended atomically in one Manifest write.

#### 3.3.2 Upload exclusion

`SyncEngine.push` gains a single predicate applied to its local-file list:

```dart
// Skip local-only SSTables — never upload derived index data.
if (manifest.isLocalOnly(file)) continue;
```

The manifest flag is authoritative. As a convenience, local-only SSTables may
also use a distinct filename suffix (`.local.sst`) so they are trivially
identifiable on disk without a manifest lookup — but the manifest flag governs
correctness.

#### 3.3.3 Compaction

Compaction merges SSTables within a level. The output partitioning rule must
match flush: **syncable and local-only entries must never co-mingle in one output
file**, or a local-only entry could end up in an uploaded SSTable.

Apply the same two-writer split to every compaction output stage, including the
`_compactAll` shortcut (the dominant path for databases ≤512 KB), which currently
emits one L2 file. It must emit two.

The `_compactAll` path also runs tombstone GC (the sync-horizon-gated reclamation
logic, §06). The reclamation condition is keyed on the sync horizon of the
*syncable* stream. The local-only stream's tombstones must be checked separately:
their reclamation condition is whether all local readers have seen the write, which
is always true on a single device, so local-only tombstones can be GC'd
aggressively (any compaction that covers all local-only levels).

#### 3.3.4 Crash recovery (§17)

No changes required. Local-only SSTables are ordinary SSTable files tracked in
the Manifest. Orphan detection, WAL triage, level reconstruction, and HLC
recovery all treat them identically to syncable SSTables. The only difference is
the `localOnly` flag in the Manifest — the recovery sequence already ignores
fields it does not understand (the CBOR optional-key pattern).

## 4. Effect on WI-3 (vault search)

With this proposal implemented, WI-3's RQ-1 blocking question is resolved:

- `$$vault:fts:*` and `$$vault:extract:*` are local-only by the `$$` prefix —
  never uploaded, never received by a peer, stub-detection cannot be corrupted
  by a foreign device's extract entries.
- The WI-3 plan's "Sync exclusion (Step 10)" section can be rewritten to
  reference this mechanism rather than a non-existent exclusion list.
- The peer-receives-foreign-`$$vault:extract:` bug is resolved by construction.

## 5. Coordination with v0.08

The v0.08 roadmap (Gap 2) plans to rename `$fts:` and `$index:` namespaces to
use HMAC tokens. That rename also touches `FtsManager`, `VecManager`, and
`IndexManager`. To avoid updating those files twice, the `$` → `$$` prefix rename
and the HMAC token rename should be performed in the same commit where they
overlap.

## 6. Out of scope

- **`$meta` reclassification.** Mixed local/syncable content. Separate work item.
- **Retroactive cloud cleanup.** No production users; no action needed.
- **`syncNamespaces` user API.** The existing parameter restricts which user
  collections are _intended_ to sync. This proposal does not change its semantics
  or surface — it only fixes what the engine actually does for system namespaces.

## 7. Spec impact

When implemented, the following spec files must be updated:

- **§06 `06_storage_engine.md`** — flush partitioning, compaction two-writer
  rule, local-only tombstone GC.
- **§08 `08_sstable.md`** — `.local.sst` suffix (if adopted) and Manifest flag.
- **§10 `10_manifest.md`** — `localOnly` field on `SstableMeta`/`VersionEdit`.
- **§12 `12_sync.md`** — replace the "Future work" note with the actual filter
  description.
- **§16 `16_secondary_indexes.md`** — namespace renamed to `$$index:*`.
- **§20 `20_text_search.md`** — namespace renamed to `$$fts:*`/`$$vec:*`;
  replace "ride in SSTables" with "excluded from upload via `$$` prefix".
- **§99 `99_glossary.md`** — add entries for `$$` (local-only namespace) and
  `isLocalOnly`.

## 8. Implementation checklist (for the plan)

- [ ] Add `isLocalOnly(String ns)` predicate to `namespace_codec.dart`.
- [ ] Add `localOnly: bool` field to `SstableMeta` and `VersionEdit` (optional
      CBOR key, default `false`).
- [ ] Partition `LsmEngine.flush()` into two `SstableWriter`s; emit two
      `VersionEdit` add entries in one Manifest append.
- [ ] Apply the same two-writer split to `_compactIfNeeded` and `_compactAll`.
- [ ] Update tombstone GC in `_compactAll` to treat local-only tombstones
      separately from the sync-horizon check.
- [ ] Add local-only predicate to `SyncEngine.push` upload loop.
- [ ] Rename `$fts:` → `$$fts:` in `FtsManager` and all callers.
- [ ] Rename `$vec:` → `$$vec:` in `VecManager` and all callers.
- [ ] Rename `$index:` → `$$index:` in `IndexManager`, `IndexDefinition`, and
      all callers.
- [ ] Update all tests that assert on namespace names.
- [ ] Update spec files per §7 above.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Run `make coverage` — confirm ≥90% on all changed files.
