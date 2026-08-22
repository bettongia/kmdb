# LocalDirectoryAdapter: await the write before the lock is released (CAS ordering)

**Status**: Questions

**PR link**: _(none yet)_

> **Provenance.** Found during the WI-5 / Dart 3.13.1 work on 2026-08-22:
> Dart 3.13.1's new `unawaited_return_in_try_block` lint flagged a real
> crash-safety defect. Spun out as its own small item (per
> `plan_dart_3_13_adoption.md`) because it is a genuine durability bug valid on
> the **current 3.12.2** toolchain — it should not wait for the toolchain
> migration.

## Problem statement

In `LocalDirectoryAdapter._updateWithLock` (the `atomicCas: true` update-if-match
path), the write future is **returned without `await` inside a `try`/`finally`**:

```dart
// packages/kmdb/lib/src/sync/local/local_directory_adapter.dart:246-261
final raf = await file.open(mode: FileMode.append);
try {
  await raf.lock(FileLock.blockingExclusive);
  …
  if (lockedEtag != expectedEtag) return false;
  return _writeViaTempRename(file, newBytes);   // ← returned, not awaited
} finally {
  try { await raf.unlock(); } catch (_) {}
  await raf.close();
}
```

Because the future is returned rather than awaited, the `finally` block runs —
**releasing the advisory lock (`raf.unlock()`) and closing the handle
(`raf.close()`) — before `_writeViaTempRename` has completed**. The whole point
of `_updateWithLock` is to serialise the read-compare-write under the advisory
lock; releasing the lock mid-write defeats that guarantee. A concurrent
cooperating writer can acquire the lock and begin its own compare-and-write while
the first write's temp-file rename is still in flight, reintroducing exactly the
lost-update / racy-write class this atomic path exists to prevent.

