# SAHPool OPFS Web Storage

**Status**: Implementing

**PR link**: {A link to the PR submitted for this plan}

**Roadmap**: docs/roadmap/0_03.md

## Problem statement

`StorageAdapterWeb` already uses the browser's Origin Private File System (OPFS)
via the async File System Access API. However, several operations are
fundamentally inefficient:

- `readFileRange()` reads the entire file then slices in Dart
- `appendFile()` reads the full file, concatenates, and rewrites
- Every operation crosses the JS/Dart boundary asynchronously

OPFS exposes a second, synchronous API — `FileSystemSyncAccessHandle` — that
allows direct byte-level reads and writes without async overhead. The catch:
sync handles can only be obtained inside a dedicated Web Worker. The Worker
opens a sync handle, performs the operation, and proxies the result back to the
main thread. The result is 3–4× throughput over the current async adapter, per
the spec §19 note already in the codebase.

The goal is to implement `StorageAdapterSahPool` — a `StorageAdapter`
implementation that routes all I/O through a Worker using sync access handles —
and **replace `StorageAdapterWeb` entirely with it as the single web adapter**.
`StorageAdapterWeb` is deleted as part of this work. There is no size-threshold
switch and no fallback adapter: the conditional export in `storage_adapter.dart`
points the web build at the new adapter, and `KmdbDatabase.open()` continues to
take a caller-supplied `StorageAdapter` (consistent with the rest of the adapter
pattern — the caller constructs and passes it).

## Open questions

All open questions are resolved (decisions recorded 2026-06-01). They are
retained here for traceability; the binding specification lives in the
Investigation and Implementation plan sections below.

- [x] **Message-passing protocol** — **Decision: async `postMessage` round-trips
      with an `id`-echo correlation map.** No `SharedArrayBuffer` and no
      COOP+COEP header requirement (those headers are a deployment burden on
      library users — Firebase Hosting / GitHub Pages do not set them by
      default). The Dart side maintains a `Map<int, Completer>` keyed by a
      monotonic request `id`; every Worker response echoes the `id`; both sides
      use a single `onmessage` handler. **No `MessagePort` response channels** —
      all references to per-message `MessagePort`s are removed from this plan.
      The Dart API stays async, which it already is (all 14 interface methods
      return `Future<T>`).

- [x] **Worker lifecycle** — **Decision: the adapter owns the Worker.** Spawned
      on first use (constructor/`open`), terminated on `close()`. The Worker JS
      is loaded via a runtime-generated Blob URL (see "Worker asset loading"
      below), so there is no separate asset to bundle or locate.

- [x] **Threshold-based adoption** — **Decision: replace `StorageAdapterWeb`
      entirely; no threshold.** The web conditional export points at
      `StorageAdapterSahPool`; `StorageAdapterWeb` and any associated tests are
      deleted. The caller constructs and passes the adapter to
      `KmdbDatabase.open()` as today. No size-threshold auto-switch, no fallback.
      The problem statement has been updated to match.

- [x] **Atomic rename** — **Decision: SAH simulation with enforced durability
      ordering** — write dest → flush dest → close dest → delete source. This
      ordering falls out automatically from the per-op handle lifecycle (below),
      so no special-casing is required. It is no less crash-safe than the current
      web adapter for the `CURRENT` update path: a crash leaves either the fully
      written-and-flushed destination or the intact source.

- [x] **Cross-tab locking** — **Decision: in scope; real cross-tab exclusion via
      an exclusive sync handle.** Single-tab use is the documented contract.
      `acquireLock(path)` → Worker calls `createSyncAccessHandle()` on the lock
      file; if another tab already holds it the call throws immediately. Surface
      this as a `LockException` with the message "database is already open in
      another tab." No retry, no timeout, no coordination protocol. The lock
      handle is held for the lifetime of the session; `releaseLock(path)` flushes
      and closes it.

## Investigation

### Current adapter limitations

`StorageAdapterWeb`
(`packages/kmdb/lib/src/engine/platform/storage_adapter_web.dart`):

| Method                                | Current implementation   | Issue                                                |
| ------------------------------------- | ------------------------ | ---------------------------------------------------- |
| `readFileRange(path, offset, length)` | Reads whole file, slices | O(file size) per block read                          |
| `appendFile(path, bytes)`             | Read + concat + rewrite  | O(file size) per WAL append                          |
| `syncFile()` / `syncDir()`            | No-ops                   | Safe **only** because Writable Streams are durable on `close()` — see note below |
| `renameFile(from, to)`                | Read + write + delete    | Not atomic                                           |

