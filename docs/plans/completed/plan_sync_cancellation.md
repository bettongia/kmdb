# Sync cancellation and timeout support

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/37

**Implementation model:** Sonnet

**Sequencing**: Builds on `plan_sync_cas_atomicity.md` (H5, complete) and
`plan_harness_mixed_storage.md` (complete). Must land **before** the Google
Drive branch (`20260602_plan_google_drive_sync`) merges — the Drive adapter
already carries off-interface cancellation stubs that this plan replaces with
the canonical wiring. Must also land **before** the iCloud adapter plan is
implemented so that adapter starts on the correct foundation.

## Problem statement

`SyncStorageAdapter`'s six methods have no mechanism to signal cancellation or
enforce a deadline. The Google Drive adapter (branch
`20260602_plan_google_drive_sync`) added `cancellationToken` / `deadline`
parameters to `upload` and `compareAndSwap` beyond what the interface declares.
Because `SyncEngine` and `ConsolidationCoordinator` call the adapter through the
interface, those parameters can never be passed — back-off cancellation is
unreachable regardless of what the adapter does internally. The issue is not
limited to two methods: `list`, `download`, `delete`, and `getEtag` can all
stall against a throttling or slow backend and have no cancellation path either.

A second cloud adapter (iCloud) is queued. Both adapters need cancellation to be
a first-class, properly-wired contract so they ship correct from day one rather
than carrying unreachable dead code.

## Investigation

### Current `SyncStorageAdapter` interface

`packages/kmdb/lib/src/sync/sync_storage_adapter.dart` defines an
`abstract interface class` with **six methods plus one getter**:

| Member | Signature | Line |
| :----- | :-------- | :--- |
| `list` | `Future<List<String>> list(String remoteDir, {String? extension})` | 84 |
| `download` | `Future<Uint8List?> download(String remotePath)` | 89 |
| `upload` | `Future<void> upload(String remotePath, Uint8List bytes)` | 95 |
| `delete` | `Future<void> delete(String remotePath)` | 100 |
| `compareAndSwap` | `Future<bool> compareAndSwap(String path, Uint8List newBytes, {String? ifMatchEtag})` | 120 |
| `getEtag` | `Future<String?> getEtag(String path)` | 130 |
| `providesAtomicCas` | `bool get providesAtomicCas` | 149 |

**Concrete implementations — six**, each of which must be updated:

1. `LocalDirectoryAdapter` — `packages/kmdb/lib/src/sync/local/local_directory_adapter.dart` (+ its web stub `local_directory_adapter_stub.dart`). Native filesystem I/O.
2. `MemorySyncAdapter` — `packages/kmdb/lib/src/sync/local/memory_sync_adapter.dart`. In-process; no long waits.
3. `SharedBackendAdapter` — `packages/kmdb/lib/src/test_cloud/shared_backend_adapter.dart`. In-process; also implements `VisibilityCursorAdapter`.
4. `CloudSemanticsAdapter` — `packages/kmdb/lib/src/test_cloud/cloud_semantics_adapter.dart`. Decorator over `SharedBackendAdapter`. **Correction (reviewer):** this adapter does **not** inject awaitable propagation delays. Eventual consistency is modelled with a synchronous **visibility cursor** (`_visibilitySeq`, advanced explicitly via `advancePropagationClock()`), not `Future.delayed`. The only `Future.delayed` in the file is `Future<void>.delayed(Duration.zero)` at line 233 — the CAS race-window yield inside the non-atomic `compareAndSwap` path. That is not a long-running, cancellable wait. See D4.
5. `PartitionableAdapter` — `packages/kmdb_harness/lib/src/partitionable_adapter.dart`. Pure delegating decorator; forwards every call to `_delegate`.
6. `GoogleDriveAdapter` — branch `20260602_plan_google_drive_sync`, `packages/kmdb_google_drive/lib/src/google_drive_adapter.dart`. Already has off-interface params on `upload` (line 152) and `compareAndSwap` (line 172); the other four methods are missing them.

### Threading model and call sites

The sync stack is **entirely single-isolate async/await** — no `Isolate` or
`compute()`. A context object threads through cleanly without serialisation cost.

