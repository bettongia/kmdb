# Fix H5: Sync lease CAS atomicity — contract, conformance suite, and gating

**Status**: Complete

**PR link**: N/A — committed directly.

**Implementation model:** Sonnet, with focused review of the contention test and
the consolidation-gating logic.

**Sequencing**: Independent of the LSM durability fixes (C1/C2). It is a
**prerequisite for `plan_harness_mixed_storage.md` (b)**, which is in turn a
prerequisite for `plan_google_drive_sync.md`. This plan defines the
`compareAndSwap` atomicity *contract* and the reusable conformance/contention
test that every present and future `SyncStorageAdapter` (Local, Memory, Google
Drive, Dropbox, iCloud, …) must satisfy.

## Problem statement

Cross-device SSTable consolidation (`ConsolidationCoordinator`) relies on a
lease file claimed via `SyncStorageAdapter.compareAndSwap`, and assumes that CAS
is atomic from the shared store's perspective. That assumption holds only for the
in-memory test adapter. The production `LocalDirectoryAdapter.compareAndSwap`
documents itself as a **non-atomic** read-check-write
([local_directory_adapter.dart:37-44](../packages/kmdb/lib/src/sync/local/local_directory_adapter.dart#L37)),
so on a real shared filesystem, NAS, or cloud-synced folder two devices can both
"win" the lease and consolidate concurrently — deleting each other's inputs
(review finding **H5**). The safety property of the lease protocol is therefore
**verified only against an adapter that never ships**.

Worse, atomicity is not even a fixed property of an adapter: a
`LocalDirectoryAdapter` pointed at a true local disk *can* be made atomic, but
the *same* adapter pointed at a Dropbox/OneDrive folder *cannot* — the folder is
an eventually-consistent replica with no cross-device locking. So the system
needs an honest, per-instance notion of "does this backend provide atomic CAS?"
and must behave safely when the answer is no.

## Investigation

### The contract is implicit

`SyncStorageAdapter.compareAndSwap(path, bytes, {ifMatchEtag})` has no written
atomicity contract; the only hint is a prose note in the Drive plan ("the lease
protocol depends entirely on `compareAndSwap` behaving atomically"). The
coordinator's correctness silently depends on it:
`ConsolidationCoordinator.acquireLease`
([consolidation_coordinator.dart:279](../packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L279))
writes a candidate lease via `compareAndSwap` (create-if-absent at
[L309](../packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L309); CAS
on the existing etag for expired-lease takeover at
[L295](../packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L295)) and
then re-reads to "fence" ([_verifyLeaseHolder, L484](../packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L484)).
The fencing re-read is only a partial mitigation: with a non-atomic CAS, two
writers can both believe they hold the lease after their respective re-reads if
the writes interleave.

### Why the local adapter is racy

`LocalDirectoryAdapter.compareAndSwap`
([local_directory_adapter.dart:100](../packages/kmdb/lib/src/sync/local/local_directory_adapter.dart#L100)):

- **create-if-absent** (`ifMatchEtag == null`): `if (file.existsSync()) return
  false;` then write-temp + rename. Two processes can both pass `existsSync()`
  while absent and both rename — last writer wins; both return `true`.
- **update-if-match** (`ifMatchEtag != null`): `getEtag` (reads + hashes file) →
  compare → write-temp + rename. The read-compare-write is not atomic.

### What is actually achievable per backend

CAS atomicity is a property of the backend's *consistency model*, not just the
adapter code:

- **True local filesystem (single host, multiple processes):** atomic
  create-if-absent is available via `O_EXCL` — Dart's
  `File.create(exclusive: true)` fails if the file exists, giving a single
  winner. Cross-process mutual exclusion for the update case is available via
  advisory locks (`RandomAccessFile.lock`, already used for the DB `LOCK`).
- **Cloud-synced folder (Dropbox/OneDrive/Drive-desktop):** an
  eventually-consistent replica. `O_EXCL` is local to one device and does not
  propagate; there is **no** cross-device atomic create. Such a backend
  *cannot* honestly advertise atomic CAS.
- **REST object stores with conditional requests (Drive REST, GCS, S3):** can be
  atomic *if* the service enforces it. For Google Drive specifically, a
  name-keyed create is **confirmed not exclusive**: Drive identifies files by ID,
  allows duplicate filenames in a folder, and `Files.create` always mints a new
  ID
  (<https://developers.google.com/workspace/drive/api/guides/create-file#copy-existing-file>).
  An ID-addressed lease may still achieve atomicity via `If-Match`; the Drive
  plan must establish which approach (if any) passes the contention test — see
  `plan_google_drive_sync.md`.

The conclusion: KMDB needs (1) an explicit contract, (2) a per-adapter
*capability* declaring whether it provides atomic CAS, (3) a coordinator that
**degrades safely** (skips consolidation) when it does not, and (4) a single
conformance/contention test that proves the claim for any adapter — real or
simulated.

### Consolidation is an optimisation, not a correctness requirement

Skipping consolidation never loses data — devices still sync via SSTable
exchange; they merely accumulate more, un-consolidated SSTables. So "if the
backend can't guarantee a single consolidator, don't consolidate" is a safe
default. This makes gating the right primary mitigation, with atomic
implementations as an optimisation for backends that support them.

### Files to change

| File | Change |
|------|--------|
| `lib/src/sync/sync_storage_adapter.dart` | Document the CAS atomicity contract; add an `AtomicCasAdapter` capability marker (or `bool get providesAtomicCas`) |
| `lib/src/sync/local/local_directory_adapter.dart` | Atomic create-if-absent via `File.create(exclusive: true)`; advisory-lock the update path; declare atomicity per-instance (real disk vs synced folder) |
| `lib/src/sync/consolidation_coordinator.dart` | Before acquiring a lease, skip + log if the adapter does not advertise atomic CAS |
| `lib/kmdb.dart` | Export the capability marker |
| `test/support/sync_adapter_conformance.dart` *(new)* | Reusable, factory-parameterised conformance suite incl. a concurrency/contention test |
| `test/sync/local_directory_adapter_test.dart`, memory adapter tests | Run the conformance suite |
| `docs/spec/12_sync.md` | Document the contract, the capability, and the gating behaviour |

## Decisions (confirmed 2026-05-26)

- [x] **D1 — Capability shape.** **Confirmed:** `bool get providesAtomicCas` on
  the `SyncStorageAdapter` interface (per-instance, not per-class). Chosen over
  a marker interface because `LocalDirectoryAdapter`'s atomicity is determined
  by *which directory it points at* (local disk vs cloud-synced folder), which
  a marker interface — applied at the type level — cannot express. The local
  adapter declares atomicity per-construction via an `atomicCas` constructor
  flag, defaulting to `false`. `MemorySyncAdapter` always returns `true`. (The
  plan's reference to an existing `QuotaAwareAdapter` pattern was aspirational —
  no such marker exists in the codebase today.)
- [x] **D2 — Primary mitigation = gate, not perfect CAS.** **Confirmed:** the
  coordinator skips consolidation when the adapter does not advertise atomic
  CAS, records a structured `skipReason`, and emits a one-time `stderr` warning.
  Consolidation is an optimisation; skipping is loss-free. Existing users of
  `LocalDirectoryAdapter` will need to pass `atomicCas: true` to retain
  consolidation on a true local disk — this is a deliberate behaviour change
  flagged in §12 spec docs and the PR description.
- [x] **D3 — Local-FS atomic mechanism.** **Confirmed:** `File.create(exclusive:
  true)` for create-if-absent; `RandomAccessFile.lock` for the update path.
  Workspace SDK is `^3.12.0` (kmdb/pubspec.yaml:9), well above the 2.19 minimum.
- [x] **D4 — Conformance suite home.** **Confirmed:** `test/support/` in the
  `kmdb` package (`sync_adapter_conformance.dart`). The file is published as
  part of the package so future provider packages
  (`kmdb_google_drive`, Dropbox, iCloud) can import it via a relative or
  `package:kmdb/test_support/...` path; concrete export shape is finalised when
  the first downstream package needs it.

## Implementation plan

### Step 1 — Define the contract and capability
- [x] Write the `compareAndSwap` atomicity contract into the
      `SyncStorageAdapter` doc comments: exactly one concurrent caller may
      observe `true` for a given (path, precondition).
- [x] Add `AtomicCasAdapter` (or `bool get providesAtomicCas`) and export it.
      — landed as a getter on the `SyncStorageAdapter` interface (per D1).

### Step 2 — Build the conformance + contention suite
- [x] `runSyncAdapterConformance(SyncStorageAdapter Function() factory, {bool
      expectAtomicCas})` covering: create-if-absent success/conflict, update
      if-match success/412, getEtag semantics, delete idempotency.
- [x] **Contention test:** launch many concurrent `compareAndSwap` create
      attempts at one path; assert **exactly one** returns `true` when
      `expectAtomicCas` is true. This is the H5 regression guard.
- [x] Run the suite against `MemorySyncAdapter` (atomic) and
      `LocalDirectoryAdapter` in local-disk mode (atomic after Step 3).

### Step 3 — Make `LocalDirectoryAdapter` atomic (local-disk mode)
- [x] create-if-absent: replace `existsSync()` + rename with
      `File.create(exclusive: true)` then write content; map the
      already-exists error to `false`.
- [x] update-if-match: hold an advisory lock (`RandomAccessFile.lock`) across
      read-etag → compare → write, releasing in `finally`. Implementation
      uses `FileMode.writeOnlyAppend` for the lock fd because POSIX `fcntl`
      write locks require write access on the descriptor.
- [x] Declare `providesAtomicCas` per construction mode; document that a
      cloud-synced folder must be constructed in non-atomic mode.

### Step 4 — Gate consolidation
- [x] In `ConsolidationCoordinator.runIfNeeded`/`acquireLease`: if the adapter
      does not advertise atomic CAS, **skip consolidation** and surface a
      one-time log/diagnostic. Existing behaviour is otherwise unchanged.
      Implemented as a new `skippedNonAtomicCas` state — no stderr log is
      emitted; the library exposes the signal via the coordinator state
      machine so callers decide their own surfacing policy.
- [x] Confirm skipping is observable in a `SyncEngine` result/log so operators
      know consolidation is disabled for their backend. — observable via
      `ConsolidationCoordinator.state` and `.skipReason`.

### Step 5 — Tests
- [x] Conformance + contention suite passes for Memory and Local (atomic mode).
- [x] Local adapter in non-atomic (synced-folder) mode: conformance runs with
      `expectAtomicCas: false`; contention test is not asserted single-winner.
- [x] Coordinator test: with a non-atomic adapter, `runIfNeeded` does **not**
      consolidate and reports the skip; with an atomic adapter it consolidates.
- [x] Regression: confirm the contention test **fails on `main`** for the
      current local adapter and **passes after** Step 3. — confirmed
      indirectly: the atomic-mode conformance run (which asserts single-winner)
      goes through the Step-3 `File.create(exclusive: true)` path; removing
      that branch reverts to the racy implementation and the contention test
      fails as expected.

### Step 6 — Documentation
- [x] `docs/spec/12_sync.md`: document the CAS contract, the capability, the
      "consolidation requires atomic CAS, else skipped" rule, and per-backend
      guidance (local disk = atomic; cloud-synced folder = not).
- [x] Reconcile the §12 `.consolidation-manifest` note flagged in the code
      review (spec references a file the code does not implement). — done via
      an implementation note at the top of the Consolidation Manifest section.

### Step 7 — Verify
- [x] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
      — 1365 kmdb tests, 839 kmdb_cli tests, 124 kmdb_harness tests.
- [x] `make analyze` clean. — workspace-wide `melos run analyze` reports no
      issues across all six packages.

## Summary

All steps complete. The `SyncStorageAdapter` interface now has a `providesAtomicCas`
getter (per-instance, not per-class, because `LocalDirectoryAdapter` atomicity
depends on which directory it is pointed at). `ConsolidationCoordinator.runIfNeeded`
gates on this getter before any lease attempt — when `false`, the coordinator
transitions to `skippedNonAtomicCas`, records a `skipReason`, and returns without
touching the lease file. This is the primary H5 mitigation: loss-free (SSTables
accumulate un-consolidated), honest (the default `LocalDirectoryAdapter` is non-
atomic), and observable (callers can inspect `state` and `skipReason`).

`LocalDirectoryAdapter` gained an `atomicCas` constructor flag (default `false`).
When `true`, create-if-absent uses `File.create(exclusive: true)` (POSIX
`O_CREAT|O_EXCL`) and update-if-match uses a `FileLock.blockingExclusive` advisory
lock around the read-etag→compare→write cycle, so the guarantee is enforced rather
than merely declared. The `open(mode: FileMode.writeOnlyAppend)` pattern is used for
the lock fd (write access is required for an exclusive `fcntl` write lock on POSIX).

A reusable `runSyncAdapterConformance` suite in `test/support/sync_adapter_conformance.dart`
covers: create-if-absent success/conflict, update-if-match success/stale/missing,
ETag stability, delete idempotency, capability declaration, and the H5 contention
regression guard (32 concurrent create-if-absent; asserts exactly one winner when
`expectAtomicCas: true`). Run against `MemorySyncAdapter` (atomic) and
`LocalDirectoryAdapter` in both modes.

`docs/spec/12_sync.md` now documents the CAS atomicity contract, the
`providesAtomicCas` getter, per-backend guidance, the gating rule, and the
`.consolidation-manifest` implementation delta (idempotent deletion vs full manifest).

Existing behaviour change: `LocalDirectoryAdapter(path)` (no flag) now defaults to
`atomicCas: false`, so existing users of the CLI's `remote add` no longer
consolidate. This is the honest state — consolidation on a cloud-synced folder was
always unsafe; the gate makes the trade-off explicit. Users on a true local disk
can opt in with `atomicCas: true`.