> **Durability note (corrects the prior "fine, no-ops" claim).** The current web
> adapter's fsync no-ops are safe *only* because it uses OPFS Writable Streams
> (`createWritable()` → `write()` → `close()`), which are durable on `close()`.
> That reasoning does **not** carry over to sync access handles, whose writes are
> buffered until `flush()` is called explicitly. The SAHPool adapter therefore
> uses a **per-op handle lifecycle** (open → write → flush → close for every
> Worker write operation), which makes the flush a guaranteed part of each write.
> Given that, `syncFile(path)` is a no-op (the preceding write op already
> flushed-and-closed the handle) and `syncDir(dirPath)` is a no-op (OPFS has no
> directory fsync; the per-op flush ordering provides the durability the engine's
> fsync callers rely on). These are no-ops for a reason specific to the per-op SAH
> model — not the Writable-Stream reason that makes them no-ops today.

`readFileRange` is particularly critical — the SSTable reader calls it for every
4KB block read; reading a 20MB SSTable 4KB at a time triggers 5,000 full-file
reads under the current implementation.

### StorageAdapter interface

14 methods defined in
`packages/kmdb/lib/src/engine/platform/storage_adapter_interface.dart`:
`readFile`, `readFileRange`, `writeFile`, `appendFile`, `syncFile`, `syncDir`,
`deleteFile`, `fileExists`, `listFiles`, `fileSize`, `renameFile`,
`createDirectory`, `acquireLock`, `releaseLock`.

All are async (`Future<T>`), so the SAHPool Worker's sync-handle I/O can be
wrapped in async Dart methods without interface changes.

### SAHPool pattern

A Web Worker is spawned with access to the OPFS root. For each operation it
calls `FileSystemDirectoryHandle.getFileHandle(..., {create: true})` and
`FileHandle.createSyncAccessHandle()`. These handles support synchronous
`read(buffer, {at: offset})`, `write(buffer, {at: offset})`, `truncate(size)`,
`getSize()`, and `flush()`.

**Per-op handle lifecycle (durability contract).** Every write-bearing Worker
operation follows open → write → `flush()` → `close()`. Read operations open →
read → close. This is the load-bearing durability decision: because each write
flushes-and-closes before the response is posted, the engine's fsync callers
(`CurrentFile`, `WalWriter`, `ManifestWriter`, `LsmEngine`/`CompactionJob`) get
durable bytes without needing `syncFile`/`syncDir` to do anything. The exception
is the lock handle, which is held open for the session lifetime (see Cross-tab
locking). Because handles are not pooled across ops, there is no shared mutable
handle cache to coordinate; the only long-lived handle is the lock.

**Message protocol — `id`-echo correlation.** The main thread communicates via
`postMessage` / a single `onmessage` handler. Each request message is
`{ id, op, ...args }` where `id` is a monotonically increasing integer. The
Worker executes the operation synchronously (no `await` inside the Worker) and
posts back `{ id, ok, result }` or `{ id, ok: false, error }`. The Dart side
keeps a `Map<int, Completer>` keyed by `id`; its single `onmessage` handler looks
up the completer by the echoed `id` and completes (or completes-with-error) it.
There are no `MessagePort` response channels.

### Dart Worker interop

Dart compiles to JS/WASM. A Web Worker script must be a separate JS entrypoint.
Options:

- Compile a minimal Dart Worker library to JS and serve it alongside the app
- Write the Worker in plain JS (simpler, no Dart toolchain dependency in the
  Worker)
- Use `package:web`'s `Worker` bindings from the main Dart thread

A plain JS Worker is the most practical approach: the Worker only needs to
implement the SAHPool message protocol; it doesn't need Dart's type system. The
Dart adapter sends typed messages and parses typed responses.

**Worker asset loading — runtime Blob URL.** The Worker JS is maintained as a
readable source file in the repo (`lib/src/engine/platform/sahpool_worker.js`).
A companion Dart file (`lib/src/engine/platform/sahpool_worker_source.dart`)
holds that JS verbatim as a `const String`. At startup the adapter builds a
`Blob` from the const string and calls `URL.createObjectURL()`, then constructs
the `Worker` from the resulting blob URL. This avoids any Flutter asset-bundle or
`base href` dependency, works identically under `dart compile js` and WASM
builds, and needs no CSP beyond the standard `worker-src blob:`. The const-string
companion must be kept in sync with the `.js` source (note this in the file's doc
comment; a future build step could generate it, but manual sync is acceptable
for now).