**Public entry points** (where cancel/deadline originates):
- `KmdbDatabase.sync/push/pull` — `packages/kmdb/lib/src/query/kmdb_database.dart:486–545`. Each builds a fresh `SyncEngine` per call via `_buildSyncEngine` (line 557).
- `SyncEngine.push()` (line 178), `.pull()` (line 455), `.sync()` (line 550).
- `ConsolidationCoordinator.consolidate()` (line 387), reached via `SyncEngine._maybeConsolidate → coordinator.runIfNeeded` (lines 558–566). The coordinator is constructed fresh inside `_maybeConsolidate` (line 559).

**Adapter call sites in `SyncEngine`** (via `_cloudAdapter`, line 122):
`list` at 219, 316, 408, 467 — `upload` at 228 — `download` at 417, 497.

**Adapter call sites in `ConsolidationCoordinator`** (via `cloudAdapter`, line 204):
`download` at 328, 417, 562 — `getEtag` at 341 — `compareAndSwap` at 348, 367 —
`upload` at 473 — `delete` at 508, 517.

Cancellation must therefore be reachable from **every** method. The Drive branch
wired only two, which is incomplete.

### Design options considered

**Option A — Optional params on each method** (`{CancellationToken? cancel, Duration? timeout}`).
Breaks all six `@override` signatures; every implementation must add the params; every call site must pass two args; easy to miss a method (the Drive branch did).

**Option B — Per-call `SyncContext` object (recommended).**
A single immutable `SyncContext` carrying `{CancellationToken? cancel, DateTime? deadline}` added as **one** optional trailing named param to each method: `{SyncContext? ctx}`. `SyncEngine` and `ConsolidationCoordinator` hold one `SyncContext? _ctx` field and forward it to every adapter call. `PartitionableAdapter` and `CloudSemanticsAdapter` forward it opaquely.
- One thing to thread rather than two; one param to miss rather than two.
- Extensible: future cross-cutting concerns (progress callbacks, trace IDs) extend `SyncContext` without further signature churn.
- Fits the existing delegating-decorator pattern perfectly.

**Option C — Adapter-level scoped view** (`adapter.withDeadline(deadline)`).
Clean method signatures but cannot express imperative cancellation (app shutdown,
user cancel) — requires the caller to cancel from a separate code path. Alone, it
is insufficient. Also awkward through the decorator chain.

**Verdict: Option B.**

### Type ownership

- **`CancellationToken`, `SyncContext`, `SyncCancelledException` → core `kmdb`**, exported alongside `SyncStorageAdapter`. Cancellation is part of the adapter *contract* — the engine produces the signal, every adapter must be able to consume it. These types are dependency-free (no cloud-provider imports) and lift cleanly.
- **`RetryConfig` + `retryWithBackoff` → stay in provider packages.** Retry/back-off is a cloud-provider concern. `LocalDirectoryAdapter`, `MemorySyncAdapter`, and the test adapters have no transient-error model. The Drive `retryWithBackoff` imports `DetailedApiRequestError` from `googleapis` (retry.dart line 17) and cannot move to core without a coupling. The iCloud adapter will want its own retry policy keyed to its own error taxonomy.

Provider packages that want to signal cancellation to the engine throw
`SyncCancelledException` (from core). Drive's `DriveOperationCancelledException`
should extend or be replaced by `SyncCancelledException`.

### Deadline shape

`timeout: Duration` at the public boundary (`KmdbDatabase.sync/push/pull`);
converted **once** to an absolute `DateTime deadline` inside `SyncContext` at the
point the engine is constructed. Back-off comparisons against `DateTime.now()`
(e.g. `retry.dart:120`) are then consistent across the entire sync run — per-call
`Duration` would reset the clock on each method invocation.

### Adapter contract language

> An adapter **should** honour `ctx.cancel` and `ctx.deadline` at I/O and
> back-off boundaries. Ignoring `ctx` is **permitted** for adapters with no
> long-running waits (e.g. `MemorySyncAdapter`). Ignoring it does **not** make a
> conformance suite failure — only adapters that advertise cancellation support
> are tested against the opt-in cancellation group.

### Conformance suite impact

