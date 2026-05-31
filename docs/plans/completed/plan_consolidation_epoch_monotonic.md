# Consolidation epoch: enforce monotonicity

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/32

## Problem statement

The consolidation lease's `epoch` field is documented as a "monotonically-increasing
fencing token" (both in the `ConsolidationLease.epoch` doc comment and in the
`ConsolidationCoordinator` class doc), but `_buildLease` sets it to the raw wall-clock
millisecond value:

```dart
final epoch = nowMs; // use wall clock as fencing token
```

The wall clock is not monotonic: a backwards NTP correction, a daylight-saving
transition, or a manual clock adjustment can produce a new epoch that is _lower_ than the
one written by the previous lease holder. The fencing token then regresses, which defeats
its purpose.

**Concrete failure scenario:**

1. Device A acquires a lease with `epoch = 1_000_000` (nowMs at time T1).
2. Device A times out mid-consolidation; its lease expires.
3. Device B's clock is set back so `nowMs = 900_000`.
4. Device B reads the expired lease (epoch 1 000 000) and writes a new lease with
   `epoch = 900_000`.
5. If device A later resumes (stale state), it believes its epoch (1 000 000) is still
   the _largest known_, so a fencing check based on epoch ordering would not protect the
   newer round's output.

The §12 spec already states the correct rule: `epoch = (previous epoch + 1)`, but the
code does not implement it.

**Blast radius:** bounded. The H5 fix ensures consolidation is only attempted when
`providesAtomicCas` is true. The CAS `compareAndSwap` provides mutual exclusion; the
epoch is a _secondary_ fencing defence. However, the discrepancy between the spec, the
doc comments, and the code is a latent correctness wrinkle that should be closed.

## Investigation

### How the epoch is currently produced

`_buildLease` (`consolidation_coordinator.dart:500-510`) receives `nowMs` from
`_wallClock()` and assigns `epoch = nowMs`. It does not read or consider any previously
used epoch value.

### How the epoch is consumed

1. **Lease file** — written as the `epoch` field of the JSON lease document.
2. **Output SSTable filename** — `SstableInfo.consolidationName` at
   `sstable_info.dart:129-135` embeds the epoch as the second dash-separated segment:
   `{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst`.
3. **Fencing verification** — `_verifyLeaseHolder` (`consolidation_coordinator.dart:517-525`)
   re-reads the lease and rejects it if the stored epoch does not equal `expectedEpoch`.
   This guards against a TOCTOU race in the CAS acquisition, not against a regressed
   epoch on a future acquisition.

### Where the existing lease is already read

`acquireLease` downloads and decodes the existing lease before calling `_buildLease`
(lines 315-338). The expired/corrupt lease's epoch is available in the local variable
`existing` at that point, but is discarded rather than forwarded to `_buildLease`.

For the "file disappeared between read and getEtag" case the code falls through to the
create path without the expired lease reference — but the epoch was already decoded from
the expired bytes, so it can be captured in a local variable before the branching.

### Recommended fix

Pass the previously-observed epoch into `_buildLease` and apply:

```dart
final epoch = previousEpoch != null ? max(previousEpoch + 1, nowMs) : nowMs;
```

`max(previousEpoch + 1, nowMs)` is strictly greater than `previousEpoch` (monotonic)
and still advances with the wall clock in the normal case.

The change is confined to `acquireLease` and `_buildLease`; no change to the
`ConsolidationLease` model, `SstableInfo`, or any callers is needed.

### Decision: global monotonicity, not per-device (resolves spec divergence)

The §12 spec describes the epoch as "monotonically increasing **per coordinatorId**"
(line 338) and step 3 frames it as `(previous epoch *for this deviceId*) + 1`. The
recommended fix does **not** implement per-device monotonicity: `acquireLease` reads
whatever lease is currently on disk — which, after a takeover, is the *previous holder's*
lease, possibly a different device. `previousEpoch` is therefore the last epoch written by
*any* device, and `max(previousEpoch + 1, nowMs)` yields a **globally** monotonic epoch
across the single lease-file slot.

