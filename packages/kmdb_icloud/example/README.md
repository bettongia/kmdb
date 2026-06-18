# kmdb_icloud Example — Phase 4a Probe Runner

A macOS Flutter app for running empirical probes against a real CloudKit
container. Use it to validate the behaviour of `ICloudAdapter` before setting
`providesAtomicCas = true` in the production package.

**Platform:** macOS only (CloudKit requires Apple platforms and an active iCloud
account).

---

## What this app does

The app runs four targeted probes, each streaming its log output to a scrollable
pane in the UI:

| Button | Probe | What it measures |
|---|---|---|
| **Basic sync** | `runICloudSyncExample` | Upload → list → download → getEtag → delete. Checks read-your-writes consistency of `ICloudAdapter.list` immediately after upload. |
| **CAS probe** | `runCasProbe` | Exercises `compareAndSwap` in four scenarios: create-if-absent (absent), create-if-absent (present), update with correct ETag, update with stale ETag. |
| **Large files** | `runLargeFileProbe` | Uploads and downloads 1 MB, 10 MB, and 50 MB payloads. Records timing and verifies byte-for-byte integrity. |
| **List propagation delay** | `runListPropagationProbe` | Uploads a record then polls `list` every 2 s (up to 30 s) to measure how long a newly created record takes to appear in a CKQuery on the same device. |

---

## Prerequisites

### 1. iCloud sign-in

The device must be signed in to iCloud (`System Settings → [Apple ID]`). CloudKit
uses the existing account — no OAuth flow or credential storage is needed.

### 2. Xcode — add the iCloud capability

1. Open `macos/Runner.xcworkspace` in Xcode.
2. Select the **Runner** target → **Signing & Capabilities**.
3. Click **+ Capability** and add **iCloud**.
4. Under **CloudKit**, tick **CloudKit** and create (or select) a container, e.g.
   `iCloud.com.bettongia.kmdb.probe`.
5. Make sure the container identifier matches `_containerIdentifier` in
   `lib/main.dart`.

### 3. CloudKit Dashboard — create the record type

In the [CloudKit Dashboard](https://icloud.developer.apple.com):

1. Select your container and switch to the **Development** environment.
2. Go to **Data → Record Types** and create `KMDBSyncFile` with these fields:

   | Field name | Type | Index |
   |---|---|---|
   | `path` | String | Queryable |
   | `content` | Asset | — |

3. Save. The custom zone (`kmdb-example-sync`) is created lazily by the adapter
   on first use.

### 4. Container identifier

The app is pre-configured with:

```
containerIdentifier = 'iCloud.com.bettongia.kmdb.probe'
syncRoot            = 'kmdb-example-sync'
```

Update the constants in `lib/main.dart` (`_ProbePage._containerIdentifier` and
`_ProbePage._syncRoot`) if your container has a different name.

---

## Running the app

```bash
cd packages/kmdb_icloud/example
flutter run -d macos
```

Press any probe button to run it. Results stream into the log pane in real time.
The previous log is cleared each time a new probe starts.

---

## Interpreting results

### Basic sync

Look for read-your-writes consistency: the uploaded file should appear in the
`list` result immediately (same device, same CloudKit container). If it does not,
the list propagation probe measures how long the delay is.

### CAS probe

Each step logs `result: <bool> (expected: <bool>)`. A passing run shows:

```
CAS create-if-absent (no record) …   result: true  (expected: true)
CAS create-if-absent (record exists) …  result: false (expected: false)
CAS update-if-match with correct ETag …  result: true  (expected: true)
CAS update-if-match with stale ETag …   result: false (expected: false)
```

Note: these are single-device sequential tests. True concurrent atomicity
(two devices racing on the same record) requires running this probe on two
devices simultaneously — see §30 of the KMDB spec.

### Large files

Timing and integrity check per size tier (1 MB / 10 MB / 50 MB). A passing run
ends each tier with `Integrity OK.`

### List propagation delay

The probe reports the elapsed milliseconds from upload to first appearance in
`list`. If the record is still absent after 30 s it reports `NOT visible`.

---

## Relationship to `providesAtomicCas`

`ICloudAdapter` currently ships with `providesAtomicCas = false` (a safe
default). Once the CAS probe confirms CloudKit's atomic create-if-absent
behaviour across two devices, `providesAtomicCas` will be set to `true` and
`kICloudProfile` will be updated with the measured consistency values.

See the parent package README (`packages/kmdb_icloud/README.md`) and
`docs/spec/30_icloud_adapter.md` for the full design and Phase 4a context.
