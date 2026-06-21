# Test Harness

## Purpose and scope

The `kmdb_harness` package is a developer-only test harness for KMDB's
multi-device sync protocol. It orchestrates multiple independent KMDB device
instances, drives them with a seeded action generator, captures every write and
sync event, and verifies that each device reaches the expected post-sync state.

**Vault testing is explicitly out of scope.** The harness does not configure a
`VaultStore`, does not generate Vault URIs, and does not exercise any Vault code
paths. Vault-specific harness scenarios are deferred to a future plan.

The harness is not shipped to end users. It is a path dependency on
`packages/kmdb` and is excluded from the melos release bundle.

---

## Actor architecture

The harness is composed of four plain Dart classes (referred to as "actors").
Presets 1–4 run entirely within a single Dart isolate using async concurrency.
Preset 5 is a separate stress mode that spawns real isolates.

### TestManager

Orchestrates the full lifecycle: configuration validation and quota checking,
actor construction, pre-seeding, the timed run loop, graceful shutdown, drain,
reconciliation, and report emission. It is the single entry point for a harness
run. It accepts a `HarnessConfig` and an optional seed override for exact-replay
runs.

**Lifecycle stages:**

1. **Validate** — quota check, configuration sanity.
2. **Setup** — create devices, open databases.
3. **Pre-seed** — write initial data to selected devices and sync to the shared
   remote.
4. **Run** — drive devices with the `UserAgent` for `config.duration`.
5. **Drain** — process any pending actions.
6. **Reconcile** — build the `HarnessReport` from the `ReconciliationAgent`.
7. **Teardown** — close all databases.

### UserAgent

Generates the action sequence for each device using a seeded `dart:math Random`
instance. The seed is stored in the `HarnessReport` so any failing run can be
replayed exactly by supplying the same seed. In fuzz mode (seed is `null`), the
seed is derived from the system clock at construction time.

The `UserAgent` drives devices exclusively through the public
`KmdbDatabase`/`KmdbCollection` API. This is a hard requirement; the harness
does not call internal KMDB methods.

Action types:

| Action             | Description                                                     |
| ------------------ | --------------------------------------------------------------- |
| `CreateDb`         | Initialises a new `KmdbDatabase` on the device                  |
| `CreateCollection` | Creates a named `KmdbCollection` on an initialised device       |
| `Put`              | Writes a generated document to a randomly-selected key pool     |
| `Get`              | Reads a document by key                                         |
| `Delete`           | Deletes a document                                              |
| `Sync`             | Triggers push/pull with the remote sync adapter                 |
| `NetworkPartition` | Injects or restores a connectivity failure on the target device |

### Device

Wraps a single `KmdbDatabase` instance. Maintains a finite state machine (FSM)
that guards against invalid action sequences:

```
Uninitialised → (CreateDb) → Initialised → (CreateCollection) → Ready
```

A `Ready` device accepts all action types. An action that cannot be applied in
the current FSM state is recorded as a no-op and forwarded to the
`ReconciliationAgent` with `type: noOp` — the expected-state model is not
advanced. This prevents spurious failures when the `UserAgent` issues an action
that is valid but inapplicable in the current device state.

Each device emits every action and its `ActionResult` to the
`ReconciliationAgent` immediately after execution. `Device.execute()` returns
the `ActionResult` so callers can also inspect it directly.

Network partitions are simulated at the `SyncStorageAdapter` layer via a
`PartitionableAdapter` wrapper. When partitioned, all adapter methods throw
`NetworkPartitionException`, causing sync to record `syncCompleted: false`
without crashing the harness.

### ReconciliationAgent

Maintains two append-only in-memory logs and is the harness's source of truth:

**Write log**:
`(actionId, deviceId, collectionName, key, hlcEncoded, document, isDelete)`

**Sync log**: `(actionId, deviceId, direction, sstablesTransferred, completed)`

From these logs the agent computes two views of expected state:

- **Per-device expected state** — all local writes by the device plus all writes
  received via completed pulls, with LWW (max HLC) applied per key.
- **Global expected state** — LWW winner across all writes on all devices — the
  state every device converges to once fully synced.

Syncs interrupted by a network partition are recorded with `completed: false`
and do not advance the receiving device's expected state. Only completed pulls
move the boundary.

**Fork detection** — when two devices have both written to the same key between
their last common sync point, the agent records a `ForkEvent`:

```dart
ForkEvent {
  collectionName,
  key,
  writeA: WriteLogEntry,
  writeB: WriteLogEntry,
  lwwWinner: WriteLogEntry,  // entry with higher HLC (or higher deviceId on tie)
}
```

Fork events appear in the `HarnessReport` regardless of pass/fail status.

