# Harden `close(flush:true)` against `SyncAuthException` on the tombstone-GC-horizon path

**Status**: Investigated — reviewed by `kmdb-plan-reviewer` on `main` @ `b846430`
(2026-09-10). Failure chain, disposition, call-site audit, §34 agreement, and
fault-injection test plan all independently re-verified against current code; see
the review note at the end. Ready for `kmdb-plan-implement`.

**PR link**: _(none yet)_

> **Provenance.** Found by `kmdb-qa` during the 0.1.0 integration-guide review
> (2026-09-07, [PR #89](https://github.com/bettongia/kmdb/pull/89)) as its
> "finding #2" — a **pre-existing core-library bug**, orthogonal to the guide,
> that the guide's authenticated-sync demo merely surfaced. The user elected to
> **fix it before the 0.1.0 tag** (rather than defer to 0.2.0), so it rides the
> 0.10.01 hardening track as a pre-tag gate item.

## Problem statement

When the sync folder contains a foreign / rotated / mismatched peer `.hwm` (the
exact hostile-input case WI-4 defends against — e.g. after an authenticated pull
against a peer this device cannot authenticate), the **next**
`KmdbDatabase.close(flush: true)` can throw an **uncaught `SyncAuthException`**,
escaping `close()` before it releases the LOCK — leaking the lock file and
skipping clean resource teardown, so the next `open()` can hit a lock conflict.
**Not data loss** (the durable flush steps complete first), but a real
robustness defect on the WI-4 exceptional path, and a gap in §34's
rejection-policy table.

> **Precision on "quarantine".** `SyncEngine.pull` quarantines A's **SSTables**
> (the `QuarantineReason.unauthenticated` records — Q1); there is **no** HWM
> quarantine concept. A peer's `.hwm` is never read by `pull` (which loads only
> *this* device's own HWM). A's `.hwm` simply sits in `highwater/`, untouched by
> the pull, and only detonates later when a compaction's horizon computation
> lists that directory and loads every file in it. The bug is therefore
> reachable **whether or not a pull ran** — all it needs is an unauthenticatable
> `.hwm` present in the sync folder and an all-levels compaction firing under an
> installed horizon provider. The pull is the realistic path that puts the file
> there and installs the provider, not a precondition of the throw.

### Verified failure chain (kmdb-qa, against `packages/kmdb`)

1. `SyncEngine`'s constructor registers the tombstone-GC-horizon provider on the
   store (`sync/sync_engine.dart:127-135`), and the closure captures
   `_cloudAdapter` (the `SyncAuthenticatingAdapter`). **It is never cleared**
   after sync returns (no `setTombstoneHorizonProvider(null)` anywhere), so it
   persists on the store for the lifetime of the `KmdbDatabase`. *(Verified on
   `main` @ `a813f37`.)*
2. `KmdbDatabase.close({flush: true})` → `_cache.close(flush)` →
   `LsmEngine.close` (`lsm_engine.dart:1590`) → `flush()`
   (called at line **1591**, guarded by `_active.length > 0`) → flush step 6
   `_compactIfNeeded()` (called at `lsm_engine.dart:902`; method at 908). The
   **single-file compaction shortcut** fires when `totalFiles > 1` **and** total
   data ≤ `singleFileThresholdBytes` (512 KB) (`_compactIfNeeded`,
   `lsm_engine.dart:916-920`) — the common case for a small app — invoking
   `_compactAll()`.
3. `_compactAll()` (`lsm_engine.dart:1061`) computes the horizon at line **1077**
   via `_computeTombstoneHorizon()` (method at `lsm_engine.dart:266-273`). When a
   provider is registered it is invoked **uncaught** (`return provider();`, line
   **268**) → `HighwaterMark.minCurrentHlcAcrossDevices` → `HighwaterMark.load`
   on **every** file in `highwater/` (peers *and* this device's own) →
   `adapter.download` → `SyncAuthEnvelope.unwrap`, which throws
   `SyncAuthException` on any file it cannot authenticate.
4. `minCurrentHlcAcrossDevices` does **not** catch it — the per-file
   `HighwaterMark.load` at `sync/highwater.dart:143` sits inside the fold loop
   (`highwater.dart:142-161`) with no `try`/`on SyncAuthException` — so it
   propagates out through `_compactAll` → `_computeTombstoneHorizon` →
   `flush` step 6 → `close`, before `LsmEngine.close` reaches its
   `_tableCache.clear()` / `releaseLock()` / `_writeEventsController.close()`
   teardown (`lsm_engine.dart:1594-1596`; `releaseLock` is line **1595**).

### §34 spec gap — **fixed** (kmdb-architect's domain)

The "Per-site rejection policy" table (`docs/spec/34_sync_authentication.md`)
enumerated the peer-`.hwm`-load sites (`SyncEngine.pull`, `_fullResync`,
`consolidate`, own-HWM-load, `_checkAndHandleEviction` peer-HWM-load, lease CAS)
but **omitted** the compaction-triggered `_computeTombstoneHorizon` →
`minCurrentHlcAcrossDevices` peer-HWM load — a genuine gap in the table, not
only in the code. **Now closed:** grounding added the missing row (with the
`defer` disposition, not `skip`) plus an explanatory paragraph on why the
horizon row blocks while the sibling `_checkAndHandleEviction` row skips (the
`min`-monotonicity argument). Regenerate the HTML site with `make doc_site_html`
once this plan's code lands (or now, since the spec edit is independent).

## Disposition (grounded by kmdb-architect — **differs from the original draft**)

The draft proposed mirroring the `_checkAndHandleEviction` row: catch
`SyncAuthException` per-peer inside `minCurrentHlcAcrossDevices` and **skip** the
failed-auth peer's contribution. **Grounding rejected that disposition for the
horizon site**, because the sibling row's "skip" is *not* safe here — the two
sites feed the peer `min` into decisions with opposite safety gradients:

- The horizon **is** `min(currentHlc)` across the *included* devices. Dropping a
  device from a `min` can only make the result **larger or equal** — i.e.
  skipping a peer **raises** the horizon (it does **not** "leave the horizon
  un-advanced", which was the draft's — and the finding's — misconception).
- A raised horizon drops tombstones a genuinely-behind peer has **not** yet
  observed → **resurrection** on that peer once it re-syncs. Under the T1 threat
  §34 exists to close, the attacker *chooses* which peer's `.hwm` to forge (they
  need no key to write a garbage file named `<victim>.hwm`), so "skip the
  failed-auth peer" would hand a mere write-access adversary a
  **premature-GC / resurrection primitive** — the opposite of a fix.
- This is exactly why it differs from the stale-device eviction
  `minCurrentHlcAcrossDevices` *already* performs: that skip is licensed by an
  explicit "presumed permanently gone after `staleDeviceEvictionAfter`" policy;
  an auth failure carries **no** presumption of absence (the peer may be live —
  only its `.hwm` *file* was forged, or is a pre-enrollment legacy artefact, R-5).

**Adopted disposition: defer GC, do not skip.** On any `SyncAuthException` while
computing the horizon, return the conservative `Hlc(0, 0)` — block *all*
tombstone drops for that `_compactAll` round (identical to the value the
existing "no live devices" fallback already returns, `sync_engine.dart:134`).
This:

- keeps `close(flush: true)` **total** and the LOCK released — the actual bug;
- can **never** resurrect (blocking GC is the maximally-safe direction; its only
  cost is deferred reclamation — tombstones accumulate until the bad `.hwm` is
  removed or the sync set re-enrolled — and it self-heals);
- introduces **no** new T1 capability, so it is consistent with §34's threat
  model rather than at odds with it.

Both dispositions fix the crash; they differ only in GC aggressiveness under a
bad HWM. `skip` = advance the horizon (unsafe under T1); `defer` = hold the
horizon down (safe, benign availability cost). §34's rejection-policy table has
been updated with the `defer` disposition and the skip-vs-block rationale.

### Open sub-questions — resolved

1. **Silent skip vs. a diagnostic signal.** **Silent catch with an explanatory
   code comment; no new durable record and no log.** Two facts settle this:
   (a) the horizon computation is read-only, idempotent, and repeats on every
   `_compactAll`, so writing a durable quarantine record from inside it would be
   a layering violation (the LSM engine reaching into sync-quarantine state) and
   would spam on every compaction; and (b) **`packages/kmdb` has no logging
   facility** — a grep of `sync/` and `engine/kvstore/` finds no `package:logging`
   dependency, `Logger`, or `dart:developer` usage anywhere, so there is no
   established channel to log to, and pulling in a logging dependency for a
   single diagnostic is out of proportion. The authoritative "peer X is
   unauthenticated" signal already surfaces on the sync path — `pull` durably
   quarantines X's SSTables under `unauthenticated`, and `push`/`sync` raise
   `SyncAuthException`. So the catch is silent, with a comment explaining the
   defer. (If observability here is later wanted, it should ride a
   package-wide logging decision, not this fix.)
2. **Other unguarded peer-HWM fold sites.** Audited (see next section). The
   horizon fold is the **only** unguarded peer-HWM fold; the sibling eviction
   fold is already guarded, and the three own-HWM loads deliberately propagate.
   Fixing the horizon computation fixes the class.
3. **Clear the persistent provider on close/sync-end?** **No — per-horizon-catch
   is the complete fix; do not add provider-lifecycle clearing.** The provider
   is *intentionally* long-lived: it must be active during `close(flush:true)`'s
   compaction so a synced DB uses the peer-HWM horizon (not the weaker local
   `now - tombstoneGraceDuration` fallback) for its final GC. Clearing it after
   sync would silently downgrade close-time GC to the local fallback — a
   behaviour change, not a fix — and add close-ordering fragility. The bug is
   "the provider throws uncaught," not "the provider is registered." Fix the
   throw; keep the provider.

## Anchor points (verified on `main` @ `a813f37`)

- `packages/kmdb/lib/src/sync/sync_engine.dart:127-135` — the horizon-provider
  registration closure (**the fix site** — catch `SyncAuthException` here).
- `packages/kmdb/lib/src/sync/highwater.dart:132-163` —
  `minCurrentHlcAcrossDevices`; the unguarded per-file `HighwaterMark.load` is
  line **143** inside the fold loop (**142-161**).
- `packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart` —
  `_computeTombstoneHorizon` (266-273; uncaught `provider()` at **268**),
  `_compactIfNeeded` single-file shortcut (908-920, shortcut at **916-920**),
  `_compactAll` horizon call (**1077**), `close` → `flush` at **1591** →
  `releaseLock` at **1595**.
- `packages/kmdb/lib/src/sync/sync_engine.dart:365-390` — the **already-guarded**
  sibling: `_checkAndHandleEviction`'s peer-HWM loop with `on SyncAuthException {
  continue; }` at 372-379. The disposition here **differs** (block, not skip) —
  see the Disposition section.
- `docs/spec/34_sync_authentication.md` — rejection-policy table (row **added**;
  now at ~267, with the skip-vs-block rationale beneath the table).
- `packages/kmdb/test/sync/auth/` (co-located with
  `sync_auth_sync_engine_integration_test.dart` and
  `sync_authenticating_adapter_test.dart`) — where the regression test belongs.
  Those WI-4 auth tests (the `MemorySyncAdapter` + `DefaultSyncAuthenticator` +
  `SyncAuthenticatingAdapter` wiring used by them) are the closest precedent;
  `MemorySyncAdapter` is sufficient to reproduce this (a MAC failure needs a key
  mismatch, not a disk fault — see Testing).

## Call-site audit — every peer-HWM / `HighwaterMark.load` fold

Grounding swept every `HighwaterMark.load` and `minCurrentHlcAcrossDevices`
caller (`grep` across `packages/kmdb/lib` + `packages/kmdb_cli/lib`). Results:

| # | Site | Kind | Guarded? | Correct disposition |
| :- | :--- | :--- | :--- | :--- |
| 1 | `highwater.dart:143` inside `minCurrentHlcAcrossDevices`, reached via the horizon provider `sync_engine.dart:128` → `_computeTombstoneHorizon` → `_compactAll` | **peer-HWM fold (horizon)** | ❌ **No** | **Defer GC (`Hlc(0,0)`)** — the bug; **fix here** |
| 2 | `sync_engine.dart:368` peer loop in `_checkAndHandleEviction` | peer-HWM fold (eviction) | ✅ Yes (372-379) | Skip (safe in *this* context — see Disposition) — **no change** |
| 3 | `sync_engine.dart:339` own-HWM load in `_checkAndHandleEviction` | own HWM | ❌ No (intentional) | Propagate (§34) — **no change** |
| 4 | `sync_engine.dart:274` own-HWM load in `push` | own HWM | ❌ No (intentional) | Propagate (§34) — **no change** |
| 5 | `sync_engine.dart:617` own-HWM load in `pull` | own HWM | ❌ No (intentional) | Propagate (§34) — **no change** |
| 6 | `sync_engine.dart:701` SSTable download in `pull` | SSTable (not HWM) | ✅ Yes (705-717) | Quarantine `unauthenticated` (Q1) — **no change** |
| 7 | `consolidation_coordinator.dart:490` input/lease download | SSTable input / lease (not HWM) | ✅ Yes | Skip input / propagate lease (§34) — **no change** |

**Conclusion:** there is exactly **one** unguarded peer-HWM *horizon* fold
(#1). The other unguarded loads (#3–#5) are the three **own-HWM** loads that
§34 deliberately propagates. So "fix the class" reduces to fixing #1; no other
site needs a code change. #2 is the only precedent to reconcile in the spec —
handled by the skip-vs-block note added to §34.

## Testing (fault injection — per CLAUDE.md durability discipline)

**T1 — the exact-chain regression (must fail pre-fix, pass post-fix).**
Reproduce the verified chain end-to-end:

1. Two `KvStore`/`KmdbDatabase` instances over a shared `MemorySyncAdapter`
   (the shared "sync folder"), each wrapped in its own `SyncAuthenticatingAdapter`
   with a **`DefaultSyncAuthenticator` holding a different 32-byte root key** —
   this is what makes B unable to authenticate A's artefacts. (A MAC mismatch is
   a key mismatch, not a disk fault, so `MemorySyncAdapter` suffices;
   `FaultyStorageAdapter` is not required for *this* failure, though see T4.)
2. Device A writes a document and `push`es — this uploads A's SSTable(s) **and**
   A's `<A>.hwm`, both enveloped under A's key, into the shared folder.
3. Device B constructs its `SyncEngine` (registering the horizon provider over
   B's `SyncAuthenticatingAdapter`) and `pull`s — B quarantines A's SSTable(s)
   under `unauthenticated`; A's `.hwm` is left in `highwater/`, unauthenticatable
   by B.
4. Device B writes **≥1** document (so `close`'s `_active.length > 0` guard is
   satisfied) and keeps total data **under `singleFileThresholdBytes`** with
   **`totalFiles > 1`** (e.g. force a flush so an L0 file plus the close-time
   flush give ≥2 files) so the single-file `_compactAll` shortcut fires.
5. Call `B.close(flush: true)`.
   - **Pre-fix assertion:** the call **throws `SyncAuthException`** (guards the
     regression — the test must observe the current bug).
   - **Post-fix assertion:** the call **completes**; then assert the LOCK is
     released by opening a fresh `KmdbDatabase`/`KvStore` on B's dir and
     confirming `open()` succeeds (no lock conflict) and B's own data is intact.

**T2 — horizon is deferred, not advanced, while a bad HWM is present.** With A's
bad `.hwm` in the folder alongside ≥1 genuine authenticated peer HWM, drive a
`_compactAll` and assert the tombstone horizon resolves to `Hlc(0, 0)` (GC
deferred), **not** to the min over the authenticated peers — i.e. a tombstone
below the authenticated-peer min is **retained**, proving the fix blocks rather
than skips. (This is the assertion that would *fail* under the rejected "skip"
disposition, and is the guardrail against a future regression back to skip.)

**T3 — GC resumes once the bad HWM is gone.** Remove A's bad `.hwm` from the
folder (or re-enroll so it authenticates), drive another `_compactAll`, and
assert the horizon now advances to the authenticated `min(currentHlc)` and an
eligible tombstone is dropped — proving the defer is transient and self-healing,
and that the healthy horizon/GC path is unbroken.

**T4 (optional) — direct unit test at the fix site.** *Note (reviewer):* there is
**no public getter** for the registered horizon provider (`KvStore` exposes only
the `setTombstoneHorizonProvider` **setter**; `_computeTombstoneHorizon` and
`_tombstoneHorizonProvider` are private), so the production closure cannot be
grabbed and invoked directly from a test without a new seam. Do **one** of:
(a) skip T4 — the catch branch and its `Hlc(0, 0)` return are already fully
exercised end-to-end by **T1** (no-throw + LOCK released) and **T2** (defer, not
skip); or (b) if a focused unit test is still wanted, add a narrow
`@visibleForTesting` accessor/method on `SyncEngine` that returns the horizon and
assert it yields `Hlc(0, 0)` under a mismatched-key adapter. Prefer (a) unless
coverage measurement shows the branch is otherwise unhit — do not invent a
public getter for the provider.

**Coverage:** keep ≥90%. The new catch branch is exercised by T1 (and asserted
behaviourally by T2); there is no log to cover.

## Implementation plan

**Scope: one production-code change site + spec (done) + tests.** The
call-site audit confirms the fix is localised to the horizon provider.

1. **Fix the horizon provider closure** —
   `packages/kmdb/lib/src/sync/sync_engine.dart:127-135`. Wrap the
   `minCurrentHlcAcrossDevices` call in `try` / `on SyncAuthException`, returning
   the conservative `const Hlc(0, 0)` on catch (the same value the `min ?? …`
   fallback already returns, and also the `CompactionJob.horizon` default —
   `compaction_job.dart:72` — so it reliably means "drop no tombstones"). **No
   log** (see sub-question 1 — `packages/kmdb` has no logging facility); the
   catch carries only an explanatory comment. Shape:

   ```dart
   _store.setTombstoneHorizonProvider(() async {
     try {
       final min = await HighwaterMark.minCurrentHlcAcrossDevices(
         _remoteHwmDir,
         _cloudAdapter,
         localDeviceId: _deviceId,
         evictAfter: _config.staleDeviceEvictionAfter,
       );
       return min ?? const Hlc(0, 0);
     } on SyncAuthException {
       // A peer `.hwm` in the sync folder failed authentication (§34 T1 / R-5).
       // We cannot know that peer's true sync position, so we conservatively
       // block ALL tombstone GC this round rather than advance the horizon past
       // a peer of unknown position (skipping it would RAISE the min and hand a
       // write-access attacker a premature-GC/resurrection primitive — see §34's
       // per-site rejection policy). Deferring GC is a benign availability cost;
       // the sync path already recorded the peer's unauthenticated status. This
       // also keeps close(flush:true)'s compaction total, so the LOCK is
       // released even when a forged/legacy HWM is present.
       return const Hlc(0, 0);
     }
   });
   ```

   Silent catch (no log — `packages/kmdb` has no logging facility; see
   sub-question 1). Import `SyncAuthException` from
   `auth/sync_auth_exception.dart` (`sync_engine.dart` is in the same `sync/`
   tree; it is also re-exported via `kmdb.dart`). Confirm the import is added if
   `SyncAuthException` is not already visible in the file.

2. **Do not** modify `HighwaterMark.minCurrentHlcAcrossDevices`
   (`highwater.dart`) to swallow `SyncAuthException` — its "defer" policy is
   horizon-specific and belongs with the horizon caller, and its existing
   `FormatException` contract (corrupt HWM = hard error) must stay. Instead,
   **augment its doc comment** (the block at 118-131, alongside the "HWM files
   that fail to parse throw `FormatException`" note) to state that
   `SyncAuthException` from the wrapped adapter likewise propagates, and that the
   horizon caller catches it to defer GC — so a future caller does not assume it
   is swallowed here.

3. **Do not** clear the provider anywhere (sub-question 3) — no `close`-path or
   `sync`-path `setTombstoneHorizonProvider(null)` is added.

4. **§34 spec** — already updated: rejection-policy row added +
   skip-vs-block rationale. Regenerate the HTML site (`make doc_site_html`)
   after the spec change lands.

5. **Tests** — add T1–T3 (T4 optional, see Testing) under
   `packages/kmdb/test/sync/auth/` next to the existing
   `sync_auth_sync_engine_integration_test.dart` /
   `sync_authenticating_adapter_test.dart`; reuse their harness
   (`MemorySyncAdapter` + `DefaultSyncAuthenticator(_key(n))` +
   `SyncAuthenticatingAdapter`). A mismatched-key device is `_key(2)` vs
   `_key(1)`.

6. **Verify** — `cd packages/kmdb && dart test` (native-asset hooks fire from
   the package dir), then `make coverage` for the ≥90% gate, then
   `make pre_commit`. No `kmdb_cli` change is expected; if the fix is confined
   to `packages/kmdb` the `pre_commit` `kmdb`-scoped test run covers it.

### Out of scope / explicitly not doing

- Provider-lifecycle clearing (sub-question 3 — rejected above).
- Any change to the three own-HWM loads (#3–#5) — §34 propagation is correct.
- Any change to `_checkAndHandleEviction`'s peer-HWM skip (#2) — correct in its
  own context.
- A durable HWM-quarantine record — none exists and none is warranted
  (sub-question 1).

## Review note — `kmdb-plan-reviewer`, 2026-09-10 (`main` @ `b846430`)

**Verdict: Investigated.** The plan clears the implementation-readiness bar — the
production fix is a single, precisely-located, unambiguous change, the
disposition is verified correct against current code, and the test plan is
fault-injected and concrete. Independently re-verified:

1. **Failure chain — accurate.** All cited line refs match current `main`:
   provider registration `sync_engine.dart:127-135` (uncaught closure);
   `minCurrentHlcAcrossDevices` at `highwater.dart:132-163`, unguarded per-file
   `HighwaterMark.load` at `:143` inside the fold; `_computeTombstoneHorizon`
   `lsm_engine.dart:266-273` (uncaught `provider()` at `:268`); single-file
   shortcut `_compactIfNeeded:916-920`; `_compactAll` horizon call `:1077`;
   `close` → `flush` at `:1591` (throws here) **before** `_tableCache.clear()`
   (`:1594`) / `releaseLock` (`:1595`) — confirming the LOCK-leak, not data loss.
2. **Defer-not-skip disposition — sound, and `Hlc(0,0)` is provably safe.** The
   horizon threads only into `CompactionJob.dropTombstone`
   (`compaction_job.dart:314-319`); its default is `const Hlc(0,0)` (`:72`), which
   means "drop no tombstones." So the defer value is the existing "no live
   devices" fallback (`sync_engine.dart:134`) **and** the CompactionJob default —
   no caller treats the horizon specially, and version reclamation is a separate
   policy path unaffected. The architect's `min`-monotonicity argument holds:
   skip raises the `min` → premature GC → resurrection under §34 T1; defer holds
   it down → safe, cost is only deferred (self-healing) reclamation. Endorsed.
   The fix makes `close(flush:true)` total and releases the LOCK.
3. **Call-site audit — complete and accurate.** Grepped every
   `HighwaterMark.load` / `minCurrentHlcAcrossDevices` caller in
   `packages/kmdb/lib` and `packages/kmdb_cli/lib`. Exactly one unguarded peer-HWM
   *horizon* fold (#1, the fix site). #2 (`_checkAndHandleEviction:368`) already
   guarded with `on SyncAuthException { continue; }` (`:372-379`). #3–#5
   (`:339`/`:274`/`:617`) are the three own-HWM loads §34 deliberately propagates.
   No other horizon caller left unguarded. `SyncAuthException` is **already
   imported** at `sync_engine.dart:23` — no new import needed.
4. **§34 agreement — confirmed.** The rejection-policy row exists at
   `34_sync_authentication.md:267` with the **Defer GC / `Hlc(0,0)`** disposition
   and "never skip the peer's contribution," plus the skip-vs-block asymmetry
   rationale at `:271-298`. Matches the plan's disposition exactly. The row also
   correctly notes reachability from **ingest-triggered compaction**, not only
   `close(flush:true)` — the fix covers both since it sits at the provider.
5. **Test plan — concrete and fault-injected.** The `test/sync/auth/` harness the
   plan reuses exists (`MemorySyncAdapter` + `DefaultSyncAuthenticator(_key(n))`
   + `SyncAuthenticatingAdapter`); a mismatched-key device is `_key(2)` vs
   `_key(1)`. The "fault" is a MAC key mismatch, not a disk fault, so
   `MemorySyncAdapter` genuinely reproduces the bug; T1 must throw pre-fix and
   complete post-fix (with a fresh `open()` proving LOCK release) — non-golden-path.

**Edits I made to the plan (no code touched):**
- Removed an internal contradiction: implementation step 1 said "emit a
  `fine`/`warning` diagnostic" while sub-question 1 and the code shape resolve to
  **silent, no log** (verified: no `package:logging`/`Logger`/`dart:developer` in
  `sync/` or `engine/kvstore/`). Aligned step 1 and the Coverage note to "no log."
- Corrected the test path from `test/sync/` to `test/sync/auth/` (two places).
- **Reframed T4 as optional.** There is no public getter for the registered
  horizon provider (only the `setTombstoneHorizonProvider` setter;
  `_computeTombstoneHorizon`/`_tombstoneHorizonProvider` are private), so T4 as
  originally worded ("the closure returns `Hlc(0,0)`") is not reachable without a
  new seam and is redundant with T1/T2. The plan now says prefer to skip T4, or
  add a narrow `@visibleForTesting` accessor if a direct unit test is wanted — do
  not invent a public provider getter. This was the only spot that could have
  forced an on-the-fly design decision; it is now explicitly resolved.

None of these were blocking for the core fix; they removed residual ambiguity
before handoff.

## Summary

_To be completed when the work is done._