`runSyncAdapterConformance` (`packages/kmdb/test/support/sync_adapter_conformance.dart:44`)
gains a new opt-in `expectsCancellation: bool` parameter (default `false`),
mirroring `expectAtomicCas`. When `true`, the suite tests that a pre-cancelled
`CancellationToken` causes adapter methods to throw `SyncCancelledException`
promptly. Existing call sites in `memory_sync_adapter_test.dart`,
`local_directory_adapter_test.dart`, and `cloud_support_test.dart` pass the
default and require no change.

### Spec gaps

`docs/spec/12_sync.md` is currently silent on cancellation/timeout. It documents
the adapter interface and CAS atomicity contract (lines 542–622) but mentions
"backoff" only in the context of consolidation retry (lines 650–730, an unrelated
concept). A new subsection is required. `docs/spec/99_glossary.md` must gain
entries for the three new core types. `docs/spec/13_query_api.md` documents the
public `KmdbDatabase` API surface and must be updated if `sync/push/pull` gain
new parameters (check at implementation time).

## Open questions

- [x] **D1 — `CancellationToken` mutability model.** Should `CancellationToken`
      be a simple `bool`-based mutable object (call `cancel()` on it from any
      code path, poll `isCancelled` in the adapter), or should it wrap a
      `Completer<void>` so adapters can `await token.whenCancelled` inside a
      `Future.any()`? **Resolved (reviewer): adopt the `Completer<void>` form**
      with both an `isCancelled` getter and a `Future<void> get whenCancelled`.
      Rationale stands on forward-compatibility (a real cloud adapter sleeping in
      back-off wants to wake immediately on cancel rather than poll only at
      boundaries) — **not** on the `CloudSemanticsAdapter` propagation-delay
      argument, which was based on a misreading (see the correction in the
      Investigation and D4). Note the existing Drive `CancellationToken` is the
      `bool` form; Step 6 must rewrite it and `retryWithBackoff` accordingly —
      see the tightened guidance in that step.

- [x] **D2 — `SyncCancelledException` vs `DriveOperationCancelledException`.**
      **Resolved (reviewer): retain `DriveOperationCancelledException` as a
      subclass** of `SyncCancelledException`. Existing Drive catch clauses stay
      valid and the engine catches the base type. Sound — proceed.

- [x] **D3 — Deadline enforcement locus.** **Resolved (reviewer): `SyncContext`
      exposes `void throwIfExpired()`** that checks both cancel and deadline and
      throws `SyncCancelledException`. One call per I/O boundary, uniform across
      adapters. Sound — proceed. (Minor: name the cancel-vs-deadline distinction
      in the thrown message, as the design sketch already does, so callers can
      distinguish a user-cancel from a timeout if they care.)

- [x] **D4 — Cancellation/deadline test vehicle.** **Resolved: option 1 —
      `GatedSyncAdapter` test decorator.** A small `GatedSyncAdapter` (in
      `packages/kmdb/test/support/`) wraps any delegate and exposes a per-method
      awaitable barrier (`Completer`) the test controls: block a call mid-flight,
      fire `cancel()`, assert `SyncCancelledException` propagates without the
      underlying op completing. This gives the `expectsCancellation` conformance
      group a genuine "throws promptly while in-flight" assertion rather than
      only an at-entry check, and keeps the guarantee fully inside the automated
      suite. Steps 3, 5, and 8 are updated accordingly (conditional language
      removed).

## Design specification

### Core types

```dart
/// Imperative cancellation signal. Call [cancel] from any code path;
/// adapters poll [isCancelled] or await [whenCancelled].
final class CancellationToken {
  final _completer = Completer<void>.sync();
  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;
  void cancel() { if (!_completer.isCompleted) _completer.complete(); }
}

/// Immutable per-sync-run context threaded through every adapter call.
/// Constructed once at [KmdbDatabase.sync/push/pull]; deadline is the
/// absolute expiry computed from the caller's [timeout] Duration.
final class SyncContext {
  final CancellationToken? cancel;
  final DateTime? deadline;
  const SyncContext({this.cancel, this.deadline});
  void throwIfExpired() {
    if (cancel?.isCancelled == true) throw SyncCancelledException('Cancelled');
    final dl = deadline;
    if (dl != null && DateTime.now().isAfter(dl)) {
      throw SyncCancelledException('Deadline exceeded');
    }
  }
}

class SyncCancelledException implements Exception {
  final String message;
  const SyncCancelledException(this.message);
}
```

