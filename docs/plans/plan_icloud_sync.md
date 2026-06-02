# Apple iCloud sync adapter (CloudKit)

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

**Implementation model:** Sonnet, **after the Phase 4a empirical probe**; the probe
is human-run on a real iOS/macOS device with an iCloud-enabled Apple developer
account.

**Roadmap**: docs/roadmap/0_03.md

**Prerequisites**:

- ✅ `plan_sync_cas_atomicity.md` (H5) — **COMPLETE** (now in
  `docs/plans/completed/`). Landed: the `providesAtomicCas` getter on
  `SyncStorageAdapter`, `ConsolidationCoordinator` gating on it, and the
  reusable `runSyncAdapterConformance({required factory, required
  expectAtomicCas})` suite. The suite was subsequently promoted into `lib/`
  by the Google Drive plan (see below) and is now public at
  `package:kmdb/test_support.dart` (source:
  `packages/kmdb/lib/src/test_support/sync_adapter_conformance.dart`).
- ✅ **`plan_harness_mixed_storage.md` — COMPLETE (PR #34, now in
  `docs/plans/completed/`).** Landed: `CloudProfile`
  (`consistency`, `atomicConditionalCreate`, `allowsDuplicateNames`,
  `quota`, plus the `CloudProfile.strong()` and
  `CloudProfile.eventual({maxPropagationDelayMs, jitterMs})` named
  constructors) at `packages/kmdb/lib/src/test_cloud/cloud_profile.dart`;
  the per-device adapter factory (`HarnessConfig.syncAdapterFactory`) and
  `SharedCloudBackend` / `SharedBackendAdapter` / `CloudSemanticsAdapter`
  exported via `package:kmdb/kmdb_test_cloud_support.dart`. The Phase 4
  simulation framework is ready and in code.
- ✅ **`plan_google_drive_sync.md` — COMPLETE (PR #36, now in
  `docs/plans/completed/`).** It established the conformance suite's public
  export path (`package:kmdb/test_support.dart`, promoting
  `sync_adapter_conformance.dart` from `test/` into `lib/src/test_support/`)
  as the first downstream consumer. That export **now exists** — this plan's
  Phase 4 consumes it directly and does **not** repeat the move. The Drive
  plan is also the precedent for the patterns this plan mirrors: the
  config-only `GoogleDriveRemoteConfig` sealed subtype in core `kmdb`, the
  async `adapterFor(...)` CLI factory (now `Future<SyncStorageAdapter>`),
  the `kGoogleDriveProfile` `CloudProfile` instance, and the test-side
  `SimulatorQuotaAdapter` that implements `QuotaAwareAdapter` while the
  production `GoogleDriveAdapter` does not.

## Problem statement

KMDB's sync protocol uses `SyncStorageAdapter` as its cloud backend abstraction.
This plan implements an `ICloudAdapter` backed by Apple's CloudKit, giving iOS
and macOS users a zero-infrastructure sync location tied to their Apple ID —
no account setup beyond the iCloud account already on their device.

The `docs/spec/01_overview.md` specifically calls out the CloudKit value
proposition: "CloudKit offers atomic batch operations and push notifications.
Worth a dedicated adapter? Yes, as a v2 cloud adapter alongside Google Drive.
Different API but same sync protocol." This plan implements exactly that
recommendation. The roadmap entry "Cloud adapter: Apple iCloud" (in
`docs/roadmap/0_03.md`) is the target.

The plan covers **CloudKit only**. iCloud Drive (Apple's consumer file sync
service, accessible via Flutter plugins such as `icloud_storage_plus`) is
evaluated and excluded — see the API decision in the Investigation.

## Open questions

- [x] **Q-A1 — API choice (CloudKit vs iCloud Drive).** RESOLVED: CloudKit
      custom zones. The platform channel architecture (Phases 2–3) follows from
      this decision.
- [x] **Q-A2 — CLI support.** RESOLVED: out of scope for this plan. `kmdb_cli`
      is a Dart binary (no Flutter runtime, no method channels); `kmdb_ui`
      integration is also deferred. This plan delivers the `kmdb_icloud` package
      (adapter + platform channel plugin + tests) only.
- [x] **Q-A3 — `ICloudSyncChannel` as the test seam.** RESOLVED (reviewer
      default, 2026-06-03): an `abstract interface class ICloudSyncChannel` is
      the correct boundary. It mirrors the Drive precedent, where the seam sits
      *below the adapter* (Drive fakes the `http.Client` under `DriveApi` so the
      real `GoogleDriveAdapter` code runs in tests). Mocking at the
      `MethodChannel` dispatcher level (`TestDefaultBinaryMessengerBinding`)
      would require a `TestWidgetsFlutterBinding` and exercise the channel
      serialisation rather than the adapter logic — worse fidelity, more
      ceremony. The Dart/Swift boundary is the right cut. See review note R-1.
- [x] **Q-A4 — CloudKit container identifier.** RESOLVED (reviewer default,
      2026-06-03): supplied at construction time, not hardcoded. The container
      ID is a constructor parameter on `PlatformICloudSyncChannel` (threaded
      into the `MethodChannel` `initialize` call and on to
      `CKContainer(identifier:)` in Swift). `FakeICloudSyncChannel` ignores it.
      This keeps the package free of a hardcoded Bettongia-specific container
      and matches the Drive precedent of injecting provider credentials/config
      at construction. The default `example/` app and (deferred)
      `ICloudRemoteConfig` carry the concrete `iCloud.<bundle-prefix>` value.
      See review note R-2.
- [x] **Q-A5 — Phase 4a probe operationally.** RESOLVED (user, 2026-06-03): the
      project can obtain an Apple developer account with a test CloudKit
      container for the Phase 4a probe, and a dedicated probe target (separate
      from the main app) is acceptable. The Phase 4a empirical probe is
      therefore unblocked on the logistics side; it remains a human-run step
      (it is not work the Sonnet implementer performs), and Phases 1–3 proceed
      independently of it. See review note R-3.
