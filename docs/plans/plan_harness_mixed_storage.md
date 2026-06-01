# Harness mixed-storage mode + behavioural cloud-API simulation

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Sonnet — additive test infrastructure; review the
eventual-consistency reconciliation refinement.

**Sequencing**: Builds on **`plan_sync_cas_atomicity.md` (H5), now complete**
(`docs/plans/completed/plan_sync_cas_atomicity.md`). H5 already landed the CAS
capability (`SyncStorageAdapter.providesAtomicCas`, gated in
`ConsolidationCoordinator`) and the adapter conformance + contention suite
(`packages/kmdb/test/support/sync_adapter_conformance.dart`, exposing
`runSyncAdapterConformance({factory, expectAtomicCas})` and
`runSyncAdapterContentionTest`). This plan **consumes** those, it does not wait
on them. It is a **prerequisite for `plan_google_drive_sync.md`**, which must
ship a behavioural Drive simulator conforming to the framework this plan
establishes.

## Problem statement

KMDB's sync correctness depends on behaviours that only appear with real
backends — eventual consistency, partial-file visibility, conditional-request
(CAS) semantics, rate limits, and provider quirks (e.g. Drive allowing duplicate
filenames). Today none of these are testable:

- The `kmdb_harness` multi-device harness drives all devices through a **single,
  shared, strongly-consistent** `SyncStorageAdapter` instance
  (`HarnessConfig.syncAdapter`), so it cannot model heterogeneous backends or
  cloud semantics.
- The Google Drive plan's current tests use "canned responses," which validate
  request *shape* but not *behaviour* (atomicity, consistency, contention).

We need (1) the harness to assign **per-device adapters** against a shared
logical remote, (2) a reusable **behavioural cloud simulation** layer that
faithfully reproduces a provider's API and consistency model for fast,
deterministic CI, and (3) real-service runs reserved for pre-release integration.
The simulation framework must be **general across providers** (Google Drive
first, then Dropbox, iCloud, GCS, …), not Drive-specific.

## Investigation

### What the harness already gives us (the asset)

Per §27, the hard part is built and is **transport-agnostic**: the
`ReconciliationAgent` is a correctness oracle (write log + sync log → per-device
and global LWW expected state, with fork detection) that does not care which
adapter moved the bytes. The harness also has seeded replay, flakiness/regression
diffing, `PartitionableAdapter` (a decorator model for fault injection), and is
already `QuotaAwareAdapter`-aware — exactly what a real Drive run needs. So the
extensions below are additive, not a rewrite.

### Gap 1 — single shared adapter

`HarnessConfig.syncAdapter` is one `SyncStorageAdapter` shared by every simulated
device. Real devices each instantiate their own adapter (own auth, own
folder-ID/metadata cache) against the same remote. The shared instance hides a
whole bug class — e.g. the Drive adapter's in-memory folder-ID cache would be
shared across "devices," masking stale-cache bugs that only occur per-device.
**Fix:** per-device adapter assignment via a factory
`SyncStorageAdapter Function(int deviceId)`, all bound to one shared backend.

### Gap 2 — strongly-consistent assumption

The reconciliation model assumes a completed push is immediately and fully
visible to the next pull. Real backends do not guarantee this: a
cloud-synced folder or REST store has propagation delay, partial-file
visibility mid-upload, out-of-order arrival, and (Drive) duplicate-name
creation. **Fix:** a cloud-semantics decorator (modelled on
`PartitionableAdapter`) injecting delayed/eventual visibility, plus a
refinement to the `ReconciliationAgent` so a *completed* pull may legitimately
observe a **subset** of prior pushes rather than all of them.

### Defining "mixed storage mode" precisely

A sync group shares one logical remote, so "device A on local FS, device B on
Drive" only makes sense as **one shared remote accessed two ways**: the remote
*is* a Drive folder, and some devices reach it via the Drive REST adapter while
others reach the *same folder* via a locally-mounted Drive/Dropbox desktop
client (a `LocalDirectoryAdapter` over the synced folder). This is a real,
important deployment and the high-value mixed-mode target: it validates that a
file written via REST is correctly seen by the FS-view device and vice versa,
including differing ETag/consistency behaviour. The simulator must therefore
support **one shared backend state accessed via multiple adapter front-ends.**

(True FS-and-REST-bridged-to-different-stores is *not* a real deployment — a user
picks one remote — so the harness will not synthesise a bridge between distinct
stores.)

### The behavioural cloud-API simulator (general framework)

