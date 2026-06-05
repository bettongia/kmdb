# kmdb_icloud

Apple iCloud (CloudKit) sync adapter for [KMDB](https://github.com/bettongia/kmdb) — a
`SyncStorageAdapter` implementation that backs the KMDB sync protocol against
Apple's CloudKit framework.

**Platform:** iOS and macOS only. CloudKit requires an active iCloud account on
the device. Android, web, Windows, and Linux callers should use the Google Drive
adapter instead.

---

## Overview

`package:kmdb_icloud` provides `ICloudAdapter`, which implements
`SyncStorageAdapter` from `package:kmdb`. Drop it in wherever KMDB expects a
sync backend:

```dart
await db.sync(syncAdapter: adapter);
```

No sign-in UI is needed — the user's existing iCloud sign-in on the device is
the credential. The adapter uses the CloudKit private database of the app's
configured container.

---

## Sync storage model

Each KMDB sync file is stored as a `CKRecord` of type `"KMDBSyncFile"` in a
custom private zone within the app's CloudKit container:

```
CKContainer: <containerIdentifier>       (e.g. iCloud.au.com.bettongia.kmdb)
└── Private Database
    └── Custom Zone: "kmdb-<syncRoot>"   (one zone per syncRoot name)
        ├── KMDBSyncFile:sstables/...
        ├── KMDBSyncFile:highwater/...
        └── KMDBSyncFile:.consolidation-lease
```

The `recordChangeTag` from each `CKRecord` is used as the adapter's ETag,
enabling atomic conditional updates via CloudKit's `savePolicy:
.ifServerRecordUnchanged`.

---

## `providesAtomicCas == false` — what it means

The `atomicConditionalCreate` behaviour of CloudKit (whether zone-level
serialisation guarantees a single winner for concurrent first-time record
creates with the same deterministic record ID) requires empirical verification
against the real CloudKit service (Phase 4a of the implementation plan). Until
that probe is complete, the adapter conservatively ships with:

```
providesAtomicCas == false
```

This causes `ConsolidationCoordinator` to skip consolidation rather than risk a
split-lease data loss. Once Phase 4a confirms CloudKit's atomic create-if-absent
behaviour, `providesAtomicCas` will be set to `true` and `kICloudProfile` will
be updated with the measured consistency values.

Conditional **update** (when `ifMatchEtag != null`) **is** atomic on CloudKit:
the adapter uses `savePolicy: .ifServerRecordUnchanged`, and CloudKit returns
`CKError.serverRecordChanged` if the record's `recordChangeTag` has changed
since the local copy was fetched.

---

## Minimal usage snippet

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_icloud/kmdb_icloud.dart';

Future<void> syncWithICloud({
  required KmdbDatabase db,
  required String containerIdentifier,
}) async {
  final channel = PlatformICloudSyncChannel(
    containerIdentifier: containerIdentifier,
  );
  final adapter = ICloudAdapter(
    channel: channel,
    syncRoot: 'myapp-kmdb-sync',
  );

  await db.sync(syncAdapter: adapter);
}
```

---

## CloudKit container setup

Before using this adapter, configure your CloudKit container in the Apple
Developer portal and Xcode:

1. Enable CloudKit capability in your iOS/macOS target.
2. Create or select a CloudKit container (e.g. `iCloud.au.com.bettongia.kmdb`).
3. In the CloudKit Dashboard, create a record type `KMDBSyncFile` with a
   `path` String field (queryable) and a `content` Asset field.
4. Pass the container identifier to `PlatformICloudSyncChannel`.

The adapter creates the custom zone (`kmdb-<syncRoot>`) lazily on first use.

---

## Phase 4a empirical probe

The `kICloudProfile` constant in this package carries **preliminary**
placeholder values for `maxPropagationDelayMs`, `jitterMs`, `maxOpsPerMinute`,
and `atomicConditionalCreate`. These values are finalised by a human-run
empirical probe against the real CloudKit service (see the implementation plan
`docs/plans/plan_icloud_sync.md`). Until the probe is complete:

- `atomicConditionalCreate: false` (loss-free default)
- `maxPropagationDelayMs` and `jitterMs` are conservative upper-bound estimates
- `maxOpsPerMinute` is a conservative default; real CloudKit rate limits depend
  on the container subscription type

---

## License

Apache 2.0 — see the root [LICENSE](../../LICENSE) file.
