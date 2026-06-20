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
- **Why not automated (as a gate):** the in-harness scenario covers the
  cross-device convergence invariant (tombstone non-resurrection) via
  `packages/kmdb_harness/test/cloud_semantics_test.dart`
  ("Tombstone non-resurrection — deleted key stays absent after peer syncs").
  The compaction-side in-process invariant is covered by `compaction_test.dart`
  and `lsm_engine_test.dart`. The remaining gap is exercising compaction with a
  *real* elapsed HLC horizon (not a test clock) across separate processes —
  that requires a real-OS multi-process run.
- **Applies when:** changes to the tombstone-GC predicate, the horizon
  computation, the HWM-min helper, or `SyncEngine`'s horizon-provider
  registration.
- **Prerequisites:** native build; two separate database directories.
- **Steps:** run the harness scenario that drives a fresh delete on device A,
  forces `_compactAll` with horizon below the tombstone HLC, then drives
  device B's sync. Assert `get` for the deleted key returns null on every
  device after settle.
- **Expected result:** no device observes the resurrected value; all devices
  agree the key is absent.
- **Related:** `docs/spec/06_storage_engine.md`, `docs/spec/12_sync.md`,
  `docs/plans/completed/plan_tombstone_gc.md`,
  `docs/plans/completed/plan_harness_mixed_storage.md` (automated coverage),
  `packages/kmdb_harness/test/cloud_semantics_test.dart`.

### RC-7 — Returning stale device does not resurrect deleted data
- **Area:** sync re-admission (H4-FU2)
- **Validates:** that a device evicted from the sync horizon performs a
  full re-sync on return and does not deliver pre-eviction SSTables to its
  peers. Device A writes a key, deletes it, advances its HWM past the
  tombstone, and a separate flush-compaction drops the tombstone while
  device B is excluded from the horizon (B's HWM `lastUpdated` exceeds
  `staleDeviceEvictionAfter`). Device B then returns. With the
  re-admission check enabled, B detects both `localCurrentHlc <
  min(livePeers.currentHlc)` and `localHwm.lastUpdated < now -
  staleDeviceEvictionAfter`, discards its local SSTables (via
  `KvStore.dropAllSstables`), and re-downloads the current consolidated
  set; the deleted key stays absent on every device.
- **Why not automated (as a gate):** the cross-device verification (B
  pushing a *real* pre-eviction SSTable and being rejected) is the same
  per-device adapter shape that gates RC-6. The in-process invariant —
  that `_checkAndHandleEviction` triggers `_fullResync` on the two-
  condition rule and that `_fullResync` keeps the manifest consistent
  during the SSTable drop — *is* covered in CI by the
  `sync_engine_test.dart` H4-FU2 tests, including the negative-control
  test that proves resurrection occurs without the guard.
- **Applies when:** changes to `SyncEngine._checkAndHandleEviction`,
  `SyncEngine._fullResync`, `KvStore.dropAllSstables`, the
  `KvStoreConfig.staleDeviceEvictionAfter` semantics, or the eviction
  filter in `HighwaterMark.minCurrentHlcAcrossDevices`.
- **Prerequisites:** `plan_harness_mixed_storage.md` landed; multi-device
  harness scenario with adjustable HWM `lastUpdated`.
- **Steps:** drive A through delete + two advance-pushes so its local
  store has GC'd the tombstone. Configure B's `staleDeviceEvictionAfter`
  short enough that B's injected stale HWM evicts B from A's horizon, but
  use a separate eviction setting on B to control re-admission detection.
  Have B return and call `push()`. Assert that B performs a full re-sync
  (local SSTables replaced) and that `get` for the deleted key returns
  null on every device.
- **Expected result:** the returning device does not resurrect the
  deleted key; A's local state stays consistent with the cloud.
- **Related:** `docs/spec/06_storage_engine.md`, `docs/spec/12_sync.md`,
  `docs/plans/completed/plan_tombstone_gc_stale_eviction.md`,
  `docs/plans/plan_harness_mixed_storage.md`.

### RC-8 — Cross-device `$ver:` purge / ingest-floor interaction

- **Area:** document versioning (§26), tombstone GC ingest floor (H4-FU3)
- **Validates:** that purging `$ver:` history on one device cannot cause a
  resurrection on another device, and that an old peer SSTable carrying
  both below-floor main-namespace entries and old `$ver:` history is rejected
  wholesale by the ingest-floor guard without causing incorrect trim or
  resurrection.
