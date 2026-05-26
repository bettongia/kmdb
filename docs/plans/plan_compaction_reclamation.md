# Fix H4: Compaction reclaims no space — version collapse + policy hook (PR1 of 2)

**Status**: Implementing

**PR link**: {pending}

**Scope of this plan (PR1).** Per D3, H4 ships in two PRs. **This plan covers
PR1 only:** version collapse (safe at any compaction level) and the
per-namespace-class reclamation policy hook (including `$ver:` exemption). The
**tombstone-GC** half (which is the risky distributed part) is split into a
separate follow-up plan, [plan_tombstone_gc.md](plan_tombstone_gc.md), and ships
as PR2. The Problem statement and Investigation below cover the **full H4
picture** because PR2 depends on this context — the implementation checklist at
the bottom is PR1-only.

**Implementation model:** Sonnet is fine for PR1 (version collapse is purely
within a compaction's inputs and read-path-equivalent). The tombstone-GC PR2
explicitly calls for Opus or strong-model review — that rule moves with it to
the follow-up plan.

**Sequencing**: Independent of C1/C2/H2 mechanically, but it is the **general
compaction-reclamation framework** that `plan_document_versioning.md` Phase 3
plugs into — author H4 first so versioning registers a `$ver:` retention policy
rather than building trim from scratch (see "Link to document versioning").

## Problem statement

KMDB compaction never reclaims space. `MergeIterator` de-duplicates only on the
**full internal key**, which embeds the HLC
([merge_iterator.dart:115](../packages/kmdb/lib/src/engine/compaction/merge_iterator.dart#L115)),
so different versions of the same user key are distinct and **all kept forever**,
and `CompactionJob.run` writes every entry it sees
([compaction_job.dart:126](../packages/kmdb/lib/src/engine/compaction/compaction_job.dart#L126))
— including delete tombstones, which are **never dropped**, even at the bottom
level. Reads stay correct (the read path collapses versions at query time), but:

- A key written N times keeps all N copies; deleted keys keep their tombstones
  permanently. Storage grows without bound under updates/deletes.
- Read cost grows with version count (every version is scanned and de-duplicated
  per query), compounding the M1 reader-cost finding.

For a database meant to run for years on a device, this defeats the purpose of
LSM compaction. This plan introduces reclamation — carefully, because in a
**synced** database dropping a tombstone too early silently resurrects deleted
data.

## Investigation

### Current behaviour

The merge yields entries in ascending internal-key order, so all versions of a
given `(namespace, userKey)` are **contiguous, oldest→newest** (HLC ascending),
because the internal key is `…[userKey][hlc][type]` and HLC is big-endian
([key_codec.dart:152](../packages/kmdb/lib/src/engine/util/key_codec.dart#L152)).
`_sameKey` compares the whole internal key, so only *byte-identical* records
(same key, HLC, and type) are ever collapsed. Nothing drops superseded versions
or tombstones.

### Two reclamation operations with very different safety

**1. Version collapse — safe at any compaction level.** For a group of versions
of one user key, keep only the highest-HLC entry and drop the rest. This is
always safe because the read path re-merges **all** levels: if a non-input level
holds an even-higher-HLC version it still wins; if it holds a lower one it is
correctly superseded. So collapsing *within the inputs* can never change a read
result on this device, and LWW makes it safe across devices too (a peer's older
version always loses regardless). This is the big, low-risk win.

**2. Tombstone drop — only safe under two conditions.** A tombstone suppresses
older versions of its key. Dropping it is safe **only if**:
- (a) **No older version of that key can exist in any level not included in this
  compaction.** In KMDB's scheme that effectively means the *all-levels*
  compaction (`_compactAll` / the single-file collapse,
  [lsm_engine.dart:678](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L678)).
  A partial compaction (`_compactL0ToL1`, `_compactL1ToL2`) must **not** drop
  tombstones — a lower-HLC value for the key may live in an excluded level and
  would resurrect. Note KMDB levels do **not** imply recency (sync ingest adds
  old-HLC data to L0), so "bottom level" alone is insufficient; the safe rule is
  "this compaction covers all on-disk data for the key."
- (b) **Every device has already observed the delete** (synced databases only).
  This is the distributed-tombstone-GC problem: if device A drops a tombstone
  (hlc=100) and peer B later ingests/sends an older value (hlc=50) for that key,
  A would resurrect the deleted row. A local-only database has no peers and can
  drop immediately.

The review's one-line H4 fix ("drop tombstones at the bottom-most level") misses
both (a)'s level-recency subtlety and (b)'s sync hazard. (b) is the real design
work.

### The sync horizon for safe tombstone GC

KMDB already tracks, per device, a high-water mark
([highwater.dart](../packages/kmdb/lib/src/sync/highwater.dart)): each `.hwm`
file records the device's `currentHlc` and the highest HLC it has processed per
peer. The principled GC horizon is **`min` of all devices' `currentHlc`** — every
device has synced past it, so a tombstone with `hlc < horizon` can be dropped
without risk of resurrection. The wrinkle: compaction runs in the engine and does
not read the sync folder today, so the horizon must be supplied to it.

### Vault ref-count boundary (no double counting)

Version collapse needs **no** vault ref adjustment: ref counts are maintained at
*write* time by `VaultRefInterceptor` (it diffs old vs new document URIs), so by
the time compaction drops an old version, its refs were already accounted. Only
the `$ver:` trim introduced by document versioning needs compaction-time ref
decrements (its entries are independent ref holders) — that stays in the
versioning plan, not here.

### Link to document versioning (`plan_document_versioning.md`)

This is the key cross-plan dependency the user flagged:

- Versioning **retains history**, but in separate `$ver:{ns}:{docKey}:{hlcHex}`
  entries — the *main* namespace still only needs the newest version. So H4's
  collapse must apply to normal namespaces, while **`$ver:` namespaces must be
  exempt from collapse** and instead get versioning's keep-N / retention-window
  policy.
- Therefore H4 should expose a **per-namespace-class reclamation policy** hook;
  versioning registers the `$ver:` policy in H4's framework (its Phase 3 becomes
  "register the `$ver:` retention predicate," not "build trim from scratch").
- Versioning's "undo a delete within the retention window" works by *promoting* a
  `$ver:` entry (a new write), so dropping the main-namespace document tombstone
  per H4 does **not** break it — the history is independent.
- Net: **author H4 first** as the framework; update the versioning plan to depend
  on it (done — see that plan's Dependencies).

### Files to change

| File | Change |
|------|--------|
| `lib/src/engine/compaction/compaction_job.dart` | Reclamation pass over `merge.entries`: group by `(ns, userKey)`, apply policy (collapse always; tombstone-drop only when `allLevels && hlc < horizon`) |
| `lib/src/engine/compaction/merge_iterator.dart` | No semantic change required (it already yields grouped/sorted entries); optionally expose helpers |
| `lib/src/engine/kvstore/lsm_engine.dart` | Pass `allLevels` (true only for `_compactAll`/single-file) and the GC horizon into `CompactionJob`; thread the horizon from config/sync |
| `lib/src/engine/kvstore/kv_store.dart` (config) | Add `tombstoneGraceDuration` and/or a way to inject the sync GC horizon |
| `lib/src/engine/compaction/*` (policy hook) | Per-namespace-class reclamation policy seam for versioning to extend |
| `docs/spec/06_storage_engine.md`, `12_sync.md`, `18_concurrency.md` | Document reclamation, the all-levels rule, and the tombstone GC horizon |

## Decisions (confirmed 2026-05-27)

- [x] **D1 — Tombstone GC horizon mechanism.** _Resolved (revised from the
  recommendation):_ **always require a horizon — drop the local-only
  fast-path.** The original recommendation kept a "drop immediately when no
  sync configured" branch, but that is unsafe across a retroactive local →
  synced transition: a previously-local DB that has already GC'd its
  tombstones can resurrect deleted data on first sync if any peer still holds
  an older copy. The revised rule:
  - **Synced database:** horizon = `min(currentHlc)` across all devices' HWM
    files (principled, exact — every device has synced past it).
  - **Local-only database:** horizon = `now - tombstoneGraceDuration`
    (wall-clock, conservative — gives the user a grace window during which
    sync can be enabled without losing tombstones). Default grace ≥ expected
    max sync lag (target a week or so unless we have a reason for shorter).
  - Horizon is *injected* into `CompactionJob` so compaction stays decoupled
    from the sync folder.
  - **All of D1 is PR2 scope** — recorded here for context. The wiring lives
    in [plan_tombstone_gc.md](plan_tombstone_gc.md).
- [x] **D2 — Where reclamation lives.** _Confirmed as recommended:_ a streaming
  transform in `CompactionJob.run` wrapping `merge.entries` (the merge already
  delivers sorted, grouped versions). Keeps `MergeIterator` general. PR1
  introduces the transform for collapse; PR2 extends it with the
  tombstone-drop policy.
- [x] **D3 — Version collapse first, tombstone GC second.** _Confirmed as
  recommended:_ collapse + policy hook + `$ver:` exemption ship as **PR1
  (this plan)**; tombstone GC + horizon wiring + sync-resurrection tests ship
  as **PR2 ([plan_tombstone_gc.md](plan_tombstone_gc.md))**. Each PR is
  independently reviewable; the risky distributed part is isolated.
- [x] **D4 — `$ver:` exemption.** _Confirmed as recommended:_ PR1 introduces a
  per-namespace-class reclamation policy interface and registers a default
  "collapse-to-newest" policy plus an explicit "retain all" policy for
  `$ver:`. The document-versioning plan supplies its real keep-N / retention
  predicate later by replacing the placeholder retain-all rule.

## Implementation plan (PR1 — version collapse + policy hook)

> Steps 3 and 4 of the original H4 plan (safe tombstone GC, horizon wiring) and
> their associated tests/docs are **deferred to [plan_tombstone_gc.md](plan_tombstone_gc.md)
> (PR2)**. The checklist below is PR1-only.

### Step 1 — Version collapse (safe at any level)
- [x] In `CompactionJob.run`, stream `merge.entries`, group by `(ns, userKey)`,
      emit only the highest-HLC entry per group. Keep tombstones for now (PR2
      handles tombstone GC).
- [x] Confirm via tests that reads are unchanged and SSTable size shrinks under
      repeated overwrites, both at `_compactAll` and at partial compaction levels.

### Step 2 — Reclamation policy hook
- [x] Introduce a per-namespace-class policy interface
      (`ReclamationPolicy`) with a default `collapse-to-newest` rule and an
      explicit `retain-all` rule used for `$ver:` (and any other
      history-bearing namespace class). Resolution is by namespace prefix.
- [x] Wire the resolver into `CompactionJob.run` so the streaming transform
      consults the policy per group.
- [x] Document the extension point so `plan_document_versioning.md` can later
      replace the placeholder `$ver:` retain-all rule with its real keep-N /
      retention predicate without further restructuring. (Documented inline
      in `reclamation_policy.dart` and in §6 of the spec; the extension
      mechanism is the optional `policyRegistry` argument on
      `CompactionJob`.)

### Step 5 — Tests (PR1 subset)
- [x] **Collapse reclaims space:** write a key M times across several flushes;
      after `_compactAll`, exactly one version remains; reads return the newest.
      (`lsm_engine_test.dart` — "H4 PR1: overwrites are collapsed by
      compaction".)
- [x] **Collapse safe in partial compaction:** versions split across L0/L1/L2;
      `_compactL0ToL1` collapses inputs but reads still return the global newest.
      (`compaction_test.dart` — "collapse applied within partial-level inputs".)
- [x] **Tombstones preserved by PR1:** writes followed by delete, then
      compaction, must retain the tombstone (PR1 makes no behavioural change to
      tombstones — PR2 owns dropping them). (`compaction_test.dart` —
      "tombstones are NOT dropped by PR1".)
- [x] **`$ver:` exemption:** `$ver:`-namespace entries are retained across
      compactions when the `retain-all` policy is registered; flipping back to
      the default policy proves the hook is what's exempting them.
      (`compaction_test.dart` — three tests under "$ver: exemption (H4 PR1
      policy hook)".)
- [x] **Policy hook surface:** unit-test policy resolution (collapse for normal
      namespaces, retain-all for registered prefixes, default fallback).
      (`reclamation_policy_test.dart` — 9 unit tests.)

### Step 6 — Documentation (PR1 subset)
- [x] `docs/spec/06_storage_engine.md`: document compaction version collapse
      and the reclamation policy hook. Reserve a forward reference to PR2 for
      tombstone GC.
- [x] `docs/spec/18_concurrency.md`: note compaction now reclaims space for
      overwrites (deletes still retain tombstones pending PR2).

### Step 7 — Verify (PR1)
- [x] `make pre_commit` clean (format_check, analyze, license_check,
      `pre_commit_test`) — 1402 tests pass (+17 new vs `main`).
- [x] `dart test packages/kmdb` passes from the worktree.
- [ ] Benchmark: confirm SSTable size no longer grows unbounded under an
      overwrite workload (deletes still grow — that's PR2's territory). _Covered
      by the `lsm_engine_test.dart` "H4 PR1" test (post-compaction SSTable
      contains exactly one entry per overwritten key); a dedicated
      `benchmark/` workload is out of scope for PR1._

### Step 8 — PR
- [ ] Open PR1 against `main`; update **PR link** above; on merge move this
      plan to `docs/plans/completed/` and unblock PR2.

## Summary

{To be completed during implementation.}