This is a deliberate, and stronger, choice — adopt it rather than the literal per-device
reading of the spec, for these reasons:

- There is exactly one lease file (`.consolidation-lease`); it is a single linearised slot
  guarded by CAS. A global epoch over that slot is the natural fencing total order.
- Per-device monotonicity would require each device to persist its own last-used epoch
  somewhere durable and survivable across crashes — state that does not exist today and is
  not worth adding for a *secondary* fencing defence (the CAS in H5 is the primary mutual
  exclusion).
- A global epoch strictly dominates the per-device guarantee for the actual invariant we
  care about: a resumed stale holder must never observe its own old epoch as the largest
  known. Since every new lease's epoch exceeds the one it replaced, this holds regardless
  of which device wrote the prior lease.

**Spec must be updated to match this decision** (see the corrected spec-edit list below),
so the implementer is aligning code *and* spec to "global per-lease-slot monotonic", not
leaving the "per coordinatorId" wording in place.

### Edge cases the implementer must handle

- **Corrupt prior lease.** `ConsolidationLease.fromBytes` returns `null` on a malformed
  document. In that case `existing` is `null` and there is no usable `previousEpoch`; the
  overwrite-via-CAS path must treat this as `previousEpoch == null` and fall back to
  `nowMs`. Capture `existingEpoch` as `existing?.epoch` so a corrupt lease naturally yields
  `null`. Do **not** read the epoch off the raw bytes independently of `fromBytes`.
- **File-disappeared-between-read-and-getEtag.** The code falls through from the overwrite
  branch to the create branch (line 337). `existingEpoch` is decoded at line 318 and must
  survive into the create-path `_buildLease` call, so it must be hoisted to a local declared
  before the `if (existingBytes != null)` block — not declared inside it.
- **No prior lease at all.** `existingBytes == null` → `existingEpoch` stays `null` →
  `epoch = nowMs`. This is the path the new "no-previous-lease" test exercises.

### Spec / doc corrections needed

- `ConsolidationLease.epoch` doc comment (line 99): correctly says
  "Monotonically-increasing" — no change needed once the code matches.
- `ConsolidationCoordinator` class doc (lines 167-169): "monotonically-increasing token
  _derived from the current wall clock_" — remove the "derived from wall clock" qualifier,
  replace with the actual rule (previous epoch + 1, floored by wall clock).
- `docs/spec/12_sync.md` line 338: JSON example comment says
  `// monotonically increasing per coordinatorId`. **Replace** "per coordinatorId" with
  "per lease file (global)", and note the implementation uses `max(previous + 1, nowMs)`.
  Per-device monotonicity is *not* what the code provides (see "Decision" above).
- `docs/spec/12_sync.md` line 375-376: Spec step 3 says
  `epoch = (previous epoch for this deviceId) + 1, or 0 if first acquisition`. **Replace**
  with: `epoch = max((epoch of the lease being replaced) + 1, nowMs), or nowMs if no prior
  lease exists`. Drop "for this deviceId" — the prior lease may belong to another device.