- **Why not automated:** requires two independent device databases (different
  paths/adapters), real HLC progression across sessions to age entries past the
  retention window, and coordination with the H4-FU3 tombstone floor. An
  in-process harness cannot reproduce the timing of compaction, clock advance,
  and SSTable ingest from a peer.
- **Applies when:** changes to `VersionRetentionPolicy.filterGroup`,
  `KvStoreImpl.ingestSstable`, `LsmEngine._computeTombstoneHorizon`,
  or `VersionConfig` defaults.
- **Steps:**
  1. Device A writes a doc, then deletes it. Device B pulls the SSTable.
  2. Advance both devices' clocks by more than `retentionDays` (default 90 days
     — use a test `VersionConfig` with a very short `retentionDays` value, e.g.
     0, and advance `nowMs` accordingly).
  3. Run compaction on device A; verify `$ver:` chain is fully purged (zero
     entries). Verify the main-namespace tombstone is also GC'd (via H4).
  4. Device B, which still has the old SSTables (below the current floor), runs
     `ingestSstable`. Verify that device B's ingest is rejected with
     `StaleSstableIngestException` (or the SSTable is silently skipped), and
     that neither the deleted document nor any `$ver:` entries resurface on
     device A after the next sync.
  5. Verify the main-namespace tombstone wins LWW against any re-ingested put.
- **Expected result:** no resurrection on any device; old `$ver:` history for
  the deleted document is also not resurrected; the floor-rejection correctly
  covers the mixed SSTable case.
- **Related:** `docs/spec/26_document_versioning.md` (§ RQ3 analysis),
  `docs/spec/12_sync.md`, `docs/plans/plan_document_versioning.md`.

### RC-9 — Real-service cloud-soak via the harness framework
- **Area:** cloud sync
- **Validates:** that a full multi-device `SyncEngine` push/pull cycle converges
  correctly against a *real* cloud service (e.g. Google Drive, Dropbox), using
  the same harness scenarios that run in CI against the behavioural simulator.
  This confirms the simulator's fidelity and catches provider behaviour that the
  simulator does not model exactly (rate limits, real propagation timing, service
  outages).
- **Why not automated:** requires real credentials and service access, consumes
  quota, is non-deterministic, and is slow. Runs in-sandbox are unsuitable.
- **Applies when:** before any release that ships or changes a cloud adapter;
  after any change to `SyncEngine` push/pull logic or `ConsolidationCoordinator`.
- **Prerequisites:** provider credentials configured (e.g.
  `GOOGLE_DRIVE_TEST_CREDENTIALS`); a shared folder/bucket; the provider's
  `QuotaAwareAdapter` configured with a safe threshold.
- **Steps:**
  1. Configure `HarnessConfig.syncAdapterFactory` to return a real provider
     adapter (e.g. `GoogleDriveAdapter`) for each device.
  2. Run the harness at preset 1 or 2 velocity for a short duration (e.g. 2
     minutes).
  3. Assert `report.passed == true` and no fork records indicate data loss.
- **Expected result:** all devices converge to the global LWW state; no data
  loss; consolidation behaves per the declared `CloudProfile` (single
  consolidator if atomic, gated/skipped if not).
- **Related:** `docs/spec/27_test_harness.md` (§ Simulated vs real service),
  `docs/plans/completed/plan_harness_mixed_storage.md`,
  RC-2 (Drive-specific soak).

### RC-10 — Web (OPFS SAHPool) crash/durability verification

- **Area:** durability / platform (web)
- **Validates:** that data acknowledged by `StorageAdapterSahPool` (writes
  flushed via the per-op handle lifecycle) survives a browser tab-kill and a
  mid-write page reload. Specifically:
  1. A `writeFile` or `appendFile` that completes (Future resolved) must be
     present on the next database open, even if the tab is killed immediately
     after.
  2. A `renameFile` that completes must leave the destination intact and the
     source absent after a crash between the flush-and-close of the destination
     and the deletion of the source.
- **Why not automated:** `dart test -p chrome` cannot simulate a hard tab-kill
  or a mid-write browser crash — the test runner requires a cooperative process
  exit. `Worker.terminate()` is not equivalent (it does not simulate a power-off
  or OS-kill scenario where the handle's `flush()` output may still be in a
  browser I/O buffer).
