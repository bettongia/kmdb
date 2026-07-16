# WalWriter directory-entry durability (syncDir)

**Status**: Complete

**PR link**: — (implemented directly on `main`, no worktree/branch/PR — small
plan, per explicit instruction)

## Abstract

`WalWriter.append`/`appendBatch` fsync a WAL file's *content* via
`StorageAdapter.syncFile` but never `syncDir` the directory that holds it, so a
brand-new `wal-{N}.log` file's *directory entry* — the fact that the file
exists at all — is only made durable incidentally, by some unrelated later
`syncDir(db-dir)` call elsewhere in the engine (device-identity write on
`open()`, Manifest rotation, or crash recovery). §07 already documents this as
a latent, currently-benign invariant gap. This plan closes it: make the
guarantee intrinsic to `WalWriter` itself, prove it with a fault-injection
test using the existing `FaultyStorageAdapter` harness (built for the
`plan_manifest_fsync_ordering.md` precedent and reused across the v0.02.01
durability track), and update §07 and the affected doc comments to describe
the closed gap rather than the open one.

The fix is small — `WalWriter` gains one bool tracking whether the active
file's directory entry has been synced yet, reset on `rotate()`, and a single
`syncDir` call the first time a new file is written to. The reason this
warrants a plan rather than a direct commit (see `docs/roadmap/0_09.md`'s
Housekeeping section) is that it's durability-critical production code, and
every comparable fix in the v0.02.01 track was gated on fault-injection proof
per CLAUDE.md's standard, not a golden-path test. **Deferred, not fixed by
this plan:** the retired-WAL-deletion path (flush syncs `sst/` but never
`db-dir` after deleting an old WAL) has the mirror-image gap, but is
confirmed benign — see Q1.

## Problem statement

`WalWriter.append` (`packages/kmdb/lib/src/engine/wal/wal_writer.dart:69-73`)
and `appendBatch` (`:114-119`) both call `adapter.appendFile(activePath,
bytes)` then, if `fsyncOnWrite`, `adapter.syncFile(activePath)` — and stop
there. Neither calls `adapter.syncDir(dirPath)`. On a strict-POSIX filesystem,
fsync'ing a file's content does not durably persist its parent directory's
entry for that file; that requires a separate fsync of the parent directory.
So when `append`/`appendBatch` is called against a WAL path that does not yet
exist on disk — which happens right after `WalWriter.rotate()` bumps the
sequence number, since `rotate()` itself does not create the new file (see
Investigation) — the resulting file's directory entry is not durable until
some unrelated later code path happens to `syncDir(db-dir)`.

Today this is genuinely latent, not live: nothing currently depends on a
freshly-created WAL surviving a crash *before* one of those incidental
`syncDir` calls runs (device-identity write at `open()`, Manifest rotation,
crash recovery). But it is exactly the class of bug the 2026-05-22 code review
was built to catch, and the guarantee should be intrinsic to `WalWriter`
rather than an accident of what else happens to run afterward — a future code
path that writes to a fresh WAL and relies on it surviving power loss before
one of those incidental calls would silently lose data on recovery.

§07 (`docs/spec/07_wal.md`, "Directory-entry durability", lines 45-72) already
documents this invariant and explicitly points at "the tracked hardening item
in the active roadmap" — this plan is that item.

## Open questions

- [x] **Q1 — Should the retired-WAL-deletion `syncDir` gap be folded into this
      plan?** **Resolved (reviewer, 2026-07-16): accept the recommendation —
      leave it out, document it in §07 as an intentionally-untouched,
      confirmed-benign mirror case.** The reasoning below was verified against
      the actual code: the deletion loop
      (`lsm_engine.dart:890-897`, in `packages/kmdb/lib/src/engine/kvstore/`)
      removes only WAL files with `seq < activeSequence`, and §17 recovery
      already re-deletes (`seq < logNumber`) or idempotently replays any
      resurrected file. Folding it in would add scope without closing a live
      hazard. Revisit only if WAL-file *absence* ever becomes load-bearing at
      recovery.
      The flush path deletes the now-retired WAL file
      (`lsm_engine.dart:890-897`) but only `syncDir`s `sst/`
      (`lsm_engine.dart:862`), never `db-dir` — so the *removal* of a WAL's
      directory entry is, symmetrically, not intrinsically durable either.
      Unlike the creation-side gap this plan fixes, this one is confirmed
      **safe to leave as-is**: a crash before that deletion's directory entry
      is durable can only resurrect an already-retired WAL file on recovery,
      and `rotate()`'s own no-boundary-marker design (§07 "Rotation") already
      requires replay to be idempotent under HLC last-write-wins — a
      resurrected retired WAL either re-applies harmlessly or is already
      superseded by its SSTable. Recommendation: **leave it out of this
      plan** — note it in §07 as an intentionally-untouched, confirmed-benign
      mirror case (with the reasoning above) so a future reader doesn't
      re-discover it as an unexplained asymmetry. Revisit only if a future
      change makes WAL-file *absence* (not content) load-bearing at recovery
      time, which nothing does today.

