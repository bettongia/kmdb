# KMDB Test Harness

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

## Scope

This plan covers the test harness for KMDB's multi-device sync protocol.
**Vault (content-addressable blob store) testing is explicitly out of scope.**
The harness does not configure a `VaultStore`, does not generate Vault URIs, and
does not exercise any Vault code paths. Vault-specific harness scenarios are
deferred to a future plan.

## Problem statement

KMDB's multi-device sync protocol is the highest-risk surface in the codebase.
The unit and integration tests in `packages/kmdb` cover individual components
(SSTable writer, Manifest, compaction, SyncEngine), but no test exercises the
full end-to-end scenario: multiple independent devices writing concurrently,
syncing to a shared remote, recovering from network partitions, and ultimately
converging to a consistent state with predictable LWW outcomes.

The failure modes are insidious. A subtle ordering bug in HLC comparison or an
edge case in the SSTable consolidation lease protocol will not surface in a
single-device integration test — it requires at least two devices writing to the
same key between sync points. Given that KMDB underpins user data in Bettongia
applications, silent data loss or incorrect LWW resolution is unacceptable.

This plan introduces a dedicated developer test harness —
`packages/kmdb_harness` — that orchestrates multiple KMDB device instances,
drives them with a seeded action generator, captures every write and sync event,
and verifies that the actual post-sync state of each device matches the
deterministically-computed expected state. The harness is a developer tool only;
it is not shipped to end users.

## Investigation

### Background

The proposal (`docs/proposals/test_harness.md`) identifies eight concrete
failure scenarios that the harness must exercise:

1. Clock skew across devices (HLC tolerance)
2. Concurrent writes to the same key (LWW fork resolution)
3. Long-offline device rejoining (stale-write protection)
4. Disparate-data syncs (namespace isolation)
5. Network partition mid-sync (interrupted upload/download)
6. Concurrent consolidation lease contention
7. Rapid successive writes to a hot key
8. Large initial sync from a heavily pre-seeded device

### Architecture

The harness is composed of four actors. The term "actor" is used in the software
sense — each is a plain Dart class, not an AI agent or OS thread. Presets 1–4
run entirely within a single Dart isolate using async concurrency. Preset 5 is
a separate stress mode that spawns real isolates.

#### TestManager

Orchestrates the full lifecycle: configuration validation, quota check, actor
construction, pre-seeding, test run, teardown, and report emission. It is the
single entry point for a harness run. It accepts a `HarnessConfig` and an
optional `--compare <report-file>` path for regression detection mode.

#### UserAgent

Generates the action sequence for each device using a seeded PRNG
(`dart:math Random`). The seed is stored in the report so any failing run can be
replayed exactly. In fuzz mode the seed is derived from the system clock at
start time and recorded in the report.

The UserAgent drives devices exclusively through the public
`KmdbDatabase`/`KmdbCollection` API — the same surface available to any client
tool. This is a hard requirement; the harness must not call internal KMDB
methods.

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

#### Device

Wraps a single `KmdbDatabase` instance. Maintains a finite state machine (FSM)
that guards against invalid action sequences:

```
Uninitialised → (CreateDb) → Initialised → (CreateCollection) → Ready
```

A `Ready` device accepts all action types. An action that cannot be applied in
the current FSM state is recorded as a no-op and forwarded to the
ReconciliationAgent with `type: noOp` — the expected state model is not
advanced. This prevents spurious failures when the UserAgent issues an action
that is structurally valid but inapplicable to the current device state (e.g.
`Sync` before any collection exists).

Each Device emits every action and its result to the ReconciliationAgent
immediately after execution.

#### ReconciliationAgent

Maintains two append-only in-memory logs and is the harness's source of truth:

**Write log**: `(actionId, deviceId, key, hlc, encodedValue)`

**Sync log**:
`(actionId, deviceId, direction: push|pull, sstablesTransferred, completed: bool)`

From these logs the agent computes two views of expected state:

- **Per-device expected state**: all local writes by the device plus all writes
  received via completed pulls, with LWW (max HLC) applied per key.
- **Global expected state**: LWW winner across all writes on all devices — the
  state every device converges to once fully synced.

Syncs interrupted by a network partition are recorded with `completed: false`
and do not advance the receiving device's expected state. Only completed pulls
move the boundary.

**Fork detection**: when two devices have both written to the same key between
their last common sync point, the agent records a `ForkEvent`:

```dart
ForkEvent {
  key,
  writeA: (deviceId, hlc, encodedValue),
  writeB: (deviceId, hlc, encodedValue),
  lwwWinner: writeA | writeB,
}
```

After the next completed sync the agent verifies each device's actual value
matches the LWW winner. A mismatch is a test failure. Fork events appear in the
report regardless of pass/fail status.

### Configuration

`HarnessConfig` exposes the following knobs:

| Knob                   | Type                  | Default    | Notes                                             |
| ---------------------- | --------------------- | ---------- | ------------------------------------------------- |
| `deviceCount`          | `int`                 | 3          | Total simulated devices                           |
| `preSeededDeviceCount` | `int`                 | 1          | Devices initialised with data before run starts   |
| `collectionCount`      | `int`                 | 10         | Collections created per device                    |
| `duration`             | `Duration`            | 10 minutes | Total test run time                               |
| `velocityPreset`       | `int?`                | 3          | 1–5 convenience preset; overridden by knobs below |
| `actionsPerMinute`     | `int?`                | null       | Per-active-device write/read rate                 |
| `simultaneousDevices`  | `int?`                | null       | Devices active concurrently                       |
| `syncIntervalSeconds`  | `int?`                | null       | Time-driven sync trigger                          |
| `syncAfterWrites`      | `int?`                | null       | Write-count-driven sync trigger                   |
| `remoteSyncLocation`   | `SyncStorageAdapter`  | local      | Adapter instance for the remote sync store        |
| `prngseed`             | `int?`                | null       | Fixed seed for seeded mode; null = fuzz mode      |
| `keyPoolRatios`        | `KeyPoolRatios`       | 50/40/10   | Shared / device-local / hot key mix               |
| `docSizeDistribution`  | `DocSizeDistribution` | 60/30/10   | Small / medium / large document mix               |

Velocity presets:

| Preset | Actions/min/device | Simultaneous devices  | Sync interval | Sync after N writes |
| ------ | ------------------ | --------------------- | ------------- | ------------------- |
| 1      | 2                  | 1                     | 300 s         | 20                  |
| 2      | 5                  | 1–2                   | 120 s         | 15                  |
| 3      | 10                 | ⌊N/2⌋                 | 60 s          | 10                  |
| 4      | 30                 | N−1                   | 30 s          | 5                   |
| 5      | 120                | N (parallel isolates) | 10 s          | 3                   |

At least one of `syncIntervalSeconds` or `syncAfterWrites` must be set. If a
preset is used, both are set by the preset. Individual knobs override preset
values.

### Cloud quota protection

At startup the TestManager inspects the configured `SyncStorageAdapter`. If the
adapter implements the `QuotaAwareAdapter` interface (defined in
`plan_google_drive_sync.md`), the TestManager estimates the total sync operation
count for the configured duration, device count, velocity, and document size
distribution. If the estimate exceeds the adapter's safe threshold the harness
rejects the configuration with a clear error identifying the offending
parameter. A hard per-minute sync cap is also enforced at runtime. Adapters that
do not implement `QuotaAwareAdapter` are assumed to have no quota constraint
(this covers `LocalDirectoryAdapter` and `MemorySyncAdapter`).

### Test data generation

All documents use a fixed schema:

| Field    | Type           | Notes                                 |
| -------- | -------------- | ------------------------------------- |
| `title`  | `String`       | Short random text                     |
| `body`   | `String`       | Variable-length; determines size tier |
| `count`  | `int`          | Random integer                        |
| `active` | `bool`         | Random boolean                        |
| `tags`   | `List<String>` | 0–5 random short strings              |