- **Applies when:** any change to `StorageAdapterSahPool`, `sahpool_worker.js`,
  the per-op handle lifecycle, or the rename durability ordering; before a
  release targeting web platforms.
- **Prerequisites:** a Chromium-based browser; the KMDB web demo or a minimal
  test page that opens a `StorageAdapterSahPool`, writes some records, and
  re-opens to verify on reload.
- **Steps:**
  1. Open the KMDB web demo (or a test harness) in a fresh browser tab.
  2. Write several documents so that at least one SSTable is flushed.
  3. Immediately kill the tab (close it, or use the browser task manager to
     hard-kill the renderer process).
  4. Re-open the same origin in a new tab and reopen the database.
  5. Verify that all committed documents are present and no corruption is
     detected.
  6. Repeat with a tab reload (`Cmd-R` / `F5`) triggered mid-write.
- **Expected result:** all documents acknowledged before the kill are present
  after recovery; no `StorageException` or data loss on re-open.
- **Related:** `docs/plans/completed/plan_sahpool_opfs.md` (durability
  contract), spec §19 (per-op handle lifecycle), RC-4 (Linux power-loss analog).

### RC-11 — Web (OPFS SAHPool) cross-tab lock exclusion

- **Area:** concurrency / platform (web)
- **Validates:** that two browser tabs cannot open the same OPFS database path
  concurrently — the second tab receives `LockException` with the message
  "database is already open in another tab."
- **Why not automated:** `dart test -p chrome` runs a single browser context.
  Two `StorageAdapterSahPool` instances in the same tab share the same Worker
  origin context and can both acquire the same SAH lock (Chrome's exclusion is
  per-browsing-context, not per-tab, for Workers spawned in the same tab).
  Cross-tab exclusion requires two independent browser tabs.
- **Applies when:** any change to `acquireLock`/`releaseLock` or the Worker's
  `opAcquireLock` function; before a release targeting web platforms.
- **Prerequisites:** a Chromium-based browser; two tabs open to the same origin.
- **Steps:**
  1. Open the KMDB web demo in tab A; open the database (acquires lock).
  2. While tab A has the database open, open the same origin in tab B and
     attempt to open the same database path.
  3. Verify that tab B's `acquireLock` raises `LockException`.
  4. Close tab A (adapter `close()` releases the lock).
  5. Attempt to open the database in tab B again.
  6. Verify that tab B's `acquireLock` now succeeds.
- **Expected result:** step 3 produces `LockException`; step 6 succeeds.
- **Related:** `docs/plans/completed/plan_sahpool_opfs.md` (cross-tab locking),
  spec §19 (cross-tab exclusion), RC-3 (native cross-process lock analog).

---

### RC-12 — iCloud (CloudKit) empirical behaviour probe

**Summary:** Re-verify the Phase 4a empirical probe findings whenever iOS or
macOS ships a major version that may change CloudKit's consistency or
atomicity behaviour.  The probe confirms the values in `kICloudProfile` and
the `ICloudAdapter.providesAtomicCas` setting.

- **What to verify:**
  1. Zone-level create-if-absent atomicity: two devices simultaneously create
     a `CKRecord` with the same deterministic record ID in the same custom
     zone. Confirm exactly one succeeds and the other receives
     `CKError.serverRecordChanged`.
  2. Conditional update atomicity (`savePolicy: .ifServerRecordUnchanged`):
     concurrent updates with the same `recordChangeTag`. Confirm exactly one
     wins.
  3. `CKQuery` BEGINSWITH consistency delay: time-to-visibility of a new
     record to a second device.
  4. `CKAsset` upload/download: verify large SSTables (≥10 MB) succeed.
  5. Rate-limit error shape: `CKError.requestRateLimited` and
     `CKErrorRetryAfterKey` availability.
- **Why not automated:** requires a real CloudKit container with an active
  Apple developer account; cannot be run in CI without Apple infrastructure.
- **Applies when:** before any release that targets iOS or macOS; after any
  iOS/macOS major version bump; after updating `kICloudProfile` values or
  `ICloudAdapter.providesAtomicCas`.
- **Prerequisites:** Apple developer account with a CloudKit-enabled container
  (`iCloud.au.com.bettongia.kmdb` or a dedicated test container); two physical
  iOS or macOS devices (or one device + simulator) on the same iCloud account.
