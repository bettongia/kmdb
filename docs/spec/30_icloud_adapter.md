# §30 Apple iCloud Adapter (CloudKit)

The `kmdb_icloud` package provides `ICloudAdapter`, a `SyncStorageAdapter`
implementation backed by Apple's CloudKit framework. It gives iOS and macOS
users zero-infrastructure sync tied to their existing iCloud account — no OAuth
flow, no separate sign-up, no credential storage.

## Package placement

`ICloudAdapter` lives in `packages/kmdb_icloud/`, a separate pub workspace
member. CloudKit requires the Flutter `MethodChannel` machinery (the Dart side
calls a native Swift plugin); this cannot run in a pure Dart CLI binary. The
adapter is therefore iOS/macOS Flutter only.

The package is **not** part of core `kmdb` — consumers opt in by adding
`kmdb_icloud` to their `pubspec.yaml`, matching the `kmdb_google_drive` pattern.

## Platform scope

| Platform | Supported |
| -------- | --------- |
| iOS      | ✅        |
| macOS    | ✅        |
| Android  | No        |
| Web      | No        |
| Windows  | No        |
| Linux    | No        |

CloudKit requires Apple platforms and an iCloud-capable Apple ID. Users who need
cross-platform sync should use the Google Drive adapter (§29) instead.

The CLI (`kmdb_cli`) is out of scope. A macOS Dart CLI binary cannot use Flutter
method channels; FFI to a native Swift library would be required and is not
implemented.

## Authentication

No explicit sign-in is required. CloudKit uses the iCloud account already
configured on the device (`Settings → [Apple ID]`) as the credential. The
adapter contains no token storage and performs no browser redirects.

`ICloudSyncChannel.isAvailable()` (checking `FileManager.ubiquityIdentityToken`)
should be called by the host app to determine whether iCloud sync can be offered
to the user. If the user is not signed in to iCloud, CloudKit operations will
fail with a `CKError.notAuthenticated` error.

## CloudKit storage model

Each KMDB sync file is stored as a `CKRecord` of type `"KMDBSyncFile"` in a
custom private zone:

```
CKContainer: <containerIdentifier>
└── Private Database
    └── Custom Zone: "kmdb-{syncRoot}"
        ├── KMDBSyncFile:{path}
        │   ├── path: String    (full relative path, e.g. "sstables/abc.sst")
        │   └── content: Asset  (file bytes)
        │   recordChangeTag → ETag
        ├── KMDBSyncFile:sstables/...
        ├── KMDBSyncFile:highwater/...
        └── KMDBSyncFile:.consolidation-lease
```

**Record ID strategy:** `CKRecord.ID(recordName: {path}, zoneID: zone.zoneID)`.
Each "file" has a globally unique, deterministic key within the zone. CloudKit
guarantees at most one record per `recordID` per zone, which is the uniqueness
property the lease protocol requires.

**Zone naming:** `"kmdb-{syncRoot}"`. One zone is created per `syncRoot` value
supplied at adapter construction time. The zone is created lazily on first use;
once confirmed to exist, its `CKRecordZone.ID` is cached in memory.

**Isolation boundaries:** There are two levels of separation:

- **Container** — scoped to the app's bundle ID (`iCloud.<bundle-id>`). CloudKit
  enforces complete isolation between containers: no app can read another app's
  container, even on the same device. Each app that embeds `kmdb_icloud`
  therefore has its own container, and its sync data is invisible to all other
  apps.

- **Zone** — scoped to `syncRoot` within a container. An app that manages
  multiple independent KMDB databases (e.g. `"work"` and `"personal"`) gives
  each a distinct `syncRoot`, resulting in separate zones (`kmdb-work`,
  `kmdb-personal`) within the same container. All devices running the same app
  with the same `syncRoot` converge on the same zone.

For the common case of a single-database app, one fixed `syncRoot` value (e.g.
`"main"`) is sufficient.

## Sync folder layout

The logical layout is identical to all other adapters:

```
{syncRoot}/
  highwater/
    {deviceId}.hwm
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst
    {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst
  .consolidation-lease
```

The `{syncRoot}` name becomes the CloudKit zone suffix (`"kmdb-{syncRoot}"`).
The path strings stored in `path` fields and used as record names follow the
same layout (e.g. `"sstables/abc-123-456.sst"`).

## ETag strategy

CloudKit assigns an opaque `recordChangeTag` to every `CKRecord` on each
successful save. This string is used directly as the adapter's ETag: it changes
on every write, it is stable for a given record revision, and it is available in
record metadata without downloading the `CKAsset`.

`getEtag` fetches record metadata with `desiredKeys: []` (no asset download) and
returns the `recordChangeTag`, or `null` if the record does not exist.

## Conditional writes (CAS)