- `docs/spec/12_sync.md` lines 350-356 ("Why epoch rather than a UUID?"): this rationale is
  written entirely in per-device terms ("If device 'a3f2b1c9' crashes and re-acquires, its
  epoch increments"). Reword so the total order is over the lease slot, not per device, to
  avoid contradicting the corrected steps above.

### Testing

The `wallClock` parameter is already injectable via the `ConsolidationCoordinator`
constructor. The regression test can inject a clock that jumps backwards between
acquisitions and assert that the second lease's epoch is still greater than the first's.
No fault-injection harness or real-OS test is required; this is fully CI-testable.

## Open questions

None.

## Implementation plan

- [x] In `acquireLease`, declare `final int? existingEpoch` **before** the
  `if (existingBytes != null)` block and assign it `existing?.epoch` so it survives both the
  "overwrite expired" branch and the fall-through to the "create new" branch. A corrupt
  lease (`existing == null`) leaves `existingEpoch` null.
- [x] Change `_buildLease` signature to `_buildLease(List<String> inputFiles, int nowMs,
  {int? previousEpoch})` and pass `existingEpoch` from both call sites
  (lines ~327 and ~341).
- [x] Implement `epoch = previousEpoch != null ? max(previousEpoch + 1, nowMs) : nowMs`.
  Added `import 'dart:math' show max;`.
- [x] Update `_buildLease` doc comment, the `ConsolidationLease.epoch` doc comment
  (re-verified — no change needed), and the `ConsolidationCoordinator` class doc (removed
  "derived from the current wall clock", replaced with actual formula and global-per-slot
  ordering note).
- [x] Update `docs/spec/12_sync.md`: line 338 inline comment, step 3 (lines 375-376), and
  the "Why epoch rather than a UUID?" rationale (lines 350-356), per the spec-corrections
  list in the Investigation.
- [x] Regression test (`consolidation_coordinator_test.dart`): construct a coordinator with
  an injected `wallClock`. Acquire a lease at a high clock value; let it expire; acquire
  again with a clock that returns a *lower* value; assert the second lease's epoch is
  `firstEpoch + 1` (strictly greater than the first). Exercised through the real
  `acquireLease` path against the in-memory `CloudAdapter`.
- [x] No-previous-lease test: first-ever acquisition yields `epoch == nowMs`.
- [x] Edge-case test: corrupt existing lease bytes (e.g. `Uint8List.fromList([1,2,3])`)
  followed by acquisition asserts the new epoch falls back to `nowMs` rather than throwing.
- [x] Confirmed SSTable-filename consumer is unaffected: epoch is interpolated as bare
  decimal `$epoch` — no width assumption. Existing `sstable_test.dart` epoch round-trip
  continues to pass.
- [x] Run `make pre_commit` — all 1541 tests pass (9 E2E skipped), format clean, analyze
  clean, license check passes. Exit code 0.

## Summary

- Fixed `_buildLease` in `consolidation_coordinator.dart` to accept a
  `previousEpoch` named parameter and implement `epoch = max(previousEpoch + 1, nowMs)`,
  ensuring the epoch is strictly greater than any previous value even when the wall clock
  has moved backwards (NTP correction, daylight-saving, manual adjustment).
- Hoisted `int? existingEpoch` in `acquireLease` before the `if (existingBytes != null)`
  block, assigned it `existing?.epoch`, and passed it to both `_buildLease` call sites
  (overwrite-expired path and create-new path). A corrupt lease leaves `existingEpoch`
  null, which falls back to `nowMs` as specified.
- Added `import 'dart:math' show max;` — no other callers or types were changed.
- Updated the `ConsolidationCoordinator` class doc (removed "derived from the current
  wall clock", stated the `max(previousEpoch + 1, nowMs)` formula and global-per-slot
  ordering). `ConsolidationLease.epoch` doc comment was already correct.
- Updated `docs/spec/12_sync.md`: the lease-file schema comment (line 338), acquisition
  step 3 (epoch formula), and the "Why epoch rather than a UUID?" rationale section —
  all now describe global monotonicity over the single lease-file slot rather than
  per-device monotonicity.
- Added three regression tests via the injectable `wallClock`: (1) clock-backwards
  acquisition asserts second epoch equals `firstEpoch + 1`; (2) no-previous-lease
  acquisition asserts `epoch == nowMs`; (3) corrupt-lease acquisition asserts epoch
  falls back to `nowMs` without throwing. All exercise the public `acquireLease` path
  against the in-memory `MemorySyncAdapter`.
- `make pre_commit` passes: format clean, `dart analyze` no issues in all 6 packages,
  license check passes, 1541 tests pass (9 E2E skipped).

---

## Reviewer notes (kmdb-plan-reviewer, 2026-05-30)

**Verdict: Investigated — ready for implementation.**

All factual claims in the plan were verified against `main`:
`consolidation_coordinator.dart` `_buildLease` (line 502) does set
`epoch = nowMs`; `acquireLease` (lines 312-351) decodes `existing` and discards its epoch;
`_verifyLeaseHolder` (517-525) checks epoch equality; `SstableInfo.consolidationName`
(135) interpolates the epoch as a decimal int (no width assumption, so a larger epoch is
safe); and §12 step 3 (line 376) prescribes `previous epoch + 1`. The cited line numbers
are accurate.

**The one design call I drove out:** the plan's fix produces a *global* epoch over the
single lease slot, whereas §12 says "per coordinatorId". Rather than leave the implementer
to reconcile that, I recorded an explicit decision (Investigation → "Decision: global
monotonicity") to adopt global monotonicity and **rewrite the conflicting spec prose**, and
expanded the spec-edit list accordingly. This is the stronger guarantee and avoids
introducing per-device durable epoch state for a secondary fencing defence (CAS/H5 is the
primary mutual exclusion). If the user prefers literal per-device monotonicity, that would
be a larger change (new durable state) and should bounce back to `Questions` — but I judge
global to be the right call and have set the plan up for it.

**Strengths:** correctly scoped (no model/SstableInfo/caller changes), correctly identifies
this as a latent wrinkle behind the H5 CAS rather than an active data-loss bug, and the
test is genuinely CI-able via the injectable `wallClock` — no fault-injection harness or
release-checklist entry needed.

**Gaps I closed:** the original test step routed through the private `_buildLease`; I
redirected it through the public `acquireLease` path against the in-memory `CloudAdapter`
the existing tests already use. Added the corrupt-lease fall-back edge case (so
`existingEpoch = existing?.epoch` rather than parsing raw bytes), the variable-hoisting
requirement for the file-disappeared fall-through, and a coverage note for the two new
branches.

**One cross-agent flag:** spec edits to `docs/spec/12_sync.md` are normally the
`kmdb-architect`'s responsibility. The implementer should coordinate that wording (the
"Why epoch rather than a UUID?" rationale in particular is written in per-device terms and
needs rewording, not just a one-line tweak).

### Re-verification pass (kmdb-plan-reviewer, 2026-06-01)

Re-checked every cited claim against current `main`; all still hold:

- `consolidation_coordinator.dart:502` — `final epoch = nowMs; // use wall clock as fencing token`.
- `acquireLease` (312-351) decodes `existing` at line 318 and discards its epoch; two
  `_buildLease` call sites at 327 and 341.
- `_verifyLeaseHolder` (517-525) checks `lease.epoch != expectedEpoch`.
- `ConsolidationLease.fromBytes` (127-140) returns `null` on any malformed document via
  `catch (_)`, so `existing?.epoch` cleanly yields `null` for a corrupt lease — the
  edge-case handling in the checklist is correct as written.
- `ConsolidationLease.epoch` doc (line 99) already reads "Monotonically-increasing" — fine
  once code matches. Class doc (167-169) still says "derived from the current wall clock" —
  the doc-correction step is still required.
- `SstableInfo.consolidationName` lives at
  `packages/kmdb/lib/src/engine/sstable/sstable_info.dart:129-135` (the plan's path omits the
  `engine/` segment, but the line numbers are accurate). It interpolates `epoch` as a bare
  decimal `$epoch` — no width assumption, so a larger epoch is safe.
- `wallClock` is injectable via the constructor (lines 191-192) — the regression test is
  fully CI-able with no harness or release-checklist entry.
- §12 spec: line 338 "monotonically increasing per coordinatorId", step 3 (375-376)
  `previous epoch + 1`, and the per-device "Why epoch rather than a UUID?" rationale
  (350-356) all confirmed present and needing the rewording the plan prescribes.

**Status unchanged: Investigated.** No new gaps. The plan remains ready for mechanical
implementation; the only off-plan coordination is the §12 spec wording with `kmdb-architect`.
