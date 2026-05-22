# kmdb_harness

Developer test harness for KMDB's multi-device sync protocol.

This package orchestrates multiple KMDB device instances, drives them with a
seeded action generator, captures every write and sync event, and verifies that
each device's post-sync state matches the deterministically-computed expected
state.

**This is a developer tool only — it is not shipped to end users and is not
included in the melos release bundle.**

---

## Scope

Vault (content-addressable blob store) testing is **out of scope**. The harness
does not configure a `VaultStore`, does not generate Vault URIs, and does not
exercise any Vault code paths. Document bodies use plain extended strings for the
Large size tier.

---

## Quick start

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';

final manager = TestManager(
  config: HarnessConfig(
    syncAdapter: MemorySyncAdapter(),
    velocityPreset: VelocityPreset.one,
    duration: Duration(seconds: 30),
  ),
);
final report = await manager.run();
print('Passed: ${report.passed}');
print('Seed: ${report.prngseed}');
```

---

## CLI

```
dart run kmdb_harness [options]

Options:
  -p, --preset <1-5>     Velocity preset (default: 1)
  -d, --devices <n>      Number of simulated devices (default: 3)
      --duration <s>     Run duration in seconds (default: 30)
  -s, --seed <n>         Fixed PRNG seed; omit for fuzz mode
  -o, --output <file>    Write JSON report to file (default: stdout)
  -c, --compare <file>   Diff this run against a saved report
  -r, --runs <n>         Repeat N times for flakiness detection (default: 1)
  -h, --help             Show usage
```

### Seeded (deterministic) replay

```sh
dart run kmdb_harness --preset 2 --devices 3 --duration 60 --seed 12345 --output run1.json
```

### Regression detection

```sh
# Save a baseline
dart run kmdb_harness --seed 99 --output baseline.json

# Compare a later build
dart run kmdb_harness --seed 99 --compare baseline.json
```

Exit codes: `0` = pass, `1` = fail, `2` = configuration rejected, `3` =
regression divergence detected.

### Flakiness detection

```sh
dart run kmdb_harness --seed 42 --runs 5
```

Runs the same seed five times. Any divergence in final state or fork outcomes
indicates non-determinism in the KMDB implementation under test.

---

## Configuration knobs

| Knob                   | Type                  | Default    | Notes                                            |
| ---------------------- | --------------------- | ---------- | ------------------------------------------------ |
| `deviceCount`          | `int`                 | 3          | Total simulated devices                          |
| `preSeededDeviceCount` | `int`                 | 1          | Devices initialised with data before run starts  |
| `collectionCount`      | `int`                 | 10         | Collections created per device                   |
| `duration`             | `Duration`            | 10 minutes | Total test run time                              |
| `velocityPreset`       | `VelocityPreset?`     | `null`     | Convenience preset; `null` = supply knobs manually |
| `actionsPerMinute`     | `int?`                | from preset | Per-active-device write/read rate               |
| `simultaneousDevices`  | `int?`                | from preset | Devices active concurrently                     |
| `syncIntervalSeconds`  | `int?`                | from preset | Time-driven sync trigger                        |
| `syncAfterWrites`      | `int?`                | from preset | Write-count-driven sync trigger                 |
| `syncAdapter`          | `SyncStorageAdapter`  | required   | Adapter for the shared remote sync store         |
| `prngseed`             | `int?`                | `null`     | Fixed seed for seeded mode; `null` = fuzz mode   |
| `keyPoolRatios`        | `KeyPoolRatios`       | 50/40/10   | Shared / device-local / hot key mix             |
| `docSizeDistribution`  | `DocSizeDistribution` | 60/30/10   | Small / medium / large document mix             |

At least one of `syncIntervalSeconds` or `syncAfterWrites` must be set (either
directly or via a `velocityPreset`).

---

## Velocity presets

| Preset | Actions/min/device | Simultaneous devices | Sync interval | Sync after N writes |
| ------ | ------------------ | -------------------- | ------------- | ------------------- |
| 1      | 2                  | 1                    | 300 s         | 20                  |
| 2      | 5                  | 1–2                  | 120 s         | 15                  |
| 3      | 10                 | ⌊N/2⌋                | 60 s          | 10                  |
| 4      | 30                 | N−1                  | 30 s          | 5                   |
| 5      | 120                | N (real isolates)    | 10 s          | 3                   |

Presets 1–4 run in a single Dart isolate using async concurrency (device loops
interleave at `await` boundaries). Preset 5 is a separate stress mode with real
Dart isolates; flakiness detection is not applicable in preset 5 (isolate
scheduling is non-deterministic).

---

## Test data

All documents share a fixed schema:

| Field    | Type           | Notes                        |
| -------- | -------------- | ---------------------------- |
| `title`  | `String`       | Short random text            |
| `body`   | `String`       | Variable-length; size tier   |
| `count`  | `int`          | Random integer               |
| `active` | `bool`         | Random boolean               |
| `tags`   | `List<String>` | 0–5 random short strings     |

Three document size tiers (driven by `body` length):

| Tier   | Approximate encoded size | `body` length |
| ------ | ------------------------ | ------------- |
| Small  | ~100 B                   | ~60 chars     |
| Medium | ~10 KB                   | ~6 000 chars  |
| Large  | ~500 KB                  | ~300 000 chars |

Three key pools:

| Pool         | Purpose                                            |
| ------------ | -------------------------------------------------- |
| Shared       | All devices may write; triggers LWW races          |
| Device-local | Single-device ownership; non-conflicting arrivals  |
| Hot          | Small shared subset; high-frequency rapid writes   |

### Disk space

At preset 5 with all devices active and the Large tier (10% of documents by
default), temporary disk usage can reach approximately:

```
N_devices × Large_body_size × docs_per_device
```

Configure `KvStoreConfig.maxValueBytes` appropriately (the harness uses 2 MiB
by default) and ensure sufficient temporary disk space is available.

---

## Report format

`HarnessReport` is JSON-serialisable:

```json
{
  "prngseed": 42,
  "deviceVerdicts": [
    { "deviceId": 0, "passed": true, "failureDetails": [] }
  ],
  "forkRecords": [
    {
      "collectionName": "notes",
      "key": "01900000...",
      "deviceA": 0,
      "deviceB": 1,
      "lwwWinnerDeviceId": 1,
      "lwwWinnerActionId": 17
    }
  ],
  "noOpCounts": [
    { "deviceId": 0, "count": 3 }
  ],
  "totalActions": 412,
  "durationMs": 31024
}
```

---

## Cloud quota protection

If the configured `SyncStorageAdapter` implements `QuotaAwareAdapter`, the
`TestManager` estimates the total sync operation count for the configured run
and rejects it with `HarnessConfigException` if the estimate exceeds
`safeOperationThreshold`. A hard per-minute sync cap is also enforced at
runtime. Adapters that do not implement `QuotaAwareAdapter` (including
`MemorySyncAdapter` and `LocalDirectoryAdapter`) are assumed to have no quota
constraint.
