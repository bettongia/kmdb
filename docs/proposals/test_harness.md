# Technical Proposal: Test Harness

## 1. Overview

KMDB is able to operate both as a stand-alone single-user document database as
well as in a multi-device approach using a remote sync copy of the data. This
latter approach allows the user to access their data from multiple devices but
avoids having to be constantly online. The user can sync all of their data to
one or more remote copies - they can also choose to sync only a subset of their
data.

This multi-device approach needs significant testing to ensure that data is not
lost. It is reasonable to consider a range of scenarios in which the
synchronisation will cause issues if KMDB cannot correctly handle the data
moving to & from the remote sync. The table below outlines a number of such
scenarios.

| Scenario                                                                                      | Why might this happen?                                                                                                                                                    | How is this expected to be handled?                                                                                                                                                                                               | Risk                                                                                                                                             |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| One device's clock is significantly "out of time"                                             | Incorrect OS configuration, failed clock (NTP/Chrony) sync                                                                                                                | The HLC approach should handle this; the User Agent can inject a "Skew Clock" action per device to exercise this tolerance explicitly                                                                                             | The data is incorrectly rejected by the sync and is overwritten                                                                                  |
| Two devices write to the same document at the same time and the sync                          | User is on one device and a schedule job (or Open Claw) on another device make the same change at the same time                                                           | LWW should handle this but this needs to be checked; the Reconciliation Agent should record a fork event (both HLC timestamps + LWW outcome) for later audit                                                                      | The wrong version is retained                                                                                                                    |
| A device has been offline for a significant time and suddenly comes online and syncs its data | A laptop may not have been used whilst a person was on holiday.                                                                                                           | LWW and the HLC should resolve this                                                                                                                                                                                               | Old data incorrectly overwrites newer data                                                                                                       |
| Disparate data syncs                                                                          | The user may have two apps, each using a separate KMDB, but syncing data to the same remote                                                                               | Separate namespaces/collections should not clash; intersecting namespaces/collections should sync as expected, even if the data is significantly different                                                                        | The sync from one app deletes data from a non-intersecting collection                                                                            |
| Network partition mid-sync                                                                    | Device loses connectivity after beginning an upload or download (mobile network drop, laptop lid closed)                                                                  | The interrupted sync is abandoned; the remote remains consistent because SSTable uploads are atomic — a partial upload simply leaves no file on the remote. On reconnect the device retries the full push/pull cycle from scratch | The device's unsynced writes are silently stranded if the retry never fires; other devices never receive data the partitioned device had written |
| Concurrent consolidation lease contention                                                     | Two devices come online simultaneously after a period of inactivity and both attempt to acquire the consolidation lease                                                   | The lease mechanism should ensure only one consolidation proceeds; the other device should back off and retry                                                                                                                     | Both consolidations proceed, producing duplicate or conflicting epoch-tagged SSTables; data loss or duplication on subsequent syncs              |
| Rapid successive writes to the same key across devices                                        | A background job on one device and a user edit on another both update a high-churn document (e.g. a counter or "last opened" timestamp) within milliseconds of each other | LWW with HLC sub-millisecond logical counters should produce a deterministic winner; the Reconciliation Agent should record each fork event                                                                                       | Logical counter overflow or HLC collision causes a non-deterministic outcome; the same write wins inconsistently across runs                     |
| Large initial sync from a heavily pre-seeded device                                           | A new sync remote is configured on a device that already holds a substantial database (e.g. years of notes)                                                               | The push path should handle large SSTable counts without timeout or memory pressure; the remote should reflect the full dataset after sync completes                                                                              | Sync aborts mid-transfer leaving the remote partially populated; subsequent pulls from other devices produce an incomplete view                  |

## 2. Proposed solution

A test harness should be created that allows the running of the scenarios
previously listed. The test harness will consist of the main "actors":

1. Devices: These are individual KMDB devices that are a simulacra of a user's
   devices (e.g. their laptop, phone, tablet). Each device has a KMDB database
   that syncs some/all of its data to the remote sync. Each agent will emit
   details of each action it takes to the Reconciliation Agent