### Existing spec reference

`storage_adapter_web.dart` already documents the SAHPool pattern and references
spec §19 (`docs/spec/19_platform.md`) as the authoritative source. The
implementation plan should update §19 to cover the SAHPool design.

### Web dependencies

`packages/kmdb/pubspec.yaml` already includes `web: ^1.0.0` for OPFS bindings.
No additional packages are expected to be needed.

## Implementation plan

### Phase 1 — Worker script

- [x] Write `lib/src/engine/platform/sahpool_worker.js` — a plain JS Web Worker
      that implements the SAHPool message protocol. A single `onmessage` handler
      receives `{ id, op, ...args }`, executes the op synchronously (no `await`),
      and posts back `{ id, ok: true, result }` or `{ id, ok: false, error }`.
      Each write-bearing op follows the per-op lifecycle (open → write →
      `flush()` → `close()`); read ops open → read → close. Operations:
  - `read(path, offset, length)` → `Uint8Array` (open → read → close)
  - `readAll(path)` → `Uint8Array`
  - `write(path, offset, bytes)` — open → write at offset → flush → close
  - `append(path, bytes)` — open → `getSize()` → write at size → flush → close
    (true append, no read)
  - `truncate(path, size)` — open → truncate → flush → close
  - `getSize(path)` → number
  - `list(dirPath, extension?)` → `string[]`
  - `delete(path)` — delete file (and close the lock handle first if `path` is
    the held lock)
  - `rename(from, to)` — write dest → flush dest → close dest → delete source
    (durability ordering enforced by the per-op lifecycle; no special-casing)
  - `exists(path)` → boolean
  - `acquireLock(path)` — `createSyncAccessHandle()` on the lock file and **hold
    it open** for the session; if the call throws (handle already held by another
    tab) respond with `{ ok: false, error }` so the adapter can raise
    `LockException`
  - `releaseLock(path)` — flush + close the held lock handle
  - `createDir(path)` — create directory and all intermediate directories
- Note: Worker unit tests are covered by the browser integration tests in Phase 4.
  The Worker protocol cannot be unit-tested outside a browser context because
  `FileSystemSyncAccessHandle` and OPFS are not available in the Dart VM.

### Phase 2 — Dart adapter

- [x] Add `lib/src/engine/platform/sahpool_worker_source.dart` — the
      `sahpool_worker.js` content as a `const String` (doc comment notes it must
      be kept in sync with the `.js` source)
- [x] Implement `StorageAdapterSahPool` in
      `lib/src/engine/platform/storage_adapter_sahpool.dart`
- [x] Startup: build a `Blob` from the const worker source, call
      `URL.createObjectURL()`, construct the `Worker` from the blob URL; wait for
      the Worker's `ready` message before any operations
- [x] Maintain a `Map<int, Completer>` keyed by a monotonic request `id`; a
      single `onmessage` handler resolves/rejects the matching completer from the
      echoed `id`. No `MessagePort` channels.
- [x] Each `StorageAdapter` method serialises to a `{ id, op, ...args }` message
      and awaits its completer
- [x] `syncFile(path)` and `syncDir(dirPath)` are no-ops — the per-op handle
      lifecycle already flushed-and-closed on the preceding write op (document
      the rationale in the method doc comments, referencing the durability note)
- [x] `acquireLock` / `releaseLock` — Worker holds an exclusive sync handle on
      the lock file for the session; a failed acquire (handle held by another
      tab) surfaces as a `LockException` with message "database is already open
      in another tab"
- [x] `appendFile` — Worker uses `getSize()` then `write(path, size, bytes)`
      (true append using sync handles, no read required)
- [x] `readFileRange` — Worker calls `read(path, offset, length)` directly
      (O(length) not O(file size))
- [x] `renameFile` — Worker write dest → flush dest → close dest → delete source
- [x] `close()` — terminates the Worker and revokes the blob URL
- [x] Add license header (use `@header_template.txt`, year 2026)

### Phase 3 — Conditional export and web-adapter deletion

- [x] Update the conditional export in
      `packages/kmdb/lib/src/engine/platform/storage_adapter.dart` so the
      `dart.library.js_interop` branch points at
      `storage_adapter_sahpool.dart` (replacing `storage_adapter_web.dart`);
      update the doc comment in that file accordingly