- **Steps:** Run the probe app in `packages/kmdb_icloud/example/` on two
  devices; exercise each of the five verification points above and record the
  observed CloudKit behaviour.  Update `kICloudProfile` and
  `ICloudAdapter.providesAtomicCas` if the results differ from the current
  values.
- **Expected result:** create-if-absent is atomic (single winner); conditional
  update is atomic; BEGINSWITH queries are consistent; large assets upload
  without orphan residue; rate-limit errors include `retryAfterSeconds`.
- **Related:** `docs/plans/plan_icloud_sync.md` (Phase 4a probe description),
  RC-2 (Drive real-service soak), RC-13 (iCloud real-service soak).

---

### RC-13 — iCloud (CloudKit) real-service sync soak

**Summary:** Full `SyncEngine` push/pull convergence against a real CloudKit
container on two physical devices (or one device + simulator), including the
contention test that exercises the lease protocol.

- **What to verify:**
  1. Two devices write documents and sync; after 2–3 sync cycles both devices
     have identical data.
  2. The lease contention test: two devices simultaneously attempt to acquire
     the consolidation lease.  Confirm the outcome is consistent with
     `ICloudAdapter.providesAtomicCas` (if `false`, consolidation is skipped
     on both; if `true`, exactly one wins and the lease is acquired safely).
  3. No data loss across network interruptions (disable WiFi mid-sync, re-enable,
     verify convergence).
- **Why not automated:** requires a real CloudKit container and physical devices;
  network interruption simulation is not reproducible in CI.
- **Applies when:** before any public release of `kmdb_icloud`; after any
  change to the `ICloudAdapter` CAS or zone logic; after Phase 4a values are
  finalised.
- **Prerequisites:** Apple developer account; CloudKit container; two devices
  on the same iCloud account.
- **Steps:** Use the `packages/kmdb_icloud/example/` app as the test vehicle.
  Run a full push/pull soak for ≥10 minutes with 2 devices, then run the
  contention scenario.
- **Expected result:** full convergence; no data loss; lease behaviour
  consistent with `providesAtomicCas`.
- **Related:** RC-12 (iCloud behaviour probe), RC-2 (Drive soak), RC-9
  (harness-based cloud soak).

---

### RC-14 — Model download SHA-256 verification and atomic rename

- **Area:** embedding model download (`betto_inferencing`)
- **Validates:** that `ModelDownloader.ensure()` correctly:
  1. Downloads the ONNX and vocabulary files to a `.part` temporary path.
  2. Verifies each file's SHA-256 against `ModelSpec.onnxSha256` /
     `ModelSpec.vocabSha256`.
  3. Atomically renames `.part` → final name only after verification passes.
  4. Refuses to use a corrupt or tampered cached file (re-downloads on
     checksum mismatch).
  5. Handles a crash mid-download (stale `.part` file) correctly on next open
     (re-downloads without corrupting the cache directory).
- **Why not automated:** requires real network access to the model CDN; the
  file sizes are hundreds of MB; the crash-recovery test requires OS-level
  process termination; the SHA-256 mismatch test requires network-level
  interception or file mutation, which CI cannot reliably reproduce.
- **Applies when:** `ModelDownloader` is introduced or its download/verify/rename
  logic changes; before any release that ships download-on-demand model support;
  when `ModelSpec` checksums are updated.
- **Prerequisites:** network access to `huggingface.co` (or the configured CDN);
  an empty or warm `~/.kmdb_cache`; a way to mutate a cached file or inject a
  bad checksum.
- **Steps:**
  1. Fresh cache: call `OnnxEmbeddingModel.load(cacheDir: dir)` with an empty
     `dir`; verify both files are downloaded, checksums verified, and the model
     loads correctly.
  2. Warm cache: call again with the same `dir`; verify no network requests are
     made (add a logging proxy if needed) and the model loads from the cache.
  3. Corrupt cache: mutate one byte of the cached ONNX file; call again; verify
     the file is re-downloaded and the model loads correctly.
  4. Mid-download crash: simulate a crash by leaving a `.part` file in the cache
     directory; call again; verify the partial file is replaced and the model
     loads correctly.
- **Expected result:** all four scenarios complete without errors; no corrupt
  data is used; the cache is left in a consistent state after each scenario.