1. Reconciliation Agent: tasked with collating the action data sent from each
   device with that of the User Agent and the state of each Device's current
   KMDB data
1. User Agent: Generates actions (each with a unique ID) that are sent to the
   Devices. These actions can be randomly assigned or may constitute a series of
   actions. Actions include:
   1. Creation (init) of a KMDB database
   1. CRUD activities
   1. Sync with remote
   1. Skew Clock: applies a configurable time offset to a device's HLC to
      simulate clock drift
   1. Network Partition: injects or restores a connectivity failure on a device,
      interrupting in-progress or future syncs
1. Test manager: sets up the tests, coordinates across the other actors and
   reports on the outcomes of the test.

_Note: the term "agent" is used here in terms of software (e.g. a
function/Class/executable) and not an AI agent._

### Key requirements

1. The test harness must call the KMDB API in the same way any client tool (e.g.
   the CLI) would be expected to.
2. Multiple devices should be able to synch in a manner that is potentially
   parallel to another device synch. This will help determine race conditions.
   This should be achievable via isolates/multi-threading.
3. One or more devices can be pre-seeded with data before the tests starts. This
   simulates adding sync to an existing database
4. Where an action is not possible in an agent, this should be recorded as a
   no-op so that the Reconciliation Agent will not expect data to have mutated.
   1. Ideally this is guarded against using a state-based mechanism (e.g. a
      finite state machine) that records the Devices current state and allows
      the User Agent to select from actions appropriate to the state. For
      example:
      1. A Device with no database can only accept a create event
      2. A Device with no collections can only sync or create a collection

### Configuration items

The test harness needs to provide the following configuration items:

1. The number of devices (default: 3)
2. The number of devices with pre-seeded data (default: 1)
3. The number of KMDB collections (default: 10)
4. The duration of the test (default: 10 minutes)
5. Activity velocity (see below)
6. Remote sync location (default: local): _future work on remotes such as Google
   Drive will be added when that functionality is added to KMDB._

### Activity velocity

Activity is controlled by three independent knobs:

| Knob                  | Type   | Description                                                                      |
| --------------------- | ------ | -------------------------------------------------------------------------------- |
| `actionsPerMinute`    | `int`  | Write/read actions issued per active device per minute                           |
| `simultaneousDevices` | `int`  | Number of devices active at any given moment                                     |
| `syncIntervalSeconds` | `int?` | Time-driven sync: each active device syncs every N seconds. Null disables.       |
| `syncAfterWrites`     | `int?` | Write-driven sync: each active device syncs after every N writes. Null disables. |

At least one of `syncIntervalSeconds` or `syncAfterWrites` must be set. When
both are set, whichever condition is satisfied first triggers the next sync.

A convenience `velocityPreset` (1–5) sets all four knobs at once and can be
overridden by specifying individual knobs explicitly:

| Preset | Actions/min/device | Simultaneous devices  | Sync interval | Sync after N writes |
| ------ | ------------------ | --------------------- | ------------- | ------------------- |
| 1      | 2                  | 1                     | 300s          | 20                  |
| 2      | 5                  | 1–2                   | 120s          | 15                  |
| 3      | 10                 | ⌊N/2⌋                 | 60s           | 10                  |
| 4      | 30                 | N−1                   | 30s           | 5                   |
| 5      | 120                | N (parallel isolates) | 10s           | 3                   |

Preset 5 fires device syncs via parallel isolates rather than staggering them,
making it a genuine concurrency stress test. The elevated `actionsPerMinute` at
this level also simulates AI agent activity rather than a single human user.

#### Cloud remote quota protection

When the sync remote is a cloud service (e.g. Google Drive), the combination of
high velocity, many devices, and large documents can exhaust API quotas rapidly.
Before a test run starts the Test Manager must:

1. **Estimate the sync operation count** for the configured duration, device
   count, velocity, and document size distribution.
2. **Reject the configuration** if the estimate exceeds a per-service safe
   threshold (defined per adapter), reporting clearly which parameter is
   responsible.