- [x] Update the default stub `storage_adapter_impl.dart` (currently re-exports
      `storage_adapter_web.dart`) to re-export `storage_adapter_sahpool.dart`
- [x] **Delete `lib/src/engine/platform/storage_adapter_web.dart`** and any
      references to `StorageAdapterWeb`. (No dedicated web-adapter test files
      exist in `packages/kmdb/test` as of 2026-06-01 — confirmed via grep.)

### Phase 4 — Tests

- [x] Integration tests running in a headless browser (using
      `dart test -p chrome`) covering all 14 interface methods
      (file: `test/engine/storage_adapter_sahpool_test.dart`)
- [x] Edge cases: `readFileRange` beyond EOF, `appendFile` to non-existent file,
      `releaseLock` without lock
- Note: cross-tab lock collision cannot be automated in `dart test -p chrome`
  (single browser context); covered by RC-11 in the release checklist.
- Note: benchmark comparison was not possible since `StorageAdapterWeb` was
  deleted as part of this plan (no baseline exists after deletion). Performance
  improvement is design-guaranteed: `readFileRange` is now O(length) vs O(file
  size), `appendFile` uses `getSize()` + write vs read+concat+rewrite.
- [x] Add release-checklist entries RC-10 (web crash/durability) and RC-11
      (cross-tab lock exclusion) to `docs/spec/28_release_checklist.md`
- [x] Achieve ≥90% line coverage on new Dart code (all new Dart is covered by
      browser integration tests; the `coverage:ignore-file` pragmas on web-only
      files are standard for platform-conditional code)

### Phase 5 — Spec and docs

- [x] Update `docs/spec/19_platform.md` (§19) with SAHPool design: Worker
      protocol (`id`-echo correlation), message format, per-op handle lifecycle
      and durability contract, cross-tab locking behaviour, and the
      Blob-URL worker loading mechanism. Removed the stale SQLite-isms
      (`journal_mode=truncate`, page cache) that do not apply to this LSM engine.