Note: there is no `attachment` / Vault URI field. Vault testing is out of scope
(see Scope section above). The Large size tier is achieved entirely through an
extended `body` string — no separate blob or Vault interaction is required.

Three size tiers:

| Tier   | Approximate encoded size | Primary driver          |
| ------ | ------------------------ | ----------------------- |
| Small  | ~100 B                   | Short `body`            |
| Medium | ~10 KB                   | Long `body`             |
| Large  | ~500 KB                  | Very long `body` string |

Three key pools:

| Pool         | Description                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------------- |
| Shared       | Pre-distributed to all devices; writes deliberately collide for LWW testing                        |
| Device-local | Owned by a single device; tests non-conflicting write arrival on peers                             |
| Hot          | Small shared subset written at high frequency; exercises clock-skew and rapid-succession scenarios |

### Test reporting

The test report (`HarnessReport`) contains:

- **Pass/fail verdict** per device, with a per-key breakdown for failures
- **Fork event log**: all detected forks including both competing writes, LWW
  winner, and whether the actual post-sync state matched the winner
- **No-op log**: all actions recorded as no-ops, preventing false failure
  attribution
- **PRNG seed**: the seed used for the run, enabling exact replay in seeded mode

### Regression and flakiness detection

The TestManager accepts a `--compare <report-file>` flag. When present it diffs
the current run's report against the saved report and fails if any of the
following differ:

- Per-device final state for any key
- Fork event outcomes (which write won LWW for each fork)
- No-op counts per device

The diff output identifies the first action in the log where the two runs
diverged, enabling targeted reproduction.

**Flakiness detection**: run the same seed N times against a single build; any
divergence in final state or fork outcomes indicates non-determinism.

**Regression detection**: run the same seed against two KMDB builds; a changed
LWW outcome or fork event log signals a regression.

### Package location

`packages/kmdb_harness` — new package in the workspace. Path-depends on
`packages/kmdb`. Not shipped to end users. Not added to the workspace's melos
release bundle.

### Alignment with existing plans

- **`plan_kmdb_database_sync_api.md` (blocking prerequisite)**: The `Sync`
  action requires a `sync()` method on `KmdbDatabase`. That method does not
  exist today; it is being added under `plan_kmdb_database_sync_api.md`. This
  plan must reach `Complete` before Phase 2 of the harness can be implemented.
  It also updates the CLI to use the new API, which removes the direct
  `SyncEngine` construction that the harness cannot replicate without breaking
  the "public API only" rule.
- `QuotaAwareAdapter` is defined in `plan_google_drive_sync.md`. This plan
  depends on that interface existing before Phase 5 (TestManager quota check)
  can be completed. If the Google Drive plan is not yet `Implementing` when this
  plan reaches that phase, a local stub `QuotaAwareAdapter` should be defined in
  `kmdb_harness` and replaced once the real interface lands.
- The harness exercises scenarios that are relevant to document versioning
  (`plan_document_versioning.md`) and may surface edge cases useful when that
  work is planned.

### Key files to read before implementing

- `packages/kmdb/lib/src/sync/` — `SyncEngine`, `SyncStorageAdapter`,
  `ConsolidationCoordinator`, `HighwaterMark`
- `packages/kmdb/lib/src/query/` — `KmdbDatabase`, `KmdbCollection`
- `packages/kmdb/lib/src/engine/util/hlc.dart` — HLC value type
- `packages/kmdb/lib/src/sync/hlc_clock.dart` — injectable clock abstraction
- `plans/plan_google_drive_sync.md` — `QuotaAwareAdapter` interface definition

### Edge cases and risks

- **Preset 5 isolate boundary**: Presets 1–4 run in a single isolate; no
  message-passing is required. Preset 5 spawns real isolates and requires a
  purpose-built isolate-safe sync adapter. Flakiness detection is documented as
  not applicable in preset 5 (isolate scheduling is non-deterministic).