To exercise the *real* provider adapter (not a stub), inject a behavioural fake
at the lowest seam: a fake `http.Client` that implements the provider's REST
endpoints with realistic behaviour — conditional requests (and whether they are
truly atomic), eventual consistency, rate-limit 429/503, resumable upload, and
provider quirks (Drive duplicate names). This runs the *actual*
`GoogleDriveAdapter` + `googleapis` code against a faithful in-memory backend.

To keep it general across providers, define a shared **`CloudProfile`**
describing a backend's observable behaviour:

```
CloudProfile {
  ConsistencyModel consistency;   // strong | eventual(delay distribution)
  bool atomicConditionalCreate;   // honest CAS-create atomicity
  bool allowsDuplicateNames;      // Drive: true
  QuotaProfile quota;             // ops/min, bytes/day
  // ...propagation, partial-visibility knobs
}
```

Each provider package ships: its real adapter, a behavioural API simulator, and
its `CloudProfile`. The harness consumes a real-adapter-over-simulator as a
per-device adapter and uses the `CloudProfile` to set reconciliation
expectations (e.g. tolerate delayed visibility; expect/forbid single-consolidator
behaviour based on `atomicConditionalCreate`, reusing H5's capability).

### Ownership split (so it generalises cleanly)

| Concern | Home |
|---------|------|
| CAS atomicity contract + adapter conformance/contention suite | `plan_sync_cas_atomicity.md` (H5), in `kmdb` test-support |
| Per-device adapters, cloud-semantics decorators, `CloudProfile`, reconciliation refinement | **this plan**, in `kmdb_harness` (+ small `kmdb` additions) |
| Provider-specific behavioural simulator + `CloudProfile` instance | each provider package (e.g. `plan_google_drive_sync.md` ships the Drive simulator) |
| Real-service soak/integration run | each provider package, credential-gated, pre-release only |

### Real service vs simulation

Running the harness against **real** Google Drive is slow, credential-gated,
rate-limited, non-deterministic, and consumes quota — suitable as an **opt-in,
pre-release soak/convergence test**, not per-commit CI. Deterministic CI value
comes from the **behavioural simulator**. The framework must support both with
the same harness scenarios, switching only the per-device adapter factory.

## Review (2026-06-01, kmdb-plan-reviewer)

The problem is real and well-framed, the ownership split is sound, and the
investigation correctly identifies the harness assets to reuse. But the plan is
**not yet implementation-ready** and was incorrectly marked `Investigated` while
its own decisions (D1–D5) sat unchecked. The gaps below would each force the
Sonnet implementer to invent design on the fly. Status reset to `Questions`.

### Blocking issues

1. **D1–D5 unanswered while status was `Investigated`.** The plan explicitly
   says "recommended answers — confirm before implementation," yet every box is
   `[ ]`. These are genuinely the user's calls (they shape the public harness
   API and where new types live). They must be confirmed and checked off before
   promotion. Captured as **open questions** below.

2. **Stale H5 framing (now corrected in the header).** H5 is **complete**.
   `providesAtomicCas` exists on `SyncStorageAdapter` (line 149) and gates
   `ConsolidationCoordinator` (line 268); `PartitionableAdapter` already forwards
   it (line 126). The conformance/contention suite exists at
   `packages/kmdb/test/support/sync_adapter_conformance.dart`. Steps that say
   "reusing H5's capability" / "per H5" must reference these concrete, landed
   symbols, not a future plan. Step 3's contention assertion is **already
   available** as `runSyncAdapterContentionTest(factory:, expectAtomicCas:)` and
   should be reused rather than re-derived.

3. **`CloudProfile.atomicConditionalCreate` collides conceptually with the
   landed `providesAtomicCas`.** The codebase already expresses CAS-create
   atomicity as a single bool on the adapter, and the conformance suite is
   parameterised by `expectAtomicCas`. Introducing a second, differently-named
   field invites drift. **Decide and write down** the relationship: either (a)
   `CloudProfile` does *not* carry an atomicity bool and the harness derives the
   expectation from `adapter.providesAtomicCas`, or (b) `CloudProfile` carries it
   and the simulator/adapter is required to make `providesAtomicCas` equal it
   (assert this in a conformance check). Name the chosen rule in Step 2/3.

