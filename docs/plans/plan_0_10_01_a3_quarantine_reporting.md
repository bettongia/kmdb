# A3 — Surface SSTable quarantine to the embedding application

**Status**: Implementing

**PR link**: _(pending)_

## Problem statement

When `SyncEngine.pull()` downloads a peer SSTable that fails ingest validation,
it **quarantines** the file: it advances this device's per-peer high-water mark
(HWM) past the file's `maxHlc` so the file is never re-fetched, then continues
the sync cycle. This is the correct S-1 posture — it stops a single hostile or
corrupt file from permanently jamming all future sync (the pre-S-1 behaviour
re-downloaded and re-rejected the same poisoned file on every pull, forever).

But quarantine makes the same **permanent, one-way** decision for a *legitimately
corrupt* peer file (a bad upload, a truncated write, cloud bit-rot — no attacker
involved) as it does for a hostile one: the file's contents are dropped, the HWM
is advanced past it, and `consolidate()` skips it too. **The data in that file is
now permanently absent on this device**, and the *only* trace is a `print()` to
the console (`sync_engine.dart:630`). The embedding application — and therefore
the user — has **no programmatic way** to learn that a peer's data was silently
dropped.

This is finding **A3** from the 2026-07-18 release-readiness review (0.10.01
track, WI-7). The review's remediation: *"surface it in a result object rather
than a console print."*

Because a quarantine advances the HWM, **each dropped file is reported by exactly
one `pull()` — the one that dropped it — and never again.** A per-pull return
value is therefore an *ephemeral* signal for a *permanent* loss: if the host app
does not happen to inspect that specific pull's result (background sync, app
killed mid-cycle), the signal is lost forever. **Maintainer decision (2026-08-10):
the fix is a durable, device-local quarantine log in addition to the per-pull
result object**, so the host can ask "what has this device dropped?" at any later
time.

## Open questions

All six questions were pressure-tested against the code in the reviewer pass of
2026-08-10 and are now **closed** — see **Reviewer decisions (2026-08-10)** below
for the full reasoning and the two corrections to the recommended answers (Q1
layering; Q2/Q3 type specifications). The checklist records the settled decision.

- [x] **Q1 — Where does the durable-log write mechanism live, and how does
      `SyncEngine` reach it?** Confirmed: extend `MetaStore`. **Corrected wiring:**
      `SyncEngine._store` is typed as the `KvStore` *interface*, which does **not**
      expose `meta` (that accessor is on `KvStoreImpl` only). Do **not** thread a
      raw `MetaStore` into `SyncEngine`. Instead add a narrow
      `appendQuarantine(QuarantinedSstable)` method to the **`KvStore` interface**,
      implemented in `KvStoreImpl` as `_meta.appendQuarantine(...)` — this mirrors
      the established `resetTombstoneFloor()` / `setTombstoneHorizonProvider()`
      seam that every other SyncEngine→engine-state call already uses.
      `KmdbDatabase` (which holds the concrete `KvStoreImpl`) reaches the read
      side via `_store.meta.listQuarantines()` / `.clearQuarantineLog()` directly.
      **The record types must live at the engine layer, not the sync layer** — see
      the decisions section (layering).
- [x] **Q2 — `PullResult` carries `deferred` too.** In scope. Two distinct,
      clearly-named lists: `quarantined` (permanent; persisted) and `deferred`
      (transient sub-floor skips; in-memory only, never persisted). **Corrected:**
      `deferred` must be a **distinct element type `DeferredSstable`**
      (`peerDeviceId`, `filename`, `maxHlc`, `floor`) — *not* a
      `List<QuarantinedSstable>` — precisely so the two can never be confused and
      the type system enforces the separation.
- [x] **Q3 — `sync()` returns a `SyncResult` wrapper; `pull()` returns
      `PullResult`; `push()` stays `Future<void>`.** Chose the wrapper over bare
      `PullResult` for `sync()`: this change lands *before* the 0.1.0 API freeze
      (WI-9), and after the freeze adding push-side reporting to a bare
      `PullResult`-returning `sync()` would be a second breaking change.
      `SyncResult` carries the `PullResult` today with a documented slot for
      future push reporting. One extra tiny class buys freeze-proofing.