This is the durability-class of bug the project treats as high-priority (cf. the
2026-05-22 review's fault-injection mandate) and it is present on `main` today.

## Open questions

The one-line fix is unambiguous, but two decisions must be made before an
implementer can execute mechanically. See the **Reviewer notes (2026-08-22)**
section for the full reasoning behind each.

- [ ] **Q1 — Pin exactly one test strategy (blocking).** The plan currently
      offers two under-specified options and tells the implementer to "land
      whichever most reliably fails." Neither is directly implementable as
      written, and one is unreliable:
      - **Option A is a category error as written.** It suggests a
        "`FaultyStorageAdapter`-style hook." `FaultyStorageAdapter` implements
        `StorageAdapter` (the engine block-device interface), **not**
        `SyncStorageAdapter`, and cannot wrap `LocalDirectoryAdapter`.
        Furthermore `LocalDirectoryAdapter` calls `dart:io`
        `File`/`RandomAccessFile` **directly** with no injection seam, and the
        buggy call is between two private methods — so there is no existing
        way to observe the ordering. Option A therefore *requires a new
        production seam* that the plan must specify.
      - **Option B (contention) does not reliably fail before the fix.** The
        bug is a within-isolate `await` ordering issue; the returned future of
        `compareAndSwap` still resolves only after the write completes (see
        Q3 below), so the outcome of a contention test is decided by
        event-loop I/O scheduling — flaky by construction. A flaky test is not
        a regression guard.
      - **Decision needed:** commit to **one** concrete test. Recommended:
        the deterministic gated-seam ordering probe specified in the reviewer
        notes (requires two small `@visibleForTesting @protected` seams). If
        the team prefers not to add test-only seams to production code, the
        alternative is to treat the `unawaited_return_in_try_block` lint as the
        mechanical regression guard **plus** a release-checklist item for
        real multi-process contention — but note the lint is inactive until
        the 3.13.1 toolchain migration lands, leaving a coverage gap until
        then.
- [ ] **Q2 — Is the fix actually sufficient for the advertised guarantee?
      (blocking)** `_writeViaTempRename` replaces the target *path* with a
      **new inode** (temp file + `rename`), but the advisory lock is held on
      the **original inode** via `raf`. A second cooperative writer that opens
      the path *before* the rename gets a handle to the old inode, blocks on
      the lock, and — after the first writer renames and releases — re-reads
      *stale* content through its own handle to the now-unlinked inode, matches
      the stale ETag, and overwrites the first writer's change. This
      lost-update window survives `return await`. So holding the lock across
      the temp-rename does **not** make the update atomic; the lock reliably
      serialises only the *compare* among writers that opened the same inode
      before any rename. **Decision needed:** is this residual window in scope?
      Real-world exposure is low (the only atomic-update caller is
      `ConsolidationCoordinator` lease *renewal*, which a single coordinator
      does not issue concurrently — see reviewer notes), but the class
      doc-comment advertises a general "read-compare-write is serialised
      against other cooperative processes" guarantee that the temp-rename
      pattern does not fully deliver. Options: (a) declare it out of scope and
      narrow the class doc-comment to what the fix guarantees; (b) replace the
      temp-rename with an in-place truncate+write+flush through the locked
      `raf` (keeps the lock and mutation on the same inode, but trades away
      the crash-atomicity temp-rename provides — a real tension worth an
      explicit call). Q2's answer also determines what Q1's test must assert.
- [ ] **Q3 — (informational, no decision) returned-bool semantics.** Confirmed
      that `return await` does **not** change the boolean returned to the
      caller. An `async` function already flattens `return futureValue;`, so
      the caller of `compareAndSwap` always waited for the write regardless;
      the only behavioural change is that the `finally` (unlock/close) now runs
      *after* the write instead of racing it. State this in the fix comment so
      the implementer does not chase a phantom semantics change.

## Investigation

- **Location:** `packages/kmdb/lib/src/sync/local/local_directory_adapter.dart`,
  `_updateWithLock` (method starts ~`:227`), the return at `:255` inside the
  `try` whose `finally` (`:256`) unlocks and closes.
- **Scope is precisely this one site.** The two other `return
  _writeViaTempRename(...)` calls — `:164` (non-atomic create-if-absent) and
  `:174` (non-atomic fallback update) — are **not** inside a `try`/`finally` that
  holds a lock, so they are unaffected. Only the locked path leaks the ordering.
- **Fix:** `return await _writeViaTempRename(file, newBytes);` so the write
  (temp write + fsync + rename) fully completes before the `finally` releases the
  lock and closes the handle.
- **Testing — must exercise the ordering, not just the result.** A golden-path
  assertion (write succeeds, bytes correct) passes both before and after the
  fix, so it does not guard the bug. Prefer a fault-injection / instrumentation
  approach against the durability-blind trap called out in CLAUDE.md:
  - Option A: wrap/observe the adapter so the test can assert that at the moment
    `unlock()`/`close()` are invoked, the temp-rename has already happened
    (e.g. via a `FaultyStorageAdapter`-style hook or a spy on file ops).
  - Option B: a concurrency test — two `compareAndSwap(atomicCas: true)` calls
    contending on the same key; assert last-writer-wins semantics hold and no
    interleaving corrupts the file (this should be flaky-before / stable-after).
  Land whichever most reliably fails on the unfixed code.

## Implementation plan

- [ ] Change `:255` to `return await _writeViaTempRename(file, newBytes);` with a
      comment explaining the lock/close ordering (do not disturb `:164`/`:174`).
- [ ] Add a regression test under `packages/kmdb/test/…/local_directory_adapter…`
      that fails on the current code and passes after the fix (see Investigation).
- [ ] Confirm existing `LocalDirectoryAdapter` tests still pass.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new/changed files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off. Do not open a PR until
      sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on any new files (2026).

## Reviewer notes (2026-08-22, kmdb-plan-reviewer)

**Code claims verified against `local_directory_adapter.dart` at HEAD.**

- `:255` `return _writeViaTempRename(file, newBytes);` is inside the `try` that
  opens at `:246`; the `finally` at `:256–261` runs `await raf.unlock()` then
  `await raf.close()`. A bare return therefore releases the advisory lock and
  closes the handle before the write completes — the problem statement is
  accurate. ✅
- `:164` (non-atomic create-if-absent) and `:174` (non-atomic update fallback)
  live directly in `compareAndSwap` (`:145–175`), not inside any lock-holding
  `try`/`finally`. Correctly excluded. ✅
- The one-line fix `return await _writeViaTempRename(...)` is correct for the
  stated problem and is the minimal change. ✅

**Test-tree reality (drives Q1).**

- `FaultyStorageAdapter` (`test/support/faulty_storage_adapter.dart:43`)
  `implements StorageAdapter` — the engine's block-device interface — not
  `SyncStorageAdapter`. It cannot wrap `LocalDirectoryAdapter`. The plan's
  Option A reference to it is a category error.
- `LocalDirectoryAdapter` has **no injection seam**: it calls `dart:io`
  `File`/`RandomAccessFile` directly, and the buggy site is a private-to-private
  call (`_updateWithLock` → `_writeViaTempRename`). Private members are not
  virtual across libraries, so a test subclass in the test library cannot
  intercept the internal call. Any observation-based test needs a *new*
  production seam.
- The existing atomic-mode contention test
  (`sync_adapter_conformance.dart:539`, "create-if-absent: at most one winner")
  only exercises `ifMatchEtag: null` → `_createExclusive`. The buggy
  `_updateWithLock` path has **no contention coverage today**, which is why the
  bug is green on `main`.
- Only production caller of the atomic *update* path:
  `consolidation_coordinator.dart:412` (lease renewal). `:392` is
  create-if-absent. A single coordinator does not issue concurrent renewals of
  its own lease, so Q2's residual window has low real-world exposure — but the
  class doc-comment advertises a broader guarantee.

**Recommended concrete test (contingent on Q2 keeping temp-rename).** A
deterministic, gated-seam ordering probe that fails on the unfixed code and
passes after — no reliance on I/O timing:

1. Add two `@visibleForTesting @protected` overridable methods to
   `LocalDirectoryAdapter`: rename `_writeViaTempRename` to a protected
   `writeViaTempRename` (callsites already dispatch through `this`), and extract
   the `finally` body's unlock+close into a protected `releaseLock(raf)` that the
   `finally` calls. (Keep the underscore-free names documented as test seams.)
2. Test subclass records an event log and holds the write open on a
   `Completer` the test controls:
   - `writeViaTempRename` overridden to append `write:start`, `await gate.future`,
     call `super`, append `write:end`.
   - `releaseLock` overridden to append `unlock`, call `super`.
3. Seed the file and capture its ETag so the *update* path is taken. Call
   `compareAndSwap(path, newBytes, ifMatchEtag: etag)` **without awaiting**, pump
   the event loop, then assert the log does **not** yet contain `unlock`
   (on the unfixed code the `finally` has already run → `unlock` present → the
   test fails, exactly as required). Complete the gate, await the call, and
   assert the final order is `[write:start, write:end, unlock]`.

This is the only approach found that is deterministic *and* actually guards the
ordering. If the team rejects test-only production seams, fall back to
lint-as-guard + a release-checklist entry (next free is RC-28 per §28) for a
real two-process contention run on a local POSIX filesystem — and say so
explicitly in the plan rather than leaving it to the implementer.

**Implementation-readiness verdict.** Blocked on Q1 and Q2. The fix line is
mechanical, but "add a test" is not yet executable: the two offered options are
respectively non-implementable and non-deterministic, and Q2 may change the
write mechanism (and therefore what the test asserts). Resolve Q1+Q2, pin the
single test, and this is ready for `Investigated`.

## Summary

_To be completed when the work is done._