4. **`QuotaAwareAdapter` name collision is unaddressed.** A `QuotaAwareAdapter`
   **already exists in the harness** (`test_manager.dart` line 55) with a single
   member `int get safeOperationThreshold`, exported from `kmdb_harness.dart` and
   used by `TestManager._validateQuota`. The Google Drive plan separately
   proposes a *different* `QuotaAwareAdapter` in **`kmdb`** with
   `maxOperationsPerMinute` / `maxUploadBytesPerDay` / `isWithinQuota(...)`. These
   are two incompatible interfaces with the same name. The investigation's claim
   that the harness is "already `QuotaAwareAdapter`-aware" is true only of the
   harness-local one. **Decide** whether `CloudProfile.quota` reuses the harness
   interface, the kmdb one, or a new shared type — and how `_validateQuota`
   reconciles. This is cross-plan and must not be left for the implementer.
   Captured as a new open question (D6).

5. **D1 mechanics under-specified.** "Change `HarnessConfig.syncAdapter` to a
   factory" omits the real integration points:
   - `Device` wraps its adapter in `PartitionableAdapter` *internally*
     (`device.dart` line 61) and `db.sync()` takes the adapter **per call**
     (`kmdb_database.dart` line 486, `device.dart` `_sync`). So "per-device
     adapter" means: `Device` receives its own `SyncStorageAdapter` from the
     factory, still wraps it in `PartitionableAdapter`. Name this.
   - The factory must be invoked in `TestManager._setup()` (line 202) where
     `Device(... syncAdapter: config.syncAdapter ...)` is constructed — change
     to `config.syncAdapterFactory(i)`.
   - State whether the existing `syncAdapter` field is **removed** or kept as a
     convenience that wraps `(_) => instance`. The §27 spec config table (line
     146) lists `syncAdapter: SyncStorageAdapter` and must be updated in lockstep
     (already in Step 6, but call out the table row).
   - The quota check (`_validateQuota`, line 168) currently reads
     `config.syncAdapter` once. Under a factory it must build (or sample) an
     adapter to test `is QuotaAwareAdapter`. Specify how.

6. **Step 3 (reconciliation refinement) is the hard part and is hand-waved.**
   "a completed pull may observe a subset of prior pushes" and "assert
   convergence only after a settle window" name an outcome, not a mechanism. The
   `ReconciliationAgent`'s current model is strict: `_recordSync` on a completed
   sync calls `_mergeGlobalIntoDevice` (line 311), folding the **entire** global
   LWW state into the device. To support eventual consistency you must specify:
   - **What "visible" means in the model.** The agent has no notion of which
     pushes have *propagated*. Does the `CloudSemanticsAdapter` expose a
     visibility clock/log the agent reads, or does the agent track per-push
     visibility timestamps itself? Name the data structure and the
     `Device`→agent signal (today only `ActionResult` flows).
   - **How `_mergeGlobalIntoDevice` changes.** Merging *global* state on every
     completed sync is precisely the strong-consistency assumption. Under
     eventual consistency a completed pull sees only the subset of pushes that
     have become visible to *this* device's adapter front-end. Specify the
     replacement: e.g. merge only writes whose originating SSTable is visible per
     the adapter's propagation state.
   - **The settle/quiescence assertion.** Define "settle window" concretely:
     drain all in-flight actions, advance the propagation clock past the max
     delay, force a final sync on every device, *then* assert each device equals
     `globalExpectedState()`. This is partly modelled on the existing
     `_verifyVersionForks` final-sync pass (`test_manager.dart` line 463) — point
     at that as the template.
   - **Fork detection interaction.** `_detectFork` (line 342) fires on *any*
     prior write by another device regardless of visibility. Under delayed
     visibility this is still correct (a fork is about write ordering, not
     propagation), but confirm and note it so the implementer doesn't "fix"
     working code.

   Without this, Step 3 is a research task, not a mechanical one. It is the
   single biggest readiness gap.

### Smaller gaps

7. **`CloudSemanticsAdapter` shared-backend contract is unspecified.** Step 2
   and Step 4 require "one shared backend state accessed via multiple adapter
   front-ends." `MemorySyncAdapter` is per-instance in-memory; per-device
   factories returning fresh `MemorySyncAdapter`s would **not** share state. Name
   the shared-backend type (e.g. a `SharedCloudBackend` holding the canonical
   file map, with `CloudSemanticsAdapter`/REST-view/FS-view front-ends reading
   and writing it under per-front-end visibility rules). This is implied but
   never stated, and it is load-bearing for both mixed-mode and eventual
   consistency.

8. **Step 4 "FS-view adapter over the same state" needs a named type.** The
   real `LocalDirectoryAdapter` operates on a real directory via `dart:io`. For a
   single-process simulator the "FS view" must be an in-memory front-end over the
   shared backend, not the real `LocalDirectoryAdapter`. Either say "a second
   `SyncStorageAdapter` front-end over `SharedCloudBackend` configured with FS-
   like consistency" or justify using a temp-dir `LocalDirectoryAdapter` bridged
   to the backend. Don't leave the implementer to guess which.

