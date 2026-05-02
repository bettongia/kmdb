# Logging Callback

**Status**: Questions

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

`kmdb` should emit logs in a resource-sensitive manner. Instead of using logging
frameworks, `kmdb` should notify callback functions that an application can
configure.

Each layer should identify itself in logs so as to help developers determine
where inside `kmdb` the message came from.

All logging data should be structured, avoiding large text output. It is
important that logging uses as few resources as possible - consider async
approaches and not requiring a response from the callback function.

Dart's [logging package](https://pub.dev/packages/logging) should be used as
appropriate, especially the level enumerations.

For the SQLite approach, refer to
[SQLite - The Error And Warning Log](https://sqlite.org/errlog.html).

## Open questions

- [x] **Q1: Should `kmdb` take a hard dependency on `package:logging`, or only
  borrow its `Level` enumeration?**

  **Resolved:** `package:logging` will be added as a dependency solely to
  expose the `Level` type in the public API. The goal is a common, familiar
  severity model for application developers — not framework adoption. The
  `Logger` hierarchy, zone-based handlers, and `LogRecord` from
  `package:logging` will **not** be used. `kmdb` defines its own
  `KmdbLogRecord` value type; the only import from `package:logging` is
  `Level`.

- [ ] **Q2: Where does the callback live in the public API?**

  The plan says "notify callback functions that an application can configure"
  but names no attachment point. The candidates are:

  - `KvStoreConfig` — already the configuration object for the storage engine;
    straightforward, but it only covers `KvStoreImpl` and below, not the
    `SyncEngine`, `CacheLayer`, or query layer.
  - `KmdbDatabase.open()` — the single entry point for the full 6-layer stack;
    would be the most natural place for a Flutter/Dart developer.
  - A top-level `KmdbLogger` singleton (similar to the `logging` package root
    logger) — avoids threading the callback through every constructor but
    introduces global mutable state, which conflicts with testability.
  - A new `KmdbConfig` / `KmdbOptions` object that wraps `KvStoreConfig` and is
    passed to `KmdbDatabase.open()`.

  This question must be answered before the implementation plan can enumerate
  which constructors and factory methods need to change.

- [ ] **Q3: What events are actually worth logging?**

  The problem statement gives no list of loggable events. Without that, the
  implementation risks either instrumenting every line of the engine (noisy,
  slow) or adding a handful of placeholder calls that provide no diagnostic
  value. A concrete list is needed — even a draft. Candidates, by layer and
  severity:

  - `FINE`: WAL record written, memtable insert, Bloom filter miss/hit,
    SSTable block read, cache hit/miss.
  - `INFO`: Database opened, flush started/completed (with SSTable filename and
    entry count), compaction round started/completed (files in → files out),
    SSTable ingested from sync, index build started/completed.
  - `WARNING`: Clock skew detected (HLC physical > observed + threshold), WAL
    checksum mismatch recovered, orphan SSTable deleted during crash recovery,
    index build interrupted (dirty-open flag set).
  - `SEVERE`: Manifest corruption, WAL replay failure, lock acquisition failure.

  These should be decided and written into the plan before implementation starts
  so that reviewers can confirm coverage is appropriate and the call sites are
  in the right layer.

- [x] **Q4: Is "async approach" the right framing for a synchronous engine?**

  **Resolved:** "Not requiring a response from the callback" means the callback
  is typed `void Function(KmdbLogRecord)` — fire-and-forget in the sense that
  `kmdb` does not await or inspect a return value. Dispatch remains synchronous,
  consistent with the engine's single-isolate, synchronous write path. No
  microtask scheduling or `Zone` plumbing is introduced.

- [ ] **Q5: What is the performance contract for the callback?**

  Because the write path is synchronous, any callback invoked during `put()`,
  `flush()`, or compaction blocks the caller. The plan must specify whether:
  (a) the callback is always invoked synchronously and callers are warned not to
  do I/O inside it, or (b) KMDB schedules the invocation outside the write path
  via a microtask queue or zone. Option (a) is simpler and consistent with the
  engine model; option (b) adds hidden latency risk. Either way, this must be
  documented as part of the API contract.

## Investigation

### Current state of logging in the codebase

No logging mechanism exists today. A search of `packages/kmdb/lib` finds zero
calls to `print()`, `debugPrint()`, or any log framework — the engine operates
silently. There are no transitive dependencies on `package:logging`; the only
dependencies are `archive`, `cbor`, `meta`, `uuid`, `web`, and `es_compression`.

### Alignment with the problem statement

The problem is genuine. KMDB is a library embedded in Flutter/Dart applications,
and without observability, developers debugging unexpected sync behaviour,
compaction timing, or crash recovery have no signal whatsoever. The SQLite error
log analogy is apt: SQLite's `sqlite3_log()` callback is a single, lightweight
hook that avoids coupling SQLite to any specific logging framework.

However, the problem statement contains several under-specified claims that will
lead to a poor implementation if not resolved first:

1. **"instead of using logging frameworks"** directly contradicts the next
   sentence **"Dart's logging package should be used as appropriate."** These
   two instructions are in tension. The `logging` package _is_ a logging
   framework. The plan must decide: does `kmdb` take a dependency on
   `package:logging` (which adds ~18KB and a transitive zone API to every
   embedder), or does it define its own minimal callback type and merely _mimic_
   the `Level` integer constants?

2. **"structured, avoiding large text output"** is correct in spirit but needs
   to be made concrete. Structured logging in Dart typically means a
   `Map<String, Object?>` payload. However, building a map per log event on
   the hot write path allocates on every write. At minimum, the structured
   record should only materialise if a listener is registered (i.e., the
   callback is non-null), which implies a guard on every call site.

3. **"async approaches"** is a misfit for the synchronous engine described in
   §18. See Q4 above.

### Architecture fit

The 6-layer stack means log events originate at different depths:

- `LsmEngine` / `CrashRecovery` / `WalWriter` / `SstableWriter` / `CompactionJob`
  — engine layer, most performance-sensitive
- `KvStoreImpl` / `MetaStore` — KvStore boundary layer
- `CacheLayer` — cache invalidation, materialised view hits
- `SyncEngine` / `ConsolidationCoordinator` — sync layer
- `KmdbDatabase` / `KmdbCollection` / `IndexManager` — query layer

The most natural attachment point for a callback is `KmdbDatabase.open()`,
which already has multiple named parameters for callbacks (`onIndexReady`,
`onIndexRebuildRequired`). A `void Function(KmdbLogRecord)?` parameter here
would be consistent with that pattern. The callback would then be threaded
downward into `KvStoreConfig` (or a separate config object) to reach the engine
layers.

Alternatively, a `KmdbLogRecord` could be defined as a public type in the
`kmdb.dart` barrel export, with the callback threading done internally. This
is cleaner from a public API perspective.

### Comparison: `package:logging` adoption vs. lightweight callback

**Full `package:logging` adoption:**

Pros: `Level` enum, `Logger` hierarchy, `LogRecord` type, and handler
  registration are all provided; familiar to Dart developers.

Cons: The framework is opinionated about how listeners are attached (root zone
  handlers). An embedding app that already uses a different log framework must
  bridge between the two. Adds a new `pub.dev` dependency. The `Logger`
  hierarchy and zone plumbing are overkill for an embedded library that simply
  needs to fire a callback.

**Lightweight callback with borrowed `Level` constants:**

Pros: Zero new dependencies (define an internal `KmdbLogLevel` with the same
  integer values as `logging.Level`). Full control over the event payload type.
  Can be wired directly to a `package:logging` `Logger` by the embedder in one
  line (`db = await KmdbDatabase.open(..., onLog: (r) => _logger.log(r.level, r.message, r.error))`).

Cons: Slightly more API surface to design and document.

The lightweight approach is the stronger choice for an embedded library. The
plan should adopt it and explicitly state that `package:logging` will _not_ be
a direct dependency.

### SQLite analogy assessment

The SQLite error log (`sqlite3_log`) is a global singleton callback — one per
process, set via `sqlite3_config(SQLITE_CONFIG_LOG, ...)`. That design works
for a C library with no object hierarchy. KMDB is object-oriented and already
passes configuration per database instance (`KvStoreConfig`). The instance-level
callback approach (per `KmdbDatabase.open()`) is cleaner and supports multiple
databases in the same Dart process without interference.

## Implementation plan

{To be filled in once the Open questions above are resolved}

## Summary

{Dot points highlighting the work undertaken}

---

## Reviewer notes

_Reviewed 2026-04-06 by plan-reviewer agent._

### Problem Statement Assessment

The problem is real and worth solving. An embedded database with zero
observability is painful to debug. The SQLite error-log analogy is sound. That
said, the problem statement contains two internal contradictions (see Q1, Q4
above) that will produce a confused implementation if not resolved before coding
begins.

### Proposed Solution Assessment

The plan is almost entirely unfilled — there is no investigation section, no
implementation plan, no list of call sites. As written it is a problem statement
only. **It is not ready to implement.**

The central tension is the instruction to avoid logging frameworks while also
using `package:logging`. This must be resolved. My recommendation: do not take
a hard dependency on `package:logging`. Define a lightweight `KmdbLogRecord`
value type (level integer, message string, layer name string, optional error
object, optional structured data map) and a `void Function(KmdbLogRecord)?`
callback. Borrow the `Level` integer constants from `package:logging` in the
documentation but do not import the package. This gives embedders maximum
flexibility and keeps the dependency footprint minimal.

The "async approaches" framing should be dropped. The engine is synchronous.
Fire-and-forget callbacks invoked synchronously (but not awaited) are sufficient
and consistent with the existing codebase model.

### Architecture Fit

The callback should attach at `KmdbDatabase.open()` (consistent with
`onIndexReady` / `onIndexRebuildRequired`). It then needs to be threaded into
`KvStoreConfig` so the engine layers can reach it. This is mechanical but
touches many constructors — specifically `LsmEngine`, `CrashRecovery`,
`KvStoreImpl`, `SyncEngine`, and `CacheLayer`. The plan must list every
constructor that changes, because missing one means a layer that silently swallows
events.

Secondary consideration: the `kmdb_cli` package. If the CLI wants to surface
engine-level log events to the terminal (which it likely does — compaction
timing, sync operations), the callback must be reachable from `KvStoreImpl.open`
and `SyncEngine` directly, not only via `KmdbDatabase.open`. This suggests the
callback either lives in `KvStoreConfig` or in a separate config object that
both code paths share.

### Risk and Edge Cases

1. **Hot-path allocation.** If `KmdbLogRecord` is a map-based object created
   on every flush and compaction, and the embedder has not registered a callback,
   those allocations are pure waste. Every call site must guard: `if (_onLog !=
   null) _onLog!(KmdbLogRecord(...))`.

2. **Callback exceptions.** If the callback throws, and the call site is inside
   `flush()` or compaction, the exception will propagate into the write path and
   corrupt the engine state. The implementation must either catch-and-ignore
   callback exceptions or document clearly that they must not throw.

3. **Testing.** Tests must be able to capture log records to assert that the
   correct events are emitted during flush, compaction, crash recovery, and sync.
   `KvStoreConfig.forTesting()` should include a default null callback. Tests
   that assert logging behaviour should pass an in-memory collector.

4. **Thread / isolate safety.** KMDB is single-isolate; the callback will always
   be invoked on the same isolate. This should be documented so embedders do not
   try to forward events across isolate boundaries from within the callback.

### Recommendations

1. Resolve Q1–Q5 before writing any code.
2. Produce a concrete list of loggable events with level, layer, and a draft
   message/payload for each (Q3 is the most important gap).
3. Adopt the lightweight callback approach; do not add `package:logging` as a
   dependency.
4. Drop "async approaches" — use a synchronous `void Function(KmdbLogRecord)?`
   callback with null-guard at every call site.
5. The implementation plan must enumerate every constructor that changes and
   every call site that emits a record.
