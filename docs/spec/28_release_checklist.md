---
title: "§28 Release Checklist"
nav_order: 28
---

# §28 Release Checklist

## Purpose and scope

This is the catalogue of **manual / out-of-band tests** a human must run before a
release — the checks that the automated suite (`make test`) deliberately cannot
cover. Examples: tests against a real cloud service (credentials, quota,
non-determinism), durability behaviour that depends on real OS/hardware
(`fsync`, power loss), and cross-process or multi-host concurrency that a
single-process test harness cannot reproduce.

It is a **living document**. It starts small and is grown by plan work: any plan
that introduces a test which cannot run in CI **must add an entry here** as part
of its "Spec and docs" phase (see `plans/README.md`). The automated suite remains
the first line of defence; this checklist covers only what it structurally
cannot.

> If a check listed here *can* be automated later (e.g. a behaviour is captured by
> a behavioural simulator), move it into the automated suite and mark the entry
> **Superseded** with a pointer to the test — do not delete the history.

## How to use it

For each release:

1. Run every entry whose **Applies when** condition is true for the changes in
   the release.
2. Record the outcome in the **Release log** at the bottom (version, date,
   tester, pass/fail per entry, notes).
3. A release is not cut until every applicable entry passes or has a documented,
   accepted waiver.

## Entry template

```
### RC-N — <short title>
- **Area:** <cloud sync | durability | concurrency | platform | …>
- **Validates:** <the property under test>
- **Why not automated:** <why CI/the sandbox cannot cover it>
- **Applies when:** <which changes trigger this check>
- **Prerequisites:** <credentials, hardware, OS, accounts, env vars>
- **Steps:** <numbered, reproducible steps>
- **Expected result:** <pass criteria>
- **Related:** <plan / spec / review-finding references>
```

---

## Checks

### RC-1 — Google Drive API behaviour probe
- **Area:** cloud sync
- **Validates:** the *actual* semantics real Google Drive exposes for
  conditional create/update, duplicate-name creation, read-after-write
  visibility, and rate limiting — the observations that calibrate the behavioural
  Drive simulator and the lease design.
- **Why not automated:** requires real Drive credentials, consumes quota, and is
  non-deterministic; cannot run in CI or the build sandbox.
- **Applies when:** the Google Drive adapter is introduced or its
  request/lease logic changes.
- **Prerequisites:** a test Google account; OAuth client; `drive.file` scope;
  `GOOGLE_DRIVE_TEST_CREDENTIALS` configured.
- **Steps:** run the Phase 4a probe harness (concurrent same-name create;
  concurrent `If-Match` update; candidate ID-addressed lease under contention;
  visibility timing; 429/503 shapes).
- **Expected result:** observations recorded as a results table in
  `plan_google_drive_sync.md`; the Drive `CloudProfile` and lease design are
  derived from them and encoded into the simulator.
- **Related:** `plans/plan_google_drive_sync.md` (Phase 4a),
  `plans/plan_sync_cas_atomicity.md` (H5), `code-review-2026-05-22.md` (H5).

### RC-2 — Google Drive real-service sync soak
- **Area:** cloud sync
- **Validates:** a full multi-device `SyncEngine` push/pull cycle plus lease
  contention converges correctly against real Drive, confirming the simulator's
  fidelity.
- **Why not automated:** real credentials, quota, network non-determinism, slow.
- **Applies when:** before any release that ships or changes the Drive adapter.
- **Prerequisites:** as RC-1, plus a shared Drive folder.
- **Steps:** run the credential-gated integration test
  (`GOOGLE_DRIVE_TEST_CREDENTIALS`); optionally a longer `kmdb_harness` soak with
  the real adapter at a quota-safe velocity.
- **Expected result:** all devices converge to the global LWW state; no data
  loss; consolidation behaves per the declared `CloudProfile` (single
  consolidator if atomic, else gated/skipped).
- **Related:** `plans/plan_google_drive_sync.md` (Phase 4),
  `plans/plan_harness_mixed_storage.md`.

### RC-3 — Cross-process database lock exclusivity
- **Area:** concurrency
- **Validates:** the `LOCK` file genuinely prevents two **separate OS processes**
  from opening the same database directory concurrently.
- **Why not automated:** the test suite uses the in-memory adapter (single
  process); real `flock`/`LockFileEx` exclusion is only observable across real
  processes.