9. **`providesAtomicCas` on decorators.** `CloudSemanticsAdapter` (a decorator)
   must forward or override `providesAtomicCas` like `PartitionableAdapter` does
   (line 126). A non-atomic profile should surface `providesAtomicCas == false`
   so `ConsolidationCoordinator` gating actually engages. State this in Step 2.

10. **H4-FU test (Step 5) — confirm the owning plan reference resolves.** The
    item credits `plan_tombstone_gc.md` for the in-process CI test. That file is
    in `docs/plans/completed/` now; cite it as completed so the implementer can
    read the existing coverage and avoid duplicating it. Otherwise the scenario
    is well-scoped.

11. **Spec section number.** Step 6 edits the existing `§27` file — good, no new
    number needed. The release-checklist `RC-5` id should be confirmed
    un-clashing against current entries in `docs/spec/28_release_checklist.md`
    before use (H4-FU already reserved RC-4/RC-6 per CLAUDE.md).

### Strengths (keep these)

- The ownership-split table is the right call and matches how H5 already
  partitioned the conformance suite into `kmdb` test-support.
- Restricting "mixed mode" to one-remote-two-views (REST + FS view) and
  explicitly *refusing* to synthesise a bridge between distinct stores is correct
  and well-justified — it avoids testing a deployment that cannot exist.
- Keeping vault out of scope is consistent with §27 and should stay (D5).
- Reusing the `PartitionableAdapter` decorator pattern for `CloudSemanticsAdapter`
  is the right structural choice.

### Verdict

Reconsider-and-refine, not proceed. The framework is sound but Steps 1–4 each
hide a design decision (factory threading, the shared-backend type, the
visibility model, the reconciliation-merge rewrite) that a Sonnet implementer
must not be left to invent. Answer D1–D6, then specify the
`SharedCloudBackend`/visibility model and the concrete `_mergeGlobalIntoDevice`
change before promoting to `Investigated`.

## Review (2026-06-01 second pass, kmdb-plan-reviewer)

All decisions are now answered (D1–D7 below, all boxes checked), and the two
load-bearing design specs the first pass demanded — the `SharedCloudBackend` /
visibility model (D7) and the `QuotaAwareAdapter` boundary (D6) — are now written
into the "Design specification" section. Re-verified every file/line claim
against `main`; codebase claims hold:

- H5 landed: `SyncStorageAdapter.providesAtomicCas`
  (`packages/kmdb/lib/src/sync/sync_storage_adapter.dart:149`),
  `ConsolidationCoordinator` gate
  (`packages/kmdb/lib/src/sync/consolidation_coordinator.dart:268`),
  `PartitionableAdapter` forward
  (`packages/kmdb_harness/lib/src/partitionable_adapter.dart:126`), and the
  conformance suite (`runSyncAdapterConformance` /
  `runSyncAdapterContentionTest` in
  `packages/kmdb/test/support/sync_adapter_conformance.dart`).
- `QuotaAwareAdapter` (harness, `safeOperationThreshold`) at
  `packages/kmdb_harness/lib/src/test_manager.dart:55`; consumed by
  `_validateQuota` (line 167); reads `config.syncAdapter` once (line 168).
- `MemorySyncAdapter` holds **per-instance** `_files`/`_versions`
  (`packages/kmdb/lib/src/sync/local/memory_sync_adapter.dart:46`) — confirms a
  per-device factory returning fresh instances would NOT share state, so the
  shared-backend type (D7) is genuinely required.
- `ReconciliationAgent._mergeGlobalIntoDevice` folds the entire
  `globalExpectedState()` into the device on every completed sync
  (`reconciliation_agent.dart:322`) — the strong-consistency assumption to be
  refined. The signal `Device`→agent is `ActionResult` via
  `_reconciler.record(result)` (`device.dart:99`), carrying `syncCompleted` and
  `sstablesTransferred`. The final-sync template is `_verifyVersionForks` (uses
  `device.syncForVerification()`, `test_manager.dart`).
- §27 config table row `syncAdapter | SyncStorageAdapter` at
  `docs/spec/27_test_harness.md:146`.

**Two corrections to the first pass, now folded into the steps:**