- **Network partition simulation**: the harness cannot intercept OS-level TCP
  connections. The `NetworkPartition` action must be implemented at the
  `SyncStorageAdapter` layer — a `PartitionableAdapter` wrapper that wraps any
  `SyncStorageAdapter` and throws `NetworkException` on demand. This is internal
  to the harness package.
- **Pre-seeding consistency**: devices selected for pre-seeding must report
  their initial state to the ReconciliationAgent before the test starts so
  expected-state computation begins from a correct baseline.
- **Large body strings at preset 5**: the ~500 KB `Large` tier + N parallel
  devices could produce significant temporary disk usage (no Vault involvement
  — all data is stored through the normal KvStore path). Document the disk
  space requirement in the package README.
- **Test isolation**: each harness run creates a temporary directory for local
  KMDB storage. The TestManager is responsible for cleanup on teardown,
  including after a panic or test failure (use `addTearDown` / `try/finally`).

## Implementation plan

### Phase 1 — Package scaffold and configuration types

- [ ] Create `packages/kmdb_harness/` with `pubspec.yaml`, `lib/`, `test/`,
      `bin/` directories
- [ ] Add `kmdb` path dependency and any other required pub dependencies
      (`dart:isolate`, `dart:math`, logging)
- [ ] Add license headers to all new files
- [ ] Define `HarnessConfig` with all configuration knobs and validation
      (`assert` at least one sync trigger is set; preset expansion logic)
- [ ] Define `KeyPoolRatios` and `DocSizeDistribution` value types
- [ ] Define velocity preset expansion logic
- [ ] Write unit tests for config validation and preset expansion

### Phase 2 — Device actor (FSM, KMDB API wrapper, action logging)

- [ ] Define `DeviceState` enum: `uninitialised`, `initialised`, `ready`
- [ ] Implement `Device` class with FSM guard and `KmdbDatabase` wrapper
- [ ] Implement `PartitionableAdapter` — wraps any `SyncStorageAdapter` and
      throws on demand when partitioned
- [ ] Implement action dispatch: `CreateDb`, `CreateCollection`, `Put`, `Get`,
      `Delete`, `Sync`, `NetworkPartition`
- [ ] Emit `ActionResult` (including no-op flag) to ReconciliationAgent after
      each action
- [ ] Write unit tests for FSM transitions and no-op recording

### Phase 3 — User Agent (action generation, PRNG, key pools, data generation)

- [ ] Implement `UserAgent` with seeded `Random` and fuzz-mode (clock-seed)
      fallback
- [ ] Implement document generator for all three size tiers using the fixed
      schema (Large tier uses an extended `body` string; no Vault interaction)
- [ ] Implement three-pool key assignment with configurable ratios
- [ ] Implement action sequence generation (random selection weighted by current
      device FSM state)
- [ ] Implement pre-seeding logic (generate and push initial documents to
      selected devices before test start)
- [ ] Write unit tests for document generation (size tier sampling, key pool
      distribution, PRNG reproducibility)

### Phase 4 — Reconciliation Agent (action logs, expected-state computation, fork detection)

- [ ] Define `WriteLogEntry` and `SyncLogEntry` data classes
- [ ] Define `ForkEvent` data class
- [ ] Implement `ReconciliationAgent` with append-only write and sync logs
- [ ] Implement per-device expected-state computation (local writes + completed
      pulls, LWW per key)
- [ ] Implement global expected-state computation (LWW across all devices)
- [ ] Implement fork detection (writes to same key between common sync points)
- [ ] Implement post-sync verification (actual vs expected for forked keys)
- [ ] Write unit tests for expected-state computation with constructed log
      scenarios covering: single device, two-device LWW, interrupted sync
      (completed: false), clock-skew ordering, hot-key rapid succession