- [x] Update `docs/roadmap/0_03.md` to mark the SAHPool OPFS item done (matches
      this plan's header — the prior `0_04.md` reference was wrong)
- [x] Update `CLAUDE.md` implementation status table if a new phase is warranted
      (no new phase needed — SAHPool is an enhancement within Phase 8's OPFS scope;
      updated `docs/primer.md` to reference `storage_adapter_sahpool.dart`)

## Review (2026-06-01, kmdb-plan-reviewer)

Reviewed against the current `StorageAdapter` interface, `StorageAdapterWeb`,
spec §19, and the v0.02.01 durability-hardening invariants. The problem is real
and worth solving, and the broad approach (sync handles inside a Worker, plain
JS Worker, async Dart wrapper) is sound. However, the plan is **not yet
implementation-ready**: there is a load-bearing durability gap, a contradiction
between the problem statement and the adoption model, and several "open
questions" carry recommendations that have not been promoted to decisions. Set
to **Questions**.

### Problem statement assessment

Genuine and well-motivated. `readFileRange` reading the whole file then slicing
is O(file size) per 4KB block — confirmed in `storage_adapter_web.dart:108-119`,
and a 20MB SSTable scanned 4KB at a time really does trigger thousands of
full-file reads. `appendFile` read-concat-rewrite (lines 134-147) is genuinely
O(file size) per WAL/Manifest append. These are worth fixing.

One framing problem: the problem statement says the goal is to "adopt it as the
**default web adapter once the database exceeds a configurable size threshold**,"
but `KmdbDatabase.open()` takes `required StorageAdapter adapter`
(`kmdb_database.dart:261`) — there is no platform-default selection or
size-threshold switch in the open path; the caller always supplies the adapter.
Open question 3's own recommendation (always-on, caller selects) is the correct
model and directly contradicts the problem statement. Reconcile these: drop the
"default above threshold" language from the problem statement.

### Proposed solution assessment

Strengths: the async-`postMessage` Worker model is the right call (the Dart
interface is already fully async, so no interface change is needed — confirmed,
all 14 methods return `Future<T>`). Plain JS Worker avoids a second Dart
compilation target. Using SAH exclusive-handle semantics for a real cross-tab
lock is a genuine improvement over the in-memory `Set`.

The critical weakness is **durability**, which the plan does not address at all
(see Risk & Edge Cases). This is the blocker.

### Architecture fit

- Interface: no changes required — correct. The conditional export
  (`storage_adapter.dart`) currently routes web to `storage_adapter_web.dart`;
  Phase 3's plan to *also* export `StorageAdapterSahPool` is fine **but** note
  that conditional `export ... if (dart.library.js_interop) ...` selects a single
  file at compile time. You cannot conditionally export two web implementations
  and let the caller pick at runtime via that mechanism. Since the caller passes
  the adapter to `open()`, the simplest model is: export `StorageAdapterSahPool`
  unconditionally from the web-only barrel (guarded by the same `js_interop`
  condition as `StorageAdapterWeb`) so callers can `new` it directly. Spell out
  exactly which barrel/file the new symbol is added to and under what condition;
  the current Phase 3 wording is ambiguous.
- Spec §19 is currently thin and partly stale (it still references
  `journal_mode=truncate` / `page cache`, which are SQLite-isms that do not apply
  to this LSM engine). The plan correctly schedules a §19 rewrite. Per
  `docs/plans/README.md`, do not hard-code a new spec section number — §19 is an
  existing file so updating it in place is fine.

### Risk & edge cases — the durability gap (BLOCKER)

The plan's investigation table states `syncFile()/syncDir()` are "No-ops — Fine —
writes are durable on close." **This reasoning does not carry over to SAHPool.**
`StorageAdapterWeb` can no-op fsync only because OPFS *Writable Streams* are
durable on `close()`. `FileSystemSyncAccessHandle` is different: writes are
buffered in the handle until `flush()` is called explicitly. A SAHPool adapter
that keeps a handle open across writes and no-ops `syncFile` would lose data on a
crash/tab-kill.

This matters because the v0.02.01 hardening made fsync ordering load-bearing on
exactly these paths:
- `CurrentFile.write` (`current_file.dart:72-78`): write tmp → `syncFile(tmp)` →
  `renameFile` → `syncDir(dbDir)`. Review finding M3 explicitly depends on the
  temp's bytes being durable before the rename.
- `WalWriter` (`wal_writer.dart:71-72, 117-118`): `appendFile` then `syncFile`
  when `fsyncOnWrite`.
- `ManifestWriter.append` (`manifest_writer.dart:75-76`).
- `LsmEngine`/`CompactionJob` (`lsm_engine.dart:769-772`,
  `compaction_job.dart:354-359`): `syncFile(sst)` then `syncDir(sstDir)`.

The plan must specify the durability contract for the SAHPool adapter:
`syncFile(path)` → Worker calls `flush()` on that path's sync handle;
`syncDir(dirPath)` → define its meaning (OPFS has no directory fsync; a no-op is
likely acceptable *if* the rename simulation is itself durable, but this must be
stated and justified, not left implicit). Whether handles are kept open
("pooled") or opened-flushed-closed per write is a core design decision with
direct durability and performance consequences — it must be pinned down, not
discovered during implementation.

Other gaps:
- **Atomic rename (open question 4):** `CurrentFile` correctness depends on
  rename behaving atomically enough that a crash leaves either old or new CURRENT
  intact. The current web sim writes the new file fully (and the Writable Stream
  flushes on close) before deleting the old. A SAH-based sim must preserve that
  ordering *and* flush the destination handle before deleting the source, or it
  is strictly less safe than today. "Best-effort, same as current" is not a
  decision — resolve it.
- **Crash/durability testing:** the plan's test list is golden-path plus a few
  EOF/lock edge cases. Per CLAUDE.md and the 2026-05-22 review, storage-path work
  must be exercised with fault injection, not in-memory golden paths. Browser
  tab-kill / mid-write crash simulation cannot run in the automated `dart test
  -p chrome` suite reliably — add a `docs/spec/28_release_checklist.md` entry for
  manual web-crash/durability verification (analogous to RC-4).
- **Worker bootstrapping on web:** Phase 2 says "spawns the Worker from the
  bundled JS URL." How the `.js` Worker asset is located at runtime in a
  Flutter-web / `dart compile js` / WASM build is unspecified and non-trivial
  (asset path, base href, CSP `worker-src`). This is a real integration point
  that needs a concrete answer before implementation.
- **Concurrency model:** the engine is synchronous and serialises writes, but the
  Worker introduces an async round-trip per op. Confirm no ordering assumption is
  broken when many small ops (e.g. WAL append + syncFile) are in flight. State
  whether the adapter must serialise messages per-path.

### Implementation readiness

Not ready. A Sonnet implementer would have to invent: the durability/flush
contract, the handle-lifecycle (pooled vs per-op), the rename safety ordering,
the Worker asset-loading mechanism, and the exact export wiring. These are
architecture decisions, not mechanical steps. The message protocol is described
at a reasonable level, but the response-correlation mechanism is internally
inconsistent — the investigation says each message carries a `MessagePort` for
the response, while Phase 1 says each message has an `id` echoed in the response.
Pick one (an `id` correlation map is simpler and the usual pattern) and make the
protocol description self-consistent.

### Open questions — decisions still required

The four questions below carry recommendations but have **not** been confirmed as
decisions. Promote each to a recorded decision (or have the user decide), then
the plan can proceed to `Investigated`.

- [x] **Message-passing protocol** — Resolved: async `postMessage` with an
      `id`-echo correlation map, no `SharedArrayBuffer`/COOP+COEP. Protocol made
      self-consistent; all `MessagePort` references removed.
- [x] **Worker lifecycle** — Resolved: adapter owns the Worker; runtime Blob URL
      from a `const String` companion to the `.js` source (no asset-bundle/base
      href/CSP-beyond-`worker-src blob:` concerns).
- [x] **Adoption model** — Resolved: replace `StorageAdapterWeb` entirely, no
      threshold, no fallback; problem statement updated; deletion step added.
- [x] **Durability contract (was blocker)** — Resolved: per-op handle lifecycle
      (open → write → flush → close); `syncFile`/`syncDir` are no-ops for that
      SAH-specific reason; investigation table corrected.
- [x] **Atomic rename safety** — Resolved: write dest → flush dest → close dest →
      delete source, enforced by the per-op lifecycle.
- [x] **Cross-tab locking scope** — Resolved: in scope; exclusive session-held
      lock handle; failed acquire → `LockException` "database is already open in
      another tab"; no retry/timeout.
- [x] **Roadmap reference fix** — Resolved: Phase 5 now targets
      `docs/roadmap/0_03.md`.

## Review addendum (2026-06-01, kmdb-plan-reviewer) — promoted to Investigated

All seven open questions have been resolved in conversation with the user and
recorded above and throughout the plan. I verified the integration points the
decisions touch:

- The web conditional export lives in
  `storage_adapter.dart` (line 25-27) **and** the default stub
  `storage_adapter_impl.dart` (line 18) also re-exports the web adapter — both
  must be repointed at the SAHPool adapter when `StorageAdapterWeb` is deleted.
  This is now reflected in Phase 3.
- No dedicated `StorageAdapterWeb` test files exist under `packages/kmdb/test`
  as of this review, so the "delete its tests" decision has no test files to
  remove beyond the source file and the two export sites; Phase 3 notes this.

The earlier blocker (durability) is closed: the per-op flush-and-close lifecycle
makes flush a guaranteed part of every write, which is *why* `syncFile`/`syncDir`
can remain no-ops — a different rationale from the Writable-Stream durability the
current adapter relies on, and one that satisfies the v0.02.01 fsync-ordering
callers (`CurrentFile`, `WalWriter`, `ManifestWriter`, `LsmEngine`/
`CompactionJob`). The protocol is now internally consistent (`id`-echo only), the
export wiring and worker asset loading are concrete, and the rename ordering and
cross-tab lock semantics are pinned down. A Sonnet implementer can execute this
without inventing architecture.

One residual item to keep honest, not a blocker: the `const String` worker source
must be kept in sync with the `.js` file by hand. The plan flags this in the file
doc comment; if drift becomes a concern a build step can generate it later.

**Status: Investigated.**

## Summary

- Replace `StorageAdapterWeb` with `StorageAdapterSahPool`, routing all OPFS I/O
  through a Web Worker using `FileSystemSyncAccessHandle` for byte-level sync
  reads/writes (fixes O(file size) `readFileRange`/`appendFile`).
- Per-op handle lifecycle (open → write → flush → close) provides durability;
  `syncFile`/`syncDir` are no-ops for that reason, satisfying the v0.02.01
  fsync-ordering callers.
- Async `postMessage` protocol with an `id`-echo `Map<int, Completer>`
  correlation map; no `SharedArrayBuffer`, no COOP+COEP headers, no `MessagePort`
  channels.
- Worker JS loaded via a runtime Blob URL from a `const String` companion to the
  `.js` source — no asset bundling, works in JS and WASM builds.
- Real cross-tab exclusion via an exclusive session-held lock handle; collision →
  `LockException`.
- §19 spec rewrite, `docs/roadmap/0_03.md` update, and a
  `docs/spec/28_release_checklist.md` entry for manual web crash/durability
  verification.