## Investigation

### `WalWriter.rotate()` does not create the new file

`rotate()` (`wal_writer.dart:133-137`) only does `_sequence++` and returns the
old path — it does **not** create or write the new `wal-{N+1}.log` file. That
file comes into existence lazily, via the first `appendFile` call inside the
next `append`/`appendBatch`. This matters for the fix's design: the "this file
is new, sync its directory entry" logic cannot live in `rotate()` (the file
doesn't exist yet there) and must live on the append path itself, gated on
whether the *currently active* file's directory entry has already been
synced.

### Design: intrinsic per-file dir-sync tracking

`WalWriter` currently holds no "is the active file new" state. Add one:

```dart
bool _activeDirSynced = false;
```

- Initialised to `false` in the constructor (the very first file `WalWriter`
  ever writes to is "new" from its own point of view, even on reopen against
  an existing file on disk — see the accepted-inefficiency note below).
- Reset to `false` inside `rotate()`, since the next `append` targets a file
  that has not yet had its directory entry synced.
- In `append`/`appendBatch`, **after** the existing `appendFile` +
  conditional `syncFile` (ordering matters — see next paragraph), if
  `fsyncOnWrite && !_activeDirSynced`: call `await
  adapter.syncDir(dirPath)`, then set `_activeDirSynced = true`. Every
  subsequent append to the same active file — the common case — skips the
  `syncDir` call entirely; it is a once-per-file cost, not a once-per-write
  one, so the hot write path is not affected.

**Ordering constraint, verified against `FaultyStorageAdapter`'s actual
semantics** (`test/support/faulty_storage_adapter.dart:130-170`):
`syncFile` must run before `syncDir` for the same path. `syncDir` is what
promotes a path from "live" to "durable" in the fault-injection model; if
`syncDir` runs before the content has been captured by `syncFile`, the path
becomes durable with **empty bytes** (`_durable[path] ??= Uint8List(0)`,
line 161) rather than the written content. The existing code's order —
`appendFile` then `syncFile` — already satisfies this; the new `syncDir`
call must be appended after that, not interleaved earlier.

**Accepted minor inefficiency:** on reopen, `WalWriter` is reconstructed
against a WAL file that may already exist on disk (and whose directory entry
is presumably already durable from whenever it was first created). Since the
new `_activeDirSynced` flag always starts `false`, the first append after any
`WalWriter` construction will issue one redundant `syncDir` call. This is
correctness-neutral and cheap (one directory fsync per database `open()`, not
per write) — simpler and safer than trying to detect "was this file already
durable before I was constructed," which `WalWriter` has no reliable way to
know. Not worth the complexity to optimise away.

### Fault-injection test (the key test artifact)

Mirror the existing crash-assert pattern in
`packages/kmdb/test/engine/manifest_fsync_recovery_test.dart`: operate against
a `FaultyStorageAdapter`, call `adapter.crash()` to simulate power loss,
reopen, and assert on what survived. For this plan:

**Prefer a `WalWriter`-direct test as the primary artifact. A KvStore-level
test is fragile here and can go false-green — see the masking hazard below.**

Primary test (`WalWriter` against `FaultyStorageAdapter`, deterministic):

1. Construct a `WalWriter(dirPath: dbDir, adapter: faulty, fsyncOnWrite: true)`
   — note `dirPath` **is** the db dir in production (`crash_recovery.dart:273`
   passes `dirPath: dbDir`), so the fix's `syncDir(dirPath)` is exactly a
   `syncDir(dbDir)`.