### Phase 5 — Test Manager (orchestration, setup, teardown, quota check)

- [ ] Implement `TestManager` class with full lifecycle: setup → preseed → run →
      drain → reconcile → report
- [ ] Implement quota check on startup (inspect adapter for `QuotaAwareAdapter`;
      estimate operations; reject if over threshold)
- [ ] Implement hard per-minute sync cap enforcement at runtime
- [ ] Implement graceful shutdown: signal UserAgent halt, drain device backlogs,
      trigger final reconciliation
- [ ] Implement temporary directory management with cleanup in teardown
- [ ] Write integration tests for TestManager lifecycle using
      `MemorySyncAdapter` and a low-velocity config

### Phase 6 — Test reporting (`--compare` mode)

- [ ] Define `HarnessReport` data class (pass/fail per device, fork event log,
      no-op log, PRNG seed)
- [ ] Implement JSON serialisation/deserialisation for `HarnessReport`
- [ ] Implement `--compare <report-file>` diff logic: per-device final state,
      fork outcomes, no-op counts; first-diverging-action identification
- [ ] Implement CLI entry point in `bin/kmdb_harness.dart` accepting `--config`,
      `--seed`, `--compare`, `--runs` (flakiness mode), `--output`
- [ ] Write unit tests for report serialisation round-trip and diff logic

### Phase 7 — Tests and docs

- [ ] Ensure overall line coverage for `kmdb_harness` meets the 90% minimum
- [ ] Write at least one end-to-end harness run test using `MemorySyncAdapter`
      at preset 1, verifying that a 3-device run with 1 pre-seeded device
      reaches the correct global expected state
- [ ] Write a targeted test for network-partition scenario (Device A partitioned
      during push; verify incomplete sync does not advance ReconciliationAgent
      expected state for Device B)
- [ ] Write a targeted test for concurrent-write fork resolution (two devices
      write same key; verify LWW winner matches post-sync actual state)
- [ ] Add package-level doc comments to all public types and methods
- [ ] Write `packages/kmdb_harness/README.md` documenting usage, configuration
      knobs, velocity presets, and disk-space requirements
- [ ] Write `docs/spec/27_test_harness.md` covering: purpose and scope; actor
      architecture and responsibilities; configuration knobs and velocity presets;
      the expected-state model and its correctness guarantee; fork detection
      algorithm; test data generation (schema, size tiers, key pools, PRNG
      modes); cloud quota protection; report format; regression and flakiness
      detection; known limitations and edge cases
- [ ] Update `docs/spec/` if any other spec section requires amendment
      (particularly §12 sync and §17 crash recovery if new seams are added)

## Open questions

- [x] **HLC clock injection seam**: Resolved. `SkewClock` has been removed from
  the action set. A device with a moderately skewed clock does not cause silent
  incorrect LWW resolution — the HLC is designed to tolerate skew up to 60s,
  and skew beyond that throws `ClockSkewException`. LWW correctness under
  concurrent writes is fully covered by controlled write ordering without
  synthetic clock skew. The HLC injection seam (`LsmEngine` → `HlcClock`) is
  tracked separately in `plan_lsm_hlc_clock.md` for its independent value to
  `kmdb`'s own test suite.

- [x] **Sync exposure at the `KmdbDatabase` API layer**: Resolved. A dedicated
  plan (`plan_kmdb_database_sync_api.md`) adds a `sync()` method to
  `KmdbDatabase` and updates the CLI to use it. This plan is a blocking
  prerequisite and must reach `Complete` before Phase 2 of the harness begins.
  The "public API only" rule is preserved.

- [x] **Isolate topology decision**: Resolved. Presets 1–4 use single-isolate
  async concurrency: each device runs as an `async` loop, with
  `simultaneousDevices` controlling how many loops are active at once via
  `Future.wait()`. Device action loops interleave at `await` boundaries,
  producing genuine concurrent write and sync scenarios without isolate
  complexity. `ReconciliationAgent` is a plain Dart class with direct method
  calls. Preset 5 is explicitly scoped as a separate stress mode using real
  Dart isolates, with flakiness detection documented as not applicable (isolate
  scheduling is non-deterministic).