- [x] **Q4 — Unbounded append + `clearQuarantineLog()`; no auto-eviction.**
      Confirmed for 0.1.0. Corruption is rare; a per-file entry keyed by filename
      (idempotent) cannot grow without bound in practice. `clearQuarantineLog()`
      (clear-all) is the host's acknowledge mechanism; per-entry ack is
      unnecessary for 0.1.0.
- [x] **Q5 — Record fields + `QuarantineReason` enum.** Confirmed as recommended:
      `peerDeviceId`, `filename`, `maxHlc` (parsed from filename, pre-body,
      trustworthy), `reason` (enum over the five caught types), `detail` (the
      error's *message string*, never the live `Object`), `quarantinedAt`
      (wall-clock). The enum earns its keep: it lets the host branch without
      coupling to exception identity.
- [x] **Q6 — Encrypt the log like the other `$$…state` values.** Confirmed. No
      exemption: `$$quarantine` is never read during the encryption bootstrap, so
      there is no `enc:blob`/`formatVersion` non-circularity concern. Each value
      is `EncryptionEnvelope`-wrapped with `ValueContext(kQuarantineNamespace,
      key)`; `listQuarantines()` unwraps per-entry using each scanned entry's real
      key (required because AAD now binds `(namespace, key)` — WI-3 / E-2).

## Reviewer decisions (2026-08-10)

Verified against `sync_engine.dart`, `meta_store.dart`, `kv_store.dart`,
`kv_store_impl.dart`, `kmdb_database.dart`, and the existing test corpus. Two of
the six recommended answers were **corrected** (Q1 layering, Q2/Q3 type shapes);
the rest confirmed. Three additional load-bearing decisions were pinned that the
draft left ambiguous and would have blocked or misled the implementer.

### D1 — Q1 access path: interface method, not a threaded `MetaStore` (corrected)

`SyncEngine._store` is typed `KvStore` (the interface, `sync_engine.dart:132`).
`meta` is declared **only on `KvStoreImpl`** (`kv_store_impl.dart:523`), not on the
interface — so `SyncEngine` cannot reach `_store.meta`. The precedent for every
existing SyncEngine→engine-state call is a narrow method on the `KvStore`
interface that delegates to `_meta` (`resetTombstoneFloor()` →
`_meta.setTombstoneFloor(...)`, `kv_store_impl.dart:380`; `setTombstoneHorizonProvider`).
**Follow it:** add `appendQuarantine(QuarantinedSstable)` to the `KvStore`
interface; `KvStoreImpl` implements it as `_meta.appendQuarantine(...)`.
`SyncEngine` calls `_store.appendQuarantine(...)`. This keeps `SyncEngine` free of
a `MetaStore` import and is the smallest, most consistent seam. The read side
(`listQuarantines()` / `clearQuarantineLog()`) is reached by `KmdbDatabase` via
`_store.meta.…` directly (`KmdbDatabase._store` *is* a `KvStoreImpl` —
`kmdb_database.dart:205`), so those two do **not** need to be on the interface.

### D2 — Record types live at the ENGINE layer (corrected layering)

The draft implies `QuarantinedSstable` / `QuarantineReason` are sync-layer result
types passed *into* `MetaStore.appendQuarantine`. That is an **illegal upward
dependency**: `MetaStore` is engine-layer and must not import sync-layer types
(sync depends on engine, never the reverse — `meta_store.dart` imports no sync
code; `sync_engine.dart` imports `engine/kvstore/kv_store.dart`). The five caught
exception types the `QuarantineReason` enum maps
(`CorruptedSstableException`/`FormatException`/`RangeError`/`StorageException`/
`OutOfMemoryError`) all already live in the **engine** layer
(`sstable_reader.dart`, `kv_store.dart`, `storage_adapter_interface.dart`).
**Decision:** define `QuarantineReason` and the persisted record `QuarantinedSstable`
in the engine layer (e.g. `engine/kvstore/quarantine.dart`), exported from
`kmdb.dart`. Both `MetaStore` and the sync-layer `PullResult` may then reference
them with no inversion. `DeferredSstable`, `PullResult`, and `SyncResult` are
sync-layer types (they reference the engine types downward, which is fine).

### D3 — Crash-safety ordering (the core of this plan) — PINNED

The re-fetch gate is the **per-peer HWM stored in the sync folder**
(`hwm.peers[peerDeviceId]`, checked at `sync_engine.dart:545-546`, persisted by
`hwm.save(_remoteHwmPath, _cloudAdapter)` at `:645-647`). The durable log is a
local WAL-backed LSM put. The only safe ordering is: **the `$$quarantine` record
must be durably committed *before* the HWM is persisted.**

- Structurally this is achieved by appending the record **inside the pull loop, in
  the `if (rejected)` block at `:628-634`** (replacing the bare `print`), because
  the single `hwm.save` happens **after** the loop. Every per-file
  `appendQuarantine` therefore completes before the HWM advance for that pull. A
  `MetaStore` write is a standalone `_engine.put`, which is WAL-append + fsync, so
  it is durable the moment `appendQuarantine` returns.
- The dangerous inverse (HWM advanced, log write lost → **permanent silent loss
  with no record**) is made impossible by this ordering: if `appendQuarantine`
  throws (e.g. `StorageException` on a full disk), the exception propagates
  *before* the post-loop `hwm.save`, so the HWM is not advanced and the file is
  reconsidered on the next pull. This is the fail-safe direction.
- **Idempotency:** key each entry by `symbolicKey('quarantine:$filename')`. The
  filename already begins with the peer `deviceId` and is globally unique, so a
  re-quarantine after a crash-before-HWM-save is a harmless overwrite of the same
  key — no duplicate entries. (The phrase "at the point the HWM advances" in the
  draft's Phase 3 is ambiguous; the correct site is the in-loop `if (rejected)`
  block, not the post-loop `hwm.save`.)
- **No new release-checklist entry needed:** the log's power-loss durability rides
  entirely on the existing WAL fsync guarantee already covered by RC-4. State this
  in the plan rather than adding a redundant RC item.

### D4 — `SyncCancelledException` must stay uncaught — PINNED

`SyncCancelledException implements Exception` (`sync_context.dart:139`) and is
**not** a subtype of any of the five caught types, nor of `StorageException`. It
is thrown only by adapter calls carrying `ctx` (`download`/`list`), which sit
**outside** the ingest `try` and outside `appendQuarantine`. The one way to
regress the §12:346-360 invariant is to wrap the loop body (or the result
accumulation) in a `catch (e)` or **`on Exception catch`** — the latter *would*
trap `SyncCancelledException`. **Rule for the implementer:** accumulate the
`quarantined` / `deferred` records into plain `List`s declared before the loop and
return them after it; introduce **no** new `catch`/`on Exception` around the loop
body. On cancel the exception unwinds and the partial `PullResult` is discarded —
that is the correct contract (no "partial result on cancel").

### D5 — `listQuarantines()` is the first scan-based `MetaStore` accessor

Every existing `MetaStore` accessor is a point-read of a known key.
`listQuarantines()` must **enumerate** the namespace. The primitive exists:
`LsmEngine.scan(namespace, {startKey, endKey})` → `Stream<KvEntry>` where
`KvEntry = ({String key, Uint8List value})` (`kv_store.dart:441`). Implement
`listQuarantines()` as `_engine.scan(kQuarantineNamespace)` → for each entry,
`EncryptionEnvelope.unwrap(entry.value, encryption, context:
ValueContext(kQuarantineNamespace, entry.key))` → CBOR-decode into
`QuarantinedSstable`. Pin this in Phase 2 so the implementer does not go looking
for a point-read helper that does not fit.

### Scope

Right-sized as a single `Investigated` plan: one cohesive change spanning new
public types, a `MetaStore` log, a one-method `KvStore`-interface extension, the
`SyncEngine`/`KmdbDatabase` surface, docs, and tests. No sub-plan split warranted.

## Investigation

### Current behaviour and exact sites

- `SyncEngine.pull()` — `packages/kmdb/lib/src/sync/sync_engine.dart:506`, returns
  `Future<void>`.
- The quarantine decision is the `rejected` branch: the five typed catches at
  `sync_engine.dart:578-603` set `rejected = true`; the file's `maxHlc` then
  feeds the per-peer HWM fold at `:635-638`, flushed at `:641-647`. The HWM
  advance **is** the quarantine mechanism.
- The only signal today: `_logRejectedSstable` (`sync_engine.dart:695`, a static
  `print`) at each catch, plus the inline quarantine `print` at `:630`.
- The **non**-quarantine sub-floor path: `StaleSstableIngestException` at
  `:604-621` `continue`s **without** advancing the HWM (it carries its own
  `filename` / `maxHlc` / `floor` — see `kv_store.dart:786-811`). This retries
  forever by design (§12:207-226) and must never be conflated with quarantine.
- Public wrapper: `KmdbDatabase.pull()` (`kmdb_database.dart:889`) `await
  engine.pull()` at `:907` and **discards** — so changing only the engine's
  return type does not reach the host. `KmdbDatabase.sync()` (`:835`) and
  `push()` (`:862`) are the sibling entry points; §12:233-267 states the host is
  intended to use these, never to construct `SyncEngine` directly.

### There is no prior art to mirror

`grep` finds no `*Result` / `*Report` / `*Outcome` type anywhere in
`packages/kmdb/lib/src/sync/`; `push()`, `pull()`, `sync()` are all
`Future<void>` at both the engine and `KmdbDatabase` layers. This is the first
structured sync result type. The codebase convention for structured returns is
`…Result` (`OpenResult`, `SearchResult`, `EncryptionSetupResult`) — follow it:
**`PullResult`** (and, if adopted, `SyncResult`). The per-file record:
**`QuarantinedSstable`**. Avoid `Report`/`Outcome` (no precedent).

### The durable log — mechanism (mirrors the `$$…state` pattern)

`MetaStore` (`packages/kmdb/lib/src/engine/kvstore/meta_store.dart`) already owns
three local-only namespaces created by WI-13/WI-14/WI-11:

- `kGenStateNamespace` = `r'$$genstate'`, `kGcStateNamespace` = `r'$$gcstate'`,
  `kDirtyStateNamespace` = `r'$$dirtystate'`.
- Writes go via `_engine.put(ns, key, wrapped)` / `batch.put(...)`, bypassing the
  `$`-namespace guard in `KvStoreImpl` (intentional internal writes; still WAL'd).
- Keys are symbolic names hashed to 32-char hex (`_nameToKey` / `symbolicKey`,
  two-seed XXH64).
- Values are CBOR-encoded and wrapped with `EncryptionEnvelope` when a provider
  is configured (all except `enc:blob` / `formatVersion`).
- `isLocalOnly(ns) => ns.startsWith(r'$$')` (`namespace_codec.dart:148`) →
  `$$quarantine` lands in `.local.sst` and is **never uploaded**, which is
  exactly right: peer B's corrupt file is B's device-local truth, not a fact
  about the sync topology, and must not sync (same posture as `$$gcstate`).

Add a fourth constant `kQuarantineNamespace` = `r'$$quarantine'` and quarantine
helpers to `MetaStore`. Each quarantined file is one KV entry keyed by its
filename (or `peerDeviceId + filename`) → the CBOR record. Keying by filename
makes re-quarantine idempotent (harmless overwrite), though the HWM guarantees it
won't recur. `listQuarantines()` scans the namespace and decodes the records.

### The public surface change

Two layers must change together:

1. `SyncEngine.pull()` → `Future<PullResult>`; build the result from the same
   `rejected` / sub-floor data already gathered in the loop (pure observation —
   must not reorder or gate the HWM fold). Persist each `quarantined` entry to
   the log in the same place the HWM advances.
2. `KmdbDatabase.pull()` → `Future<PullResult>` (`return await engine.pull()`);
   `KmdbDatabase.sync()` → returns the `PullResult`/`SyncResult` (Q3);
   add a read accessor, e.g. `KmdbDatabase.quarantinedSstables()` →
   `Future<List<QuarantinedSstable>>`, delegating to `MetaStore.listQuarantines()`.

This is a **breaking public-API change** (`Future<void>` → `Future<PullResult>`).
It is `await`-compatible for callers that ignore the value, but it changes the
public surface, so it should land **before the 0.1.0 format/API freeze** (WI-9),
not after. Flag it in the eventual CHANGELOG work (A5 / WI-10).

### Invariants that must not be disturbed

- **`SyncCancelledException` must propagate uncaught** (§12:346-360). `pull()`
  deliberately catches `OutOfMemoryError` *explicitly* (not via a bare `catch`)
  precisely so cancellation is never swallowed (`sync_engine.dart:594-601`).
  Building the result must not introduce any catch-all that traps
  `SyncCancelledException`. On cancel mid-pull the partial result is **discarded**
  (the exception unwinds) — there is no "partial `PullResult` on cancel". State
  this in the docs.
- **HWM advancement ordering is the quarantine mechanism.** The result object and
  the log write are pure observations built from the same `info.maxHlc` /
  `peerDeviceId`; they must not change whether or when the HWM advances, nor
  reorder the fold at `:641-647`.
- **Idempotency of repeated pulls.** Because the HWM is advanced past a
  quarantined file, a later `pull()` will **not** re-fetch or re-report it — the
  durable log is what makes the one-shot signal durable. A test must assert a
  second pull does not duplicate the entry.
- **Local-only rule.** The `$$quarantine` log must never sync — assert this
  (it lands in `.local.sst`, absent from the sync root).

### Spec / doc touch-points (per kmdb-architect grounding)

- `docs/spec/12_sync.md`: add a "Quarantine reporting" subsection near the
  quarantine description (`:102-110`) documenting `PullResult`, the durable log,
  and that quarantine is now programmatically observable (the spec is currently
  silent on *how* the host learns). Update the `KmdbDatabase` sync-API region
  (`:233-267`) for the new return types.
- `docs/spec/13_query_api.md`: if the `KmdbDatabase` sync methods' signatures are
  listed there, update them and document `quarantinedSstables()`.
- `docs/spec/99_glossary.md`: add/confirm a "quarantine" entry.
- §20 / §24 are **not** involved (quarantine is a pure §12 sync-path concern).

## Implementation plan

> **Resume note (2026-08-10).** The first `kmdb-plan-implement` run completed
> Phases 1–4 and most of Phase 5, then terminated on a billing spend-limit mid
> way through the `QuarantineReason` mapping tests. The main session resumed the
> remainder inline: added the `outOfMemory` reason test (via a `TestKvStore`
> subclass that throws `OutOfMemoryError` from `ingestSstable` — the file-driven
> trigger no longer exists post-S-1/S-8, which now reject a hostile file as
> `corruptedSstable` before `malloc`), the sub-floor `deferred` test, the
> `KmdbDatabase`-level accessor/`SyncResult`/never-synced tests, and all Phase 6
> docs.

### Phase 1 — result & record types

- [x] Add `QuarantineReason` enum (five reasons mapping the caught types) with
      doc comments **at the engine layer** (D2). → `engine/kvstore/quarantine.dart`.
- [x] Add `QuarantinedSstable` (immutable: `peerDeviceId`, `filename`, `maxHlc`,
      `reason`, `detail`, `quarantinedAt`) with CBOR encode/decode and doc
      comments, **at the engine layer** (`engine/kvstore/quarantine.dart` — D2).
- [x] Add `DeferredSstable` (`peerDeviceId`, `filename`, `maxHlc`, `floor`) as a
      **distinct** type (Q2/D-corrected). Sync layer (`sync/pull_result.dart`).
- [x] Add `PullResult` (`quarantined` / `deferred`) and `SyncResult` (wraps a
      `PullResult`, documented push-reporting slot — Q3). Sync layer.
- [x] Export the new public types from `kmdb.dart`.

### Phase 2 — durable log in `MetaStore`

- [x] Add `kQuarantineNamespace` = `r'$$quarantine'` with a house-style doc comment.
- [x] Add `appendQuarantine(QuarantinedSstable)`: CBOR + `EncryptionEnvelope.wrap`
      with `ValueContext(kQuarantineNamespace, key)`, key from the filename
      (idempotent overwrite per D3), via `_engine.put`.
- [x] Add `listQuarantines()` via `_engine.scan(kQuarantineNamespace)` → per-entry
      unwrap with `ValueContext(kQuarantineNamespace, entry.key)` → CBOR-decode
      (D5 — first scan-based `MetaStore` accessor).
- [x] Add `clearQuarantineLog()` (Q4).

### Phase 3 — wire `SyncEngine.pull()`

- [x] Add `appendQuarantine(QuarantinedSstable)` to the **`KvStore` interface**;
      `KvStoreImpl` delegates to `_meta.appendQuarantine(...)` (D1).
- [x] `SyncEngine.pull()` → `Future<PullResult>`; plain `quarantined`/`deferred`
      `List`s built in the loop, no `catch`/`on Exception` wrapper (D4).
- [x] `_store.appendQuarantine(...)` inside the `if (rejected)` block, before the
      post-loop `hwm.save` (D3); bare quarantine `print` replaced.
- [x] `SyncEngine.sync()` → `Future<SyncResult>` (Q3).

### Phase 4 — public surface on `KmdbDatabase`

- [x] `KmdbDatabase.pull()` → `Future<PullResult>`; `.sync()` → `Future<SyncResult>`
      (threaded, not discarded); `push()` stays `Future<void>`.
- [x] `KmdbDatabase.quarantinedSstables()` + `clearQuarantineLog()` (delegating to
      `_store.meta.…`, D1).

### Phase 5 — tests (fault injection, not golden path)

- [x] Corrupt peer SSTable → `PullResult.quarantined` with the right `reason`;
      durable log persists it (`sync_engine_test.dart`).
- [x] **Durability (WAL replay):** the record survives a genuine reopen
      (`quarantine_crash_ordering_test.dart` (b)).
- [x] **Crash-window ordering (D3):** failure injected **between**
      `appendQuarantine` and `hwm.save` — (a) log-put failure leaves the HWM
      un-advanced (fail-safe); (b) HWM-save failure after a good log put →
      record present on reopen, idempotent re-quarantine, no duplicate
      (`quarantine_crash_ordering_test.dart`).
- [x] **Never synced:** `$$quarantine` lands in `.local.sst`, never uploaded
      (`kmdb_database_sync_test.dart`).
- [x] **Idempotency:** a second `pull()` does not re-fetch/duplicate
      (`sync_engine_test.dart`).
- [x] Sub-floor `StaleSstableIngestException` → `deferred` (a `DeferredSstable`),
      **not** `quarantined`, **not** persisted (`quarantine_reason_coverage_test.dart`).
- [x] **Cancellation:** pre-cancelled / mid-flight token → `SyncCancelledException`
      propagates uncaught, no partial result (`sync_cancellation_integration_test.dart`,
      unmodified — still green under the new return types).
- [x] Every `QuarantineReason` mapping covered — the four file-driven reasons plus
      `outOfMemory` via an injected `OutOfMemoryError`
      (`quarantine_reason_coverage_test.dart`).

### Phase 6 — docs

- [x] §12 "Quarantine reporting" subsection + "Return values" (new sync-API return
      types + `quarantinedSstables()`/`clearQuarantineLog()`); §99 glossary
      "Quarantine (sync)". (§13 lists no sync-method signatures, so no §13 change.)
- [x] Doc comments on every new public symbol.
- [x] Breaking-signature change noted in §12 for the eventual CHANGELOG (A5/WI-10).

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off. (Run from the main
      session — the resume is inline.)
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
      (`make pre_commit` is `kmdb`-only; this change is confined to `kmdb`.)
- [ ] Verify licence headers on all new files (2026).

## Summary

_(to be completed during implementation)_

- Adds `PullResult` / `QuarantinedSstable` / `QuarantineReason`, making SSTable
  quarantine programmatically observable instead of a console `print`.
- Persists each permanent quarantine to a device-local, never-synced
  `$$quarantine` log (via `MetaStore`), so the signal survives a missed pull —
  queryable via `KmdbDatabase.quarantinedSstables()`.
- Keeps the transient sub-floor skip strictly separate (`DeferredSstable`, never
  persisted) from permanent quarantine.
- Breaking sync-API return types (`pull()` → `PullResult`, `sync()` →
  `SyncResult`; `push()` unchanged); lands before the 0.1.0 freeze.
