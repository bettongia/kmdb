# Fix H4: Compaction reclaims no space (version collapse + safe tombstone GC)

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Opus, or strong-model review, for the tombstone-GC path
— the all-levels + sync-horizon rule is easy to get *almost* right and resurrect
deleted data; version collapse alone is fine for Sonnet.

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

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — Tombstone GC horizon mechanism.** Recommended: a **hybrid** —
  for a synced database, `min(currentHlc)` across all devices' HWM files
  (principled, exact); for a local-only database, drop immediately. Provide a
  conservative time-based `tombstoneGraceDuration` fallback when HWM data is
  unavailable. Keep the horizon *injected* into the engine so compaction stays
  decoupled from the sync folder.
- [ ] **D2 — Where reclamation lives.** Recommended: a streaming transform in
  `CompactionJob.run` wrapping `merge.entries` (the merge already delivers sorted,
  grouped versions). Keeps `MergeIterator` general.
- [ ] **D3 — Version collapse first, tombstone GC second.** Recommended: ship
  collapse (safe everywhere, large win) as a first PR; ship tombstone GC (gated by
  all-levels + horizon) as a second, so the risky part is isolated and separately
  reviewable.
- [ ] **D4 — `$ver:` exemption.** Recommended: H4 exempts `$ver:` (and any other
  history-bearing namespace class) from collapse via the policy hook; versioning
  supplies the retention predicate. Default policy for all other namespaces:
  collapse + conditional tombstone drop.

## Implementation plan

### Step 1 — Version collapse (safe at any level)
- [ ] In `CompactionJob.run`, stream `merge.entries`, group by `(ns, userKey)`,
      emit only the highest-HLC entry per group. Keep tombstones for now.
- [ ] Confirm via tests that reads are unchanged and SSTable size shrinks under
      repeated overwrites.

### Step 2 — Reclamation policy hook
- [ ] Introduce a per-namespace-class policy interface (`collapse-to-newest` vs a
      caller-supplied predicate). Default = collapse. Exempt `$ver:` (reserved for
      versioning) so it is never collapsed by H4.

### Step 3 — Safe tombstone GC
- [ ] Thread an `allLevels` flag into `CompactionJob` — true only for
      `_compactAll`/single-file collapse; false for partial compactions.
- [ ] Thread a GC horizon (HLC) into `CompactionJob` per D1.
- [ ] Drop a group's surviving tombstone only when `allLevels == true` **and**
      its `hlc < horizon`. Never drop tombstones in partial compactions.
- [ ] For a local-only database (no sync configured), set horizon = "now" so
      tombstones drop promptly.

### Step 4 — Config / horizon wiring
- [ ] Add `tombstoneGraceDuration` (and/or horizon injection) to `KvStoreConfig`;
      document the default conservatively (e.g. ≥ expected max sync lag).
- [ ] Provide the sync layer a way to compute `min(currentHlc)` from HWM files and
      hand it to the engine before compaction (or via config refresh).

### Step 5 — Tests
- [ ] **Collapse reclaims space:** write a key M times across several flushes;
      after `_compactAll`, exactly one version remains; reads return the newest.
- [ ] **Collapse safe in partial compaction:** versions split across L0/L1/L2;
      `_compactL0ToL1` collapses inputs but reads still return the global newest.
- [ ] **Tombstone dropped only when safe:** in `_compactAll` with `hlc < horizon`,
      the tombstone is gone and the key reads as absent.
- [ ] **Tombstone NOT dropped in partial compaction:** delete a key with an older
      value in an excluded level; partial compaction keeps the tombstone; the key
      stays deleted (no resurrection).
- [ ] **No resurrection across sync (CI-testable):** delete + `_compactAll`-drop a
      tombstone whose `hlc >= horizon` must be **refused**; then `ingestSstable` a
      crafted older-HLC SSTable for that key and assert the key is **not**
      resurrected. (Construct the pre-delete value in an SSTable and ingest it.)
- [ ] **Local-only drops promptly:** no sync configured → tombstone dropped in the
      next `_compactAll`.
- [ ] **`$ver:` exemption:** with the versioning policy registered, `$ver:`
      entries are retained per keep-N/retention, not collapsed.

### Step 6 — Documentation
- [ ] `docs/spec/06_storage_engine.md`: document compaction reclamation (collapse
      + tombstone GC), the all-levels rule, and the level-recency caveat.
- [ ] `docs/spec/12_sync.md`: document the tombstone GC horizon (`min` HWM) and
      why early tombstone drop would resurrect deleted data.
- [ ] `docs/spec/18_concurrency.md`: note compaction now reclaims space.

### Step 7 — Verify
- [ ] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
- [ ] `make analyze` clean. Benchmark: confirm storage no longer grows unbounded
      under an overwrite/delete workload.

> A `kmdb_harness` multi-device scenario should also assert no tombstone
> resurrection after cross-device sync once `plan_harness_mixed_storage.md`
> lands; the in-process ingest test above covers the core case in CI without it.

## Summary

{To be completed during implementation.}