- [x] **`MemorySyncAdapter` thread-safety across isolates**: Resolved as a
  consequence of the isolate topology decision. In the single-isolate design
  (presets 1–4), all `Device` instances share the same `MemorySyncAdapter` by
  reference — no message passing, no thread-safety concern. Preset 5 requires
  a purpose-built isolate-safe adapter; this is a documented limitation of that
  mode, not a blocker for the core harness.

- [x] **Vault interaction in the document schema**: Resolved. Vault testing is
  explicitly out of scope for this plan. The `attachment` field has been removed
  from the test data schema. The Large size tier is achieved using a plain
  extended `body` `String`. See Scope section.

## Review notes

_Review conducted 2026-05-21._

### Problem statement assessment

The problem is real and the priority is correct. The sync protocol — HLC
comparison, SSTable ingestion ordering, lease contention, and LWW resolution
across multiple devices — is the highest-risk surface in KMDB, and none of
the existing tests exercise the full multi-device convergence path. The eight
failure scenarios listed are well-chosen and genuinely important; scenarios 2
(concurrent LWW), 3 (stale-write after offline), and 6 (consolidation lease
contention) in particular have subtle failure modes that only emerge when two
independent device instances drive the same sync folder concurrently. The
motivation is sound.

### Proposed solution assessment

**Strengths:**

- The four-actor design (TestManager / UserAgent / Device / ReconciliationAgent)
  cleanly separates concerns. The ReconciliationAgent's append-only write and
  sync log is the right model — it mirrors how a formal correctness checker
  would approach this problem.
- Seeded PRNG with a saved seed for exact-replay is essential for a fuzzing
  harness and is correctly identified as a first-class requirement.
- The key-pool design (shared / device-local / hot) is well thought out. Using
  shared keys deliberately forces LWW races, which is exactly what the harness
  needs to exercise.
- Recording no-ops separately to avoid false-failure attribution is a nice
  detail that avoids a common pitfall in property-based testing.
- Fork detection algorithm is sensible and the `ForkEvent` data class captures
  enough information to diagnose failures.
- The `PartitionableAdapter` wrapper for network partition simulation is the
  right approach — adapter-layer injection avoids the impossibility of OS-level
  TCP interception in a Dart process.

**Weaknesses and concerns:**

**1. The `SkewClock` action has been removed. (Resolved)**

A device with a moderately skewed clock (< 60 s) does not produce silent
incorrect LWW resolution — the HLC tolerates that skew by design. A device
skewed beyond 60 s triggers `ClockSkewException` on pull — a loud failure,
not a silent one. Neither case is a correctness bug that the harness's fork
detection would catch. LWW correctness is fully covered by the controlled
write-ordering approach already in the plan. `SkewClock` has been removed from
the action table.

The HLC injection seam (`LsmEngine` → `HlcClock`) has independent value for
`kmdb`'s own deterministic tests and is tracked in `plan_lsm_hlc_clock.md`.
It is not a prerequisite for the harness.

The incorrect file path reference (`src/primitives/hlc.dart`) has also been
corrected in the key files section.

**2. The "public API only" rule conflicts with how sync actually works.**

The UserAgent is required to drive devices through `KmdbDatabase`/
`KmdbCollection` only. But `KmdbDatabase` does not expose sync — sync is done
today by constructing a `SyncEngine` separately against the underlying
`KvStore`. If the harness must not call internal APIs, either `KmdbDatabase`
needs a `sync()` method added (a reasonable and desirable change), or the rule
must be relaxed to allow direct `SyncEngine` use. The plan does not resolve
this. For the `Sync` action to be implemented as described, this decision
must be made before Phase 2.

**3. Isolate topology — resolved.**

