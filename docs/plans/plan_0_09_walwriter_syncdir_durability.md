# WalWriter directory-entry durability (syncDir)

**Status**: Open

**PR link**: —

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

- [ ] **Q1 — Should the retired-WAL-deletion `syncDir` gap be folded into this
      plan?** The flush path deletes the now-retired WAL file
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

1. Open a `KvStoreImpl` (or exercise `WalWriter` directly, whichever gives a
   cleaner assertion surface — implementer's call) against a
   `FaultyStorageAdapter`.
2. Force a WAL rotation (write enough to trigger `rotate()`, or call it
   directly if testing `WalWriter` in isolation) so the *next* write targets a
   brand-new WAL file.
3. Write one record to the new file (content `syncFile`'d, per current
   behaviour) — **without** the fix's `syncDir` call having run yet
   (i.e. run this against the pre-fix code path, or structure the test to
   assert the fix's absence would lose data — implementer's call on the
   cleanest way to express "prove the fix is necessary," e.g. a
   before/after pair or a single test that fails without the fix applied).
4. Call `adapter.crash()`.
5. Reopen. Assert the record from step 3 is present (with the fix) — per the
   `FaultyStorageAdapter` mechanics in the Investigation above, without the
   fix the fresh file's directory entry was never promoted to `_durable`, so
   `crash()` reverts `_live` to `_durable` and the file — and therefore the
   record — disappears entirely; §17's "Multiple WAL Files on Recovery" step
   would not even enumerate it, since the directory listing itself would not
   show the file.

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

- [ ] Resolve Q1 (or accept the stated recommendation) before writing code.
- [ ] Add `_activeDirSynced` bool field to `WalWriter`; initialise `false` in
      the constructor; reset `false` in `rotate()`.
- [ ] In `append` and `appendBatch`, after the existing `appendFile` +
      conditional `syncFile`, add: if `fsyncOnWrite && !_activeDirSynced`,
      `await adapter.syncDir(dirPath); _activeDirSynced = true;`.
- [ ] Add the fault-injection test described in the Investigation section,
      using `FaultyStorageAdapter` — place it alongside the existing
      WAL/durability tests (confirm exact file with `kmdb-architect` if
      `wal_writer_test.dart`'s existing structure suggests a different home,
      e.g. a crash-recovery-focused integration test file).
- [ ] Update `docs/spec/07_wal.md`'s "Directory-entry durability" section per
      the Investigation notes. Run `make site` after editing.
- [ ] Update `WalWriter`'s class-level and `append`/`appendBatch` doc
      comments to describe the new intrinsic behaviour.
- [ ] Confirm no regression in WAL-heavy existing tests/benchmarks — this
      adds one `syncDir` call per WAL file (not per write), so steady-state
      write throughput should be unaffected; note this explicitly in the PR
      description so it's an documented, deliberate non-finding rather than
      an unstated assumption.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Summary

{Dot points highlighting the work undertaken}
