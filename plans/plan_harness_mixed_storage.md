# Harness mixed-storage mode + behavioural cloud-API simulation

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Sonnet — additive test infrastructure; review the
eventual-consistency reconciliation refinement.

**Sequencing**: Depends on `plan_sync_cas_atomicity.md` (H5) — it consumes the
CAS capability and the adapter conformance suite defined there. It is a
**prerequisite for `plan_google_drive_sync.md`**, which must ship a behavioural
Drive simulator conforming to the framework this plan establishes.

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

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — Per-device adapters.** Recommended: change `HarnessConfig` to accept
  `SyncStorageAdapter Function(int deviceId)` (a single shared adapter becomes a
  factory returning the same instance — backward compatible).
- [ ] **D2 — Simulator seam.** Recommended: fake `http.Client` (drives the real
  `googleapis`/adapter code) rather than a hand-rolled adapter stub, for maximum
  fidelity. Provider simulators live in provider packages.
- [ ] **D3 — `CloudProfile` location.** Recommended: define `CloudProfile` +
  decorators in `kmdb` (so all adapters/harness share them); provider packages
  supply concrete instances.
- [ ] **D4 — Reconciliation under eventual consistency.** Recommended: refine the
  oracle so a completed pull may observe a subset of prior pushes; convergence is
  asserted only after a quiescent "settle" period (drain + propagation delay).
- [ ] **D5 — Vault scope.** Recommended: keep vault **out of scope** (consistent
  with §27). Drive stub-sync/hydration testing is a later, separate extension.

## Implementation plan

### Step 1 — Per-device adapters in the harness
- [ ] Change `HarnessConfig.syncAdapter` to a per-device factory; update
      `TestManager` to build each `Device` with its own adapter instance bound to
      one shared backend.
- [ ] Keep a single-adapter convenience constructor for existing scenarios.

### Step 2 — Cloud-semantics decorators + `CloudProfile`
- [ ] Define `CloudProfile` and a `CloudSemanticsAdapter` decorator (modelled on
      `PartitionableAdapter`) injecting propagation delay, partial-visibility,
      out-of-order arrival, and optional non-atomic CAS, driven by a profile.
- [ ] Provide a `StrongConsistency` profile (current behaviour) and an
      `EventualConsistency` profile.

### Step 3 — Reconciliation refinement
- [ ] Update `ReconciliationAgent` so a completed pull may see a subset of prior
      pushes; assert global convergence only after a settle window.
- [ ] Add `CloudProfile`-aware expectations: when `atomicConditionalCreate` is
      false, expect possible multiple consolidators (or, per H5, consolidation
      skipped) and assert no data loss either way.

### Step 4 — Mixed-mode scenario
- [ ] Support one shared simulated backend accessed by heterogeneous per-device
      front-ends (REST-adapter-over-simulator and FS-view adapter over the same
      state) and assert cross-access-method convergence.

### Step 5 — Tests
- [ ] Harness run under `EventualConsistency` converges after settle (no false
      failures from delayed visibility).
- [ ] Mixed-mode run (REST + FS view of one backend) converges.
- [ ] Contention: multi-device consolidation under a non-atomic `CloudProfile`
      shows either single-consolidator (if gated per H5) or no data loss.
- [ ] Backward-compat: existing single-adapter presets still pass.

### Step 6 — Documentation
- [ ] Update `docs/spec/27_test_harness.md`: per-device adapters, `CloudProfile`,
      mixed-mode definition, simulated-vs-real policy, and the explicit statement
      that every cloud provider package must ship a behavioural simulator +
      `CloudProfile` and reserve real-service runs for pre-release.
- [ ] Register **RC-5 (harness preset 5 real-isolate soak)** in the release
      checklist `docs/spec/28_release_checklist.md`, and note there that each
      provider's real-service soak (e.g. RC-2) runs through this harness.

### Step 7 — Verify
- [ ] `dart test packages/kmdb_harness` and `packages/kmdb` pass; `make analyze`
      clean.

## Summary

{To be completed during implementation.}