- **Related:** `docs/plans/plan_configurable_embedding_model.md` (Phase 3),
  `betto_inferencing/lib/src/model_downloader.dart` (standalone repo),
  `betto_inferencing/lib/src/model_spec.dart` (standalone repo).

---

### RC-15 — `betto_onnxrt` ORT binary download, session load, and identity-model inference

- **Area:** native-assets hook / ONNX Runtime (`betto_onnxrt`)
- **Validates:**
  1. `hook/build.dart` downloads the ORT binary for the target platform from
     GitHub Releases, verifies its SHA-256 against `_sha256Manifest` in the
     hook, and stages it as a `CodeAsset` without errors.
  2. `OnnxRuntime.load()` opens the staged library and returns a non-null
     runtime instance with a valid `OrtApi` vtable pointer.
  3. `OnnxSession.create()` loads `test/fixtures/identity_float32.onnx` (a
     minimal float32[1,4] → float32[1,4] identity graph) without error.
  4. `session.run()` with `{'input': OnnxTensor.fromFloat32([1,4], [1,2,3,4])}`
     returns one output tensor with shape `[1,4]` and values `[1,2,3,4]`.
  5. No `.part` temp files remain in `.dart_tool/betto_onnxrt/` after a
     successful download (atomic-rename discipline holds).
  6. Re-running `dart test` with a warm cache skips the download (short-circuit
     check passes).
- **Why not automated:** `OnnxRuntime.load()` calls `DynamicLibrary.open` with
  a platform-specific short name (`libonnxruntime.dylib`, `libonnxruntime.so`,
  `onnxruntime.dll`). Under plain `dart test` JIT mode the Dart SDK does not
  inject the native-assets directory onto the OS library-search path for
  filename-based opens, so all OnnxSession tests in
  `test/onnx_session_test.dart` are automatically skipped in CI. A full
  `dart build` or `flutter build` pipeline is required to place the library on
  the search path. The `test/hook_smoke_test.dart` and
  `test/model_downloader_test.dart` suites run fully in CI.
- **Applies when:** `betto_onnxrt` is introduced; `VERSION_ONNX` is bumped;
  `hook/build.dart` download/extract/SHA logic changes; `runtime.dart`
  `_openLibrary()` changes; before any release of `betto_onnxrt` or
  `betto_inferencing` that depends on it.
- **Prerequisites:**
  - macOS, Linux, or Windows native build environment.
  - Network access to `github.com/microsoft/onnxruntime/releases`.
  - Real SHA-256 checksums filled in `_sha256Manifest` in `hook/build.dart`
    (currently placeholder zeros for v1.22.0 — replace before release; see
    the TODO comment in that file).
- **Steps:**
  1. From `betto_onnxrt/` root, run `dart test` to confirm the non-FFI tests
     pass and the OnnxSession tests are correctly skipped.
  2. Fill in `_sha256Manifest` checksums for the target platform artifact (see
     the TODO in `hook/build.dart`; obtain with
     `curl -fsSL <url> | sha256sum`).
  3. Run `dart build cli --output build/` (requires a minimal `bin/` entry
     point, or use a scratch Flutter app that declares `betto_onnxrt` as a
     dependency). Verify the build completes without hook errors and the
     library is staged under `.dart_tool/betto_onnxrt/{version}/`.
  4. Set `DYLD_LIBRARY_PATH` (macOS) or `LD_LIBRARY_PATH` (Linux) to the
     staged library directory and run `dart test test/onnx_session_test.dart`.
     Verify all 6 OnnxSession tests pass (no skips).
  5. Confirm no `.part` files remain in `.dart_tool/betto_onnxrt/`.
  6. Run again to confirm the short-circuit (no re-download).
- **Expected result:** All OnnxSession tests pass; identity model outputs match
  inputs; hook cache is clean; second run completes without a network request.
- **Related:** `docs/plans/plan_betto_onnxrt_extraction.md` (Phase 4),
  `betto_onnxrt/hook/build.dart`, `betto_onnxrt/test/onnx_session_test.dart`,
  `betto_onnxrt/test/hook_smoke_test.dart`.

---

### RC-16 — Encryption: Argon2id timing and re-derive-per-session on web