---

## Configuration knobs

| Knob                   | Type                                | Default     | Notes                                                                                                                    |
| ---------------------- | ----------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| `deviceCount`          | `int`                               | 3           | Total simulated devices                                                                                                  |
| `preSeededDeviceCount` | `int`                               | 1           | Devices initialised with data before run starts                                                                          |
| `collectionCount`      | `int`                               | 10          | Collections created per device                                                                                           |
| `duration`             | `Duration`                          | 10 minutes  | Total test run time                                                                                                      |
| `velocityPreset`       | `VelocityPreset?`                   | `null`      | Convenience preset; `null` = supply knobs manually                                                                       |
| `actionsPerMinute`     | `int?`                              | from preset | Per-active-device write/read rate                                                                                        |
| `simultaneousDevices`  | `int?`                              | from preset | Devices active concurrently                                                                                              |
| `syncIntervalSeconds`  | `int?`                              | from preset | Time-driven sync trigger                                                                                                 |
| `syncAfterWrites`      | `int?`                              | from preset | Write-count-driven sync trigger                                                                                          |
| `syncAdapter`          | `SyncStorageAdapter?`               | —           | Single shared adapter for all devices (convenience form). Mutually exclusive with `syncAdapterFactory`.                  |
| `syncAdapterFactory`   | `SyncStorageAdapter Function(int)?` | —           | Per-device adapter factory. Called once per device with the 0-based device index. Mutually exclusive with `syncAdapter`. |
| `prngseed`             | `int?`                              | `null`      | Fixed seed for seeded mode; `null` = fuzz mode                                                                           |
| `keyPoolRatios`        | `KeyPoolRatios`                     | 50/40/10    | Shared / device-local / hot key mix                                                                                      |
| `docSizeDistribution`  | `DocSizeDistribution`               | 60/30/10    | Small / medium / large document mix                                                                                      |

Exactly one of `syncAdapter` or `syncAdapterFactory` must be set; providing both
or neither raises `ArgumentError`. The convenience helper
`resolveAdapter(deviceId)` returns the adapter for a given device index,
handling both forms transparently.

At least one of `syncIntervalSeconds` or `syncAfterWrites` must be set (either
directly or via a `velocityPreset`). A `velocityPreset` of `null` with no sync
trigger configured raises `ArgumentError` at construction time.

### Velocity presets

| Preset | Actions/min/device | Simultaneous devices | Sync interval | Sync after N writes |
| ------ | ------------------ | -------------------- | ------------- | ------------------- |
| 1      | 2                  | 1                    | 300 s         | 20                  |
| 2      | 5                  | 1–2                  | 120 s         | 15                  |
| 3      | 10                 | ⌊N/2⌋                | 60 s          | 10                  |
| 4      | 30                 | N−1                  | 30 s          | 5                   |
| 5      | 120                | N (real isolates)    | 10 s          | 3                   |

Individual knobs always override preset values. Presets 1–4 use single-isolate
async concurrency. Preset 5 spawns real Dart isolates; flakiness detection is
not applicable in preset 5.

---

## Expected-state model and correctness guarantee

The `ReconciliationAgent` builds the expected state incrementally as actions
execute, without looking ahead. Its correctness guarantee is:

> For any key K in any collection C on device D: the expected state of D for K
> is the LWW winner (highest HLC, ties broken by highest device ID) among all
> writes to K that D has either (a) performed locally, or (b) received via a
> **completed** pull from the shared remote.

This model is conservative: it never attributes knowledge of a write to a device
until a completed sync is recorded. A sync that is interrupted by a
`NetworkPartitionException` is stored with `completed: false` and does not
advance the expected state.

The global expected state is the LWW winner across all writes from all devices
and represents the state every device should converge to after a full sync.

---

## Fork detection algorithm

