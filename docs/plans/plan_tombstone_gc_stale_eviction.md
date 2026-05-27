# Tombstone GC: stale-device eviction from the sync horizon

**Status**: Open

**PR link**: {pending}

**Origin**: H4-FU2 — explicitly deferred from H4-FU during PR2 sign-off. Roadmap
entry: [docs/roadmap/0_02_01.md → H4-FU2](../roadmap/0_02_01.md). Documented as
a known limitation in
[plans/completed/plan_tombstone_gc.md](completed/plan_tombstone_gc.md#the-inactive-device-wrinkle)
and [docs/spec/12_sync.md](../spec/12_sync.md#tombstone-retention--garbage-collection).

**Sequencing**: Sibling to **H4-FU3** (ingest-side horizon floor) — together
they close the "tombstone GC robustness" follow-up cluster opened by H4 PR2.
H4-FU3 protects the *local* invariant; H4-FU2 protects the *distributed*
invariant by ensuring `min(currentHlc)` can actually advance. They are
independent and can land in either order, but the test surface overlaps —
both want a multi-device scenario where one peer is offline. Worth aligning
the test plumbing.

## Problem statement

[`HighwaterMark.minCurrentHlcAcrossDevices`](../../packages/kmdb/lib/src/sync/highwater.dart#L113)
(the synced GC horizon registered by `SyncEngine`) returns the strict
`min(currentHlc)` across every `.hwm` file in `{syncRoot}/highwater/`. The
horizon is therefore pegged by the slowest reporter — a device that uploads
a single `.hwm` and never returns blocks tombstone GC indefinitely. On any
long-lived synced workload with churning device IDs (uninstalls, lost
laptops, retired phones, ephemeral CI runners, …), the sync folder grows
without bound for *the very class of workload PR2 was meant to fix*.

The known shape of the solution — sketched in the H4-FU2 roadmap entry and in
the historical `12_sync.md` text — is **stale-device eviction**: exclude HWM
files whose `lastUpdated` is older than a configurable threshold from the
horizon computation, so the horizon can advance past the dead device. A
device that exceeds the threshold and *does* return must perform a **full
re-sync** rather than incremental catch-up; otherwise it can ingest records
older than the now-advanced horizon and deliver content that would resurrect
GC'd deletes.

The plan must answer two distinct safety questions, not just one:

1. **Eviction:** which HWMs are excluded from `min`, and on what evidence?
2. **Re-admission:** when an evicted device returns, how is its incremental
   catch-up downgraded to a safe full re-sync without silently producing
   resurrections?

Get either wrong and we either keep storage growing forever (eviction too
conservative) or resurrect deleted rows when a dormant peer comes back
(eviction too aggressive, or re-admission unguarded).

## Open questions

These gate the implementation. Q1 and Q4 are the load-bearing ones — the
others are mostly tuning and surfacing decisions.

- [ ] **Q1 — What is the eviction threshold and where does it live?** The
  H4-FU2 roadmap entry suggests "90 days" (matching the historical
  `12_sync.md` text). The threshold must be **≥ the longest realistic
  offline window for a legitimately-active device** — phones in drawers,
  laptops in storage, devices that only sync from a specific Wi-Fi network.
  Where is it configured? *(Recommended: a new
  `KvStoreConfig.staleDeviceEvictionAfter: Duration` with a conservative
  default of 90 days, mirroring the `tombstoneGraceDuration` pattern. It
  pairs naturally with `tombstoneGraceDuration` — the local-only grace and
  the multi-device eviction window are the two halves of "how long until a
  delete is considered globally observed.")*
- [ ] **Q2 — Whose clock authorises eviction?** `lastUpdated` is the
  uploading device's wall clock and is unsigned. A misbehaving / unsynced
  peer could write a future-dated `lastUpdated` and avoid eviction forever,
  or a far-past one and force its own eviction. Compare to "now" on the
  evaluating device, or fold in HLC-derived monotonic skew? *(Recommended:
  evaluating device's wall clock vs. uploader's `lastUpdated`. Worst-case
  damage is bounded — a misbehaving uploader either persists past the
  threshold (delaying GC for that peer's contribution) or excludes itself
  (advancing GC for everyone else); neither produces a resurrection. Skew
  is already part of the wider sync model.)*
- [ ] **Q3 — Does the evaluating device need to evict itself?** The local
  device's own `.hwm` is included in the `min` scan today (see Q3a in the
  investigation). If the local device hasn't synced in > threshold its
  `currentHlc` will already be small, pegging GC even though it's the one
  doing the eviction. *(Recommended: never exclude the local device's
  HWM. Its `currentHlc` advances on every push; if the device is online
  enough to run compaction, it has by definition just updated its own
  HWM.)*
- [ ] **Q4 — How does an evicted device re-admit safely?** This is the
  hazardous side. A device that returns after the eviction window holds
  SSTables whose `maxHlc` is below the now-advanced horizon. If those
  SSTables are ingested, peers can resurrect deletes that GC has already
  reclaimed. Three candidate strategies, in increasing order of complexity:
  - **(a) Full re-sync on return.** When a device's local state shows
    `currentHlc < horizon - staleDeviceEvictionAfter` on next push (i.e.
    "I have been excluded"), it discards its local SSTables, downloads the
    current consolidated set, and rebuilds. Simple, expensive, *correct*.
    The historical `12_sync.md` text named this approach.
  - **(b) Ingest-side filter at the recipient.** Recipients reject any
    SSTable whose `maxHlc < horizon` from a known-stale peer. Cheaper, but
    couples to H4-FU3's ingest-side floor; the floor would do this for
    *all* peers, not just stale ones.
  - **(c) Sender-side floor.** The returning device, on detecting "I was
    evicted," self-prunes its outbound SSTables. Avoids the recipient
    needing to know who is stale, but requires the device to discover the
    current horizon before pushing — which means reading peer HWMs first.
  *(Recommended: **(a)** as the spec-level guarantee, with **(b)** as the
  defence-in-depth backstop once H4-FU3 lands. The pair makes both ends
  responsible for the invariant, which is appropriate for a silent-data-
  loss class of bug. Implementation can ship (a) first.)*
- [ ] **Q5 — Detection of one's own evicted state.** On return, how does a
  device know it was evicted vs. merely behind? `lastUpdated` on its own
  prior `.hwm` is the obvious signal but is self-reported. Reading the
  *other* devices' HWMs and observing `min(currentHlc)` over peers (with
  self excluded) is more robust. *(Recommended: read peer HWMs first; treat
  `localCurrentHlc < min(peers.currentHlc)` *and* local
  `lastUpdated < now - staleDeviceEvictionAfter` as a re-sync trigger.)*
- [ ] **Q6 — Garbage-collecting the evicted `.hwm` file itself.** A
  permanently dead device's `.hwm` will be excluded forever but stays in
  the sync folder. Should the consolidation coordinator delete it after
  some second, much longer threshold (or never)? *(Recommended: leave it
  for a follow-up; the per-file cost is trivial and a returning device
  that finds its old HWM still present can rejoin without coordination.)*
- [ ] **Q7 — Interaction with [`HighwaterMark.isPeerStale`](../../packages/kmdb/lib/src/sync/highwater.dart#L190).**
  This method exists, takes a `staleness: Duration = 90 days` parameter,
  and is unused outside its own tests (grep'd: only `highwater_test.dart`).
  Its current implementation only checks "have I ever seen this peer" — it
  ignores `staleness`. Is this the natural home for the new logic
  (operating against the *peers* map within one HWM), or should the
  eviction live in `minCurrentHlcAcrossDevices` (operating across *HWM
  files*)? They are different data: the peers map records "highest HLC I
  processed from X," not "X's last self-reported update." *(Recommended:
  eviction lives in / next to `minCurrentHlcAcrossDevices` because it
  operates on `lastUpdated` of the HWM files themselves, not peers
  entries. `isPeerStale` is concerned with a different lifecycle — peer
  *liveness* per-this-device — and should either be wired up properly or
  deprecated as a separate cleanup. Keep it out of scope here.)*

## Investigation

### Current behaviour and the exact peg

`minCurrentHlcAcrossDevices`
([highwater.dart:113](../../packages/kmdb/lib/src/sync/highwater.dart#L113))
lists every `*.hwm` in the HWM directory, loads each, and tracks the strict
minimum `currentHlc`. There is no filter — corrupt files throw, but a
syntactically valid but ancient `lastUpdated` is honoured at full weight. The
result feeds the provider registered by `SyncEngine`
([sync_engine.dart:106](../../packages/kmdb/lib/src/sync/sync_engine.dart#L106));
when the provider returns a value, `LsmEngine._computeTombstoneHorizon`
([lsm_engine.dart:169](../../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L169))
uses it verbatim (no further bounds check). So the peg flows directly from
the dead `.hwm` through to `CompactionJob`'s `dropTombstone` predicate.

### What `lastUpdated` already provides

[`HighwaterMark.lastUpdated`](../../packages/kmdb/lib/src/sync/highwater.dart#L73)
is set inside `withCurrentHlc` and persisted on every push — so for a live
peer it is at most one sync cycle behind real wall-clock time. The
[parser](../../packages/kmdb/lib/src/sync/highwater.dart#L240) normalises to
UTC. This field is exactly the eviction signal we need; nothing about the
HWM format changes for H4-FU2.

### What `isPeerStale` does and does not do today

[`HighwaterMark.isPeerStale`](../../packages/kmdb/lib/src/sync/highwater.dart#L190)
operates on the `peers` map *within a single HWM file* and answers "have I
ever recorded a peer's HLC?" The `staleness` duration parameter is
**unused** (documented "reserved for future use"). Grep confirms zero
production callers — `highwater_test.dart` is the only site, and it asserts
the trivial unknown-peer-true / known-peer-false behaviour. This method is
concerned with the wrong lifecycle for H4-FU2: it asks about local peer
*tracking* within one HWM, not about whole-device liveness across HWM
files. The plan should not repurpose it.

### How an evicted-then-returning device can resurrect

A device with a 6-month-old `.hwm` and `currentHlc = T0` was the slowest
reporter; eviction lets the horizon advance to `T1 ≫ T0`. While the device
was offline:

1. Some other peer wrote `delete(k)` at HLC `T0 < hlc_del < T1`.
2. That tombstone was observed by all *remaining* peers.
3. Compaction on some peer dropped the tombstone (`hlc_del < T1` and the
   eviction means the slow peer no longer pegs the horizon).

When the dormant device returns, it still holds a pre-`delete` SSTable
containing `put(k, v_old)` at some HLC `< hlc_del`. If it pushes that
SSTable and a peer ingests it as an L0 file, the merge result reads `v_old`
because the tombstone is gone. The peer has resurrected a deleted key.

This is why **incremental re-admission is unsafe** and Q4's recommended
answer is full re-sync: the returning device's existing SSTables are no
longer trustworthy relative to the advanced horizon. They are not corrupt;
they are simply pre-decision data the rest of the topology has already
moved past.

### The "freshly-configured sync folder" interaction

`SyncEngine`'s provider returns `Hlc(0, 0)` when no `.hwm` files exist
([sync_engine.dart:111](../../packages/kmdb/lib/src/sync/sync_engine.dart#L111)),
which blocks every drop until at least one device has pushed. After
eviction, if *every* HWM is excluded (e.g. a long-quiescent project where
no device pushed within the eviction window), we land back at this case.
The conservative behaviour — block GC entirely rather than dropping to the
local-only grace fallback — appears correct: there is at least one HWM
file, so the database *is* in synced mode; we just have no current ground
truth. The plan should preserve this branch.

### Files to change (provisional)

| File | Change |
|------|--------|
| `lib/src/sync/highwater.dart` | Add an `evictAfter: Duration?` parameter (or sibling helper) to `minCurrentHlcAcrossDevices`; skip HWM files whose `lastUpdated` is older than `now - evictAfter` *except* the local device's own HWM. |
| `lib/src/sync/sync_engine.dart` | Plumb `KvStoreConfig.staleDeviceEvictionAfter` (or sibling) into the provider it registers; pass the local `deviceId` so the helper can exclude self. |
| `lib/src/engine/kvstore/kv_store.dart` | Add `staleDeviceEvictionAfter: Duration` to `KvStoreConfig` (default 90 days; document trade-offs and the re-admission requirement). |
| `lib/src/sync/sync_engine.dart` (return path) | Detect "I was evicted" on push start (Q5 rule) and trigger a **full re-sync** — discard local SSTables for synced namespaces, redownload, rebuild HWM from scratch. Phasing TBD; may split into a follow-up sub-plan. |
| `docs/spec/12_sync.md` | Replace the "known limitation" paragraph with the eviction rule, the default threshold, the re-admission protocol, and the safety argument. Reinstate (and update) the historical 90-day text. |
| `docs/spec/06_storage_engine.md` | Cross-reference the eviction rule from the tombstone-GC section. |
| `packages/kmdb/test/sync/highwater_test.dart` | Cover eviction in `minCurrentHlcAcrossDevices` (basic, self-not-evicted, all-evicted blocks GC, returning-device flow). |
| `packages/kmdb/test/sync/sync_engine_test.dart` | Eviction-aware horizon registration; re-admission trigger detection. |

### What this plan deliberately does **not** do

- It does not introduce the ingest-side horizon floor — that is **H4-FU3**.
  Once both land, the protection is layered: H4-FU2 keeps the distributed
  horizon advancing; H4-FU3 keeps any single device's ingest from
  contradicting it.
- It does not garbage-collect old `.hwm` files (Q6). That is a separate
  consolidation-coordinator concern.
- It does not change `isPeerStale` (Q7). That method's wire-up or
  deprecation is its own micro-plan.
- It does not relitigate the H4 PR2 safety conditions; it composes with
  them by ensuring the `horizon` input is no longer pegged by ghosts.

## Implementation plan

> Provisional. Lock down after open questions are answered.

### Step 1 — Configuration
- [ ] Add `KvStoreConfig.staleDeviceEvictionAfter: Duration` (default 90
      days). Doc comment must spell out: the safety trade-off (longer is
      safer but defers GC), the re-admission requirement (a device idle
      longer than this must full-re-sync), and the
      pairing-with-`tombstoneGraceDuration` semantics.

### Step 2 — Eviction-aware horizon
- [ ] Extend `HighwaterMark.minCurrentHlcAcrossDevices` (or add a sibling
      `minCurrentHlcExcludingStale`) to accept an `evictAfter: Duration?`
      and a `now: DateTime` (test seam), and an optional `localDeviceId`
      that is **never** excluded.
- [ ] Skip HWM files where `now.difference(hwm.lastUpdated) > evictAfter`
      *and* `hwm.deviceId != localDeviceId`.
- [ ] Preserve the "no HWM files yet" / "all evicted" → `null` contract so
      `SyncEngine` continues to map it to a blocking horizon.

### Step 3 — Wire through `SyncEngine`
- [ ] Pass `_config.staleDeviceEvictionAfter` and `_deviceId` into the
      provider registered in the `SyncEngine` constructor.

### Step 4 — Safe re-admission
- [ ] Before the first push in any cycle, the device reads peer HWMs and
      checks whether its local `currentHlc` is below
      `min(peer.currentHlc) - staleDeviceEvictionAfter` (per Q5's
      recommendation) — i.e. "the topology will treat me as evicted."
- [ ] When true: discard local synced-namespace SSTables, redownload the
      consolidated set, rebuild HWM. This step is **the** correctness-
      critical piece; if it grows large, split into its own sub-plan
      (`plan_sync_full_resync_after_eviction.md`) and let H4-FU2 land
      eviction alone.
- [ ] When false (normal): proceed with the existing incremental push.

### Step 5 — Tests
- [ ] **Eviction admits the horizon to advance:** two HWMs, one with
      `lastUpdated > evictAfter` ago, one fresh; `min` returns the fresh
      device's HLC, not the strict minimum.
- [ ] **Local device never self-evicts:** a stale `lastUpdated` on the
      local HWM is ignored when the helper is called with that device's
      ID; the strict minimum still includes self.
- [ ] **All-evicted → null/block:** every HWM stale (e.g. dormant project)
      collapses to `null`, which `SyncEngine` maps to `Hlc(0, 0)` so no
      tombstones drop.
- [ ] **Returning-device resurrection guard (CI):** simulate eviction +
      drop a tombstone past the advanced horizon + simulate the device's
      return *with* the re-admission check enabled — assert the device
      performs a full re-sync (no resurrection). Then disable the check —
      assert the resurrection occurs (proves the test is wired right).
- [ ] **Multi-device end-to-end:** in-process two-device test, then add a
      release-checklist entry for the cross-process variant under
      `kmdb_harness` once `plan_harness_mixed_storage.md` lands.

### Step 6 — Documentation
- [ ] `docs/spec/12_sync.md`: replace the "Known limitation: slowest-device
      peg" bullet with the eviction rule, threshold, and re-admission
      protocol. Restore the historical 90-day text adjusted for the
      current model.
- [ ] `docs/spec/06_storage_engine.md`: cross-reference the eviction rule
      from the tombstone-GC paragraph.
- [ ] Update the H4-FU2 roadmap entry status when complete.
- [ ] Update doc comments on `KvStoreConfig`, `HighwaterMark`, and
      `SyncEngine` to mention the new pairing.

### Step 7 — Verify
- [ ] `make pre_commit` clean.
- [ ] `dart test` passes in `packages/kmdb` and `packages/kmdb_cli`.
- [ ] Coverage ≥ 90% as per `CLAUDE.md`.
- [ ] Release-checklist entry added to
      `docs/spec/28_release_checklist.md` for the cross-device returning-
      stale-device scenario (companion to RC-6 from H4 PR2).

### Step 8 — PR
- [ ] Branch + worktree per `docs/plans/README.md`. Open PR against `main`,
      update **PR link** above, and on merge move this plan to
      `docs/plans/completed/`.

## Summary

{To be completed during implementation.}