Presets 1–4 use single-isolate async concurrency. Device loops interleave at
`await` boundaries via `Future.wait()`, which is sufficient to produce
concurrent write and sync scenarios. `ReconciliationAgent` and
`MemorySyncAdapter` are plain Dart objects shared by reference — no
message-passing complexity. Preset 5 is scoped as a separate stress mode with
real isolates and documented limitations (non-deterministic, flakiness
detection disabled, isolate-safe adapter required).

**4. The document schema embedded Vault URIs without a Vault setup strategy. (Resolved)**

This concern has been addressed. Vault testing is explicitly out of scope (see
Scope section). The `attachment` field has been removed from the test data
schema and replaced with a plain extended `body` `String` for the Large size
tier. No `VaultStore` configuration, blob writes, or Vault GC interaction is
required.

**5. The `--compare` regression detection mode conflates two distinct use cases.**

Using a saved seed to compare two runs is useful. But the plan wants to use
the same mechanism for both flakiness detection (same build, same seed, N
runs) and regression detection (two builds, same seed). These require
different invocations and different interpretations of divergence. Separating
them into distinct CLI flags (`--check-flakiness --runs N` vs `--compare
<report>`) would make the UX clearer and the implementation more
straightforward. Currently the `--runs` flag is mentioned but its interaction
with `--compare` is not specified.

### Architecture fit

The package placement as `packages/kmdb_harness` (dev-only, not in the melos
release bundle) is correct. Path-depending on `packages/kmdb` is the right
dependency model.

The plan correctly identifies `MemorySyncAdapter` as the target adapter for
harness tests, which keeps the test suite free of I/O. The phased
implementation plan is sensible — configuration types first, then actors,
then orchestration.

The `QuotaAwareAdapter` dependency on `plan_google_drive_sync.md` is noted,
and the fallback (local stub) is reasonable. This dependency is not a
blocker for the core harness functionality.

### Risk and edge cases

Beyond the open questions above, two additional risks are worth calling out:

**Determinism at preset 5 with multiple Dart isolates.** Dart isolates run on
the Dart thread pool and their scheduling is not deterministic. If Device actors
run in separate isolates, the same seed will not produce the same action
interleaving on two different runs, which breaks the flakiness detection model.
The plan should either acknowledge this limitation explicitly (flakiness
detection only works for single-isolate configurations) or use `Completer`-
based sequencing to impose a deterministic interleaving, which largely defeats
the purpose of parallel isolates.

**`maxValueBytes` default is 1 MiB.** The `Large` tier documents (~500 KB
after encoding) are within the default limit, but this is close. Zstd
compression is native-only; on platforms without it, CBOR-encoded 500 KB
bodies will be stored uncompressed. The harness should configure
`KvStoreConfig` explicitly with `maxValueBytes` set high enough to avoid
spurious size-limit exceptions in the Large tier, and this should be documented
in `HarnessConfig`.

### Recommendations

1. **Resolve the four open questions before marking Investigated.** The HLC
   clock seam and the sync API surface questions have direct Phase 2
   blockers; the isolate topology question has direct Phase 4 (ReconciliationAgent)
   blockers.

2. **Incorrect file path reference — resolved.** Updated to
   `packages/kmdb/lib/src/engine/util/hlc.dart` (HLC value type) and
   `packages/kmdb/lib/src/sync/hlc_clock.dart` (injectable clock).

3. **Isolate model — resolved.** Single-isolate async for presets 1–4; preset 5
   scoped as a separate stress mode with documented limitations.

4. **Vault interaction — resolved.** The `attachment` field has been removed and
   Vault testing is explicitly out of scope. The Large-tier size is achieved via
   an extended `body` `String`. No further action required on this item.

5. **HLC injection seam — not a prerequisite.** `SkewClock` has been removed;
   the injection seam is tracked independently in `plan_lsm_hlc_clock.md` and
   does not block the harness.

## Summary

{Dot points highlighting the work undertaken — to be completed after
implementation}
