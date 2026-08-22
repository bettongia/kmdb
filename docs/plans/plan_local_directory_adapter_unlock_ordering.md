# LocalDirectoryAdapter: await the write before the lock is released (CAS ordering)

**Status**: Open

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

- [ ] None. The fix is unambiguous (`return await`); the only open work is a
      test that actually exercises the ordering rather than the golden path.

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

## Summary

_To be completed when the work is done._