3. **Enforce a hard cap** on sync operations per minute during the run,
   independent of the velocity setting, so that a miscalculation or unexpected
   write volume cannot breach the quota at runtime.

Quota thresholds are defined per cloud adapter and must be updated whenever the
service provider changes its limits. Local sync has no quota.

_Implementation note: the `SyncStorageAdapter` interface will be accompanied by
an optional `QuotaAwareAdapter` interface (see `plan_google_drive_sync.md`) that
quota-constrained adapters implement. The Test Manager checks for this interface
at startup — its absence signals no quota constraint. All quota estimation and
runtime capping logic should be driven by the values exposed through
`QuotaAwareAdapter` rather than hardcoded per-service thresholds in the harness
itself._

### Testing process

Prior to starting, the Test Manager:

1. Creates the Reconciliation Agent
1. Creates the required number of Devices and aligns them with the
   Reconciliation Agent
1. Configures the User Agent (aligns to the Reconciliation Agent and Devices)
   and requests that:
   1. The pre-seeded data be generated and sent to the (randomly selected)
      Devices.
   2. The devices will inform the Reconciliation Agent of the initial state of
      the database (whether they're pre-seeded or empty)
1. Asks the User Agent to generate actions for each device

At start time, the Test Manager hands over to the User Agent to start sending
actions to the Devices (actions can be sent in parallel). The User Agent
executes the action, records the result and logs it to the Reconciliation Agent.
This continues for the duration of the test.

At the end of the test the Test Manager:

1. Signals to the User Agent to halt sending actions.
2. Waits until all Devices signal that they have processed their action backlog.
3. Notifies the Reconciliation Agent that final reconciliation is to be done and
   waits for the final report.
4. Reports the test outcome

### Reconciliation Agent

The Reconciliation Agent is the harness's source of truth. Its correctness is
critical — a flawed expected-state model produces false passes or false
failures, which is worse than no harness at all.

#### Fundamental principle

With LWW + HLC, expected state is always deterministic. Given a complete log of
every write made on every device, and a complete log of every sync, the
Reconciliation Agent can compute exactly what value any device _should_ hold for
any key at any point in time. There is no ambiguity to resolve — only
simulation.

#### Two views of expected state

**Global expected state** — the LWW winner across all writes ever made to a key,
across all devices. This is the value every device should converge to once they
have all fully synced.

**Per-device expected state** — what a specific device should hold right now,
given only the writes it has made locally plus the writes it has received via
completed syncs. A device that has not synced recently legitimately holds stale
data; that is not a failure.

#### The action log

The Reconciliation Agent maintains two append-only logs:

| Log       | Entry shape                                                                         |
| --------- | ----------------------------------------------------------------------------------- |
| Write log | `(actionId, deviceId, key, hlc, encodedValue)`                                      |
| Sync log  | `(actionId, deviceId, direction: push\|pull, sstablesTransferred, completed: bool)` |

From these two logs, per-device expected state at any point in time is computed
as: _take all writes the device has either made locally or received via a
completed pull, then for each key select the write with the highest HLC._

Syncs are recorded as atomic events. A sync interrupted by a network partition
is recorded with `completed: false` and does not advance the device's expected
state. Only completed pulls move the boundary of what a device is expected to
know.

#### Fork detection

Fork detection falls out naturally from the action log. When the Reconciliation
Agent finds that two devices have both written to the same key between their
last common sync point, it records a fork event:

```
ForkEvent {
  key,
  writeA: { deviceId, hlc, encodedValue },
  writeB: { deviceId, hlc, encodedValue },
  lwwWinner: writeA | writeB,   // the write with the higher HLC
}
```

After the next sync the Reconciliation Agent verifies that each device's actual
value for the key matches the LWW winner. A mismatch is a test failure. Fork
events are included in the test report regardless of outcome — they are the
primary signal for understanding conflict behaviour across a run.

### Test data generation

Test data generation is handled entirely by the User Agent using a seeded
pseudo-random number generator (PRNG). The seed is recorded in the test report
so that any run that surfaces a failure can be replayed exactly with the same
sequence of documents and actions.

#### Document schema

The content of documents is not significant to sync correctness, but the shape
and size are. All generated documents share a fixed schema with fields that
exercise the full codec and vault path:

| Field        | Type           | Notes                                    |
| ------------ | -------------- | ---------------------------------------- |
| `title`      | `String`       | Short random text                        |
| `body`       | `String`       | Variable-length (drives the size tier)   |
| `count`      | `int`          | Random integer                           |
| `active`     | `bool`         | Random boolean                           |
| `tags`       | `List<String>` | 0–5 random short strings                 |
| `attachment` | `String?`      | Vault URI — present on ~20% of documents |

#### Document size distribution

Each document is generated into one of three size tiers, sampled from a
configurable distribution (default: 60% / 30% / 10%):

| Tier   | Approximate encoded size | Primary driver        |
| ------ | ------------------------ | --------------------- |
| Small  | ~100 B                   | Short `body` string   |
| Medium | ~10 KB                   | Long `body` string    |
| Large  | ~500 KB                  | Vault attachment blob |

#### Key targeting modes

The User Agent assigns each generated document key to one of three pools. The
mix across pools is a configuration knob (default: 50% / 40% / 10%):

| Pool         | Description                                                                                                                      |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Shared       | Keys pre-distributed to all devices before the test starts; writes will deliberately collide and exercise LWW                    |
| Device-local | Keys owned by a single device; tests that non-conflicting writes arrive intact on other devices after sync                       |
| Hot          | A small subset of shared keys written to at high frequency; specifically exercises the rapid-succession and clock-skew scenarios |

#### Reproducibility and fuzz modes

Two generation modes are supported:

- **Seeded mode** (default): a fixed seed produces a fully deterministic action
  sequence. The seed is included in every test report. Use this mode to
  reproduce a specific failure.
- **Fuzz mode**: the seed is drawn from the system clock at start time and
  recorded in the report. Use this mode for exploratory runs across varied
  conditions; a failing fuzz run can always be converted to a seeded replay.

### Test reporting

The test report needs to indicate if the data across the devices is in the
expected state at the conclusion of the test. Where the data is not in the
expected state, the report needs to indicate where this started to occur.

The Reconciliation Agent's action logs are the basis for this. The report must
include:

- **Pass / fail verdict** per device, with a per-key breakdown for any failures
- **Fork event log**: all detected forks across the run, each showing the two
  competing writes, the LWW winner, and whether the actual post-sync device
  state matched the expected winner
- **No-op log**: actions that could not be applied due to device state, recorded
  so failures are not attributed to expected no-ops
- **PRNG seed**: the seed used for the run, so any failure can be replayed
  exactly in seeded mode

### Repeatability and regression detection

Because the PRNG seed fully determines the action sequence, the same seed run
against the same KMDB build must always produce the same final state. The
harness supports two modes that exploit this property:

**Flakiness detection** — run the same seed N times against a single build and
assert that every run produces identical per-device final state and fork event
logs. Any divergence indicates non-determinism in the sync layer.

**Regression detection across builds** — run the same seed against two different
builds of KMDB and compare their reports. A build that produces a different LWW
outcome, a different fork event log, or a different final state for the same
action sequence has introduced a regression.

Both modes are driven by the existing test report format. The Test Manager
accepts a `--compare <report-file>` flag that diffs the current run's report
against a previously saved one and fails if any of the following differ:

- Per-device final state for any key
- Fork event outcomes (which write won LWW for each fork)
- No-op counts per device (a change here may indicate a state machine regression)

The diff output must identify the first action in the log where the two runs
diverged, so the developer can reproduce the point of failure in isolation.

### Package home

The test harness is not part of the core `kmdb` library or the CLI. It should
live in a new `packages/kmdb_harness` package within the workspace, with its own
`pubspec.yaml` and test entry point. It depends on `kmdb` as a path dependency
and is excluded from release bundles. It is intended to be run as a developer
tool, not shipped to end users.