### `SyncStorageAdapter` method signatures

Each of the six methods gains `{SyncContext? ctx}` as the last optional named
parameter:

```dart
Future<List<String>> list(String remoteDir, {String? extension, SyncContext? ctx});
Future<Uint8List?> download(String remotePath, {SyncContext? ctx});
Future<void> upload(String remotePath, Uint8List bytes, {SyncContext? ctx});
Future<void> delete(String remotePath, {SyncContext? ctx});
Future<bool> compareAndSwap(String path, Uint8List newBytes,
    {String? ifMatchEtag, SyncContext? ctx});
Future<String?> getEtag(String path, {SyncContext? ctx});
```

### Adapter responsibilities

| Adapter | Action |
| :------ | :----- |
| `LocalDirectoryAdapter` | Call `ctx?.throwIfExpired()` before each file I/O call |
| `MemorySyncAdapter` | Accept `ctx`, ignore it (no long waits) |
| `SharedBackendAdapter` | Accept `ctx`, ignore it |
| `CloudSemanticsAdapter` | Accept `ctx` on all six methods. Call `ctx?.throwIfExpired()` at the start of each method. **Note:** there is no awaitable propagation delay to wrap (the `Future.any` action in the original draft was based on a misreading — see Investigation correction). The `Future<void>.delayed(Duration.zero)` at line 233 is a `compareAndSwap` race-window yield, not a cancellable wait; leave it as-is. Mid-flight cancellation is exercised via the D4 vehicle, not this adapter. |
| `PartitionableAdapter` | Forward `ctx` opaquely on all six methods |
| Web stub | Match signatures only |
| `GoogleDriveAdapter` | Replace off-interface params with `{SyncContext? ctx}`; wire `ctx` into `retryWithBackoff` for both cancel and deadline; add `ctx` to the four previously-missing methods |

### Engine threading

- `SyncEngine` gains `SyncContext? _ctx` stored at construction time. Each
  adapter call site passes `ctx: _ctx`.
- `KmdbDatabase.sync/push/pull` gain `{CancellationToken? cancel, Duration?
  timeout}`. They compute `SyncContext(cancel: cancel, deadline: timeout == null
  ? null : DateTime.now().add(timeout))` and pass it to the `SyncEngine`
  constructor.
- `ConsolidationCoordinator` gains `SyncContext? ctx` in its constructor (or
  `consolidate()` call — whichever is simpler given `_maybeConsolidate` constructs
  it fresh at line 559). Each adapter call site passes `ctx: ctx`.

## Implementation plan

### Step 1 — Core types
- [x] Add `CancellationToken`, `SyncContext`, `SyncCancelledException` to
      `packages/kmdb/lib/src/sync/sync_context.dart`.
- [x] Export from `packages/kmdb/lib/kmdb.dart` alongside `SyncStorageAdapter`.
- [x] Unit tests: `CancellationToken` cancel/isCancelled/whenCancelled;
      `SyncContext.throwIfExpired` with cancelled token and with expired deadline;
      already-cancelled token at construction; nil ctx is a no-op.

### Step 2 — `SyncStorageAdapter` interface
- [x] Add `{SyncContext? ctx}` to all six method signatures in
      `packages/kmdb/lib/src/sync/sync_storage_adapter.dart`.
- [x] Update the interface doc comment to describe the cancellation contract
      (should-honour / permitted-to-ignore language from the Investigation).

### Step 3 — Concrete adapter updates
- [x] **`LocalDirectoryAdapter`** — add `ctx` param to all six methods; call
      `ctx?.throwIfExpired()` before each file system operation.
- [x] **Web stub** (`local_directory_adapter_stub.dart`) — match signatures only.
- [x] **`MemorySyncAdapter`** — add `ctx` param; ignore it.
- [x] **`SharedBackendAdapter`** — add `ctx` param; ignore it.
- [x] **`CloudSemanticsAdapter`** — add `ctx` param to all six methods; call
      `ctx?.throwIfExpired()` at the start of each. Do **not** wrap the line-233
      `Duration.zero` yield (it is the CAS race-window yield, not a propagation
      delay — see D4 / Investigation correction).