- **Applies when:** changes to `acquireLock`/`releaseLock` or the native storage
  adapter.
- **Prerequisites:** native build on each target OS (macOS, Linux, Windows).
- **Steps:** open a DB dir in process A; attempt to open the same dir in process
  B; close A; reopen in B.
- **Expected result:** B throws `LockException` while A holds the lock; B
  succeeds after A closes.
- **Related:** `packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart`.

### RC-4 — Linux directory-fsync durability
- **Area:** durability
- **Validates:** `syncDir` durably persists new directory entries (new SSTables,
  WAL files, the `CURRENT` rename) on Linux, so a power loss does not lose files
  the manifest already references.
- **Why not automated:** `syncDir` is a no-op on macOS/Windows/memory; its effect
  is only meaningful on real Linux, and true verification needs power-loss-class
  fault injection.
- **Applies when:** changes to the durability ordering (C2/H1) or the native
  adapter; before a release targeting Linux.
- **Prerequisites:** a Linux host (ideally with a way to simulate unclean
  shutdown, e.g. a VM that can be hard-killed).
- **Steps:** drive writes that trigger flush/compaction; hard-kill the process;
  reopen and verify all acknowledged data and referenced SSTables are present.
- **Expected result:** no missing referenced SSTables; no silent data loss.
- **Related:** `plans/plan_manifest_fsync_ordering.md` (C2/H1),
  `code-review-2026-05-22.md` (C2, H1).

### RC-5 — Harness preset 5 (real-isolate) stress soak
- **Area:** concurrency
- **Validates:** sync convergence under genuine parallel isolate execution at
  high velocity (the only mode that exercises real concurrency rather than
  single-isolate async interleaving).
- **Why not automated (as a gate):** preset 5 is non-deterministic (isolate
  scheduling); flakiness detection does not apply, so it is a soak/observational
  run, not a pass/fail CI gate.
- **Applies when:** changes to the sync protocol, consolidation, or the engine's
  concurrency assumptions.
- **Prerequisites:** none beyond a native build.
- **Steps:** run `kmdb_harness` preset 5 for an extended duration across several
  seeds.
- **Expected result:** all devices converge to the global LWW state; no crashes,
  deadlocks, or data loss; any fork is resolved to the correct LWW winner.
- **Related:** `docs/spec/27_test_harness.md`.

### RC-6 — Multi-device tombstone non-resurrection
- **Area:** sync + compaction (H4 PR2)
- **Validates:** that the sync-horizon-gated tombstone GC in `_compactAll` does
  not allow a deleted key to resurrect across devices. Device A writes a key,
  deletes it, and runs `_compactAll` with a horizon below the tombstone HLC
  so the tombstone is dropped. Device B (carrying an older copy of the key in
  its synced SSTables) then converges with A. The key must remain deleted
  globally.
- **Why not automated (as a gate):** the cross-device assertion requires the
  per-device adapter harness from `docs/plans/plan_harness_mixed_storage.md`,
  which is not yet landed. The in-process invariant — that PR2 retains
  tombstones whose HLC is at or above the horizon — *is* covered in CI by
  the `compaction_test.dart` and `lsm_engine_test.dart` PR2 tests; RC-6
  is the cross-device companion.
- **Applies when:** changes to the tombstone-GC predicate, the horizon
  computation, the HWM-min helper, or `SyncEngine`'s horizon-provider
  registration.
- **Prerequisites:** `plan_harness_mixed_storage.md` landed; multi-device
  harness scenario from that plan's Step 5 wired up.
- **Steps:** run the harness scenario that drives a fresh delete on device A,
  forces `_compactAll` with horizon below the tombstone HLC, then drives
  device B's sync. Assert `get` for the deleted key returns null on every
  device after settle.
- **Expected result:** no device observes the resurrected value; all devices
  agree the key is absent.
- **Related:** `docs/spec/06_storage_engine.md`, `docs/spec/12_sync.md`,
  `docs/plans/completed/plan_tombstone_gc.md`,
  `docs/plans/plan_harness_mixed_storage.md`.

---

## Release log

| Version | Date | Tester | Checks run | Result | Notes |
| ------- | ---- | ------ | ---------- | ------ | ----- |
| _e.g. 0.x.0_ | _YYYY-MM-DD_ | _name_ | _RC-1…RC-5_ | _pass/fail_ | _link to evidence_ |