| Operation                                | CloudKit mechanism                                                               | Atomic?              |
| ---------------------------------------- | -------------------------------------------------------------------------------- | -------------------- |
| Create-if-absent (`ifMatchEtag == null`) | Save fresh record with nil `recordChangeTag`, `savePolicy: .allKeys`             | **Pending Phase 4a** |
| Update-if-match (`ifMatchEtag != null`)  | Save record with known `recordChangeTag`, `savePolicy: .ifServerRecordUnchanged` | **Yes**              |

### Create-if-absent

A fresh local `CKRecord` (no `recordChangeTag`) is saved with
`savePolicy: .allKeys`. If the server already has a record with the same
`recordID`, CloudKit returns `CKError.serverRecordChanged` (the nil local tag
conflicts with the existing server tag) — the adapter returns `false`. If no
record exists, it is created and the adapter returns `true`.

Whether CloudKit's zone-level sequencing guarantees exactly one winner among
simultaneous creates with the same `recordID` is an empirical question. This
behaviour **must be verified** in the Phase 4a probe before
`ICloudAdapter.providesAtomicCas` is set to `true`. Until then it ships as
`false` (loss-free posture: `ConsolidationCoordinator` skips consolidation).

### Update-if-match

A local `CKRecord` carrying the known server `recordChangeTag` is saved with
`savePolicy: .ifServerRecordUnchanged`. If the server tag has changed, CloudKit
returns `CKError.serverRecordChanged` — the adapter returns `false`. If the tag
still matches, the write succeeds and the adapter returns `true`. This path is
atomic and documented by Apple.

### Phase 4a probe results

> **Placeholder — to be filled in after the empirical probe.** See the Phase 4a
> checklist in `docs/plans/plan_icloud_sync.md`.

| Behaviour                                                                 | Observed |
| ------------------------------------------------------------------------- | -------- |
| Concurrent create same record ID → exactly one winner                     | TBD      |
| `savePolicy: .ifServerRecordUnchanged` → only one winner                  | TBD      |
| Read-your-writes consistency (`CKQueryOperation` after save, same device) | TBD      |
| Other-device propagation delay                                            | TBD      |
| Max observed SSTable size (probe at 1 MB, 10 MB, 50 MB)                   | TBD      |
| `CKError.requestRateLimited` shape, `retryAfterSeconds` present           | TBD      |
| `CKError.quotaExceeded` shape                                             | TBD      |

These values will be encoded in `kICloudProfile` (in
`packages/kmdb_icloud/lib/src/icloud_profile.dart`) and `providesAtomicCas` will
be updated to reflect the create-if-absent atomicity finding.

## Rate limiting and back-off

The adapter retries on `CKError.requestRateLimited` using exponential back-off
with full jitter, honouring the `retryAfterSeconds` hint from the error's
`userInfo` dictionary when present. The back-off loop calls
`ctx?.throwIfExpired()` at each boundary so a cancelled sync context aborts
cleanly.

## Developer setup

This section describes the one-time steps required to configure CloudKit before
running the adapter in development or running the Phase 4a empirical probe.

### 1. Apple Developer Program membership