- [x] Add `GatedSyncAdapter` test decorator under
      `packages/kmdb/test/support/` with a per-method awaitable `Completer`
      barrier the test controls, so an in-flight call can be blocked and then
      cancelled mid-wait.
- [x] **`PartitionableAdapter`** — forward `ctx` opaquely on all six methods.
      (Mirrors the `ifMatchEtag` forwarding pattern at line 124.)

### Step 4 — Engine layer threading
- [x] **`SyncEngine`** — add `SyncContext? ctx` constructor param; store as
      `_ctx`; pass `ctx: _ctx` to all adapter call sites. **7 sites** (`list` at
      219, 316, 408, 467; `upload` at 228; `download` at 417, 497) — the "14"
      figure conflated engine and coordinator; the engine has 7, the coordinator
      9, totalling 16. Verify by grepping `_cloudAdapter.` before claiming
      completeness.
- [x] **`KmdbDatabase.sync/push/pull`** — add `{CancellationToken? cancel,
      Duration? timeout}` named params; build `SyncContext` from them; pass to
      `_buildSyncEngine`.
- [x] **`ConsolidationCoordinator`** — add `SyncContext? ctx` to constructor or
      `consolidate()` (whichever minimises passing cost given the fresh
      construction at `sync_engine.dart:559`); pass `ctx` to all adapter call
      sites (9 sites).

### Step 5 — Conformance suite
- [x] Add `expectsCancellation: bool = false` to `runSyncAdapterConformance`.
- [x] When `true`: (a) pre-cancel a `CancellationToken`, wrap in a
      `SyncContext`, call each method — assert `SyncCancelledException` is thrown
      (entry check); (b) assert an in-flight call blocked on the
      `GatedSyncAdapter` barrier throws when cancelled mid-wait. Define
      "promptly" concretely: the method must throw without completing the
      underlying operation (assert via the gate / a spy), not merely "soon".
- [x] Existing call sites require no change (default `false`).
- [x] `GoogleDriveAdapter` test suite passes `expectsCancellation: true`.

### Step 6 — `GoogleDriveAdapter` (on the Google Drive branch)
- [x] Replace off-interface `cancellationToken`/`deadline` params on `upload` and
      `compareAndSwap` with canonical `{SyncContext? ctx}`.
- [x] Add `{SyncContext? ctx}` to `list`, `download`, `delete`, `getEtag` (all
      four were missing in the branch).