- [x] **R-4 — `FakeICloudSyncChannel` consistency/atomicity fidelity.** RESOLVED
      (user, 2026-06-03 — **Option C**): `FakeICloudSyncChannel` is an
      **immediately-consistent, atomic functional fake**, exactly like the landed
      `DriveSimulator`. It does **not** model the non-atomic create-if-absent race
      window or any propagation delay. Non-atomic / eventual-consistency fidelity
      lives only in the `kICloudProfile`-parameterised `kmdb_harness` scenario
      (via `CloudSemanticsAdapter`) and the deferred real-service soak (RC-Y).
      Rationale (confirmed by code inspection of
      `packages/kmdb/lib/src/sync/consolidation_coordinator.dart`):
      `ConsolidationCoordinator` early-returns
      `ConsolidationState.skippedNonAtomicCas` at line 284 **before** any
      `compareAndSwap` call whenever `providesAtomicCas == false`. With
      `kICloudProfile.atomicConditionalCreate == false` (the safe default and
      likely outcome), there is therefore **no split-lease race for the fake to
      model** — consolidation is gated off entirely, not racing. The non-atomic
      CAS race is a property of `CloudSemanticsAdapter` in the harness, not of any
      adapter-specific simulator. This matches the Drive precedent exactly. See
      review note R-4.

## Investigation

### Existing adapter interface