CloudKit requires an active Apple Developer Program membership
(https://developer.apple.com/programs/). The free Xcode signing tier does not
provide CloudKit access.

### 2. Create a CloudKit container in Xcode

CloudKit containers are created through Xcode, not through the Apple Developer
portal web UI.  The portal reflects what Xcode registers; CloudKit Dashboard
is used only for schema management (step 3).

1. Open the example app's Xcode workspace:
   `packages/kmdb_icloud/example/macos/Runner.xcworkspace`.
2. Select the target → **Signing & Capabilities**.
3. Click **+ Capability** and add **iCloud**.
4. Under the iCloud capability, tick **CloudKit**.
5. Under **Containers**, click **+** to add a new container.  Enter an
   identifier of the form `iCloud.<bundle-id>`, e.g.
   `iCloud.au.com.bettongia.kmdb`.  For development/probe work a dedicated
   container such as `iCloud.au.com.bettongia.kmdb.probe` is recommended to
   keep test data separate from any production container.
6. Xcode registers the container with Apple's servers and updates the target's
   entitlements file automatically:

   ```xml
   <key>com.apple.developer.icloud-services</key>
   <array>
       <string>CloudKit</string>
   </array>
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array>
       <string>iCloud.au.com.bettongia.kmdb.probe</string>
   </array>
   ```

The container identifier (e.g. `iCloud.au.com.bettongia.kmdb.probe`) is the
value passed as `containerIdentifier` to `PlatformICloudSyncChannel` at
construction time.

> **Adding the container to an existing app:** If the container already exists
> (e.g. you are integrating `kmdb_icloud` into an app that already uses
> CloudKit), select the existing container from the list in step 5 rather than
> creating a new one.

### 3. Configure the CloudKit Dashboard schema

Before the adapter can perform `list` queries, the `KMDBSyncFile` record type
and its `path` field index **must** be configured in CloudKit Dashboard
(https://icloud.developer.apple.com/).  A missing queryable index causes
`CKQuery` with an `NSPredicate` `BEGINSWITH` on `path` to silently return
empty results in production — this is a classic CloudKit "works in
development, empty results in production" trap (plan note N-2).

**Steps:**

1. Open CloudKit Dashboard and select your container.
2. Select the environment: **Development** for initial setup; repeat for
   **Production** before shipping.
3. Under **Schema → Record Types**, click **+ Add Record Type** and enter
   `KMDBSyncFile`.
4. Add the following fields to `KMDBSyncFile`:

   | Field name | Type   | Notes                                     |
   | ---------- | ------ | ----------------------------------------- |
   | `path`     | String | Full relative path, e.g. `sstables/x.sst` |
   | `content`  | Asset  | File bytes                                |

5. For the `path` field, click the field row and enable **Queryable** (and
   **Sortable** if you want sorted results, though KMDB does not require it).
   Without this, `NSPredicate(@"path BEGINSWITH %@", ...)` will always return
   zero results.
6. Click **Save Changes**.

> **Note:** CloudKit schema changes in the Development environment can be
> deployed to Production via **Deploy to Production** in Dashboard once the
> schema is stable.  The `KMDBSyncFile` record type and the `path` queryable
> index must be present in Production before the adapter is shipped to end
> users.

### 4. Construct the adapter

Pass the container identifier to `PlatformICloudSyncChannel` and the channel to
`ICloudAdapter`:

```dart
import 'package:kmdb_icloud/kmdb_icloud.dart';

final channel = PlatformICloudSyncChannel(
  containerIdentifier: 'iCloud.au.com.bettongia.kmdb',
  syncRoot: 'my-sync-root',
);
final adapter = ICloudAdapter(channel: channel, syncRoot: 'my-sync-root');
```

The zone `"kmdb-my-sync-root"` is created lazily in the container's private
database on first use.

The example app (`packages/kmdb_icloud/example/lib/main.dart`) has a
`_containerIdentifier` constant at the top of `_ProbePage` — update this to
match the container identifier you registered in Xcode before running.

### 5. Phase 4a probe app setup

The Phase 4a empirical probe requires a dedicated iOS or macOS target (separate
from the main app) configured against a **test CloudKit container** (e.g.
`iCloud.au.com.bettongia.kmdb.probe`). Follow steps 1–4 above using the probe
container identifier, then follow the Phase 4a checklist in
`docs/plans/plan_icloud_sync.md` to run the atomicity, consistency, and
rate-limit probes. Record all results in the plan and in the Phase 4a probe
results table above before proceeding to Phase 4 implementation.

## Test infrastructure

> **Phase 4 is gated on the Phase 4a empirical probe.** The test infrastructure
> described here will be implemented once the probe results are recorded.

### `FakeICloudSyncChannel`

`FakeICloudSyncChannel` (in `packages/kmdb_icloud/test/`) is an
immediately-consistent, atomic functional fake that implements
`ICloudSyncChannel` over `SharedCloudBackend` (from
`package:kmdb/kmdb_test_cloud_support.dart`). It mirrors `DriveSimulator`
exactly — it does **not** inject a race window or model propagation delay.
Non-atomic / eventual-consistency fidelity is provided by the
`kICloudProfile`-parameterised `kmdb_harness` scenario via
`CloudSemanticsAdapter`.

### Conformance suite

`runSyncAdapterConformance` (exported from `package:kmdb/test_support.dart`) is
run against the real `ICloudAdapter` over `FakeICloudSyncChannel` with:

```dart
runSyncAdapterConformance(
  factory: () => ICloudAdapter(channel: FakeICloudSyncChannel(), syncRoot: 'test'),
  expectAtomicCas: kICloudProfile.atomicConditionalCreate,
  expectsCancellation: true,
);
```

### `SimulatorICloudQuotaAdapter`

`SimulatorICloudQuotaAdapter` (test tree only, `kmdb_harness` dependency) wraps
`ICloudAdapter` and implements `QuotaAwareAdapter`, mirroring
`SimulatorQuotaAdapter` in `kmdb_google_drive`. The production `ICloudAdapter`
does **not** implement `QuotaAwareAdapter`.

## Release checklist items

RC-12 and RC-13 are registered in `docs/spec/28_release_checklist.md`:

- **RC-12 (iCloud behaviour probe)** — the Phase 4a empirical results must be
  re-verified after any major iOS/macOS version bump.
- **RC-13 (iCloud real-service soak)** — full `SyncEngine` convergence against a
  real CloudKit container, two devices, contention test. Not automated.
