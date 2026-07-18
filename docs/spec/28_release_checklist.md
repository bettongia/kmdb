# Release Checklist

## Purpose and scope

This is the catalogue of **manual / out-of-band tests** a human must run before
a release — the checks that the automated suite (`make test`) deliberately
cannot cover. Examples: tests against a real cloud service (credentials, quota,
non-determinism), durability behaviour that depends on real OS/hardware
(`fsync`, power loss), and cross-process or multi-host concurrency that a
single-process test harness cannot reproduce.

It is a **living document**. It starts small and is grown by plan work: any plan
that introduces a test which cannot run in CI **must add an entry here** as part
of its "Spec and docs" phase (see `plans/README.md`). The automated suite
remains the first line of defence; this checklist covers only what it
structurally cannot.

> If a check listed here _can_ be automated later (e.g. a behaviour is captured
> by a behavioural simulator), move it into the automated suite and mark the
> entry **Superseded** with a pointer to the test — do not delete the history.

## How to use it

For each release:

1. Run every entry whose **Applies when** condition is true for the changes in
   the release.
2. Record the outcome in the **Release log** at the bottom (version, date,
   tester, pass/fail per entry, notes).
3. A release is not cut until every applicable entry passes or has a documented,
   accepted waiver.

See [docs/releasing/README.md](../releasing/README.md) for the full release
*process* — package publish order, version-bump rules, and the per-release
checklist convention that consumes this list. This list is not duplicated
there; each per-release checklist file references the current entries here
by ID.

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
- **Validates:** the _actual_ semantics real Google Drive exposes for
  conditional create/update, duplicate-name creation, read-after-write
  visibility, and rate limiting — the observations that calibrate the
  behavioural Drive simulator and the lease design.
- **Why not automated:** requires real Drive credentials, consumes quota, and is
  non-deterministic; cannot run in CI or the build sandbox.
- **Applies when:** the Google Drive adapter is introduced or its request/lease
  logic changes.
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
  (`GOOGLE_DRIVE_TEST_CREDENTIALS`); optionally a longer `kmdb_harness` soak
  with the real adapter at a quota-safe velocity.
- **Expected result:** all devices converge to the global LWW state; no data
  loss; consolidation behaves per the declared `CloudProfile` (single
  consolidator if atomic, else gated/skipped).
- **Related:** `plans/plan_google_drive_sync.md` (Phase 4),
  `plans/plan_harness_mixed_storage.md`.

### RC-3 — Cross-process database lock exclusivity

- **Area:** concurrency
- **Validates:** the `LOCK` file genuinely prevents two **separate OS
  processes** from opening the same database directory concurrently.
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
- **Related:**
  `packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart`.

### RC-4 — Linux directory-fsync durability

- **Area:** durability
- **Validates:** `syncDir` durably persists new directory entries (new SSTables,
  WAL files, the `CURRENT` rename) on Linux, so a power loss does not lose files
  the manifest already references.
- **Why not automated:** `syncDir` is a no-op on macOS/Windows/memory; its
  effect is only meaningful on real Linux, and true verification needs
  power-loss-class fault injection.
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
  deletes it, and runs `_compactAll` with a horizon below the tombstone HLC so
  the tombstone is dropped. Device B (carrying an older copy of the key in its
  synced SSTables) then converges with A. The key must remain deleted globally.