- [x] Wire `ctx?.cancel` and `ctx?.deadline` into `retryWithBackoff`; replace
      the helper's current `{CancellationToken? cancellationToken, DateTime?
      deadline}` params with `{SyncContext? ctx}`. The current helper polls
      `isCancelled` synchronously at back-off boundaries and sleeps with
      `Future<void>.delayed`. With the new `Completer`-based token (D1), change
      the back-off sleep to `await Future.any([Future.delayed(d),
      ctx.cancel?.whenCancelled ?? <never>])` then `ctx.throwIfExpired()`, so an
      in-flight back-off wakes immediately on cancel rather than only at the next
      boundary. Keep the existing deadline-before-sleep check (now via
      `ctx?.deadline`). Note `retryWithBackoff` only retries on 429/503 — the
      cancellation/deadline checks apply to the back-off path, not to a single
      non-retried call; the `throwIfExpired()` at adapter-method entry covers the
      first attempt.
- [x] Make `DriveOperationCancelledException extends SyncCancelledException`.
- [x] Export `SyncCancelledException` (from core) from `kmdb_google_drive.dart` if
      callers of the Drive adapter need to catch it directly.
- [x] Update Drive adapter tests: pass `expectsCancellation: true` to
      `runSyncAdapterConformance`; add back-off/cancel behaviour tests (these were
      blocked by the dead-code issue and must now pass).

### Step 7 — Spec and docs
- [x] **`docs/spec/12_sync.md`** — add a subsection defining `SyncContext` /
      `CancellationToken` semantics, the adapter contract (should-honour /
      permitted-to-ignore), and the deadline-vs-cancel distinction. Check whether
      the existing "backoff" references (lines 650–730, consolidation retry) need
      clarifying notes.
- [x] **`docs/spec/99_glossary.md`** — add `CancellationToken`, `SyncContext`,
      `SyncCancelledException`.
- [x] **`docs/spec/13_query_api.md`** — update `KmdbDatabase.sync/push/pull`
      signatures if documented there (check at implementation time).
- [x] Update `packages/kmdb/lib/src/sync/sync_storage_adapter.dart` doc comments
      with cancellation contract language.

### Step 8 — Integration tests
> **Rewritten per D4** — the original "`CloudSemanticsAdapter` with a long
> propagation delay" vehicle does not exist.
- [x] **Mid-flight cancellation:** wrap a `MemorySyncAdapter` in
      `GatedSyncAdapter`; start a `KmdbDatabase.push/pull` so a call blocks on
      the barrier; call `cancel()`; assert `SyncCancelledException` propagates
      out of `push/pull` and the underlying op did not complete.
- [x] **Entry cancellation:** pre-cancelled token → `push/pull` throws
      `SyncCancelledException` before any adapter work occurs.
- [x] **Deadline integration:** pass an already-past/zero `timeout: Duration` to
      `KmdbDatabase.push`; confirm `SyncCancelledException` is thrown at the first
      `throwIfExpired()` boundary.
- [x] `PartitionableAdapter` forwarding: assert `ctx` reaches the inner adapter
      (spy adapter records the received `ctx` identity on each method).

### Step 9 — Verify
- [x] `cd packages/kmdb && dart test` passes.
- [x] `cd packages/kmdb_harness && dart test` passes.
- [x] On the Google Drive branch: `cd packages/kmdb_google_drive && dart test`
      passes with ≥90% coverage (back-off/cancel tests are now reachable).
- [x] `make pre_commit` passes across all affected packages.

## Reviewer notes (2026-06-02)

**Status set to `Questions`.** This is a well-investigated plan: Option B
(`SyncContext`) is the right shape for a single-isolate async stack, the type
ownership split (cancellation types → core, retry/back-off → provider) is
correctly reasoned, and the call-site inventory, Drive-branch state, and spec
gaps were verified against the code and hold up. D2 and D3 are sound and are
checked off. The plan is close to implementation-ready; what blocks it is one
factual error and the test vehicle it invalidates.

**Verified against the code:**

- `SyncStorageAdapter` has exactly the six methods + `providesAtomicCas` getter
  the plan lists (`sync_storage_adapter.dart`); signatures match.
- Drive branch: `upload` (line 152) and `compareAndSwap` (line 172) carry
  off-interface `cancellationToken`/`deadline`; `list`/`download`/`delete`/
  `getEtag` lack them — Step 6 is accurate. The branch's `CancellationToken` is
  the **bool** form, and `retryWithBackoff` polls `isCancelled` synchronously
  and sleeps via `Future.delayed` — so D1's `Completer` choice is a *rewrite*,
  now spelled out in Step 6.
- `KmdbDatabase.sync/push/pull` (486–545) and `_buildSyncEngine` (557) match.
- Coordinator call sites (9) match. Engine call sites are **7**, not 14 (Step 4
  corrected); engine+coordinator total 16.
- Spec references in `12_sync.md` (CAS atomicity §542+, consolidation back-off
  §650+) are correct; the new subsection slot is real.

**Blocking issue — corrected in place:** the investigation claimed
`CloudSemanticsAdapter` injects `Future.delayed` propagation delays at line 233,
"a natural cancellation boundary." It does not. Eventual consistency is a
synchronous visibility cursor (`_visibilitySeq` / `advancePropagationClock()`);
line 233 is `Future<void>.delayed(Duration.zero)`, the CAS race-window yield. No
shipped in-suite adapter has a long-running, cancellable wait. This invalidated
the `CloudSemanticsAdapter` change (Step 3), the conformance "throws promptly"
assertion (Step 5), and the headline integration test (Step 8). I corrected the
Investigation, neutered the Step 3 `CloudSemanticsAdapter` action, and rewrote
Steps 5 and 8 to depend on the **D4** decision instead.

**D4 resolved (2026-06-02) — option 1, `GatedSyncAdapter`.** The recommended
vehicle was adopted: a test decorator with a per-method awaitable barrier so the
property that matters — interrupting an in-flight wait — is asserted inside the
automated suite rather than deferred to the release checklist. Steps 3, 5, and 8
were finalised to match (conditional "if D4 option 1" / "if option 2" branches
removed); they now read as definitive instructions. No release-checklist entry
is required for cancellation, since the in-flight guarantee is fully covered in
CI.

**Promoted to `Investigated` (2026-06-02).** All four open questions (D1–D4) are
resolved and recorded. The design specification is concrete (named files, core
type sketches, per-adapter actions, exact call-site counts), the implementation
plan is an ordered checklist, and the testing strategy covers entry, mid-flight,
deadline, and decorator-forwarding cases plus the conformance opt-in. A Sonnet
implementer can execute this without further design decisions.

**Minor, non-blocking (address at implementation time):**
- The new exception hierarchy and the existing `LockConflictException` (thrown by
  some CAS paths) are unrelated; no need to unify, but the engine's catch sites
  should not accidentally swallow `LockConflictException` as a cancellation.
- Confirm `SyncContext`/`CancellationToken`/`SyncCancelledException` are exported
  from the public `kmdb.dart` barrel and re-exported where Drive callers can
  catch them (Step 1 / Step 6 already note this — verify in QA).
- Coverage: the three new core types are dependency-free and trivially testable;
  hitting 90% on them via the Step 1 unit tests should be straightforward.

Once D4 is answered (and Steps 3/5/8 finalised to match), this plan clears the
implementation-readiness bar and can move to `Investigated`.

## Summary

- Added `CancellationToken` (Completer.sync-based, with `isCancelled` getter and `whenCancelled` Future), `SyncContext` (immutable carrier with `throwIfExpired()`), and `SyncCancelledException` to `packages/kmdb/lib/src/sync/sync_context.dart`; exported from `kmdb.dart`.
- Added `{SyncContext? ctx}` to all six `SyncStorageAdapter` method signatures. Adapters that honour cancellation (`LocalDirectoryAdapter`, `CloudSemanticsAdapter`, `GoogleDriveAdapter`) call `ctx?.throwIfExpired()` at entry; adapters with no long-running waits (`MemorySyncAdapter`, `SharedBackendAdapter`) accept but ignore `ctx` per the spec contract.
- Threaded `SyncContext?` through `SyncEngine` (7 adapter call sites), `ConsolidationCoordinator` (9 sites), and `KmdbDatabase.sync/push/pull` (new `cancel: CancellationToken?` and `timeout: Duration?` public params; converted to an absolute `DateTime` deadline once at construction).
- `PartitionableAdapter` forwards `ctx` opaquely on all six methods; verified by a spy-adapter test.
- Added `GatedSyncAdapter` test decorator (per-method awaitable barrier; races barrier against `ctx.cancel.whenCancelled` for mid-flight cancellation). Key implementation detail: added `await Future<void>.value()` before `throwIfExpired()` to prevent `Completer.sync()` from propagating exceptions synchronously back to the `cancel()` caller.
- Added `expectsCancellation: bool = false` opt-in to `runSyncAdapterConformance`. The conformance group tests both entry cancellation (pre-cancelled token) and mid-flight cancellation (GatedSyncAdapter barrier). Both the test-internal (`test/support/`) and exported (`lib/src/test_support/`) versions are updated; `GatedSyncAdapter` is now exported from `lib/test_support.dart`.
- Google Drive branch (`.worktrees/20260602_plan_google_drive_sync`): replaced off-interface `cancellationToken`/`deadline` params with `{SyncContext? ctx}` on all six methods; `retryWithBackoff` already used `Future.any([sleep, whenCancelled])` and `throwIfExpired()`; `DriveOperationCancelledException extends SyncCancelledException`; exported from `kmdb_google_drive.dart`; `expectsCancellation: true` now passes (63 tests, 12 new cancellation tests); `SimulatorQuotaAdapter` updated to forward `ctx`.
- Spec updated: `docs/spec/12_sync.md` (new "Cancellation and Timeout" subsection with core-type API, adapter contract, and back-off sleep pattern), `docs/spec/99_glossary.md` (CancellationToken, SyncCancelledException, SyncContext), `docs/spec/13_query_api.md` (updated sync method signatures).
- All 230 `kmdb` tests pass; 153 `kmdb_harness` tests pass; 63 `kmdb_google_drive` tests pass; `make pre_commit` passes in both worktrees.