- **RC-5 is already taken** (`docs/spec/28_release_checklist.md:128` — "Harness
  preset 5 real-isolate stress soak"). The new real-isolate cloud-soak entry
  must take the **next free id (RC-9)**; RC-1..RC-8 all exist. Review item 11's
  "register RC-5" instruction was wrong.
- **RC-6 already exists and IS the H4-FU multi-device tombstone
  non-resurrection test** (`docs/spec/28_release_checklist.md:145`), and already
  names *this plan* as its blocker ("requires the per-device adapter harness
  from `plan_harness_mixed_storage.md`, which is not yet landed"). So Step 5's
  tombstone item must **implement the harness scenario that unblocks RC-6** — it
  must not register a new checklist entry. Once the scenario lands and passes
  in-harness, the RC-6 entry's "not yet landed" caveat should be updated to point
  at the new automated coverage (a §28 edit, not a new RC id).

**D6 resolved consistent with the Drive plan's B1.** The Drive plan
(`plan_google_drive_sync.md` B1) already flags the same collision and recommends
adopting the existing harness interface as-is unless the rich shape is
load-bearing. This plan now adopts the matching boundary (see D6 / Design
spec §"Quota boundary"): `CloudProfile.quota` is **descriptive only** and does
not introduce a kmdb-side `QuotaAwareAdapter`; the harness `QuotaAwareAdapter`
(`safeOperationThreshold`) is untouched and `_validateQuota` keeps working. The
two plans are now reconciled.

Promoting to **Investigated**: D1–D7 answered, the shared-backend/visibility
model and the concrete `_mergeGlobalIntoDevice` rewrite are specified, the RC-id
clash is fixed, and the cross-plan quota boundary is pinned down.

## Open questions

All resolved (2026-06-01). Decisions recorded below; see the Design
specification for the load-bearing detail.

- [x] **D1 — Per-device adapters.** `HarnessConfig` gains
      `SyncStorageAdapter Function(int deviceId) syncAdapterFactory`. The
      existing `syncAdapter` field is **kept as a convenience**: when set, it
      forwards `(_) => syncAdapter`; the factory and the field are mutually
      exclusive (assert in `HarnessConfig`). §27 table keeps the `syncAdapter`
      row and adds a `syncAdapterFactory` row. (Backward compatible.)
- [x] **D2 — Simulator seam.** Fake `http.Client` driving the real `googleapis`
      adapter. Out of scope for this plan — the Drive plan owns the simulator.
      This plan only fixes the *seam contract* the harness consumes (per-device
      factory + `CloudProfile` + shared-backend front-ends).
- [x] **D3 — `CloudProfile` location.** `CloudProfile`, `CloudSemanticsAdapter`,
      and `SharedCloudBackend` live in **`kmdb` test-support**
      (`packages/kmdb/test/support/`, alongside `sync_adapter_conformance.dart`)
      so both adapters and the harness share them. Provider packages supply
      concrete `CloudProfile` instances.
- [x] **D4 — Reconciliation under eventual consistency.** A completed pull merges
      only the *visible* subset of pushes (per the device's visibility cursor);
      convergence is asserted only after a quiescent settle (drain in-flight +
      advance the backend's propagation clock past max delay + final sync on
      every device). See Design spec §"Visibility model".
- [x] **D5 — Vault scope.** Vault stays **out of scope** (consistent with §27).
- [x] **D6 — `QuotaAwareAdapter` boundary.** Keep the two concerns separate with
      a documented boundary. `CloudProfile.quota` is **descriptive metadata
      only** (it parameterises the simulator's 429/503 behaviour); it does NOT
      introduce or require a kmdb-side `QuotaAwareAdapter`. The harness
      `QuotaAwareAdapter` (`safeOperationThreshold`) is untouched, and
      `_validateQuota` keeps reading it from whichever adapter the factory yields
      for device 0 (see D1 mechanics below). This matches the Drive plan's B1
      recommendation; the rich quota shape proposed there is not load-bearing.
- [x] **D7 — Shared-backend + visibility model.** Specified in Design spec
      §"Shared backend" and §"Visibility model" below.

## Decisions (confirmed 2026-06-01)

- [x] **D1 — Per-device adapters.** `HarnessConfig.syncAdapterFactory:
  SyncStorageAdapter Function(int deviceId)`; `syncAdapter` retained as a
  convenience that forwards `(_) => instance`. Backward compatible.
- [x] **D2 — Simulator seam.** Fake `http.Client` (drives real
  `googleapis`/adapter). Provider simulators live in provider packages; not built
  here.
- [x] **D3 — `CloudProfile` location.** `CloudProfile` + decorators +
  `SharedCloudBackend` in `kmdb` test-support; provider packages supply concrete
  instances.
- [x] **D4 — Reconciliation under eventual consistency.** Visible-subset merge +
  quiescent-settle convergence assertion.
- [x] **D5 — Vault scope.** Vault out of scope.
- [x] **D6 — Quota boundary.** `CloudProfile.quota` is descriptive only; no
  kmdb-side `QuotaAwareAdapter`; harness `QuotaAwareAdapter` untouched.
- [x] **D7 — Shared-backend + visibility model.** Specified below.

## Design specification

### Shared backend (`SharedCloudBackend`)

`MemorySyncAdapter` holds **per-instance** `_files`/`_versions`
(`memory_sync_adapter.dart:46`), so per-device factories returning fresh
instances would not share state. Introduce a single canonical backing store:

- **`SharedCloudBackend`** (`packages/kmdb/test/support/cloud/`) — owns the
  canonical file map `Map<String, _StoredFile>` where `_StoredFile` carries
  `{bytes, etag (monotonic int), writeSeq (monotonic int), writerDeviceId}`.
  `writeSeq` is a global counter assigned at commit time and is the basis of the
  visibility model. The backend is **strongly consistent internally** (it is the
  source of truth); per-front-end weakening is layered on top by the decorator.
- **Front-ends** are thin `SyncStorageAdapter`s over one `SharedCloudBackend`:
  - **`SharedBackendAdapter`** — a direct, strongly-consistent view (used as the
    `StrongConsistency` baseline; equivalent in behaviour to today's shared
    `MemorySyncAdapter`).
  - **`CloudSemanticsAdapter`** (decorator, modelled on `PartitionableAdapter`)
    — wraps a `SharedBackendAdapter` + a `CloudProfile` and applies
    propagation delay, partial-visibility, out-of-order arrival, and optional
    non-atomic CAS. It must **forward/override `providesAtomicCas`** to equal
    `profile.atomicConditionalCreate` (mirrors `partitionable_adapter.dart:126`)
    so `ConsolidationCoordinator`'s gate engages under a non-atomic profile.
- **Mixed-mode (Step 4)** is two front-ends over the *same* `SharedCloudBackend`:
  a REST-style `CloudSemanticsAdapter` (the place the real adapter-over-simulator
  later plugs in) and an **FS-view** front-end. The FS view is a **second
  `SharedBackendAdapter`/`CloudSemanticsAdapter` configured with FS-like
  consistency** (the real `LocalDirectoryAdapter` is NOT used — it needs a real
  `dart:io` dir and would not share the in-memory backend). The test seeds a
  `SharedCloudBackend`, hands device 0 the REST front-end and device 1 the FS
  view, and asserts cross-front-end convergence.

### CloudProfile

```
CloudProfile {
  ConsistencyModel consistency;     // strong | eventual(maxPropagationDelay, jitter)
  bool atomicConditionalCreate;     // MUST equal the front-end's providesAtomicCas
  bool allowsDuplicateNames;        // Drive: true (descriptive; simulator-honoured)
  QuotaProfile? quota;              // DESCRIPTIVE ONLY (D6) — drives sim 429/503,
                                    // not a kmdb QuotaAwareAdapter
}
```

Ship two instances in this plan: `CloudProfile.strong()` (current behaviour) and
`CloudProfile.eventual(...)`. Provider-specific profiles (Drive) ship in their
own packages.

**CAS-atomicity rule (resolves review item 3):** there is exactly one source of
truth at runtime — the front-end's `providesAtomicCas`. `CloudProfile`'s
`atomicConditionalCreate` is the *declared* value the simulator/decorator is
built to honour; `CloudSemanticsAdapter` sets `providesAtomicCas =>
profile.atomicConditionalCreate`. Add a conformance assertion (reuse
`runSyncAdapterConformance(expectAtomicCas: profile.atomicConditionalCreate)`)
so the two can never drift.

### Quota boundary (D6)

No new `QuotaAwareAdapter`. `CloudProfile.quota` only parameterises simulated
rate-limit responses. `_validateQuota` (`test_manager.dart:167`) currently reads
`config.syncAdapter` once; under the factory it must sample **device 0's**
adapter: `final adapter = config.resolveAdapter(0);` (a helper that returns the
field if set, else `syncAdapterFactory(0)`), then the existing
`adapter is QuotaAwareAdapter` check is unchanged. Document that the quota
estimate uses a representative device when adapters are heterogeneous.

### Visibility model (D4 / D7)

The reconciliation oracle gains a per-device **visibility cursor** so a completed
pull merges only the subset of pushes that have propagated to *that* device's
front-end:

- **Data carried `Device`→agent:** today only `ActionResult` flows
  (`device.dart:99`). Add a field `visibleWriteSeqHigh` to `ActionResult`,
  populated on a completed sync from the front-end's current visible
  `writeSeq` high-water (the `CloudSemanticsAdapter` exposes
  `int visibleWriteSeq(int observerDeviceId)` computed from the backend's
  `writeSeq`s minus those still inside their propagation delay). For
  strongly-consistent front-ends this equals the backend's max `writeSeq`
  (preserving current behaviour exactly).
- **`globalExpectedState()` is unchanged.** Add
  `visibleExpectedStateFor(int deviceId, int seqHigh)` that runs the same LWW
  fold but only over `writeLog` entries whose originating push has
  `writeSeq <= seqHigh`. (The agent learns each write's `writeSeq` from the
  `ActionResult` of the *sync* that carried it; entries not yet pushed are
  excluded — a pull cannot see an un-pushed write.)
- **`_mergeGlobalIntoDevice` rewrite (`reconciliation_agent.dart:322`):** rename
  to `_mergeVisibleIntoDevice(int deviceId, int seqHigh)` and fold
  `visibleExpectedStateFor(deviceId, seqHigh)` instead of the full
  `globalExpectedState()`. `_recordSync` (line 311) passes
  `result.visibleWriteSeqHigh`. Under a strong profile, `seqHigh` is the global
  max so the merged set equals today's — **backward compatible** (Step 5
  backward-compat presets prove this).
- **Settle assertion (modelled on `_verifyVersionForks`):** add a
  `_settleAndVerifyConvergence()` pass that (1) drains all in-flight actions,
  (2) advances `SharedCloudBackend`'s propagation clock past the profile's
  `maxPropagationDelay` so every push becomes visible, (3) calls
  `device.syncForVerification()` on every device, then (4) asserts each device's
  expected state equals `globalExpectedState()`. Only after settle is global
  convergence required.
- **Fork detection is unchanged (confirms review item 6).** `_detectFork`
  (line 342) keys off write ordering, not propagation, so delayed visibility
  does not affect it. The implementer must NOT "fix" `_detectFork`.

## Implementation plan

> All new shared types (`SharedCloudBackend`, `SharedBackendAdapter`,
> `CloudSemanticsAdapter`, `CloudProfile`, `QuotaProfile`) live in
> `packages/kmdb/test/support/cloud/` (D3), exported for the harness to import
> the same way it already imports `MemorySyncAdapter`. Follow the Design
> specification above for every mechanic.

### Step 1 — Per-device adapters in the harness
- [ ] Add `syncAdapterFactory: SyncStorageAdapter Function(int deviceId)?` to
      `HarnessConfig` (`config.dart`); keep `syncAdapter` as the convenience
      field. Assert exactly one of the two is set in the constructor. Add
      `SyncStorageAdapter resolveAdapter(int deviceId)` returning the field (as
      `(_) => syncAdapter`) or `syncAdapterFactory(deviceId)`.
- [ ] In `TestManager._setup()` (`test_manager.dart:202`), construct each
      `Device` with `syncAdapter: config.resolveAdapter(i)` instead of
      `config.syncAdapter`. `Device` still wraps its adapter in
      `PartitionableAdapter` internally (`device.dart:61`) — unchanged.
- [ ] In `_validateQuota()` (`test_manager.dart:167`), replace
      `config.syncAdapter` with `config.resolveAdapter(0)` (representative
      device); the `is QuotaAwareAdapter` check is otherwise unchanged (D6).

### Step 2 — Shared backend, front-ends, `CloudProfile`
- [ ] Implement `SharedCloudBackend` (canonical file map with `etag` +
      monotonic global `writeSeq`; see Design spec §"Shared backend").
- [ ] Implement `SharedBackendAdapter` (strongly-consistent front-end) and
      `CloudSemanticsAdapter` decorator (modelled on `PartitionableAdapter`,
      `partitionable_adapter.dart`) applying propagation delay, partial
      visibility, out-of-order arrival, and optional non-atomic CAS. The
      decorator overrides `providesAtomicCas => profile.atomicConditionalCreate`.
- [ ] Define `CloudProfile` (+ `QuotaProfile`, descriptive only per D6) with
      `CloudProfile.strong()` and `CloudProfile.eventual(...)` constructors. Add
      `int visibleWriteSeq(int observerDeviceId)` to `CloudSemanticsAdapter`.
- [ ] Add a conformance assertion tying `providesAtomicCas` to
      `profile.atomicConditionalCreate` via
      `runSyncAdapterConformance(factory:, expectAtomicCas: profile.atomicConditionalCreate)`
      (reuse `packages/kmdb/test/support/sync_adapter_conformance.dart`).

### Step 3 — Reconciliation refinement (the visibility model)
- [ ] Add `visibleWriteSeqHigh` to `ActionResult`; `Device._sync`
      (`device.dart:252`) populates it on a completed sync from the front-end's
      `visibleWriteSeq(deviceIndex)` (strong front-ends return the backend max,
      preserving current behaviour).
- [ ] In `ReconciliationAgent`: add `visibleExpectedStateFor(deviceId, seqHigh)`
      (same LWW fold restricted to pushed writes with `writeSeq <= seqHigh`);
      rename `_mergeGlobalIntoDevice` → `_mergeVisibleIntoDevice(deviceId,
      seqHigh)` and call it from `_recordSync` (line 311) with
      `result.visibleWriteSeqHigh`. Leave `globalExpectedState()` and
      `_detectFork` (line 342) unchanged (see Design spec — do not "fix"
      `_detectFork`).
- [ ] Add `_settleAndVerifyConvergence()` to `TestManager` (modelled on
      `_verifyVersionForks`): drain in-flight → advance the backend propagation
      clock past `maxPropagationDelay` → `syncForVerification()` on all devices →
      assert each device equals `globalExpectedState()`.
- [ ] CAS expectation: when `profile.atomicConditionalCreate == false`, the
      `ConsolidationCoordinator` gate (`consolidation_coordinator.dart:268`)
      either skips consolidation or admits multiple consolidators — the test must
      assert **no data loss** either way (reuse
      `runSyncAdapterContentionTest(factory:, expectAtomicCas: false)`).

### Step 4 — Mixed-mode scenario
- [ ] Build one `SharedCloudBackend`; hand device 0 a REST-style
      `CloudSemanticsAdapter` front-end and device 1 an FS-view front-end (a
      second front-end with FS-like consistency — NOT the real
      `LocalDirectoryAdapter`; see Design spec §"Shared backend"). Assert
      cross-front-end convergence after settle.

### Step 5 — Tests
- [ ] `EventualConsistency` run converges after settle (no false failures from
      delayed visibility).
- [ ] Mixed-mode run (REST + FS view of one backend) converges.
- [ ] Contention: multi-device consolidation under a non-atomic `CloudProfile`
      shows single-consolidator (if gated per H5) or no data loss.
- [ ] **H4-FU multi-device tombstone non-resurrection (unblocks RC-6).** This is
      the in-harness automation of the existing release-checklist entry **RC-6**
      (`docs/spec/28_release_checklist.md:145`), which already names this plan as
      its blocker. Device A writes a key, deletes it, runs `_compactAll` with
      `hlc < horizon` so the tombstone is GC'd; peer B (carrying an older copy in
      its synced SSTables) joins and converges with A. Assert the key remains
      deleted globally. The in-process invariant is already covered in CI by
      `compaction_test.dart` / `lsm_engine_test.dart` (per
      `plan_tombstone_gc.md`, now in `docs/plans/completed/`); this is the
      cross-device companion. Do **not** add a new RC id for this — instead, in
      Step 6, update RC-6's "not yet landed" caveat to point at this coverage.
- [ ] Backward-compat: existing single-adapter (`config.syncAdapter`) presets
      still pass unchanged.

### Step 6 — Documentation
- [ ] Update `docs/spec/27_test_harness.md`: per-device `syncAdapterFactory`
      (add a row to the config table at line 146, keeping the `syncAdapter`
      row), `CloudProfile` + `SharedCloudBackend`, mixed-mode definition
      (one-remote-two-views), simulated-vs-real policy, and the statement that
      every cloud provider package ships a behavioural simulator + `CloudProfile`
      and reserves real-service runs for pre-release.
- [ ] In `docs/spec/28_release_checklist.md`: (a) update **RC-6**'s "Why not
      automated" note to reference the new cross-device harness scenario now that
      the per-device adapter harness has landed; (b) register a **new entry with
      the next free id (RC-9)** — "Harness real-isolate cloud-soak via behavioural
      simulator" — noting each provider's real-service soak (e.g. RC-2) runs
      through this harness. (RC-5 is already taken — preset 5 real-isolate soak.)

### Step 7 — Verify
- [ ] `cd packages/kmdb_harness && dart test` and `cd packages/kmdb && dart test`
      pass; `make analyze` clean. Re-run a representative existing preset to
      confirm backward compatibility.

## Summary

{To be completed during implementation.}
