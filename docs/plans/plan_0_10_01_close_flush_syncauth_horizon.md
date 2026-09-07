# Harden `close(flush:true)` against `SyncAuthException` on the tombstone-GC-horizon path

**Status**: Draft (needs `kmdb-architect` grounding + §34 fix → `kmdb-plan-reviewer`)

**PR link**: _(none yet)_

> **Provenance.** Found by `kmdb-qa` during the 0.1.0 integration-guide review
> (2026-09-07, [PR #89](https://github.com/bettongia/kmdb/pull/89)) as its
> "finding #2" — a **pre-existing core-library bug**, orthogonal to the guide,
> that the guide's authenticated-sync demo merely surfaced. The user elected to
> **fix it before the 0.1.0 tag** (rather than defer to 0.2.0), so it rides the
> 0.10.01 hardening track as a pre-tag gate item.

## Problem statement

After an authenticated pull correctly **quarantines** a foreign / rotated /
mismatched peer `.hwm` (the exact hostile-input case WI-4 defends against), the
**next** `KmdbDatabase.close(flush: true)` can throw an **uncaught
`SyncAuthException`**, escaping `close()` before it releases the LOCK — leaking
the lock file and skipping clean resource teardown, so the next `open()` can hit
a lock conflict. **Not data loss** (the durable flush steps complete first), but
a real robustness defect on the WI-4 exceptional path, and a gap in §34's
rejection-policy table.

### Verified failure chain (kmdb-qa, against `packages/kmdb`)

1. `SyncEngine`'s constructor registers the tombstone-GC-horizon provider on the
   store (`sync/sync_engine.dart:127`), and the closure captures the
   `SyncAuthenticatingAdapter`. **It is never cleared** after sync returns (no
   `setTombstoneHorizonProvider(null)` anywhere), so it persists on the store
   for the lifetime of the `KmdbDatabase`.
2. `KmdbDatabase.close({flush: true})` → `_cache.close(flush)` →
   `LsmEngine.close` → `flush()` → step 6 `_compactIfNeeded()`
   (`engine/kvstore/lsm_engine.dart:902`). The **single-file compaction
   shortcut** fires whenever total data ≤ 512 KB (`_compactIfNeeded`,
   ~`lsm_engine.dart:916-920`) — the common case for a small app — invoking
   `_compactAll()`.
3. `_compactAll()` → `_computeTombstoneHorizon()` (`lsm_engine.dart:~1077`) →
   the registered provider → `HighwaterMark.minCurrentHlcAcrossDevices` →
   `HighwaterMark.load` on **every** peer `.hwm` → `adapter.download` →
   `SyncAuthEnvelope.unwrap`, which throws `SyncAuthException` on a peer file it
   cannot authenticate.
4. `minCurrentHlcAcrossDevices` does **not** catch it
   (`sync/highwater.dart:~132-163`), so it propagates out through `_compactAll`
   → `flush` step 6 → `close`, before `LsmEngine.close` reaches
   `releaseLock()` / `_writeEventsController.close()` (`lsm_engine.dart:~1591`).

### §34 spec gap (kmdb-architect's domain)

The "Per-site rejection policy" table (`docs/spec/34_sync_authentication.md:~260`)
enumerates the peer-`.hwm`-load sites (`SyncEngine.pull`, `_fullResync`,
`consolidate`, own-HWM-load, `_checkAndHandleEviction` peer-HWM-load, lease CAS)
but **omits** the compaction-triggered `_computeTombstoneHorizon` →
`minCurrentHlcAcrossDevices` peer-HWM load. The finding is a genuine gap in the
table, not only in the code.

## Proposed disposition (to confirm with kmdb-architect)

Mirror the existing `_checkAndHandleEviction` peer-HWM-load row: **a peer whose
`.hwm` fails authentication simply must not contribute to the GC horizon.** So
`minCurrentHlcAcrossDevices` (and any sibling that folds peer HWMs for the
horizon) should **catch `SyncAuthException` per-peer and skip that peer's
contribution** — never propagate. A failed-auth peer HWM is untrustworthy input,
exactly like a quarantined SSTable; skipping it is correct (the horizon simply
doesn't advance on that peer, which is the safe direction). This keeps
`close(flush:true)` total and durable on the exceptional path.

**Open sub-questions for grounding:**
- Should the skip be **silent**, or surface via the existing `$$quarantine` /
  a diagnostic signal? (Lean: skip + a debug log; the pull path already recorded
  the quarantine, so no new durable record is needed — confirm.)
- Are there **other** unguarded peer-HWM fold sites with the same shape (audit
  every `HighwaterMark.load` / `minCurrentHlcAcrossDevices` caller), so we fix
  the class, not just this instance?
- Should the persistent provider also be **cleared** when appropriate, or is
  per-peer catch sufficient on its own? (Lean: per-peer catch is the real fix;
  provider-lifecycle is secondary.)

## Anchor points

- `packages/kmdb/lib/src/sync/sync_engine.dart:127` — provider registration.
- `packages/kmdb/lib/src/sync/highwater.dart:~132` — `minCurrentHlcAcrossDevices`
  (the catch site).
- `packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart:~902,~1077,~1591` —
  `_compactIfNeeded` / `_computeTombstoneHorizon` / `close`'s lock release.
- `docs/spec/34_sync_authentication.md:~260` — the rejection-policy table (add
  the missing row).
- `packages/kmdb/test/sync/auth/` + the `FaultyStorageAdapter` fault-injection
  harness — where the regression test belongs.

## Testing (fault injection — per CLAUDE.md durability discipline)

- A regression test that reproduces the exact chain: enroll two devices with
  **mismatched** sync keys, have device B pull (quarantining A's `.hwm`), write
  enough to keep total data under the single-file-shortcut threshold, then call
  `close(flush: true)` and assert it **completes**, the LOCK is released, and a
  subsequent `open()` succeeds — asserting the test **fails on the pre-fix code**
  (the current uncaught throw) and passes after.
- Assert the GC horizon is computed from the authenticated peers only (the
  skipped peer doesn't corrupt it), and that tombstone GC still works on a
  later successful compaction.
- Audit-driven tests for any sibling peer-HWM fold sites found during grounding.

## Implementation plan

_To be completed once kmdb-architect grounds the disposition and confirms the
call-site audit scope._

## Summary

_To be completed when the work is done._