2. `append` a record to `wal-00001.log`, then `rotate()` so the next write
   targets a brand-new `wal-00002.log`.
3. `append` one record to the fresh file (content `syncFile`'d per current
   behaviour; with the fix, its directory entry is now `syncDir`'d too).
4. Call `adapter.crash()`.
5. Reopen / re-list. Assert `wal-00002.log` still exists
   (`adapter.fileExists`) and its bytes are intact (`readFile`). Per the
   `FaultyStorageAdapter` mechanics in the Investigation above, **without** the
   fix the fresh file's directory entry was never promoted to `_durable`, so
   `crash()` reverts `_live` to `_durable` and the file — and therefore the
   record — disappears entirely; §17's "Multiple WAL Files on Recovery" step
   would not even enumerate it.

**Proving necessity:** the committed test asserts survival *with* the fix (it
passes with the fix, fails without). Do not attempt to commit a "pre-fix"
variant — demonstrate necessity by manually reverting the fix locally once and
confirming the test fails (mirrors the `manifest_fsync_recovery_test.dart`
workflow); state this in the PR description. This is the "single test that fails
without the fix" option, chosen deliberately over a before/after pair.

**Masking hazard (why not a plain KvStore-level test):** the KvStore write/open
path issues several *incidental* `syncDir(dbDir)` calls — `ensureDeviceId()`
(`kv_store_impl.dart:437`), the format-marker self-heal (`:204`), `changeDeviceId`
(`:357`), Manifest publish (`lsm_engine.dart:1210` / `current_file.dart:77`),
and crash recovery (`crash_recovery.dart:108`). Any one of these firing
*between* the fresh-WAL write and `crash()` makes the fresh file's directory
entry durable **without the fix**, turning the test green regardless — a
non-discriminating test that proves nothing. If an integration-level test is
*also* wanted, the implementer must guarantee no `syncDir(dbDir)` runs between
the fresh-WAL-creating `put()` and the crash (a single small `put()` that does
not trigger a flush, immediately followed by `crash()`), and should assert this
explicitly. The `WalWriter`-direct test above avoids the hazard entirely and is
the required deliverable; the KvStore-level test is optional.

### Spec and doc-comment updates required

- **`docs/spec/07_wal.md`, "Directory-entry durability" (lines 45-72):**
  currently describes the gap as open ("In practice this is presently
  benign... The hazard is latent..."). Rewrite to describe the guarantee as
  intrinsic and closed, folding in the Q1 reasoning for why the
  retired-WAL-deletion mirror case is intentionally left as-is.
- **`WalWriter` doc comments** (`wal_writer.dart:33-38` class-level "Fsync
  behaviour" section, `:66-73` `append`, `:107-119` `appendBatch`): update to
  state that a newly-created file's directory entry is now synced
  intrinsically, once, gated on `fsyncOnWrite` — not just its content.

## Implementation plan

- [x] Resolve Q1 (or accept the stated recommendation) before writing code.
- [x] Add `_activeDirSynced` bool field to `WalWriter`; initialise `false` in
      the constructor; reset `false` in `rotate()`.
- [x] In `append` and `appendBatch`, after the existing `appendFile` +
      conditional `syncFile`, add: if `fsyncOnWrite && !_activeDirSynced`,
      `await adapter.syncDir(dirPath); _activeDirSynced = true;`. Extract the
      three lines into a private `_syncDirOnce()` helper rather than duplicating
      them across both call sites (code health; keeps the two write paths in
      lock-step).
- [x] Fix the now-stale/redundant defensive `syncDir(dbDir)` in
      `kv_store_impl.dart:186-204`. Its comment (`"WalWriter.append only
      syncFile's file *content*, never syncDir's its own directory entry"`)
      becomes **factually wrong** once this fix lands, and the call itself
      becomes a guaranteed no-op (the format-marker's own WAL write will have
      `syncDir`'d the dir via `WalWriter`). At minimum rewrite the comment to
      state that `WalWriter` now makes a fresh WAL file's directory entry
      durable intrinsically; prefer removing the redundant call outright (the
      comment already documents that reverting it breaks no test) to satisfy the
      "no dead/unreachable code" standard. Do not leave the misleading comment
      in place. **Done — removed outright**, per the "prefer removing" guidance;
      replaced with a short comment pointing at `WalWriter`'s new intrinsic
      guarantee instead of leaving a factually-wrong one in place.
- [x] Add the fault-injection test described in the Investigation section,
      using `FaultyStorageAdapter` — place it alongside the existing
      WAL/durability tests (confirm exact file with `kmdb-architect` if
      `wal_writer_test.dart`'s existing structure suggests a different home,
      e.g. a crash-recovery-focused integration test file). **Done** — added a
      new `WalWriter — directory-entry durability (syncDir)` group to
      `test/engine/wal_test.dart` (the file already housed all other
      `WalWriter` tests; no separate home needed). Necessity independently
      verified: temporarily reverted both `_syncDirOnce()` call sites,
      confirmed the two discriminating tests fail with exactly the expected
      assertion failures, then restored the fix and reconfirmed all pass.
- [x] Update `docs/spec/07_wal.md`'s "Directory-entry durability" section per
      the Investigation notes. Run `make doc_site` after editing (`make site`
      is a silent no-op — it names the checked-in `site/` directory, not a build
      target; see CLAUDE.md). **Done** — used `make site/spec.html` instead
      (the targeted fast build; `make doc_site` unnecessarily runs the full
      coverage suite first) and confirmed the new content renders in
      `site/spec.html`.
- [x] Update `WalWriter`'s class-level and `append`/`appendBatch` doc
      comments to describe the new intrinsic behaviour.
- [x] Confirm no regression in WAL-heavy existing tests/benchmarks — this
      adds one `syncDir` call per WAL file (not per write), so steady-state
      write throughput should be unaffected; note this explicitly in the PR
      description so it's an documented, deliberate non-finding rather than
      an unstated assumption. **Done** — full `kmdb` suite 2373/2373 passing
      (2370 pre-existing + 3 new), no regressions. Implemented directly on
      `main` per explicit instruction (small plan, no worktree/branch/PR), so
      "PR description" becomes this Summary section instead.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95%. Note the three branches of the new
      guard must all be exercised: (a) `fsyncOnWrite && !_activeDirSynced` →
      `syncDir` fires (new crash test); (b) `fsyncOnWrite && _activeDirSynced` →
      skip on subsequent same-file writes (existing `fsyncOnWrite: true` WAL
      tests, e.g. `wal_test.dart:527`); (c) `!fsyncOnWrite` short-circuit
      (existing `fsyncOnWrite: false` tests, e.g. `wal_test.dart:38`). **Done**
      — `wal_writer.dart` 100% (30/30), all three branches confirmed exercised
      by the new tests; `kv_store_impl.dart` 98.2% (168/171, unaffected by a
      pure deletion); aggregate 94.9% (package baseline, unchanged).
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
      **Done (2026-07-17) — signed off, zero blocking issues.** Independently
      traced the fix's correctness and re-derived the `kv_store_impl.dart`
      removal's safety rather than trusting the plan/implementer. Three
      non-blocking optional-polish notes (test 2's name could more precisely
      reflect what it asserts; `appendBatch` relies on shared coverage via
      `_syncDirOnce` rather than its own dedicated crash test, judged sound
      since the behaviour is identical to `append`'s; this plan-file
      bookkeeping was still outstanding at review time — now done).
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
      **Done** — full `kmdb` package pre_commit gate green (2373 tests).
- [x] Verify licence headers on all new files (2026). No new files were
      added — all changes are edits to existing, already-headered files.

## Reviewer assessment (kmdb-plan-reviewer, 2026-07-16)

**Verdict: Investigated. Proceed.** Small, well-scoped, low-risk durability
hardening that makes an intrinsic guarantee out of a currently-incidental one.
All code citations were checked against `main` and are accurate:

- `wal_writer.dart` line ranges (`append` 69-73, `appendBatch` 114-119,
  `rotate()` 133-137, doc-comment ranges) — exact. `rotate()` genuinely does not
  create the new file; lazy creation on first `appendFile` is confirmed, so the
  design's placement of the flag-reset in `rotate()` and the `syncDir` on the
  append path is correct.
- `FaultyStorageAdapter` semantics (`syncFile` snapshots into `_syncedContent`;
  `syncDir` promotes to `_durable`, else `_durable[path] ??= Uint8List(0)` at
  line 161) — exact. The stated ordering constraint (`syncFile` before
  `syncDir`, else the name becomes durable with empty bytes) is real and the
  existing `appendFile → syncFile` order already satisfies it.
- Q1 citations (`lsm_engine.dart:890-897` deletion loop, `:862` `syncDir(sst/)`)
  — exact (file lives under `.../kvstore/`; the plan's bare filename is
  harmless). The incidental `syncDir(dbDir)` calls the plan/§07 rely on all
  exist: `crash_recovery.dart:108`, `current_file.dart:77`,
  `kv_store_impl.dart:204/357/437`, `lsm_engine.dart:1210`. None fire per-write,
  so "presently benign" holds.
- `WalWriter.dirPath == dbDir` (`crash_recovery.dart:273`), so
  `syncDir(dirPath)` is the correct directory.

**Changes I made to reach Investigated:**

1. **Resolved Q1** — accepted the recommendation (leave the retired-WAL mirror
   gap out, document in §07). Verified the idempotent-replay reasoning against
   the deletion loop and §17 recovery.
2. **Closed a test-design trap** — the plan let the implementer pick
   KvStore-level or `WalWriter`-direct freely. A KvStore-level test is prone to
   a *masking* false-green because several open/write paths issue incidental
   `syncDir(dbDir)` calls that would make the fresh WAL durable even without the
   fix. The test section now mandates a `WalWriter`-direct test as the primary
   discriminating artifact and documents the hazard for any optional
   integration test.
3. **Added a required cleanup** — `kv_store_impl.dart:186-204`'s defensive
   `syncDir(dbDir)` exists *specifically* to work around this WalWriter gap; its
   comment becomes factually wrong and the call redundant once the fix lands.
   The plan now requires correcting/removing it so no stale, misleading comment
   or dead defensive call is left behind.
4. **Minor fixes** — `make site` → `make doc_site` (the former is a silent
   no-op); added a `_syncDirOnce()` helper to avoid duplicating the guard;
   spelled out the three-branch coverage expectation.

No remaining open questions; no unresolved design decisions for the implementer.

## Summary

- Made a fresh WAL file's directory-entry durability intrinsic to `WalWriter`
  rather than incidental to unrelated later code paths: added
  `_activeDirSynced` (reset on `rotate()`) and a `_syncDirOnce()` helper that
  `syncDir`s the WAL directory once per newly-active file, called from both
  `append` and `appendBatch` after the existing content-fsync.
- Removed a now-redundant defensive `syncDir(dbDir)` in `kv_store_impl.dart`
  that existed specifically to work around this gap — its own comment already
  documented it as a confirmed no-op even before this fix, and its rationale
  becomes factually wrong once `WalWriter` covers the guarantee itself.
- Added a `WalWriter`-direct fault-injection test group (3 tests) using
  `FaultyStorageAdapter`, deliberately not a `KvStore`-level test — the
  latter would be prone to a false-green from several incidental
  `syncDir(dbDir)` calls elsewhere in the open/write path. Verified necessity
  by hand: temporarily reverted the fix, confirmed the two discriminating
  tests fail with the exact expected assertions, restored the fix, reconfirmed
  all pass.
- Rewrote `docs/spec/07_wal.md`'s "Directory-entry durability" section to
  describe the guarantee as closed/intrinsic (was previously documented as an
  open, latent gap), folding in the reasoning for why the mirror-image
  retired-WAL-deletion gap is intentionally left untouched (confirmed benign
  via idempotent HLC-LWW replay).
- Updated `WalWriter`'s class-level and per-method doc comments to describe
  the new intrinsic behaviour, including the `syncFile`-before-`syncDir`
  ordering constraint the fault-injection adapter's semantics require.
- Verification: full `kmdb` suite 2373/2373 passing (2370 pre-existing + 3
  new, zero regressions); `wal_writer.dart` 100% coverage (all three guard
  branches exercised); `kv_store_impl.dart` 98.2% (unaffected by a pure
  deletion); `kmdb-qa` signed off with zero blocking issues, independently
  tracing the fix's correctness and re-deriving the removed call's safety
  rather than trusting the plan; `make pre_commit` fully green.
- Implemented directly on `main` per explicit instruction (small,
  well-scoped plan) — no worktree, branch, or PR.