A fork occurs when two devices have both written to the same `(collection, key)`
pair between their last common sync point (i.e., without either device having
pulled the other's write first).

The `ReconciliationAgent` detects a fork when it processes a write entry and
finds that another device has already written to the same key since that
device's last completed pull. When a fork is detected:

1. A `ForkEvent` is created capturing both writes and the LWW winner.
2. The event is appended to `forkEvents`.
3. After the next completed sync, the agent verifies that the actual value (as
   read from the device) matches the LWW winner. A mismatch is a test failure.

---

## Test data generation

All documents share a fixed schema:

| Field    | Type           | Notes                      |
| -------- | -------------- | -------------------------- |
| `title`  | `String`       | Short random text          |
| `body`   | `String`       | Variable-length; size tier |
| `count`  | `int`          | Random integer             |
| `active` | `bool`         | Random boolean             |
| `tags`   | `List<String>` | 0–5 random short strings   |

There is no `attachment` / Vault URI field. The Large size tier is achieved
entirely through an extended `body` string — no blob or Vault interaction.

### Size tiers

| Tier   | Approximate encoded size | `body` length  |
| ------ | ------------------------ | -------------- |
| Small  | ~100 B                   | ~60 chars      |
| Medium | ~10 KB                   | ~6 000 chars   |
| Large  | ~500 KB                  | ~300 000 chars |

### Key pools

| Pool         | Description                                                             |
| ------------ | ----------------------------------------------------------------------- |
| Shared       | Pre-distributed to all devices; writes deliberately collide for LWW     |
| Device-local | Owned by a single device; tests non-conflicting write arrival on peers  |
| Hot          | Small shared subset at high write frequency; exercises rapid-succession |

Keys are deterministic UUIDv7 hex strings derived from the pool label and index
— they are reproducible across runs with the same configuration, regardless of
PRNG seed.

### PRNG modes

- **Seeded mode** — supply `prngseed` (or `--seed` on the CLI). The same seed
  always produces the same document content, enabling exact replay of a failing
  run.
- **Fuzz mode** — omit the seed. The seed is derived from the system clock at
  construction time and recorded in the `HarnessReport` for replay.

---

## Per-device adapters and cloud-backend simulation

### Why per-device adapters?

Real devices each instantiate their own adapter — their own auth context,
folder-ID metadata cache, and session state — against the same remote. The
original `syncAdapter` field shared a single instance across all simulated
devices, hiding an entire class of bugs (e.g. a stale per-device cache shared
across "devices" that masks bugs that only occur per-device).

The `syncAdapterFactory: SyncStorageAdapter Function(int deviceId)` parameter
allows each simulated device to receive its own adapter instance. All instances
should front the same `SharedCloudBackend` to ensure they share a logical
remote.

### `SharedCloudBackend` and front-end adapters

`SharedCloudBackend` (`package:kmdb/kmdb_test_cloud_support.dart`) is the
canonical in-memory backing store for multi-device tests. It owns a file map
where every write is stamped with a monotonically-increasing global `writeSeq`.
All per-device adapters reference the same backend object.

Two front-end adapter types are provided:

| Front-end               | Type                            | Consistency                                      | `providesAtomicCas`                        |
| ----------------------- | ------------------------------- | ------------------------------------------------ | ------------------------------------------ |
| `SharedBackendAdapter`  | Strongly-consistent direct view | All writes immediately visible                   | `true`                                     |
| `CloudSemanticsAdapter` | Eventual-consistency decorator  | Writes visible after `advancePropagationClock()` | per `CloudProfile.atomicConditionalCreate` |

### `CloudProfile`

Each cloud provider package ships a `CloudProfile` instance describing its
observable behaviour. The profile drives:

- The `CloudSemanticsAdapter`'s propagation delay and CAS-atomicity simulation.
- The reconciliation oracle's visibility model (via `visibleWriteSeqHigh`).
- The simulator's 429/503 rate-limit injection (descriptive only — no
  `kmdb`-side `QuotaAwareAdapter` is introduced).

Two built-in profiles ship with the framework:

| Profile                                           | Consistency | `providesAtomicCas` | Use case                      |
| ------------------------------------------------- | ----------- | ------------------- | ----------------------------- |
| `CloudProfile.strong()`                           | Strong      | `true`              | Baseline (existing behaviour) |
| `CloudProfile.eventual(maxPropagationDelayMs: N)` | Eventual    | `false`             | Delayed-visibility scenarios  |

Provider-specific profiles (e.g. a Drive profile with
`allowsDuplicateNames: true`) ship in their respective provider packages.

### Mixed-mode: one remote, two views

"Mixed-mode" means one shared `SharedCloudBackend` accessed by two different
adapter front-ends — for example, device 0 reaches it via a
`CloudSemanticsAdapter` (simulating REST access) while device 1 reaches it via a
`SharedBackendAdapter` (simulating FS-like access). This tests that a file
written via REST is correctly seen by the FS-view device and vice versa.

**True FS-and-REST-bridged-to-different-stores is not a real deployment** — a
user picks one remote — so the harness never synthesises a bridge between
distinct stores.

```dart
final backend = SharedCloudBackend();
final config = HarnessConfig(
  syncAdapterFactory: (deviceId) {
    if (deviceId == 0) {
      return CloudSemanticsAdapter(
        backend: SharedBackendAdapter(backend, deviceId: 'rest'),
        profile: CloudProfile.eventual(maxPropagationDelayMs: 200),
      );
    }
    return SharedBackendAdapter(backend, deviceId: 'fs-$deviceId');
  },
  ...
);
```