`SyncStorageAdapter` (in `packages/kmdb/lib/src/sync/sync_storage_adapter.dart`)
defines six methods. Each now also takes an optional `SyncContext? ctx`
parameter (added by the sync-cancellation work, PR #37) for cooperative
cancellation/timeout — the `ICloudAdapter` and `ICloudSyncChannel` signatures
must thread `ctx` through, and how it maps onto CloudKit operation cancellation
is an open design point for the implementer (see the note after the table):

| Method                                       | Notes                          |
| -------------------------------------------- | ------------------------------ |
| `list(dir, {extension})`                     | Returns bare filenames only    |
| `download(path)`                             | Returns `null` if file absent  |
| `upload(path, bytes)`                        | Overwrites if exists           |
| `delete(path)`                               | No-op if absent                |
| `compareAndSwap(path, bytes, {ifMatchEtag})` | `null` etag = if-none-match:\* |
| `getEtag(path)`                              | Returns `null` if absent       |

All ETags are implementation-specific opaque strings. The lease protocol in
`ConsolidationCoordinator` depends entirely on `compareAndSwap` behaving
atomically from the server's perspective.

> **`SyncContext? ctx` — RESOLVED (reviewer default, 2026-06-03).** PR #37 added
> an optional `SyncContext? ctx` to every adapter method, and the landed
> `GoogleDriveAdapter` (PR #36) already establishes the prevailing pattern, so
> this is **not** an open design point: every `ICloudAdapter` method calls
> `ctx?.throwIfExpired()` at entry, and any back-off sleep uses the
> `Future.any([Future.delayed(d), <cancellation future>])` form the
> `SyncStorageAdapter` doc comment prescribes (see
> `packages/kmdb/lib/src/sync/sync_storage_adapter.dart` lines 78–101 and the
> Drive adapter's per-method `ctx?.throwIfExpired()` calls). This is sufficient
> to pass the conformance suite with `expectsCancellation: true`, which is the
> bar.
>
> Mid-flight CloudKit cancellation (cancelling a live `CKOperation` /
> `CKAsset` transfer across the method-channel boundary) is an **optional
> enhancement, not a requirement**: the entry-check pattern already satisfies
> cooperative cancellation between operations. If the implementer chooses to
> wire `CKOperation.cancel()` through the channel they may, but the plan does
> not require it and the conformance suite does not test it (no in-suite adapter
> exposes a long-running interruptible I/O wait). The Swift `cancel` plumbing,
> if added, is verified only in the deferred real-service soak (RC-Y).

### API choice: CloudKit vs iCloud Drive

#### iCloud Drive (via Flutter plugin)

iCloud Drive exposes the user's iCloud-synced file container as a familiar
file-system-like API. The most capable Flutter plugin is `icloud_storage_plus`
(MIT, full pub points, coordinated iOS/macOS access).

**Advantages:**
- Natural 1:1 file mapping — SSTables, `.hwm` files, and the lease file all
  map directly to iCloud Drive files.
- Simple to implement; no custom native code needed.

**Disadvantages:**
- **No ETags.** The plugin does not expose file revision tokens or content
  hashes. Implementing ETags would require custom Objective-C/Swift code
  using `NSFileVersion` or `NSFileCoordinator` — which still only provides
  local coordination, not server-side atomicity.
- **Eventually consistent across devices.** iCloud Drive syncs files in the
  background; iOS controls when syncs occur and files become visible to a
  second device. There is no way to programmatically trigger iCloud sync
  from Dart.
- **`providesAtomicCas = false` is mandatory.** Two devices can both write
  local copies of the lease file; iOS reconciles them later (last-write-wins
  at the filesystem level). The lease cannot protect against concurrent
  consolidation.
- ConsolidationCoordinator will skip consolidation (loss-free per H5), but
  SSTables accumulate without being consolidated.

#### CloudKit custom zones

CloudKit is Apple's structured cloud database. Each record has a `recordType`,
typed fields, and an optional `CKAsset` for binary blobs. Records in a **custom
private zone** have server-enforced sequencing and atomic batch semantics. The
platform-native `CloudKit` framework (Swift/Objective-C) is available on iOS
and macOS; the Dart side drives it via a Flutter `MethodChannel`.

**Advantages:**
- **True atomic CAS.** Two devices simultaneously creating a record with the
  same deterministic `CKRecord.ID` in the same custom zone will result in
  exactly one success — the zone's update counter serialises writes. A
  create-if-absent produces a single winner. Update-with-`If-Match` is
  similarly atomic via `savePolicy: .ifServerRecordUnchanged`.
- **ETags via `recordChangeTag`.** CloudKit assigns an opaque, stable
  `recordChangeTag` on each record save, directly usable as the adapter's
  ETag.
- **`providesAtomicCas = true` (pending Phase 4a verification).** Full
  consolidation support.
- **Implicit auth.** No OAuth; the user's iCloud sign-in on the device is the
  credential. No token storage, no browser redirect.
- **Push notifications.** Out of scope for this plan, but CloudKit's
  subscription model can notify devices of new SSTables without polling — a
  future enhancement.

**Disadvantages:**
- **No mature Dart/Flutter CloudKit package.** `cloudkit_flutter` (v0.1.4,
  37 pub downloads) and `flutter_cloud_kit` (v0.0.3, 164 downloads) do not
  expose custom zones, conditional saves, or asset download — the operations
  KMDB needs. A purpose-built `ICloudSyncChannel` plugin must be written.
- **iOS/macOS only.** CloudKit requires Apple platforms. No Android, no web,
  no Windows/Linux.
- **Records, not files.** Binary SSTables are stored as `CKAsset` blobs
  attached to `CKRecord` metadata records. This indirection is manageable but
  means every operation involves both a metadata fetch and an asset
  download/upload.
- **CLI not supported.** See Q-A2.

#### Decision: CloudKit

CloudKit is the recommended implementation target. The spec's explicit
endorsement of CloudKit's atomic operations, and the architecture's reliance on
a working lease protocol (`providesAtomicCas = true` → consolidation enabled),
make the extra implementation complexity worthwhile. iCloud Drive's inability
to provide atomic CAS makes it a weaker fit, even though its file model is more
natural for KMDB's SSTable layout.

### CloudKit storage model

Each KMDB sync file is a `CKRecord` of type `"KMDBSyncFile"` in a custom
private zone:

```
CKContainer: <containerIdentifier>          (e.g. iCloud.au.com.bettongia.kmdb)
└── Private Database
    └── Custom Zone: "kmdb-<syncRoot>"      (one zone per syncRoot name)
        ├── KMDBSyncFile:<path>             (record type + deterministic record name)
        │   ├── path: String               (the full relative path, e.g. "sstables/abc.sst")
        │   └── content: CKAsset           (the file bytes, stored on Apple's servers)
        │   recordChangeTag → ETag
        ├── KMDBSyncFile:sstables/...
        ├── KMDBSyncFile:highwater/...
        └── KMDBSyncFile:.consolidation-lease
```

**Record ID strategy:** `CKRecord.ID(recordName: <path>, zoneID: zone.zoneID)`.
This gives each "file" a globally unique, deterministic key within the zone.
CloudKit guarantees exactly one record per `recordID` per zone.

**Sync folder layout** is unchanged from the rest of the engine:

```
{syncRoot}/               ← encoded as the CloudKit zone name
  highwater/
    {deviceId}.hwm        ← path = "highwater/{deviceId}.hwm"
  sstables/
    *.sst                 ← path = "sstables/{filename}"
  .consolidation-lease    ← path = ".consolidation-lease"
```

### SyncStorageAdapter → CloudKit mapping

| Adapter method                          | CloudKit operation |
| --------------------------------------- | -------------------|
| `list(dir, {extension})`                | `CKQuery` on zone with `NSPredicate("path BEGINSWITH %@", dir + "/")`, filtered by extension suffix. Returns bare filenames (strip the `dir + "/"` prefix). |
| `download(path)`                        | `CKFetchRecordsOperation` for deterministic record ID; download `CKAsset` file to temp path; read bytes; return `null` on not-found error. |
| `upload(path, bytes)`                   | Write bytes to a temp file; create `CKAsset`; save `CKRecord` with `savePolicy: .changedKeys` (update) or `.allKeys` (create). Caller does not distinguish — the adapter checks existence first (or tries create then falls back to update on conflict). |
| `delete(path)`                          | `CKModifyRecordsOperation` delete by deterministic record ID; swallow `CKError.unknownItem`. |
| `compareAndSwap(path, bytes, {etag})`   | See below. |
| `getEtag(path)`                         | `CKFetchRecordsOperation` with `desiredKeys: []` (metadata only, no asset download); return `record.recordChangeTag`; `null` on not-found. |

### compareAndSwap on CloudKit

**Update path (`ifMatchEtag != null`):** Create a local `CKRecord` with the
deterministic record ID and the known server `recordChangeTag` set on it. Save
with `savePolicy: .ifServerRecordUnchanged`. If the server's tag no longer
matches, CloudKit returns `CKError.serverRecordChanged` → return `false`. If it
matches, the write succeeds → return `true`. This is the standard conditional-
update atomic operation, well-documented in CloudKit.

**Create-if-absent path (`ifMatchEtag == null`):** Create a fresh local
`CKRecord` (no server record, nil `recordChangeTag`) with the deterministic
record ID. Save with `savePolicy: .allKeys`. If the server already has a record
with that ID, CloudKit returns `CKError.serverRecordChanged` (the local record
with no change tag conflicts with the existing server record that has one) →
return `false`. If no record exists, it is created → return `true`.

**Atomicity caveat — must be verified empirically.** The create-if-absent
path relies on CloudKit's zone-level sequencing ensuring exactly one winner
among concurrent creates for the same record ID. This is the expected behaviour
for custom zones, but it **must be verified** in Phase 4a against the real
CloudKit service before the adapter declares `providesAtomicCas = true`. Until
Phase 4a confirms it, the adapter defaults to `providesAtomicCas = false`
(loss-free posture: consolidation coordinator skips consolidation).

> **Scope constraint (Q-A1).** The lease design uses the deterministic record
> ID within the `"kmdb-<syncRoot>"` custom private zone. This keeps all KMDB
> sync data in one zone and avoids requesting additional CloudKit permissions.
> If Phase 4a shows that zone-level serialisation does not guarantee a single
> winner on simultaneous creates with the same record ID, the adapter declares
> `providesAtomicCas = false` (loss-free) — it does **not** attempt a
> workaround via a different CloudKit API surface.

### ETag strategy

CloudKit's `recordChangeTag` is an opaque, server-assigned string that changes
on every successful record save. It is available as a metadata field on
`CKRecord` without downloading the `CKAsset`. This is a clean ETag: it changes
on every write, it is stable for a given revision, and it matches what the
`compareAndSwap` conditional-save machinery expects.

### Dart/Flutter package landscape

No existing Dart/Flutter package provides the CloudKit operations this adapter
needs (custom zones, conditional saves, `CKAsset` upload/download,
`CKQuery` with predicate). The two available packages:

| Package | Version | Downloads | Gap |
| ------- | ------- | --------- | --- |
| `cloudkit_flutter` | 0.1.4 | 37 | No custom zones; no conditional save |
| `flutter_cloud_kit` | 0.0.3 | 164 | No zones; no asset support |

**Conclusion:** The `kmdb_icloud` package must include a purpose-built
`ICloudSyncPlugin` in Swift and an `ICloudSyncChannel` Dart abstraction. This
is standard Flutter federated-plugin practice. The Swift layer wraps the native
`CloudKit` framework; the Dart layer calls it via `MethodChannel`.

### Platform scope

**iOS and macOS are both first-class targets.** CloudKit and the platform
channel plugin are supported on both platforms; macOS desktop Flutter
applications (the primary target for `kmdb_ui`) are an explicit use case. The
Swift plugin is shared across both platform targets. Android, web, Windows, and
Linux are excluded — they do not have iCloud access. Users who want
cross-platform sync should use the Google Drive adapter.

CLI (`kmdb_cli`) support is out of scope (Q-A2 resolved). A macOS Dart CLI
binary cannot use Flutter method channels. CLI access to CloudKit would require
FFI to a native Swift library or helper binary; that complexity is not part of
this plan.

### Simulator approach (test seam)

The Google Drive plan's behavioural simulator sits below the `googleapis`
`DriveApi` as a fake `http.Client`. For CloudKit, the analogous seam is the
`ICloudSyncChannel` abstraction (not an HTTP client):

- **Production:** `PlatformICloudSyncChannel` calls the native Swift plugin via
  `MethodChannel`. The Swift plugin uses the real `CloudKit` framework.
- **Tests:** `FakeICloudSyncChannel` implements the same interface in Dart,
  over `SharedCloudBackend` (from `package:kmdb/kmdb_test_cloud_support.dart`,
  landed by the harness plan). It models the CloudKit semantics verified in
  Phase 4a (atomicity, consistency delay, quota errors).

Because `ICloudAdapter` takes an `ICloudSyncChannel` at construction, the real
adapter code is exercised in tests — the abstraction boundary is between Dart
and Swift, not between the adapter and the adapter's caller.

### CloudProfile (preliminary)

The `CloudProfile` type is already in code at
`packages/kmdb/lib/src/test_cloud/cloud_profile.dart`, exported via
`package:kmdb/kmdb_test_cloud_support.dart`. Its constructor is
`CloudProfile({required ConsistencyModel consistency, required bool
atomicConditionalCreate, bool allowsDuplicateNames = false, QuotaProfile quota =
const QuotaProfile.unlimited()})`, and it offers `CloudProfile.strong()` /
`CloudProfile.eventual({maxPropagationDelayMs, jitterMs})` shorthands. CloudKit
needs the general constructor (eventual consistency, but `allowsDuplicateNames:
false`). **Location (matches the Drive precedent):** `kICloudProfile` ships in
`lib/src/icloud_profile.dart` and is exported publicly from
`lib/kmdb_icloud.dart` — exactly as `kGoogleDriveProfile` lives in
`packages/kmdb_google_drive/lib/src/google_drive_profile.dart` and is exported
from `kmdb_google_drive.dart`. It is **not** a test-only constant. (The
`maxPropagationDelayMs`/`jitterMs`/`quota`/`atomicConditionalCreate` values are
filled in from the Phase 4a probe, but the file and its export are created in
Phase 3, not Phase 4.) The preliminary shape:

```dart
// CloudKit CloudProfile — preliminary; atomicConditionalCreate and
// consistency values are finalised by the Phase 4a empirical probe.
const kICloudProfile = CloudProfile(
  consistency: EventualConsistency(
    maxPropagationDelayMs: /* Phase 4a result */,
    jitterMs: /* Phase 4a result */,
  ),
  atomicConditionalCreate: false, // safe default; set to true only if
                                  // Phase 4a confirms zone serialisation
                                  // guarantees single-winner creates
  allowsDuplicateNames: false,    // CloudKit zones: one record per ID, no
                                  // duplicate record names possible
  quota: QuotaProfile(
    maxOpsPerMinute: /* from CKError.requestRateLimited / Apple docs */,
    maxUploadBytesPerDay: null,   // or derive from 2 GB daily transfer quota
  ),
);
```

Following the `kGoogleDriveProfile` precedent, this instance is a named
constant the simulator and the conformance/quota tests share.

## Implementation plan

### Phase 1 — Package scaffold

- [ ] Create `packages/kmdb_icloud/` with standard layout: `lib/`, `test/`,
      `ios/`, `macos/`, `pubspec.yaml`, `README.md`
- [ ] `pubspec.yaml`: Flutter plugin; dependencies: `flutter`, `kmdb`. Platform
      declarations for `ios` and `macos` plugin classes (Swift).
- [ ] Add `kmdb_icloud` to root workspace `pubspec.yaml`
- [ ] Add `kmdb_icloud` entry to `melos.yaml` if one exists
- [ ] Add license header to all new Dart and Swift source files (use
      `@header_template.txt` for Dart; Apache 2.0 comment block for Swift)
- [ ] Add `kmdb_icloud` to `CLAUDE.md` package table

### Phase 2 — Platform channel plugin (`ICloudSyncChannel`)

- [ ] Define `abstract interface class ICloudSyncChannel` in
      `lib/src/icloud_sync_channel.dart` with methods mirroring the six
      `SyncStorageAdapter` operations (typed for the channel boundary — path
      strings, byte lists, nullable etag strings). This is the Dart-side
      contract the adapter calls and tests mock.
- [ ] Implement `PlatformICloudSyncChannel` using `MethodChannel
      'kmdb_icloud/sync'`. Serialises call arguments to/from the channel
      (paths as `String`, bytes as `Uint8List`, etags as `String?`).
- [ ] Implement `ICloudSyncPlugin.swift` in `ios/Classes/` and
      `macos/Classes/` (shared Swift source via symlink or conditional):
  - CloudKit initialisation: `CKContainer(identifier:)` → private database →
    custom zone `CKRecordZone(zoneName: "kmdb-\(syncRoot)")`, created lazily
    on first use.
  - Zone ID cache: once the zone is confirmed to exist, cache its
    `CKRecordZone.ID` in memory.
  - Method handler: dispatch channel calls to `list`, `download`, `upload`,
    `delete`, `compareAndSwap`, `getEtag` implementations.
  - Error mapping: `CKError.unknownItem` → file-not-found sentinel;
    `CKError.serverRecordChanged` → CAS failure sentinel;
    `CKError.requestRateLimited` → retriable error with backoff hint.

### Phase 3 — Core adapter implementation

- [ ] Implement `ICloudAdapter` in `lib/src/icloud_adapter.dart`
      implementing `SyncStorageAdapter`
- [ ] Constructor accepts `ICloudSyncChannel channel` and `String syncRoot`
      (zone name suffix). Production callers pass `PlatformICloudSyncChannel`;
      tests pass `FakeICloudSyncChannel`.
- [ ] `list(dir, {extension})` — delegate to channel; strip `dir + "/"` prefix
      from returned paths; filter by extension.
- [ ] `download(path)` — delegate to channel; return `null` on file-not-found.
- [ ] `upload(path, bytes)` — delegate to channel; channel's Swift layer writes
      bytes to a temp file, wraps in `CKAsset`, saves record with
      `savePolicy: .changedKeys` (creates if record is new, updates if
      existing).
- [ ] `delete(path)` — delegate to channel; channel swallows not-found.
- [ ] `compareAndSwap(path, bytes, {ifMatchEtag})` — delegate to channel;
      return `true`/`false` per the CAS semantics above.
- [ ] `getEtag(path)` — delegate to channel; return `null` if absent.
- [ ] `bool get providesAtomicCas` — a hardcoded getter (per-instance is not
      needed; mirrors `GoogleDriveAdapter`'s `bool get providesAtomicCas =>
      false`). Ships as `=> false` in Phase 3 (loss-free default). Phase 4a may
      flip it to `=> true` if the probe confirms atomic create-if-absent. The
      value must equal `kICloudProfile.atomicConditionalCreate` — the Phase 4
      drift test (last checklist item) asserts this. Note: even when this is
      `false`, conditional *update* by record ID is still atomic on CloudKit;
      `false` only disables the create-if-absent contention guarantee that
      `ConsolidationCoordinator` relies on.
- [ ] Add `kICloudProfile` in `lib/src/icloud_profile.dart` with the
      preliminary values (Phase 4a fills in the real numbers). Mirrors
      `packages/kmdb_google_drive/lib/src/google_drive_profile.dart`.
- [ ] Expose `ICloudAdapter` **and** `kICloudProfile` as the package's public
      API via `lib/kmdb_icloud.dart` (mirrors `kmdb_google_drive.dart` exporting
      both `GoogleDriveAdapter` and `kGoogleDriveProfile`).

### Phase 4 — Behavioural CloudKit simulator + tests

**Phase 4 prerequisite:** ✅ already satisfied. The conformance suite export
path (`package:kmdb/test_support.dart`, exporting `runSyncAdapterConformance`
and `runSyncAdapterContentionTest`) was established by the Google Drive plan
(PR #36) and is in `main`. Likewise the cloud-simulation infrastructure
(`SharedCloudBackend`, `CloudSemanticsAdapter`, `CloudProfile`) is public via
`package:kmdb/kmdb_test_cloud_support.dart`. No prerequisite work remains for
this phase; it begins as soon as Phase 4a (the empirical probe) completes.

#### Phase 4a — Empirical CloudKit behaviour probe (must run first)

Build a small, credential-gated probe app (an iOS/macOS test target with a
configured CloudKit container) that records what real CloudKit actually does:

- [ ] Probe **zone-level create atomicity**: two clients simultaneously create
      a `CKRecord` with the **same deterministic record ID** in the same custom
      zone (using fresh local records with no `recordChangeTag`). Does exactly
      one succeed and the other receive `CKError.serverRecordChanged`? What are
      the observed status codes under both `CKModifyRecordsOperation` and the
      convenience `CKDatabase.save()` path?
- [ ] Probe **conditional update atomicity** (`savePolicy:
      .ifServerRecordUnchanged`): concurrent updates to the same record ID with
      the same `recordChangeTag`. Confirm exactly one wins, others receive
      `CKError.serverRecordChanged`.
- [ ] Probe **`CKQuery` consistency**: time-to-visibility of a newly created
      record to a second client via `CKQueryOperation`; whether queries are
      read-your-writes consistent immediately after a save on the same device.
- [ ] Probe **CKAsset upload/download**: maximum observed SSTable size (probe
      at 1MB, 10MB, 50MB); upload latency; whether partial/failed uploads
      leave orphaned assets; whether `savePolicy: .changedKeys` on a record
      with a changed `CKAsset` re-uploads the full asset or diffs.
- [ ] Probe **rate-limit and quota error shapes**: `CKError.requestRateLimited`
      and `CKError.quotaExceeded` — structure, `retryAfterSeconds` field
      availability.
- [ ] **Record all findings in this plan** (a results table) and derive the
      CloudKit `CloudProfile` values and the final `providesAtomicCas` setting
      from them.

#### Phase 4 — Simulator and test suite

- [ ] Implement `FakeICloudSyncChannel` in `test/` over `SharedCloudBackend`
      (from `package:kmdb/kmdb_test_cloud_support.dart`):
  - Implements `ICloudSyncChannel` as an **immediately-consistent, atomic
    functional fake** — it delegates CAS straight to
    `SharedCloudBackend.compareAndSwap` (which is truly atomic) and applies no
    propagation delay. This matches the landed `DriveSimulator` exactly (see
    `packages/kmdb_google_drive/test/support/drive_simulator.dart`).
  - It maps the CloudKit-shaped error contract onto the backend:
    `CKError.unknownItem` → file-not-found (`download`/`getEtag` return `null`,
    `delete` is a no-op), `CKError.serverRecordChanged` → CAS failure
    (`compareAndSwap` returns `false`), and one record per deterministic record
    ID (no duplicate names).
  - **R-4 (Option C) — explicit non-goal:** the fake does **NOT** model the
    non-atomic create-if-absent race window or any eventual-consistency delay.
    Do **not** inject a yield between the existence check and the write, and do
    **not** wrap the backend in `CloudSemanticsAdapter`. The non-atomic /
    eventual-consistency fidelity is modelled only in the
    `kICloudProfile`-parameterised `kmdb_harness` scenario (below, via
    `CloudSemanticsAdapter`) and the deferred real-service soak (RC-Y). This is
    safe because `ConsolidationCoordinator` gates consolidation off entirely
    when `providesAtomicCas == false` (it never reaches a `compareAndSwap`
    call), so there is no split-lease race for an adapter-specific fake to
    reproduce.
- [ ] For the `kmdb_harness` mixed-mode scenario, follow the Drive precedent:
      add a **test-side** `SimulatorICloudQuotaAdapter` in `test/` that
      `implements SyncStorageAdapter, QuotaAwareAdapter` (wrapping an
      `ICloudAdapter` over a `FakeICloudSyncChannel`), deriving
      `safeOperationThreshold` from the iCloud `QuotaProfile` knobs. The
      production `ICloudAdapter` does **not** implement `QuotaAwareAdapter` —
      this keeps `kmdb_icloud`'s production code free of any `kmdb_harness`
      dependency (mirrors `SimulatorQuotaAdapter` in
      `packages/kmdb_google_drive/test/support/drive_simulator.dart`, which
      imports `QuotaAwareAdapter` from `package:kmdb_harness/kmdb_harness.dart`).
- [ ] Fill in `kICloudProfile`'s values (the file/export already exist from
      Phase 3) from the Phase 4a probe results:
      `maxPropagationDelayMs`, `jitterMs`, `quota.maxOpsPerMinute`,
      `atomicConditionalCreate`. Set `ICloudAdapter.providesAtomicCas` from the
      same Phase 4a finding (it should equal `kICloudProfile.atomicConditionalCreate`).
      If zone-level CAS is not confirmed atomic, both are `false` so
      `ConsolidationCoordinator` gates consolidation off (loss-free).
- [ ] Run the H5 adapter conformance suite from
      `package:kmdb/test_support.dart` against the real adapter over
      `FakeICloudSyncChannel`. Signature (verified 2026-06-03):
      `runSyncAdapterConformance({required SyncStorageAdapter Function() factory,
      required bool expectAtomicCas, bool expectsCancellation = false})`. Pass
      `expectAtomicCas: kICloudProfile.atomicConditionalCreate` and
      `expectsCancellation: true` (the adapter honours `ctx?.throwIfExpired()`
      at entry — same as the Drive adapter's invocation in
      `packages/kmdb_google_drive/test/google_drive_adapter_test.dart`).
- [ ] Unit tests for all six `SyncStorageAdapter` methods and zone-bootstrap
      behaviour, driven through `FakeICloudSyncChannel`.
- [ ] Wire real-adapter-over-`FakeICloudSyncChannel` into a `kmdb_harness`
      mixed-mode scenario (per-device adapters; two front-ends over one shared
      backend) and assert convergence.
- [ ] **Pre-release integration test** (skipped by default; enabled by env var
      `ICLOUD_TEST_CONTAINER`): full `SyncEngine` push/pull cycle and the
      contention test against a **real** CloudKit container — confirming the
      simulator's fidelity and the real atomicity behaviour. Not part of
      per-commit CI. The `packages/kmdb_icloud/example/` app (Phase 7) is the
      manual integration test vehicle for this, filling the role that `kmdb_ui`
      integration (Phase 5, deferred) would otherwise provide.
- [ ] Achieve ≥90% line coverage on the Dart parts of the package (via the
      `FakeICloudSyncChannel` path). Swift plugin code is excluded from the
      Dart coverage target.
- [ ] Conformance assertion: add a test that `FakeICloudSyncChannel` passes
      `runSyncAdapterConformance(expectAtomicCas:
      profile.atomicConditionalCreate)`, so the simulator and the adapter's
      `providesAtomicCas` cannot drift.

### Phase 5 — Flutter UI integration (`kmdb_ui`) (deferred)

> Deferred — `kmdb_ui` wiring is out of scope for this plan. The adapter and
> platform channel plugin (Phases 2–4) are self-contained and can be consumed
> directly by any iOS or macOS Flutter app. Key design notes for when the
> `kmdb_ui` settings integration is picked up:
>
> - No sign-in UI is needed; auth is implicit via the user's Apple ID on device.
> - `ICloudSyncChannel.isAvailable()` (checking `FileManager.ubiquityIdentityToken`)
>   should gate whether iCloud sync is offered in settings.
> - Account changes (sign out / different Apple ID) must invalidate the
>   adapter's cached zone state.
> - `ICloudRemoteConfig` (config-only sealed subtype in core `kmdb`,
>   `type == 'icloud'`, field `syncRoot`) can be added at that time following
>   the `GoogleDriveRemoteConfig` pattern.

### Phase 6 — Spec and docs

- [ ] Add `docs/spec/NN_icloud_adapter.md` (next available section number,
      assigned at creation time — see `plans/README.md`) covering: CloudKit
      zone model, ETag strategy, CAS semantics, platform limitations, and the
      Phase 4a probe findings.
- [ ] Record the Phase 4a probe results table in this plan.
- [ ] Register in `docs/spec/28_release_checklist.md`:
  - **RC-X (iCloud behaviour probe)** — empirical Phase 4a results must be
    re-verified after any major iOS/macOS version bump.
  - **RC-Y (iCloud real-service soak)** — full `SyncEngine` convergence
    against real CloudKit, two devices, contention test. Not automated.
  - Use next available RC IDs (currently RC-1 through RC-11 are taken in
    `docs/spec/28_release_checklist.md`, so RC-12 is the next free id —
    re-grep `RC-[0-9]` at implementation time to confirm).
- [ ] Update `docs/roadmap/0_03.md` to mark the Apple iCloud item done.
- [ ] Confirm `kmdb_icloud` (production package) takes **no** dependency on
      `kmdb_harness`.
- [ ] Build out `packages/kmdb_icloud/example/` as a minimal iOS/macOS Flutter
      app that constructs `ICloudAdapter` directly and runs a push/pull cycle.
      This is the primary manual integration test vehicle given that `kmdb_ui`
      integration is deferred — it lets a developer exercise the full stack
      (Dart → method channel → Swift → CloudKit) without a production app.

## Review (2026-06-03, kmdb-plan-reviewer)

**Status set to `Questions`.** This is a strong, well-researched plan — the
CloudKit-vs-iCloud-Drive analysis is genuinely good, the storage model is
concrete, the CAS semantics are correctly reasoned, and the loss-free default
(`providesAtomicCas = false` until Phase 4a) is the right posture. It mirrors
the landed Drive precedent faithfully. Most of what I flagged on this pass I
resolved inline with reviewer defaults (Q-A3, Q-A4, the `ctx` design point, the
profile location, the `providesAtomicCas` mechanics). **Two things keep it off
`Investigated`:** one genuine human gate (Q-A5) and one design gap a mechanical
implementer would otherwise have to invent (R-4, the non-atomic CAS modelling in
the fake). Resolve those two and this is ready.

### Problem statement assessment

Real and worth solving. The spec (`docs/spec/01_overview.md`) explicitly
endorses a CloudKit adapter, and the roadmap (`docs/roadmap/0_03.md`) lists it as
the next cloud adapter after Drive. Scope is well-bounded: CloudKit only (iCloud
Drive correctly excluded with a documented rationale), CLI and `kmdb_ui`
deferred. No concerns.

### Proposed solution assessment

Sound. The `CKRecord` + `CKAsset` storage model maps cleanly onto the
`SyncStorageAdapter` six-method contract, the deterministic record ID gives the
key uniqueness the lease protocol needs, and `recordChangeTag` is a clean ETag.
The decision to gate `providesAtomicCas` on an empirical probe rather than
assuming CloudKit's documented behaviour is exactly the durability-first posture
this codebase demands (cf. the 2026-05-22 review's "don't trust the golden
path"). Strong.

### Architecture fit

Confirmed against the landed code:

- The conformance export (`package:kmdb/test_support.dart`) and cloud-sim export
  (`package:kmdb/kmdb_test_cloud_support.dart`) exist and export exactly what the
  plan claims. Conformance signature verified:
  `runSyncAdapterConformance({required factory, required expectAtomicCas, bool
  expectsCancellation = false})`.
- `CloudProfile` / `QuotaProfile` / `EventualConsistency` constructor shapes
  match the plan's preliminary `kICloudProfile`.
- The Drive precedent is accurately characterised, with one correction (R-5,
  profile location — fixed inline).
- RC-id ledger: verified `docs/spec/28_release_checklist.md` holds RC-1..RC-11;
  **RC-12 is the next free id**, as the plan states. Good.

### Resolved on this pass (reviewer defaults — see inline edits)

- **R-1 (Q-A3):** `ICloudSyncChannel` is the right seam — it puts the cut at the
  Dart/Swift boundary so the real adapter runs in tests, mirroring how Drive
  fakes `http.Client` under `DriveApi`. Resolved.
- **R-2 (Q-A4):** Container ID supplied at construction, not hardcoded. Resolved.
- **R-6 (`ctx`):** Not an open design point. The landed `GoogleDriveAdapter`
  already prescribes the pattern — `ctx?.throwIfExpired()` at each method entry,
  cancellable back-off sleeps — which passes the suite with
  `expectsCancellation: true`. Mid-flight `CKOperation` cancellation is an
  optional enhancement, not a requirement. Resolved inline.
- **R-5 (profile location):** The plan said `kICloudProfile` "ships with the
  simulator (Phase 4)". Wrong: `kGoogleDriveProfile` lives in `lib/` and is
  publicly exported. Moved `kICloudProfile` to `lib/src/icloud_profile.dart`
  (created in Phase 3, exported from `lib/kmdb_icloud.dart`); Phase 4a only fills
  in the numeric values. Resolved inline.
- **R-7 (`providesAtomicCas` mechanics):** Clarified it is a hardcoded getter
  (not a runtime flag), must equal `kICloudProfile.atomicConditionalCreate`, and
  ships `=> false` in Phase 3. Resolved inline.

### Resolved follow-up (2026-06-03)

- **R-3 (Q-A5) — Phase 4a logistics gate. RESOLVED (user, 2026-06-03).** The user
  confirms the project can obtain an Apple developer account with a test CloudKit
  container, and that a dedicated probe target (separate from the main app) is
  acceptable. The Phase 4a empirical probe is unblocked. It remains a human-run
  step that gates the Phase 4 simulator/test track; the Sonnet implementer can
  execute Phases 1–3 (scaffold, platform channel, core adapter) without it, then
  the probe is run by a human before the Phase 4 numbers (`kICloudProfile`
  values, `providesAtomicCas`) are finalised.

### Resolved follow-up (2026-06-03, second pass) — promoted to `Investigated`

- **R-4 — `FakeICloudSyncChannel` consistency/atomicity fidelity. RESOLVED
  (user, 2026-06-03 — Option C).** The fake is an immediately-consistent, atomic
  functional stand-in (matching `DriveSimulator`); it does not model the
  non-atomic create-if-absent race window or any propagation delay. Non-atomic /
  eventual-consistency fidelity lives only in the `kICloudProfile`-parameterised
  harness scenario (via `CloudSemanticsAdapter`) and the deferred real-service
  soak (RC-Y). Confirmed by code inspection: `ConsolidationCoordinator`
  early-returns `ConsolidationState.skippedNonAtomicCas`
  (`packages/kmdb/lib/src/sync/consolidation_coordinator.dart` line 284) **before
  any `compareAndSwap`** when `providesAtomicCas == false`, so with
  `atomicConditionalCreate == false` there is no split-lease race for an
  adapter-specific fake to reproduce — consolidation is gated off, not racing.
  This is the cleanest of the three options I offered and removes the design
  decision from the implementer's plate. Written into the Open questions block
  (R-4) and the Phase 4 checklist (the `FakeICloudSyncChannel` item now states
  the immediately-consistent posture and the explicit "do not inject a race
  window / do not wrap in `CloudSemanticsAdapter`" non-goal).

<details>
<summary>Original R-4 design gap (now resolved by Option C)</summary>

- **R-4 — How does `FakeICloudSyncChannel` model the NON-atomic create-if-absent
  case? (genuine design gap, blocks mechanical implementation).** The plan says
  the fake sits "over `SharedCloudBackend`" and "models the CloudKit semantics
  verified in Phase 4a (... consistency delay ...)". But the landed building
  blocks do not give this for free, and the Drive precedent does *not* actually
  exercise eventual consistency in its simulator:
  - `SharedCloudBackend.compareAndSwap` is **truly atomic** (no `await` between
    check and write); `SharedBackendAdapter.providesAtomicCas => true`.
  - The `DriveSimulator` is a single immediately-consistent in-memory
    `http.Client` fake — it does **not** use `CloudSemanticsAdapter` or a
    visibility cursor. Eventual-consistency modelling is a *harness*-side concern
    layered on via `CloudSemanticsAdapter`, advanced by an explicit synchronous
    `advancePropagationClock()` (there is no awaitable propagation delay — see
    `cloud_semantics_adapter.dart`).

  So if Phase 4a returns `atomicConditionalCreate: false` (the default and, by
  the Drive analogy, the likely outcome), `FakeICloudSyncChannel` cannot simply
  delegate create-if-absent to `SharedCloudBackend.compareAndSwap` — that path is
  atomic and would make the fake *more* consistent than the real service, hiding
  exactly the split-lease class of bug. The plan must specify **one** of:
    1. The fake delegates CAS to `SharedCloudBackend` but injects a race-window
       (a `Future<void>.delayed(Duration.zero)` yield between the existence
       check and the write on the create-if-absent path) when
       `kICloudProfile.atomicConditionalCreate == false` — the same technique
       `CloudSemanticsAdapter` uses at its non-atomic CAS path; **or**
    2. The fake wraps the backend in a `CloudSemanticsAdapter` configured from
       `kICloudProfile`, and the tests drive `advancePropagationClock()`
       explicitly to settle visibility (note: this requires the harness
       convergence test to advance the clock, which the Drive convergence test
       does not need to do — call this out so the implementer doesn't assume
       auto-settling); **or**
    3. The plan accepts (and states) that the in-suite fake is
       immediately-consistent and atomic like `DriveSimulator`, and that the
       non-atomic / eventual-consistency fidelity is verified only by the
       `kICloudProfile`-parameterised harness scenario and the deferred
       real-service soak (RC-Y) — i.e. the fake is a functional stand-in, not a
       semantic one.

  Any of these is defensible, but the plan currently implies semantic fidelity
  ("models ... consistency delay") that the chosen substrate does not
  automatically provide. **Pick one and write it into the Phase 4 checklist**,
  including who advances the propagation clock if option 2. Without this, the
  implementer is left to invent the most subtle and safety-critical part of the
  test harness on the fly — precisely the kind of decision an `Investigated`
  plan must not defer.

</details>

### Minor notes (non-blocking, address during implementation)

- **N-1:** The `upload` mapping is described two ways — the SyncStorageAdapter
  mapping table says the adapter "checks existence first (or tries create then
  falls back to update on conflict)", while the Phase 3 checklist says Swift uses
  `savePolicy: .changedKeys` which "creates if record is new, updates if
  existing". These should be reconciled to one approach; the single-`savePolicy`
  form is simpler and avoids a redundant round-trip. Pin it down so the Swift and
  Dart sides agree, but it is not architecturally load-bearing.
- **N-2:** `list` via `CKQuery` with an `NSPredicate` `BEGINSWITH` on `path`
  requires the `path` field to be queryable, which in CloudKit means it must be
  added to the zone's index (a schema/console concern in the CloudKit Dashboard,
  or `recordType` index config). Phase 4a should confirm string-field
  queryability and the plan/spec should note the index requirement, since a
  missing queryable index is a classic CloudKit "works in dev, empty results in
  prod" trap.
- **N-3:** Swift source "shared via symlink or conditional" (Phase 2) — pick one
  at implementation time; a shared source set referenced by both the `ios/` and
  `macos/` podspecs is the conventional federated-plugin approach and avoids
  symlink portability issues in git.

### Verdict

Status set to **`Investigated`** (2026-06-03, second pass). All open questions
are resolved: Q-A1–Q-A5 and both review blockers (R-3 logistics gate, R-4 fake
fidelity) are closed. R-4 was settled on **Option C** — `FakeICloudSyncChannel`
is an immediately-consistent atomic functional fake matching the Drive
precedent, with non-atomic/eventual-consistency fidelity confined to the
`kICloudProfile`-parameterised harness scenario and the deferred RC-Y soak.
Verified by code inspection that `ConsolidationCoordinator` gates consolidation
off before any `compareAndSwap` when `providesAtomicCas == false`, so there is
no split-lease race for the adapter fake to reproduce.

The plan clears the implementation-readiness bar: named files/classes/methods,
concrete CloudKit storage model and CAS semantics, an ordered phase checklist, a
testing strategy (conformance suite, unit tests, harness convergence,
release-checklist RC-X/RC-Y entries), and the loss-free `providesAtomicCas =>
false` default. The three minor notes (N-1 upload mapping reconciliation, N-2
`path` field queryability/index, N-3 Swift shared-source mechanism) are
non-blocking and flagged for the implementer to settle in place.

**One sequencing reminder for the implementer (not a blocker):** Phases 1–3
(scaffold, platform channel, core adapter shipping `providesAtomicCas => false`
and preliminary `kICloudProfile`) are fully mechanical and proceed now. The
Phase 4 numeric finalisation (`kICloudProfile` values, flipping
`providesAtomicCas`) is gated on the **human-run Phase 4a probe** — that is an
external dependency, not an unresolved design decision, so it does not hold the
plan off `Investigated`.

## Summary

{Dot points highlighting the work undertaken}