- **Why not automated (as a gate):** the in-harness scenario covers the
  cross-device convergence invariant (tombstone non-resurrection) via
  `packages/kmdb_harness/test/cloud_semantics_test.dart` ("Tombstone
  non-resurrection — deleted key stays absent after peer syncs"). The
  compaction-side in-process invariant is covered by `compaction_test.dart` and
  `lsm_engine_test.dart`. The remaining gap is exercising compaction with a
  _real_ elapsed HLC horizon (not a test clock) across separate processes — that
  requires a real-OS multi-process run.
- **Applies when:** changes to the tombstone-GC predicate, the horizon
  computation, the HWM-min helper, or `SyncEngine`'s horizon-provider
  registration.
- **Prerequisites:** native build; two separate database directories.
- **Steps:** run the harness scenario that drives a fresh delete on device A,
  forces `_compactAll` with horizon below the tombstone HLC, then drives device
  B's sync. Assert `get` for the deleted key returns null on every device after
  settle.
- **Expected result:** no device observes the resurrected value; all devices
  agree the key is absent.
- **Related:** `docs/spec/06_storage_engine.md`, `docs/spec/12_sync.md`,
  `docs/plans/completed/plan_tombstone_gc.md`,
  `docs/plans/completed/plan_harness_mixed_storage.md` (automated coverage),
  `packages/kmdb_harness/test/cloud_semantics_test.dart`.

### RC-7 — Returning stale device does not resurrect deleted data

- **Area:** sync re-admission (H4-FU2)
- **Validates:** that a device evicted from the sync horizon performs a full
  re-sync on return and does not deliver pre-eviction SSTables to its peers.
  Device A writes a key, deletes it, advances its HWM past the tombstone, and a
  separate flush-compaction drops the tombstone while device B is excluded from
  the horizon (B's HWM `lastUpdated` exceeds `staleDeviceEvictionAfter`). Device
  B then returns. With the re-admission check enabled, B detects both
  `localCurrentHlc < min(livePeers.currentHlc)` and
  `localHwm.lastUpdated < now - staleDeviceEvictionAfter`, discards its local
  SSTables (via `KvStore.dropAllSstables`), and re-downloads the current
  consolidated set; the deleted key stays absent on every device.
- **Why not automated (as a gate):** the cross-device verification (B pushing a
  _real_ pre-eviction SSTable and being rejected) is the same per-device adapter
  shape that gates RC-6. The in-process invariant — that
  `_checkAndHandleEviction` triggers `_fullResync` on the two- condition rule
  and that `_fullResync` keeps the manifest consistent during the SSTable drop —
  _is_ covered in CI by the `sync_engine_test.dart` H4-FU2 tests, including the
  negative-control test that proves resurrection occurs without the guard.
- **Applies when:** changes to `SyncEngine._checkAndHandleEviction`,
  `SyncEngine._fullResync`, `KvStore.dropAllSstables`, the
  `KvStoreConfig.staleDeviceEvictionAfter` semantics, or the eviction filter in
  `HighwaterMark.minCurrentHlcAcrossDevices`.
- **Prerequisites:** `plan_harness_mixed_storage.md` landed; multi-device
  harness scenario with adjustable HWM `lastUpdated`.
- **Steps:** drive A through delete + two advance-pushes so its local store has
  GC'd the tombstone. Configure B's `staleDeviceEvictionAfter` short enough that
  B's injected stale HWM evicts B from A's horizon, but use a separate eviction
  setting on B to control re-admission detection. Have B return and call
  `push()`. Assert that B performs a full re-sync (local SSTables replaced) and
  that `get` for the deleted key returns null on every device.
- **Expected result:** the returning device does not resurrect the deleted key;
  A's local state stays consistent with the cloud.
- **Related:** `docs/spec/06_storage_engine.md`, `docs/spec/12_sync.md`,
  `docs/plans/completed/plan_tombstone_gc_stale_eviction.md`,
  `docs/plans/plan_harness_mixed_storage.md`.

### RC-8 — Cross-device `$ver:` purge / ingest-floor interaction

- **Area:** document versioning (§26), tombstone GC ingest floor (H4-FU3)
- **Validates:** that purging `$ver:` history on one device cannot cause a
  resurrection on another device, and that an old peer SSTable carrying both
  below-floor main-namespace entries and old `$ver:` history is rejected
  wholesale by the ingest-floor guard without causing incorrect trim or
  resurrection.
- **Why not automated:** requires two independent device databases (different
  paths/adapters), real HLC progression across sessions to age entries past the
  retention window, and coordination with the H4-FU3 tombstone floor. An
  in-process harness cannot reproduce the timing of compaction, clock advance,
  and SSTable ingest from a peer.
- **Applies when:** changes to `VersionRetentionPolicy.filterGroup`,
  `KvStoreImpl.ingestSstable`, `LsmEngine._computeTombstoneHorizon`, or
  `VersionConfig` defaults.
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
  correctly against a _real_ cloud service (e.g. Google Drive, Dropbox), using
  the same harness scenarios that run in CI against the behavioural simulator.
  This confirms the simulator's fidelity and catches provider behaviour that the
  simulator does not model exactly (rate limits, real propagation timing,
  service outages).
- **Why not automated:** requires real credentials and service access, consumes
  quota, is non-deterministic, and is slow. Runs in-sandbox are unsuitable.
- **Applies when:** before any release that ships or changes a cloud adapter;
  after any change to `SyncEngine` push/pull logic or
  `ConsolidationCoordinator`.
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
  `docs/plans/completed/plan_harness_mixed_storage.md`, RC-2 (Drive-specific
  soak).

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
macOS ships a major version that may change CloudKit's consistency or atomicity
behaviour. The probe confirms the values in `kICloudProfile` and the
`ICloudAdapter.providesAtomicCas` setting.

- **What to verify:**
  1. Zone-level create-if-absent atomicity: two devices simultaneously create a
     `CKRecord` with the same deterministic record ID in the same custom zone.
     Confirm exactly one succeeds and the other receives
     `CKError.serverRecordChanged`.
  2. Conditional update atomicity (`savePolicy: .ifServerRecordUnchanged`):
     concurrent updates with the same `recordChangeTag`. Confirm exactly one
     wins.
  3. `CKQuery` BEGINSWITH consistency delay: time-to-visibility of a new record
     to a second device.
  4. `CKAsset` upload/download: verify large SSTables (≥10 MB) succeed.
  5. Rate-limit error shape: `CKError.requestRateLimited` and
     `CKErrorRetryAfterKey` availability.
- **Why not automated:** requires a real CloudKit container with an active Apple
  developer account; cannot be run in CI without Apple infrastructure.
- **Applies when:** before any release that targets iOS or macOS; after any
  iOS/macOS major version bump; after updating `kICloudProfile` values or
  `ICloudAdapter.providesAtomicCas`.
- **Prerequisites:** Apple developer account with a CloudKit-enabled container
  (`iCloud.au.com.bettongia.kmdb` or a dedicated test container); two physical
  iOS or macOS devices (or one device + simulator) on the same iCloud account.
- **Steps:** Run the probe app in `packages/kmdb_icloud/example/` on two
  devices; exercise each of the five verification points above and record the
  observed CloudKit behaviour. Update `kICloudProfile` and
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
     the consolidation lease. Confirm the outcome is consistent with
     `ICloudAdapter.providesAtomicCas` (if `false`, consolidation is skipped on
     both; if `true`, exactly one wins and the lease is acquired safely).
  3. No data loss across network interruptions (disable WiFi mid-sync,
     re-enable, verify convergence).
- **Why not automated:** requires a real CloudKit container and physical
  devices; network interruption simulation is not reproducible in CI.
- **Applies when:** before any public release of `kmdb_icloud`; after any change
  to the `ICloudAdapter` CAS or zone logic; after Phase 4a values are finalised.
- **Prerequisites:** Apple developer account; CloudKit container; two devices on
  the same iCloud account.
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
  4. Refuses to use a corrupt or tampered cached file (re-downloads on checksum
     mismatch).
  5. Handles a crash mid-download (stale `.part` file) correctly on next open
     (re-downloads without corrupting the cache directory).
- **Why not automated:** requires real network access to the model CDN; the file
  sizes are hundreds of MB; the crash-recovery test requires OS-level process
  termination; the SHA-256 mismatch test requires network-level interception or
  file mutation, which CI cannot reliably reproduce.
- **Applies when:** `ModelDownloader` is introduced or its
  download/verify/rename logic changes; before any release that ships
  download-on-demand model support; when `ModelSpec` checksums are updated.
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
- **Why not automated:** `OnnxRuntime.load()` calls `DynamicLibrary.open` with a
  platform-specific short name (`libonnxruntime.dylib`, `libonnxruntime.so`,
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
    (currently placeholder zeros for v1.22.0 — replace before release; see the
    TODO comment in that file).
- **Steps:**
  1. From `betto_onnxrt/` root, run `dart test` to confirm the non-FFI tests
     pass and the OnnxSession tests are correctly skipped.
  2. Fill in `_sha256Manifest` checksums for the target platform artifact (see
     the TODO in `hook/build.dart`; obtain with `curl -fsSL <url> | sha256sum`).
  3. Run `dart build cli --output build/` (requires a minimal `bin/` entry
     point, or use a scratch Flutter app that declares `betto_onnxrt` as a
     dependency). Verify the build completes without hook errors and the library
     is staged under `.dart_tool/betto_onnxrt/{version}/`.
  4. Set `DYLD_LIBRARY_PATH` (macOS) or `LD_LIBRARY_PATH` (Linux) to the staged
     library directory and run `dart test test/onnx_session_test.dart`. Verify
     all 6 OnnxSession tests pass (no skips).
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
     (target: ≤ 5 s on a mid-range device) using the default parameters (m = 64
     MiB, t = 3, p = 1).
  2. Re-deriving the KEK on every `KmdbDatabase.open()` call (because
     `InMemoryDekCache` is session-scoped and does not persist across page
     loads) is acceptable UX — or a loading indicator is shown.
  3. The first encrypted write after `open()` succeeds (Argon2id is fully
     initialised before `open()` returns).
- **Why not automated:** `dart test -p chrome` runs in a sandboxed Worker
  context with memory limits that may not reflect real-device Argon2id
  performance. Timing is browser- and device-dependent; pass/fail thresholds are
  human-judged.
- **Applies when:** before any release that ships database encryption on a web
  target; after changes to Argon2id parameters or the WASM compression init
  path.
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
  CloudKit requires a real Apple developer entitlement that cannot be
  provisioned in CI.
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
  4. Confirm the plugin registers without linker errors and that
     `import Flutter` resolves correctly.
  5. Send a method call to the `kmdb_icloud/sync` channel (e.g. `initialize`)
     and confirm the plugin responds.
- **Expected result:** App launches on the iOS Simulator; the plugin channel
  responds to the `initialize` method call without a linker error or missing
  symbol.
- **Related:** `docs/plans/completed/plan_icloud_spm.md`,
  `packages/kmdb_icloud/ios/kmdb_icloud/Package.swift`, RC-12 (iCloud behaviour
  probe), RC-13 (iCloud real-service sync soak).

---

### RC-18 — `kmdb_flutter`: DEK round-trip and native crypto acceleration

- **Area:** encryption / platform (Flutter mobile/desktop)
- **Validates:**
  1. `FlutterSecureDekCache` persists the DEK across app restarts: store DEK →
     kill app process → relaunch → `read` returns the DEK without re-prompting
     the user for their passphrase.
  2. `KmdbFlutter.initialize()` actually enables native AES-256-GCM and Argon2id
     hardware acceleration on a real device (i.e.
     `FlutterCryptography.isPluginPresent` is `true` after the call and
     operations are measurably faster than the pure-Dart path).
  3. Passphrase unlock latency is acceptable on a mid-range mobile device
     (Argon2id ≤ 2 s with native acceleration; the pure-Dart path may reach 10+
     s on low-end hardware).
- **Why not automated:** `flutter_secure_storage` platform-channel calls are
  mocked in `flutter_test`; the real Keychain/Keystore write-then-kill-then-read
  cycle requires a physical or simulator device. Native crypto acceleration is
  confirmed by `FlutterCryptography.isPluginPresent`, which is always `false`
  under `flutter_test`. Timing depends on device hardware and cannot be asserted
  in a headless test.
- **Applies when:** `kmdb_flutter` is introduced or updated; before any release
  that ships `kmdb_flutter` as a recommended add-on; after changes to
  `FlutterSecureDekCache` or `KmdbFlutter.initialize()`.
- **Prerequisites:** an iOS simulator or device (for Keychain) or Android
  emulator/device (for Keystore); Xcode or Android Studio; Flutter SDK
  installed.
- **Steps:**
  1. Build and run the `packages/kmdb_flutter/example/` app on an iOS simulator
     or Android emulator.
  2. Open an encrypted database with
     `EncryptionConfig(passphrase: 'test', dekCache: FlutterSecureDekCache())`.
     Verify the app opens without error.
  3. Write a document (to confirm encryption is active) and close the app
     process (terminate, not just background).
  4. Relaunch the app and reopen the same database path. Verify: a. No
     passphrase prompt appears — the DEK was loaded from Keychain/Keystore. b.
     The previously written document is readable.
  5. Inspect `FlutterCryptography.isPluginPresent` after
     `KmdbFlutter.initialize()`; confirm it is `true`.
  6. Time a passphrase unlock with and without `initialize()` on a mid-range
     device; confirm the native path is faster (target: ≤ 2 s; pure-Dart: ≥ 5
     s).
- **Expected result:** steps 3–4 confirm DEK persistence; step 5 confirms plugin
  registration; step 6 confirms measurable acceleration on real hardware.
- **Related:** `docs/plans/completed/plan_kmdb_flutter.md`,
  `docs/spec/31_encryption.md` (Flutter Integration subsection), RC-16 (web
  Argon2id timing).

---

### RC-19 — Two-file flush crash-recovery fault injection

- **Area:** storage engine / crash safety
- **Validates:** when `LsmEngine.flush()` produces two files (one syncable, one
  `.local.sst`) and the process is killed after the first file is written but
  before the Manifest is updated, crash recovery on next `open()` correctly
  deletes the orphaned file and replays the WAL from scratch, with no data loss
  and no corruption of the local-only partition.
- **Why not automated:** requires `FaultyStorageAdapter` fault injection at the
  exact point between the second `SstableWriter.close()` and the `Manifest.append`
  call. While `FaultyStorageAdapter` exists in the test suite, constructing a
  precise mid-flush fault point for the two-file case requires a test harness
  change beyond what was in scope for WI-0.
- **Applies when:** the two-writer flush path is modified; before any release that
  ships WI-0 (v0.06+).
- **Steps:**
  1. Configure `FaultyStorageAdapter` to fail after the second SSTable write but
     before the Manifest append.
  2. Open a database and write documents to both a syncable namespace and a `$$`
     namespace until a flush is triggered.
  3. Confirm the fault fires; both SSTable files may or may not be on disk.
  4. Re-open the database; crash recovery should delete orphan SSTables and
     replay the WAL.
  5. Read back documents from both namespaces; confirm all data is present and
     correct.
- **Expected result:** no data loss, no stale orphan files, clean re-open.
- **Related:** `docs/plans/completed/plan_0_06_wi0_local_only_namespaces.md`,
  RC-4 (Linux real-OS power-loss), `docs/reviews/code-review-2026-05-22.md` §8.

---

### RC-20 — Multi-device sync: `$$` namespace isolation

- **Area:** sync protocol / multi-device
- **Validates:** after a push/pull cycle, device B has no `$$fts:`, `$$vec:`, or
  `$$index:` entries in its KV store, and device B independently rebuilds its
  local derived indexes from the synced document data.
- **Why not automated:** requires a two-device `kmdb_harness` test run with a
  real or simulated cloud sync folder (Google Drive or a local mock). The
  `kmdb_harness` multi-device integration suite is a separate setup and was out
  of scope for WI-0.
- **Applies when:** WI-0 ships; before any release that includes local-only
  namespace segregation (v0.06+); after any change to `SyncEngine.push` or the
  `.local.sst` exclusion predicate.
- **Steps:**
  1. Device A: open a database, write documents, trigger FTS/vec/index writes
     (confirm `$$fts:`, `$$vec:`, `$$index:` entries are present).
  2. Device A: push to the sync folder.
  3. Device B: pull from the sync folder.
  4. Device B: enumerate all KV namespaces; confirm none start with `$$`.
  5. Device B: open a collection with FTS and secondary indexes; trigger a search
     and an index query; confirm both work (indexes are rebuilt on demand).
- **Expected result:** device B receives no `$$`-prefixed data; all derived
  indexes are rebuilt locally from the synced document SSTables.
- **Related:** `docs/plans/completed/plan_0_06_wi0_local_only_namespaces.md`,
  `packages/kmdb_harness/`, RC-9 (real-service sync soak).

---

### RC-21 — Vault search isolate crash recovery

- **Area:** vault search / durability
- **Validates:** that `VaultSearchManager._recover()` correctly rebuilds the KV
  extraction state from filesystem artifacts when the process is killed at each
  phase of the indexing pipeline (after `extracting` is written, after
  `text.txt` is written, after `chunks_v1.json` is written, after
  `vectors_{modelId}_sq8.bin` is written). **Since WI-10, these writes/reads
  also go through `VaultSearchManager.writeExtractArtifact` /
  `readExtractArtifact`, so on a database opened with an `EncryptionConfig`
  the real-OS kill test also exercises a process kill mid-encrypted-write
  (partial ciphertext on disk) and confirms recovery still self-heals to
  `pending` rather than hanging or crashing `KmdbDatabase.open()` on the next
  start.** The crash points themselves are unchanged by WI-10 — only the
  bytes written at them differ — so no new RC entry is needed; this scope
  note is sufficient.
- **Why not automated:** requires killing the process (SIGKILL) at precise
  points between filesystem writes — not reproducible in a single-process
  Dart test without a dedicated fault-injection harness for subprocess
  interruption. The `FaultyStorageAdapter` covers LSM crash-safety (including
  the encrypted-artifact crash-injection tests added in
  `vault_search_manager_test.dart` for WI-10) but not the vault search
  isolate's multi-phase filesystem writes under a real OS kill.
- **Applies when:** WI-3 vault search ships; before any release that includes
  `VaultSearchManager`, `VaultIndexingIsolate`, or changes to the
  `$$vault:extract:` recovery sequence (v0.06+). Re-verify after WI-10
  (`extract/` artifact encryption) ships, with an `EncryptionConfig` configured.
- **Prerequisites:** a native-platform machine (Linux or macOS); the `kmdb_cli`
  binary built with `dart compile exe`; a small corpus of `text/plain` blobs.
- **Steps:**
  1. Open a database with `vaultSearch: VaultSearchConfig()` and ingest several
     text blobs.
  2. Kill the process with `kill -9` immediately after the `extracting` status
     is written (use OS-level process monitoring or a debug `sleep` in code).
  3. Re-open the database; verify recovery resets the killed blob to `pending`
     and re-indexes it successfully.
  4. Repeat by killing after each subsequent filesystem artifact is written
     (`text.txt`, `chunks_v1.json`, `vectors_*_sq8.bin`).
  5. After each recovery, run `kmdb <db> vault status` and confirm all blobs
     reach `indexed` with no `failed` entries.
- **Expected result:** all blobs are fully indexed after recovery in every
  kill scenario; no orphan `extract/` directories or stale `extracting` entries
  remain.
- **Related:** `docs/plans/plan_0_06_wi3_vault_search_core.md`, §32 (Vault
  Search — Startup Recovery), `docs/reviews/code-review-2026-05-22.md` §8.

---

### RC-22 — Encryption confidentiality reconciliation: legacy database format break

- **Area:** encryption / storage engine
- **Validates:** that a database created before the Encryption
  confidentiality reconciliation plan landed (`$meta` values stored as bare
  CBOR, no leading `EncryptionFlag` byte) fails to open with a clear,
  explicit error (`LegacyDatabaseFormatException`) rather than a silent
  misparse of a legacy value's first CBOR byte as an encryption/compression
  flag — this matters most for `device_id`, since a silently-corrupted
  device identity would break sync continuity rather than fail loudly.
- **Why not automated:** the automated suite (`meta_store_encryption_test.dart`
  and the `KvStoreImpl.open()` format-version-gate tests) already covers the
  detection logic itself against synthetic legacy-shaped fixtures. What
  cannot be automated is confirming this against a *genuinely* pre-plan
  on-disk database directory produced by an actual older build of `kmdb` —
  the automated suite has no such artifact and constructing one requires a
  human to have kept (or be willing to regenerate) a pre-plan database.
- **Applies when:** before the first release that ships the Encryption
  confidentiality reconciliation plan (`docs/roadmap/completed/0_08.md`); a reminder
  for anyone with a pre-existing dev/test database directory created before
  this plan landed.
- **Prerequisites:** a database directory created by a `kmdb` build from
  before this plan's Phase 2 landed (tag/commit prior to the `$meta`
  format-version gate), or a fresh directory with a hand-crafted bare-CBOR
  `$meta` entry and no `formatVersion` marker.
- **Steps:**
  1. Attempt `KmdbDatabase.open()` (or `KvStoreImpl.open()`) against the
     pre-plan database directory.
  2. Confirm the call throws `LegacyDatabaseFormatException` with a message
     pointing to this document and `docs/spec/31_encryption.md`'s _Database
     Format-Version Gate_ section — not a generic decode error, a hang, or
     (worst case) a successful open with corrupted `device_id`/namespace
     registry data.
  3. Confirm there is no supported way to open the legacy database with the
     current code — the only remedy is to recreate the database (export any
     needed data first, using an older `kmdb` build if necessary).
- **Expected result:** the legacy database fails to open with a clear,
  actionable `LegacyDatabaseFormatException`; no silent corruption or
  partial-open state occurs.
- **Related:** `docs/spec/31_encryption.md` (_Database Format-Version
  Gate_), `docs/plans/completed/
  plan_0_08_encryption_confidentiality_reconciliation.md` (B8),
  `packages/kmdb/lib/src/engine/kvstore/kv_store.dart`
  (`LegacyDatabaseFormatException`).

### RC-23 — `dart build cli` native-asset bundling on Linux and Windows

- **Area:** platform / packaging
- **Validates:** that `dart build cli` correctly stages all three native
  libraries `kmdb_cli` now bundles (`libonnxruntime`, `libzstd`, PDFium) into
  `bundle/lib/` on Linux and Windows, and that the compiled binary loads and
  runs correctly on those platforms — not just macOS arm64, the only platform
  this was verified on during development.
- **Why not automated:** this development environment and CI both run on
  macOS; verifying a `dart build cli` compiled-binary artifact on Linux/Windows
  requires a real machine or CI runner for those platforms, which was not
  available here. `betto_onnxrt`'s loader
  (`betto_onnxrt/lib/src/runtime.dart`) has separate, architecturally distinct
  code paths for each platform (Linux: `DynamicLibrary.open('libonnxruntime.so')`
  relying on the dynamic linker finding the bundled `.so`; Windows:
  adjacent-to-exe absolute path) that are sound by inspection but unverified
  in a real `dart build cli` bundle on those platforms.
- **Applies when:** before any release that ships a compiled `kmdb_cli`
  binary for Linux or Windows, and after any change to `kmdb_extractor_pdf`,
  `betto_pdfium`, `betto_onnxrt`, or `betto_zstd`'s native-asset build hooks.
- **Prerequisites:** a Linux (x64) and a Windows (x64) machine or CI runner
  with the Dart SDK installed; no other credentials needed.
- **Steps:**
  1. From `packages/kmdb_cli`, run `dart pub get` then `dart build cli`.
  2. Confirm the build log reports "Copying 3 build assets" (or equivalent)
     and that `build/cli/<platform>/bundle/lib/` contains the platform's
     three native libraries (e.g. `libonnxruntime.so`/`libzstd.so`/
     `libpdfium.so` on Linux; `onnxruntime.dll`/`zstd.dll`/`pdfium.dll` on
     Windows).
  3. Copy the whole `bundle/` directory to a scratch location (not just
     `bundle/bin/`) and run the binary from an arbitrary working directory:
     `kmdb --version`, then `kmdb <scratch-db> vault status` (exercises the
     vault code path, which loads PDFium indirectly via `kmdb_extractor_pdf`).
  4. Confirm both commands succeed with no `dlopen`/`LoadLibrary` failures.
- **Expected result:** the compiled binary runs correctly on both platforms
  from an arbitrary working directory, with all three native libraries
  loading successfully — matching the macOS arm64 result already verified
  during development (see `docs/plans/completed/
  plan_0_06_wi12_vault_search_cli.md`, Phase A).
- **Related:** `docs/plans/completed/plan_0_06_wi12_vault_search_cli.md`
  (Phase A native-assets investigation), `packages/kmdb_cli/README.md`
  (`dart build cli` bundle workflow).

### RC-24 — `kmdb_cli` credential store: real-OS permission verification

- **Area:** platform / `kmdb_cli`
- **Validates:** that `DirectoryCredentialStore` actually produces the
  permissions its design claims on a real OS, not just under this
  development environment's sandboxed `chmod`/`stat()` calls — macOS and
  Linux should show the credential file at `600` and its `local/` parent at
  `700`; Windows should show the credentials file landing under the user's
  own profile-inherited ACLs with no separate enforcement attempted.
- **Why not automated:** the automated suite (`packages/kmdb_cli/test/config/
  credential_store/directory_credential_store_test.dart`) already exercises
  the `chmod`/`stat()` logic deterministically on whichever POSIX OS runs the
  test (this development environment and CI both run on macOS — see RC-23),
  and the Windows no-op behaviour is `skip:`-guarded to run for real only on
  a Windows machine. What is not automatable anywhere is an independent,
  real-`ls -la`/`icacls` visual confirmation that the bits actually landed as
  claimed outside of Dart's own `stat()` view of them — the kind of
  "trust but verify with a second tool" check this checklist exists for.
- **Applies when:** before any release, and after any change to
  `packages/kmdb_cli/lib/src/config/credential_store/
  directory_credential_store.dart`.
- **Prerequisites:** a macOS, a Linux, and (optionally) a Windows machine or
  CI runner; no cloud credentials needed — a `google-drive` remote can be
  registered with dummy `--client-id`/`--client-secret` values since the
  check only needs the credential file to exist, not a completed OAuth flow.
- **Steps:**
  1. On macOS and Linux: run `kmdb <db> remote add gdrive --type google-drive
     --folder x --client-id x --client-secret x` and complete (or Ctrl-C
     after) the browser consent step once the credentials file has been
     written, or, more simply, run any command that write-through-refreshes
     an already-present credentials file.
  2. Run `ls -la {dbDir}/local/` and confirm `google_credentials.json` shows
     `-rw-------` (`600`) and the `local/` directory itself shows `drwx------`
     (`700`).
  3. On Windows: run the same `remote add` flow, then confirm via `icacls
     {dbDir}\local\google_credentials.json` that the effective permissions
     are inherited from the user's profile (owner + Administrators/SYSTEM
     only) — no `kmdb_cli`-set ACL should be present.
  4. Deliberately loosen the file with `chmod 644` (macOS/Linux) and re-run a
     `push`/`pull`/`sync` against that remote; confirm the CLI hard-refuses
     with a one-line `Error: ... Fix with: chmod 600 ...` message (no stack
     trace) rather than silently syncing.
- **Expected result:** `600`/`700` on macOS and Linux, no `kmdb_cli`-added ACL
  on Windows, and a clean hard-refusal on a deliberately loosened file —
  matching `docs/spec/33_cli_credential_store.md`'s documented permission
  model.
- **Related:** `docs/spec/33_cli_credential_store.md`,
  `docs/plans/completed/plan_0_09_cli_keychain_credentials.md`.

---

## Release log

| Version      | Date         | Tester | Checks run  | Result      | Notes              |
| ------------ | ------------ | ------ | ----------- | ----------- | ------------------ |
| _e.g. 0.x.0_ | _YYYY-MM-DD_ | _name_ | _RC-1…RC-5_ | _pass/fail_ | _link to evidence_ |