### Eventual-consistency visibility model

When a `CloudSemanticsAdapter` is used, a completed sync may observe only a
subset of prior peer pushes (those whose `writeSeq` is at or below the adapter's
visibility cursor). The `ReconciliationAgent` tracks a `visibleWriteSeqHigh`
field on each completed `ActionResult` and uses
`visibleExpectedStateFor(deviceId, seqHigh)` to merge only the visible subset —
not the full global state. This prevents false failures from delayed-visibility
runs.

After the run loop, `TestManager._settleAndVerifyConvergence()`:

1. Advances the propagation clock on all `CloudSemanticsAdapter` fronts (making
   all writes visible).
2. Forces a final `syncForVerification()` on all devices.

Global convergence is then asserted implicitly by the verdict comparison.

**Fork detection is unchanged.** `_detectFork` keys on write _ordering_, not
propagation. Delayed visibility does not affect fork detection and must not be
used to modify `_detectFork`.

### Simulated vs real service

Running the harness against a real cloud service (e.g. real Google Drive) is
slow, credential-gated, rate-limited, and non-deterministic — suitable only as
an opt-in, pre-release soak (see RC-2 and RC-9 in §28). Deterministic CI value
comes from the **behavioural simulator**. The framework supports both with the
same harness scenarios by switching the per-device adapter factory.

Every cloud provider package must ship:

- Its real adapter.
- A behavioural API simulator (fake `http.Client` implementing provider REST
  endpoints with realistic semantics).
- A `CloudProfile` instance for that provider.

Real-service soak runs are reserved for pre-release (see §28 RC-2, RC-9).

---

## Cloud quota protection

If the configured adapter (resolved via `resolveAdapter(0)` as the
representative device) implements `QuotaAwareAdapter`, the `TestManager`
estimates the total sync operation count for the configured duration, device
count, velocity, and document size distribution. If the estimate exceeds
`safeOperationThreshold`, the run is rejected with `HarnessConfigException`
identifying the configuration as too aggressive. A hard per-minute sync cap (60
syncs/device/minute) is also enforced at runtime.

When `syncAdapterFactory` is used and adapters are heterogeneous, device 0 is
used as the representative device for the quota check.

Adapters that do not implement `QuotaAwareAdapter` are assumed to have no quota
constraint. This covers `MemorySyncAdapter`, `LocalDirectoryAdapter`, and
`SharedBackendAdapter`.

---

## Report format

`HarnessReport` is JSON-serialisable via `toJsonString()` / `fromJsonString()`.

Fields:

| Field            | Type                  | Description                               |
| ---------------- | --------------------- | ----------------------------------------- |
| `prngseed`       | `int`                 | PRNG seed used for this run               |
| `deviceVerdicts` | `List<DeviceVerdict>` | Per-device pass/fail, with key breakdown  |
| `forkRecords`    | `List<ForkRecord>`    | All detected forks with LWW outcome       |
| `noOpCounts`     | `List<NoOpCount>`     | Per-device no-op action counts            |
| `totalActions`   | `int`                 | Total actions executed across all devices |
| `durationMs`     | `int`                 | Elapsed wall-clock time in milliseconds   |

---

## Regression and flakiness detection

`diffReports(a, b)` compares two `HarnessReport` instances and returns a list of
`ReportDiff` entries. The comparison checks:

- Per-device verdict (pass/fail) and failure detail counts.
- Fork event count and LWW outcome (collection, key, winning device) per fork.
- Per-device no-op counts.

**Flakiness detection** — run the same seed N times against a single build (CLI
`--runs N`). Any divergence in final state or fork outcomes indicates
non-determinism in the implementation.

**Regression detection** — run the same seed against two KMDB builds and compare
reports. A changed LWW outcome or fork event log signals a regression in the
sync protocol.

---

## Known limitations and edge cases

- **Preset 5 non-determinism** — Dart isolate scheduling is not deterministic.
  The same seed will not produce the same action interleaving across two preset
  5 runs. Flakiness detection is documented as not applicable in preset 5.

- **`maxValueBytes` proximity** — the Large tier (~500 KB after encoding) is
  within the default 1 MiB limit but close. The harness overrides
  `KvStoreConfig.maxValueBytes` to 2 MiB to avoid spurious size-limit
  exceptions. Configure this explicitly if testing with even larger documents.

- **No Vault interaction** — Vault URIs and the `VaultStore` are not exercised.
  All document content is stored through the normal `KvStore` path.

- **Single-process only** — the harness simulates network partitions at the
  adapter layer. It cannot simulate OS-level connectivity failures between
  separate processes.
