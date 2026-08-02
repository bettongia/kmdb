# Move `gen:{ns}` generation counters off synced `$meta`; fix cross-device cache invalidation & reactivity (WI-13)

**Status**: **Investigated**

**PR link**: _(none yet)_

> **Provenance.** WI-13 of the [0.10.01 hardening track](../roadmap/0_10_01.md) —
> the **last** device-local-vs-replicated `$meta` entry (WI-11 moved index/FTS/Vec
> state + the tombstone floor; WI-12 removed `device_id`; WI-14 moved the dirty
> flag). Spun out of WI-11's Phase 3 audit (Q-C) because, unlike the mechanical
> `$$` moves, `gen` is read **cross-device** for cache invalidation today, so
> "make it device-local" is not correct on its own — it must be paired with an
> ingest-side fix. Grounded with `kmdb-architect` (2026-07-29); the direction and
> the two sub-decisions below were confirmed with the maintainer before drafting.
> Code coordinates verified against `main` (HEAD `7b21754`, post-WI-14).

## Problem statement

`gen:{ns}` namespace generation counters are written to `$meta` and bumped on
every local `WriteBatch` (`MetaStore.appendGenerationCounterBump`). The Cache
Layer (`cache_layer.dart`) uses them to invalidate the session object cache: each
entry is keyed by `(namespace, key, gen)`, so a changed `gen` makes the old entry
unreachable (lazy invalidation in `get()`), and `writeEvents` drive proactive
eviction. Because `$meta` **replicates**, this is wrong in three distinct ways:

1. **LWW-backwards cache resurrection (latent correctness bug).** `$meta` resolves
   by Last-Write-Wins on HLC. A peer's later-HLC-but-**lower** `gen` value can move
   the counter *backwards*. Unlike a spurious forward change (harmless miss), a
   backwards move can land on a value that **matches a still-cached stale entry**,
   resurrecting it — the cache serves data from before the newer writes. This is a
   silent-wrong-results bug (session cache only; the underlying LSM data is intact).

   > **Reviewer correction (mechanism — this matters for test #2).** The session
   > cache (`session_cache.dart`) is keyed by **`(namespace, key)` only** — the
   > generation is stored as a *discriminator field* on the entry, not part of the
   > LRU key (`_cacheKey` = `'$namespace\x00$key'`, `SessionCache.get` returns the
   > entry only when `entry.generation == generation`, `SessionCache.put`
   > **overwrites** the single entry per `(ns,key)`). So a gen mismatch produces a
   > **miss without removing the stale entry** — the stale `(ns,key)`→`(G, V1)`
   > entry **physically persists** in the LRU until it is either overwritten by a
   > later `put` or proactively purged by `evictNamespace`. *That physical
   > persistence is the whole bug.* Resurrection is only reachable when the store is
   > advanced to `V2` by a source that does **not** proactively evict — i.e. an
   > **ingest** (which today emits only `$sync`, so `_onWriteEvent` skips it and the
   > stale entry is never evicted) — and gen is then moved back to `G`. A *local*
   > write can never resurrect, because `_onWriteEvent(ns)` fires `evictNamespace`
   > and removes the stale entry. The plan's earlier "keyed by `(ns,key,gen)`"
   > wording was imprecise and, taken literally, would lead an implementer to write
   > a **vacuous** test #2 (see the corrected construction in Test surface).

2. **Cross-device invalidation secretly depends on replication.** When device B
   ingests device A's SSTable (new docs for `ns`), A's higher `gen:ns` rides in via
   `$meta`, and B's lazy `get()` re-reads it and self-invalidates. `ingestAt0`
   emits only a generic `$sync` writeEvent (not the affected user namespaces), so
   the *proactive* path never invalidates user-namespace caches on ingest —
   correctness rests **entirely** on the replicated `gen`. This is exactly why the
   counter cannot simply be moved device-local like its five siblings without a
   compensating ingest-side bump.

3. **The spec claims an invalidation that does not happen (false spec claim).**
   §15 states that on sync the generation counter is bumped. It is not — `ingestAt0`
   bumps nothing. The real (accidental) mechanism is defect #2's replicated-value
   read. §15 must be corrected regardless of which fix we choose.

Two adjacent issues this WI also resolves (maintainer-approved scope):

4. **Cross-device reactivity gap.** `watch()`/`stream()` re-execute on `writeEvents`
   for their namespace (§14). Ingest emits only `$sync`, so a `watch('notes')` does
   **not** re-fire when a peer's `notes` data is ingested — reactive queries are
   stale across devices until a local write to that namespace. Fixing ingest to emit
   per-namespace writeEvents closes this.

5. **`$cache` misclassification.** The persisted materialised-view cache (`$cache`,
   §15) — designed for mobile/web where processes are silently killed — is **pure
   spec with zero code writers** and is classified single-`$` (syncable). A
   per-device materialised view must never sync. It is reclassified local-only
   (`$$cache`) here so the generation-counter design keeps it viable.

## Decision (confirmed with maintainer, 2026-07-29)

- **Option A — device-local `$$genstate` + bump-on-ingest.** Move `gen` to a
  local-only `$$genstate` namespace and have the ingest path bump the local
  counter so the cache invalidates. **Option B** (keep `gen` replicated in `$meta`
  with max-merge) is **rejected**: `$meta`'s LWW is value-opaque, so max-merge would
  require value-aware merge special-cased for `gen` keys in the LSM merge/compaction
  path — invasive, with no engine precedent.
- **A1 (persist), not A2 (in-memory).** Persist the counter in `$$genstate`
  (relocating today's already-persisted counter), rather than an in-memory-only
  counter. A2 has no correctness cost *today* but forecloses a functional persisted
  materialised-view cache; A1 keeps `$$cache` viable and preserves the gen's
  survival across process death (mobile/web). Consequently, **`$cache` is kept and
  reclassified to `$$cache`** (spec-only fix; no code, since it is unimplemented).
- **Include the reactivity fix (#4)** in this WI: ingest emits per-namespace
  writeEvents so `watch()`/`stream()` update live when peer data arrives.

## Investigation

### Mechanism (verified against `main`)

- `MetaStore` gen methods, all writing `kNamespace` (`$meta`):
  `getGenerationCounter` (meta_store.dart:92), `incrementGenerationCounter` (110),
  `appendGenerationCounterBump` (137), `genKey`/`_genKey` (154/156), and the
  `unregisterNamespace` gen delete (342).
- `CacheLayer._readGeneration` (cache_layer.dart:287) reads
  `_store.get(MetaStore.kNamespace, MetaStore.genKey(namespace))`. Lazy `get()`
  (135) keys the session cache by this value; `_onWriteEvent` (256) and `onResume`
  (244) evict proactively. `onResume` re-reads persisted gens after suspension —
  **a persisted gen is required** for the mobile/web resume path to detect changes,
  which A1 satisfies and A2 would not.
- `LsmEngine.ingestAt0` (lsm_engine.dart): validates, floor-checks, `advanceClock`,
  appends a `VersionEdit` admitting the file, adds to `_levels`, then emits
  `_writeEventsController.add(r'$sync')` (1339). Bumps no gen.
- `KvStoreImpl.ingestSstable` (kv_store_impl.dart:307) writes+fsyncs the file,
  `syncDir`s, then calls `_engine.ingestAt0(filename)` last — so a gen bump inserted
  **before** that call is durable (WAL fsync) ahead of the manifest edit.

### The fix, by area

1. **Relocate the counter.** Add `MetaStore.kGenStateNamespace = r'$$genstate'`
   (doc comment mirroring `kGcStateNamespace`/`kDirtyStateNamespace`: why it moved,
   the LWW-backwards resurrection hazard, local-only guarantee). Switch all gen
   methods from `kNamespace` to it. Repoint `CacheLayer._readGeneration` to read
   `kGenStateNamespace`. Value/key encoding and the cache keying are unchanged.

2. **Bump on ingest (correctness for #2).** In `KvStoreImpl.ingestSstable`, before
   `_engine.ingestAt0`, bump the local `$$genstate` counter for the affected
   namespaces, durably (WAL) so the bump is ordered before the manifest edit that
   makes the ingested data visible. *A crash between the bump and the manifest edit
   leaves gen bumped with no new data — a harmless spurious cache miss; the reverse
   ordering would leave new data visible under a stale gen ⇒ stale cache.* See the
   open question on **which** namespaces to bump.

3. **Per-namespace reactivity (#4).** Have ingest emit a `writeEvent` per affected
   namespace (in addition to, or instead of, `$sync`) so `watch()`/`stream()`
   re-fire. This shares the "affected namespaces" computation with the gen bump.

4. **`$cache` → `$$cache` (#5).** No code **writers** exist (verified: grep for
   `$cache` across `packages/kmdb/lib` finds only doc-comment mentions). It is
   *not* strictly spec-only, though: 7 code **doc-comments** name `$cache`
   (cache_layer.dart:149, cache_tier.dart:27/67, kmdb_database.dart:213,
   kmdb_collection.dart:86, reclamation_policy.dart:103, kv_store_impl.dart:537).
   Update those to `$$cache` too so the code docs and spec agree.

5. **Spec/doc truth (#3).** Correct §15's false "sync bumps gen" claim to describe
   the real device-local + bump-on-ingest mechanism.

## Open questions

- [x] **Q1 — which namespaces does ingest bump/emit: precise or over-broad?**
  **RESOLVED (reviewer, 2026-08-03): uniform PRECISE, computed once from the
  ingested SSTable and reused for both the gen bump and the per-namespace
  writeEvents.**

  Rationale (the decisive argument is consistency, not just tidiness): the
  **local** `writeBatch` path is already **precise** — `LsmEngine.writeBatch`
  collects `namespaces.add(entry.namespace)` (lsm_engine.dart:401) and emits one
  writeEvent per *distinct namespace actually written* (lsm_engine.dart:419-420).
  A local multi-namespace write therefore fires only the affected watchers. If
  ingest were over-broad, cross-device reactivity would obey a **different**
  contract from local reactivity (fire *all* watchers vs only affected), and every
  live `watch()`/`watchKey()` would receive a **redundant duplicate emission on
  every unrelated peer sync** (`watchKey` is *not* debounced — kmdb_collection.dart:154
  emits immediately). Since the reactivity fix is a first-class deliverable of this
  WI, it should match the established precise semantics, not overshoot them.

  The plan's proposed "over-broad gen bump + precise writeEvents (reuse the set for
  both)" is **incoherent** and is rejected: a single shared set cannot be
  simultaneously over-broad (for gen) and precise (for emit). Once you scan for
  precise emits you *have* the exact set, so bumping gen from that same set is
  strictly simpler than *also* calling `getNamespaces()`. The real choice was
  binary (uniform over-broad vs uniform precise); precise wins on the consistency
  argument above.

  **Feasibility confirmed:** the primitives exist and the work is mechanical —
  `SstableReader.scan()` yields `SstEntry`s whose `.key` is the internal
  (namespace-prefixed) key, and `KeyCodec.decodeNamespace(Uint8List)` extracts the
  namespace. The reader is *already open* inside `ingestAt0` (via `_tableCache.open`,
  lsm_engine.dart:1254), so the scan reuses it with no extra file open.

  **Accepted tradeoff:** precise reads every data block of the ingested SSTable
  (front-loaded I/O on the ingest path; noticeable on full-resync / OPFS). This is
  proportionate — ingest is already heavyweight (write + fsync + syncDir + manifest
  append) and the blocks are read into page cache that a follow-up query would read
  anyway. If profiling later shows ingest-path regression on bulk resync, the scan
  can be swapped for over-broad without touching the correctness design.

  **Placement (this corrects the plan — see Reviewer findings §A):** do the scan +
  gen bump + emit **inside `ingestAt0`, after the GC-floor check passes
  (lsm_engine.dart:1273) and before the manifest append (lsm_engine.dart:1327)** —
  *not* in `KvStoreImpl.ingestSstable` before `_engine.ingestAt0` as the draft says.
  Bumping in `KvStoreImpl` would (a) require a second reader open from `bytes`, and
  (b) bump gen / emit reactivity events even for SSTables that `ingestAt0` will
  **reject** via `StaleSstableIngestException` (the floor check lives *inside*
  `ingestAt0`), spuriously waking every affected watcher for data that never became
  visible. Engine-side placement after the floor check fixes both and still lands
  the WAL-durable bump ahead of the manifest append (ordering preserved).

- [x] **Q2 — does any `watch()`/`stream()` terminal already react to `$sync`?**
  **RESOLVED (reviewer, 2026-08-03): NO consumer reacts to `$sync`; the
  per-namespace emit is purely additive — no regression risk. Keep the `$sync`
  emit (harmless, no external contract) and add the per-namespace emits alongside
  it.**

  Verified against `main`: `$sync` is *emitted* at exactly one site
  (lsm_engine.dart:1339) and *consumed* nowhere. `KmdbQuery.watch/stream`
  (kmdb_query.dart:280) and `KmdbCollection.watchKey` (kmdb_collection.dart:154)
  both early-out with `if (ns != namespace)` / `if (ns == namespace)`, so a
  `$sync` event matches no user namespace. `CacheLayer._onWriteEvent`
  (cache_layer.dart:263) explicitly skips any `$`-prefixed namespace. Grep for
  `$sync` across `packages/*/lib`+`bin` returns only the one emit and doc-comment
  mentions. **Bonus:** because `_onWriteEvent` *does* act on a bare user namespace,
  the new per-namespace ingest emit also fixes the **proactive cache eviction** gap
  on ingest (defect #2), not just `watch()` reactivity — one emit closes both.

## Implementation plan

- [ ] Add `MetaStore.kGenStateNamespace = r'$$genstate'` with a rationale doc
      comment; switch `getGenerationCounter`, `incrementGenerationCounter`,
      `appendGenerationCounterBump`, `_genKey`, and the `unregisterNamespace` delete
      to it. Update the class-level doc comment listing `$meta` residents.
      Keep the `EncryptionEnvelope.wrap`/`unwrap` on the gen value — relocating the
      namespace does **not** change encoding; `$$genstate` values stay encrypted
      exactly like `$$dirtystate`/`$$gcstate` (do not accidentally drop the wrap).
- [x] **VERIFIED (reviewer):** `$$` reads *are* permitted through the cache's
      `KvStore.get` path — `KvStoreImpl.get` calls `_engine.get(normaliseNamespace(...))`
      with no `$`-guard (the guard is write-only). `isLocalOnly` is prefix-based
      (`ns.startsWith(r'$$')`, namespace_codec.dart:148), so `$$genstate` is
      automatically sync-excluded with no new wiring.
- [ ] Repoint `CacheLayer._readGeneration` (cache_layer.dart:287) to
      `kGenStateNamespace`.
- [ ] **Ingest bump + emit — engine-side, per Q1/§A.** Inside `LsmEngine.ingestAt0`,
      **after** the GC-floor check (lsm_engine.dart:1273) and **before** the manifest
      append (:1327):
      1. Scan the already-open `reader` (`reader.scan()`), decode each entry's
         namespace via `KeyCodec.decodeNamespace(entry.key)`, collect a
         `Set<String> affected`.
      2. Bump the local `$$genstate` counter for each `ns` in `affected`. Prefer a
         **single `WriteBatch`** of `appendGenerationCounterBump(ns, batch)` +
         `_engine.writeBatch(batch)` (one WAL frame, one fsync, atomic) over N
         separate `incrementGenerationCounter` puts. The WAL fsync makes the bump
         durable ahead of the manifest append (ordering: safe-on-crash, see #2).
         Guard on `_metaStore != null` (mirrors the floor-check guard).
      3. After the manifest append + `_levels` update, emit one writeEvent per `ns`
         in `affected` (`_writeEventsController.add(ns)`), then keep the existing
         `$sync` emit (Q2: additive, harmless).
- [ ] Tests (see Test surface).
- [ ] Docs: §15 (correct the false "sync bumps gen" claim + describe device-local
      `$$genstate` + bump-on-ingest; reclassify `$cache` → `$$cache` local-only);
      registry row 48 (finalise `gen:{ns}` → `$$genstate`, drop the `⚠`); §12
      (:501-509 sync-exclusion list); §14 (cross-device reactivity now works via
      per-namespace ingest events); `docs/roadmap/0_10_01.md` (`$meta` end-state
      table row + mark WI-13 done + tick exit criterion); **CLAUDE.md:423-424**
      (generation counters now `$$genstate` local-only, not `$meta`). Route spec
      wording through `kmdb-architect`.
- [ ] `kmdb-qa` sign-off; `kmdb-pre-commit`; **also run `cd packages/kmdb_cli &&
      dart test`** and grep other packages for `gen`/`$meta`/`listSync` assumptions
      (the kmdb-only gates missed a `kmdb_cli` regression in WI-14 — commit `e7ea7cb`).
      Open PR; move plan to `docs/plans/completed/`.

## Test surface

Existing gen tests drive the public cache/`MetaStore` API and should pass unchanged
(the counter still works; only its namespace moved). **Added** (each must fail
before the corresponding fix):

1. **Device-local isolation.** After a write, the `gen:{ns}` entry is present under
   `MetaStore.symbolicKey('gen:{ns}')` in `$$genstate` and **absent** from `$meta`
   (analogue of WI-12/WI-14 absence assertions).
2. **LWW-backwards resurrection is closed (defect #1).** Deterministic, on-disk
   regression. **Construction matters — the naive version is vacuous** (see the
   Reviewer correction under defect #1). The stale entry must *survive* in the LRU
   until the backwards move, which means the store must be advanced by an **ingest**,
   never by a local write (a local write fires `evictNamespace` and removes it,
   masking the bug). Sequence:
   1. `get(ns, key)` → caches `(ns,key)`→`(G, V1)` at gen `G`.
   2. **Ingest** a synthetic SSTable carrying the fresh doc `ns/key = V2` (higher
      HLC) **and** a `$meta` `gen:ns = G+1`. Store now holds `V2` and (pre-fix)
      `$meta` gen `G+1`. Ingest emits only `$sync`, so `_onWriteEvent` skips it and
      the `(G, V1)` entry is **not** evicted — it persists.
   3. **Ingest** a second synthetic SSTable carrying `$meta` `gen:ns = G` at an HLC
      **later** than step 2's. Pre-fix, `$meta` LWW moves gen **back to `G`**.
   4. `get(ns, key)` → pre-fix reads gen `G`, hits the surviving `(G, V1)` entry,
      returns **stale `V1`** (resurrection). Assert it returns **`V2`**.
   Post-fix: gen lives in `$$genstate`; the ingested `$meta` gen entries are inert,
   and step 2's bump-on-ingest raises the local counter *and* emits a per-namespace
   writeEvent that proactively evicts `(G, V1)`, so step 4 misses and reads `V2`.
   **Must fail with the relocation reverted** (gen back in `$meta` and the
   bump/emit removed) — otherwise the test is not exercising the defect. Use a real
   on-disk store / `FaultyStorageAdapter`, never an in-memory adapter (CLAUDE.md;
   [[reference_lww_erasure_test_technique]]).
3. **Cross-device cache invalidation after ingest (defect #2).** Device A writes
   `ns`; B ingests A's SSTable; B's cached `get(ns, key)` returns the **fresh**
   ingested value, not a stale cache hit. Verify it fails without the bump-on-ingest.
4. **Cross-device reactivity (defect #4).** A `watch('ns')`/`stream('ns')` on device
   B re-fires when A's `ns` data is ingested. Verify it fails without the
   per-namespace writeEvent.
5. **Ingest bump durability/ordering.** Under `FaultyStorageAdapter`, inject a crash
   *between* the WAL-durable gen bump and the manifest append inside `ingestAt0`.
   On reopen, assert: the `$$genstate` gen for the affected ns **is** bumped (the
   WAL frame replays), and the ingested SSTable is **not** admitted (no manifest
   edit ⇒ orphan swept by crash recovery) ⇒ a spurious cache miss, never a stale
   hit. Also assert the *reverse* ordering would be unsafe (documented, not
   necessarily coded). Fault-injection per CLAUDE.md, not golden-path.

6. **`onResume` with the relocated counter.** On a mobile/web `CacheTier`, cache an
   entry, advance the persisted `$$genstate` gen out-of-band (as a background sync
   would), call `onResume`, and assert the stale entry is evicted. Confirms the
   persisted-gen resume path (`onResume` → `_readGeneration`) still works after the
   namespace move (A1's motivation). Small, but cheap insurance that the repoint
   didn't silently break the resume path.

## Reviewer findings (2026-08-03)

Verified against `main` @ `7b21754`. **Status set to `Investigated`** — Q1 and Q2
are resolved to concrete decisions above; no design decisions remain for the
implementer. The three defects and the two adjacent issues are all real and
correctly diagnosed. Findings, in priority order:

- **§A — Placement of the bump/emit was wrong; corrected (blocking, now fixed).**
  The draft put the gen bump in `KvStoreImpl.ingestSstable` before `_engine.ingestAt0`.
  But the GC-floor check (`StaleSstableIngestException`) lives *inside* `ingestAt0`
  (lsm_engine.dart:1264-1273), so a `KvStoreImpl`-side bump would fire for SSTables
  that get **rejected** — bumping gen and (worse) waking every affected `watch()`
  for data that never becomes visible. It would also need a second reader open from
  `bytes`. **Resolved:** do scan + bump + emit inside `ingestAt0`, after the floor
  check and before the manifest append, reusing the already-open reader. Ordering
  (WAL-durable bump before manifest append) is preserved. Verified `_engine.put`/
  `writeBatch` fsync the WAL (wal_writer.dart:96/146-147) and that `ingestAt0`
  appends the manifest at :1327 — so the durability/atomicity claim in defect #2 is
  **sound**.

- **§B — Defect #1's mechanism was mis-stated; corrected (blocking, now fixed).**
  The cache is keyed by `(ns,key)` with gen as a match-*field*, not `(ns,key,gen)`.
  The stale entry physically persists on a gen mismatch and is only reachable-again
  because **ingest doesn't evict**. This is the crux of the bug and the reason test
  #2's construction must advance the store via *ingest*, not a local write.
  Corrected the problem statement and rewrote test #2 to avoid a vacuous pass. The
  defect is real; the plan just described it loosely.

- **§C — Q1 resolved to uniform precise.** The clinching argument is **consistency
  with the local `writeBatch` path**, which is already precise (lsm_engine.dart:401,
  419-420); over-broad ingest would give cross-device reactivity a different,
  noisier contract (undebounced duplicate `watchKey` emissions on every unrelated
  sync). The draft's "over-broad gen + precise emit, shared set" hybrid is
  incoherent and was rejected. Tradeoff (full data-block scan on ingest)
  acknowledged and accepted.

- **§D — Q2 resolved.** Nothing consumes `$sync`; the per-namespace emit is
  additive and, as a bonus, also fixes proactive cache eviction on ingest (defect
  #2), not just `watch()` reactivity.

- **§E — Encryption invariant (non-blocking, folded into checklist).** The gen
  value is `EncryptionEnvelope`-wrapped in both `MetaStore` and
  `CacheLayer._readGeneration`. Relocating the namespace must **keep** the wrap;
  `$$genstate` values stay encrypted like `$$dirtystate`/`$$gcstate`. Called out so
  the mechanical move doesn't accidentally drop it.

- **§F — `$cache` reclassification isn't purely spec (non-blocking, folded in).**
  Zero writers confirmed, but 7 code doc-comments name `$cache`; update them to
  `$$cache` for code/spec agreement.

- **§G — `unregisterNamespace` (meta_store.dart:342)** deletes `_genKey` from
  `kNamespace`; the checklist's "switch all gen methods" already covers it, but the
  implementer must not miss this one `delete` — it must target `$$genstate` too, or
  a stale gen row is orphaned in `$meta` on collection deletion.

- **§H — Reader-scan namespace decode is mechanical.** `SstableReader.scan()` yields
  `SstEntry.key` = the internal (namespace-prefixed) key (sstable_reader.dart:64-67),
  and `KeyCodec.decodeNamespace` (key_codec.dart:191) extracts the namespace. No new
  primitive needed. Ingested peer SSTables may also surface system namespaces
  (`$meta`, `$ver`, `$vault`); bumping/emitting for those is harmless (cache skips
  `$`, watchers filter by user namespace) — no special-casing required.

Doc touch-point list spot-checked and accurate: §15:49-56 does make the false
"on sync … counters incremented" claim (defect #3 confirmed); §15:58-63 confirms
`$cache` is unimplemented spec; roadmap `0_10_01.md` carries the WI-13 rows
(:52, :269, :330) and the `$meta` end-state table (:291); CLAUDE.md's Cache Layer
section states gen counters live in `$meta`. Route spec wording through
`kmdb-architect` as the checklist says.

## Summary

_(to be written on completion)_
