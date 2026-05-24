# Fix H5: Sync lease CAS atomicity — contract, conformance suite, and gating

**Status**: Investigated

**PR link**: {pending}

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

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — Capability shape.** Recommended: a marker interface
  `AtomicCasAdapter` (mirrors the existing `QuotaAwareAdapter` pattern) plus,
  for the local adapter, a constructor flag declaring whether the target is a
  true local FS or a cloud-synced folder. `MemorySyncAdapter` implements it;
  `LocalDirectoryAdapter` implements it *only* when constructed in
  local-disk mode.
- [ ] **D2 — Primary mitigation = gate, not perfect CAS.** Recommended: the
  coordinator **skips consolidation** when the adapter is not atomic
  (consolidation is an optimisation; skipping is loss-free). Atomic
  implementations are an added optimisation, not a precondition for shipping.
- [ ] **D3 — Local-FS atomic mechanism.** Recommended: `File.create(exclusive:
  true)` for create-if-absent; `RandomAccessFile.lock` advisory lock around the
  update path. Confirm the SDK exposes `exclusive` (Dart ≥ 2.19) on the target
  platforms.
- [ ] **D4 — Conformance suite home.** Recommended: ship it as test-support in
  `kmdb` (`test/support/`) and export a helper so provider packages
  (`kmdb_google_drive`, future Dropbox/iCloud) can import and run it against
  both their real adapter and their behavioural simulator.

## Implementation plan

### Step 1 — Define the contract and capability
- [ ] Write the `compareAndSwap` atomicity contract into the
      `SyncStorageAdapter` doc comments: exactly one concurrent caller may
      observe `true` for a given (path, precondition).
- [ ] Add `AtomicCasAdapter` (or `bool get providesAtomicCas`) and export it.

### Step 2 — Build the conformance + contention suite
- [ ] `runSyncAdapterConformance(SyncStorageAdapter Function() factory, {bool
      expectAtomicCas})` covering: create-if-absent success/conflict, update
      if-match success/412, getEtag semantics, delete idempotency.
- [ ] **Contention test:** launch many concurrent `compareAndSwap` create
      attempts at one path; assert **exactly one** returns `true` when
      `expectAtomicCas` is true. This is the H5 regression guard.
- [ ] Run the suite against `MemorySyncAdapter` (atomic) and
      `LocalDirectoryAdapter` in local-disk mode (atomic after Step 3).

### Step 3 — Make `LocalDirectoryAdapter` atomic (local-disk mode)
- [ ] create-if-absent: replace `existsSync()` + rename with
      `File.create(exclusive: true)` then write content; map the
      already-exists error to `false`.
- [ ] update-if-match: hold an advisory lock (`RandomAccessFile.lock`) across
      read-etag → compare → write, releasing in `finally`.
- [ ] Declare `providesAtomicCas` per construction mode; document that a
      cloud-synced folder must be constructed in non-atomic mode.

### Step 4 — Gate consolidation
- [ ] In `ConsolidationCoordinator.runIfNeeded`/`acquireLease`: if the adapter
      does not advertise atomic CAS, **skip consolidation** and surface a
      one-time log/diagnostic. Existing behaviour is otherwise unchanged.
- [ ] Confirm skipping is observable in a `SyncEngine` result/log so operators
      know consolidation is disabled for their backend.

### Step 5 — Tests
- [ ] Conformance + contention suite passes for Memory and Local (atomic mode).
- [ ] Local adapter in non-atomic (synced-folder) mode: conformance runs with
      `expectAtomicCas: false`; contention test is not asserted single-winner.
- [ ] Coordinator test: with a non-atomic adapter, `runIfNeeded` does **not**
      consolidate and reports the skip; with an atomic adapter it consolidates.
- [ ] Regression: confirm the contention test **fails on `main`** for the
      current local adapter and **passes after** Step 3.

### Step 6 — Documentation
- [ ] `docs/spec/12_sync.md`: document the CAS contract, the capability, the
      "consolidation requires atomic CAS, else skipped" rule, and per-backend
      guidance (local disk = atomic; cloud-synced folder = not).
- [ ] Reconcile the §12 `.consolidation-manifest` note flagged in the code
      review (spec references a file the code does not implement).

### Step 7 — Verify
- [ ] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
- [ ] `make analyze` clean.

## Summary

{To be completed during implementation.}