- **Area:** encryption / platform (web)
- **Validates:**
  1. Argon2id key derivation completes in a reasonable time on a web browser
     (target: ≤ 5 s on a mid-range device) using the default parameters
     (m = 64 MiB, t = 3, p = 1).
  2. Re-deriving the KEK on every `KmdbDatabase.open()` call (because
     `InMemoryDekCache` is session-scoped and does not persist across page loads)
     is acceptable UX — or a loading indicator is shown.
  3. The first encrypted write after `open()` succeeds (Argon2id is fully
     initialised before `open()` returns).
- **Why not automated:** `dart test -p chrome` runs in a sandboxed Worker context
  with memory limits that may not reflect real-device Argon2id performance.
  Timing is browser- and device-dependent; pass/fail thresholds are
  human-judged.
- **Applies when:** before any release that ships database encryption on a web
  target; after changes to Argon2id parameters or the WASM compression init path.
- **Prerequisites:** a Chromium-based browser; the KMDB web demo or a test page
  that calls `KmdbDatabase.open()` with an `EncryptionConfig`.
- **Steps:**
  1. Open the KMDB web demo in a fresh browser tab on a mid-range device.
  2. Provision a new encrypted database (`EncryptionConfig.createResult`).
     Record the wall-clock time from call to `open()` returning.
  3. Close the page and reopen — measure the time to unlock (Argon2id
     re-derivation from passphrase).
  4. Write and read a document; verify the round-trip is correct.
- **Expected result:** provisioning and unlock each complete in ≤ 5 s; the
  document round-trip is correct; no JavaScript exceptions in the console.
- **Related:** `docs/spec/31_encryption.md` (Platform Notes),
  `docs/plans/plan_encryption.md`.

---

### RC-17 — iOS SPM manifest: compile and link verification

- **Area:** `kmdb_icloud` plugin / SPM
- **Validates:** The iOS SPM manifest (`ios/kmdb_icloud/Package.swift`) compiles
  and links the Flutter plugin correctly on iOS. The macOS manifest is exercised
  automatically by CI (`make cicd_icloud` runs `flutter pub get` on
  `macos-latest`); the iOS manifest is human-only because the example app has no
  iOS target and CloudKit requires a real entitlement.
- **Why not automated:** No iOS Simulator CI lane exists for `kmdb_icloud`.
  CloudKit requires a real Apple developer entitlement that cannot be provisioned
  in CI.
- **Applies when:** Releasing any version of `kmdb_icloud` that includes the SPM
  manifest change (`ios/kmdb_icloud/Package.swift`) or any subsequent
  modification to the Swift source in `ios/kmdb_icloud/Sources/kmdb_icloud/`.
- **Prerequisites:**
  - Xcode 15 or later (required for `swift-tools-version: 5.9`).
  - A Flutter app project (or the example adapted for iOS) that declares
    `kmdb_icloud` as a dependency.
  - A real Apple developer account with a CloudKit-enabled container (or at
    minimum, a bundle ID for which the iCloud capability can be activated in
    Xcode).
- **Steps:**
  1. Create (or adapt) a Flutter iOS app that declares `kmdb_icloud` as a
     dependency with a path reference to `packages/kmdb_icloud`.
  2. Run `flutter pub get` in the app; confirm no "does not support Swift
     Package Manager" warning for `kmdb_icloud`.
  3. Build and run the app on an iOS Simulator with CocoaPods disabled (use
     `--no-codesign` or SPM-only mode: remove `Podfile` from the iOS target).
  4. Confirm the plugin registers without linker errors and that `import Flutter`
     resolves correctly.
  5. Send a method call to the `kmdb_icloud/sync` channel (e.g. `initialize`)
     and confirm the plugin responds.
- **Expected result:** App launches on the iOS Simulator; the plugin channel
  responds to the `initialize` method call without a linker error or missing
  symbol.
- **Related:** `docs/plans/completed/plan_icloud_spm.md`,
  `packages/kmdb_icloud/ios/kmdb_icloud/Package.swift`, RC-12 (iCloud behaviour
  probe), RC-13 (iCloud real-service sync soak).

---

## Release log

| Version | Date | Tester | Checks run | Result | Notes |
| ------- | ---- | ------ | ---------- | ------ | ----- |
| _e.g. 0.x.0_ | _YYYY-MM-DD_ | _name_ | _RC-1…RC-5_ | _pass/fail_ | _link to evidence_ |
