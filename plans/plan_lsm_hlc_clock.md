# LsmEngine HLC Clock Injection Seam

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

`LsmEngine` maintains its own `Hlc _hlc` field and advances it via a private
`_tick()` method that calls `DateTime.now()` directly. This duplicates the
logic already implemented in `HlcClock` (`src/sync/hlc_clock.dart`), which
was designed as the per-database injectable clock abstraction but is never
wired into the engine.

The consequences are twofold:

1. **`HlcClock` is dead code on the write path.** Every document write goes
   through `LsmEngine._tick()`, not through `HlcClock`. `HlcClock` is only
   exercised by `ConsolidationCoordinator`, which uses it for lease timestamps
   — not for WAL/SSTable HLC values.

2. **`LsmEngine` cannot be tested with a deterministic clock.** There is no
   way to freeze or advance the wall clock seen by `LsmEngine` in tests. Any
   test that cares about HLC ordering must race against `DateTime.now()`, which
   is inherently flaky. This makes it impossible to write deterministic tests
   for clock-sensitive paths such as rapid successive writes, HLC rollover, and
   `ClockSkewException` propagation.

This plan migrates `LsmEngine` to use `HlcClock` as its authoritative clock,
threads the injection point through `KvStoreConfig` and `KvStoreImpl`, and
removes the duplicated `_tick()` logic.

## Investigation

### Current state confirmed by code review

**`LsmEngine._tick()` — the duplicated clock (lsm_engine.dart, line 153)**

`LsmEngine` holds a private `Hlc _hlc` field, initialised from `initialHlc` in
the constructor (set by `CrashRecovery.open`). It advances the field via
`_tick()` on every write. `_tick()` calls `DateTime.now().millisecondsSinceEpoch`
directly and has its own logical-counter overflow handling (advance physical
by +1ms). The method is called from 10 sites: `put`, `delete`, `writeBatch`,
`flush` (WAL rotate), `_compactL0ToL1`, `_compactL1ToL2`, `_compactAll`,
`_doManifestRotation`, `ingestAt0`, and `reassignDeviceId`.

**`advanceClock(Hlc)` (lsm_engine.dart, line 170)**

A second public-ish method that advances `_hlc` to be at least `observed`,
used only in `ingestAt0` before a `_tick()` call. This maps exactly to
`HlcClock.update(received)` — the two semantics are equivalent. Note:
`advanceClock` silently ignores the `ClockSkewException` guard that
`HlcClock.update()` provides; this is arguably a latent correctness gap on the
ingest path.

**`HlcClock` (sync/hlc_clock.dart)**

A fully-featured, injectable per-database clock class with two methods:
- `now()` — local tick (equivalent to `_tick()` but with proper 48-bit mask
  `& 0xFFFFFFFFFFFF` and a spin-wait for logical overflow rather than +1ms
  physical bump).
- `update(Hlc received)` — remote observation with `ClockSkewException` guard.

`HlcClock` accepts a `wallClock` function injection and a `maxClockSkew`
duration at construction time. It is **completely dead code on the write path**:
no production source file imports `hlc_clock.dart` outside the file itself.
It is only exercised by tests (`hlc_test.dart`) and was clearly written to be
injected here but never wired up.

**`ConsolidationCoordinator`**

Uses its own `int Function() _wallClock` injectable for wall-clock time, but
uses the value only for lease timestamps (millisecond epoch integers), not for
`Hlc` generation. It does not use `HlcClock`.

**`CrashRecovery.open`**

Computes `initialHlc` manually (lines 205–208):
```dart
final nowMs = DateTime.now().millisecondsSinceEpoch;
final initialHlc = nowMs > clock.physicalMs
    ? Hlc(nowMs, 0)
    : Hlc(clock.physicalMs, clock.logical + 1);
```
This manual advance-to-wall-time logic is the same as what `HlcClock`
would do on `now()` after `update(replayedMaxHlc)`. It passes the resulting
`Hlc` as `initialHlc` to `LsmEngine.create()`.

**`KvStoreConfig.maxClockSkew` — orphaned field**

`KvStoreConfig` declares `maxClockSkew` (default 60 s, line 331) and the
`HlcClock` constructor parameter is documented as referencing it, but the
value is never passed to `HlcClock` anywhere in production code. This is
a secondary inconsistency unlocked by this refactor.

**`_tick()` vs `HlcClock.now()` — semantic differences**

The two implementations are almost identical in intent but differ in two
edge cases:

1. **48-bit physical mask**: `HlcClock.now()` applies `& 0xFFFFFFFFFFFF` to
   constrain the physical component to 48 bits; `_tick()` does not. In
   practice this has no effect for timestamps in the foreseeable future, but
   `HlcClock` is more correct.

2. **Logical counter overflow**: `_tick()` increments the physical component
   by +1ms when `logical >= 0xFFFF`; `HlcClock.now()` spins on the wall
   clock until it advances. The spin-wait is more correct (it doesn't
   fabricate future physical time), though both paths are unreachable under
   KMDB's synchronous single-isolate write model.

Neither difference poses a correctness risk in practice, but `HlcClock` is
the more principled implementation.

**Test coverage of clock-sensitive paths**

`lsm_engine_test.dart` has zero clock-aware tests. It cannot test HLC
ordering, rapid-write monotonicity, or `ClockSkewException` propagation
through the write path because there is no way to inject a controlled clock.
`hlc_test.dart` covers `HlcClock` in isolation, but there are no integration
tests connecting the clock to the engine.

**Summary of files to change**

| File | Change |
|------|--------|
| `engine/kvstore/lsm_engine.dart` | Replace `Hlc _hlc` + `_tick()` + `advanceClock()` with an injected `HlcClock _clock`; update all 10 call sites |
| `engine/kvstore/crash_recovery.dart` | Construct `HlcClock`, call `update(replayedMax)` + `now()` instead of manual `initialHlc` computation; pass clock to engine |
| `engine/kvstore/kv_store_impl.dart` | Pass `HlcClock` from config (or factory) through `CrashRecovery` to `LsmEngine`; or let `CrashRecovery` own construction — see Implementation plan |
| `engine/kvstore/kv_store.dart` | No change needed; `KvStoreConfig.maxClockSkew` already exists and will now be honoured |
| `test/engine/lsm_engine_test.dart` | Add deterministic-clock tests for HLC ordering, ingest advance, and (optionally) `ClockSkewException` on ingest |

## Implementation plan

### Guiding principles

- `HlcClock` is injected into `LsmEngine` as a field; `LsmEngine` calls
  `_clock.now()` in place of every `_tick()` call and `_clock.update(observed)`
  in place of `advanceClock(observed)`.
- `CrashRecovery` constructs the `HlcClock` (seeding it from the replayed WAL
  max HLC via `update()`) and passes it to `LsmEngine.create()`. This keeps
  clock construction co-located with the recovery logic that determines the
  starting HLC, rather than spreading it across three classes.
- `KvStoreImpl.open` passes `config.maxClockSkew` to `HlcClock` via
  `CrashRecovery`, finally honouring the config field that has been dead until
  now.
- `LsmEngine`'s existing `currentHlcString` getter is updated to read from
  `_clock.current` instead of the old `_hlc` field.
- No changes to the `KvStore` public interface. No changes to `KvStoreConfig`
  (it already has `maxClockSkew`).

### Step-by-step

**Step 1 — Update `LsmEngine` constructor and factory**

In `lsm_engine.dart`:

1. Replace the `required Hlc initialHlc` parameter in `LsmEngine._()` and
   `LsmEngine.create()` with `required HlcClock clock`.
2. Replace the `Hlc _hlc` field with `final HlcClock _clock`.
3. Add the import for `hlc_clock.dart`.
4. Replace every `_tick()` call with `_clock.now()` (10 call sites: `put`,
   `delete`, `writeBatch`, `flush`, `_compactL0ToL1`, `_compactL1ToL2`,
   `_compactAll`, `_doManifestRotation`, `ingestAt0`, `reassignDeviceId`).
5. Replace `advanceClock(observed)` body — change `if (observed > _hlc) _hlc = observed`
   to `_clock.update(observed)`. The `ClockSkewException` propagates naturally
   up the call stack; callers of `advanceClock` (currently only `ingestAt0`)
   should let it propagate uncaught so `KvStore.ingestSstable` surfaces it.
6. Remove the `_tick()` method entirely.
7. Update `currentHlcString` getter to use `_clock.current` instead of `_hlc`.

**Step 2 — Update `CrashRecovery`**

In `crash_recovery.dart`:

1. Add the import for `hlc_clock.dart`.
2. Inject `maxClockSkew` into `CrashRecovery` — add a `Duration maxClockSkew`
   parameter to `open()` (or store it on the `CrashRecovery` instance alongside
   `config`; consistent with the existing pattern of taking `config` in the
   constructor, store it as `config.maxClockSkew`).
3. Replace the manual `initialHlc` computation block (lines 205–208) with:
   ```dart
   final clock = HlcClock(maxClockSkew: config.maxClockSkew);
   clock.update(clock.current > Hlc(0,0) ? clock : replayedMax);
   // more precisely:
   if (clock.current < replayedMax) clock.update(replayedMax);
   clock.now(); // advance past wall time
   ```
   More precisely, the correct replacement is:
   - Construct `HlcClock(maxClockSkew: config.maxClockSkew)`.
   - Call `clock.update(replayedMaxHlc)` to seed from the replayed WAL max.
     (`update` already handles the wall-clock comparison internally, so the
     manual `nowMs > clock.physicalMs` branch is not needed.)
   - Pass `clock` to `LsmEngine.create()`.
4. Remove the `DateTime.now()` call that computed `nowMs`.

**Step 3 — Update `KvStoreImpl`**

`KvStoreImpl.open` passes `config` to `CrashRecovery` already. Because
`CrashRecovery` now reads `config.maxClockSkew`, no change to
`KvStoreImpl.open` is needed beyond verifying the wiring is correct. No
changes to `KvStoreConfig`.

**Step 4 — Update `kv_store.dart` doc comment**

Add a brief note to `KvStoreConfig.maxClockSkew` clarifying it is now
forwarded to the engine's `HlcClock` and governs both the SSTable ingest
path and the write path.

**Step 5 — Tests in `lsm_engine_test.dart`**

Add a test group `'LsmEngine — HLC clock injection'` covering:

- **Monotonic ordering**: create an engine with a frozen clock; write two keys;
  decode their HLC from the WAL or SSTable; assert the second HLC is strictly
  greater than the first (logical counter increments in the same millisecond).
- **Clock advance on ingest**: provide a fake SSTable with a future `maxHlc`
  well beyond the injected wall time; call `ingestSstable`; verify that the
  subsequent write carries an HLC >= the ingested max (i.e. `advanceClock`
  correctly forwarded to `HlcClock.update`).
- **`ClockSkewException` on ingest**: provide an SSTable with a `maxHlc` more
  than 60 seconds ahead of the injected wall clock; assert that `ingestSstable`
  throws `ClockSkewException`. This validates the previously-missing guard.
- **Deterministic flush timestamp**: provide a frozen clock; call `flush()`;
  verify the SSTable filename embeds the expected HLC segment.

The test helper `_open()` should gain an optional `wallClock` parameter so
tests can inject a controlled `int Function()`. `CrashRecovery` needs to
accept the injected clock or a `wallClock` factory — the cleanest seam is to
add an optional `HlcClock Function()? clockFactory` parameter to `open()`, or
to accept the fully-constructed `HlcClock` directly for tests.

**Recommended seam for test injection**

Rather than adding a `clockFactory` callback through three layers, add an
optional `HlcClock? clock` parameter to `LsmEngine.create()`. When provided it
bypasses construction in `CrashRecovery`. `KvStoreImpl` never passes it
(production always goes via `CrashRecovery`). Tests that construct `LsmEngine`
directly can pass a pre-built `HlcClock` with an injected wall clock. This is
a one-parameter addition to an already-internal factory method and avoids
threading a factory callback through `KvStoreImpl`.

**Step 6 — `HlcClock` export**

`ClockSkewException` will now propagate through `KvStore.ingestSstable`. It
should be exported from `kmdb.dart` so callers can catch it explicitly. Add
an export of `HlcClock` and `ClockSkewException` from `sync/hlc_clock.dart`
to `lib/kmdb.dart`.

### What does NOT need to change

- `ConsolidationCoordinator` — it already has its own `int Function() wallClock`
  seam and uses it only for lease epoch integers, not for `Hlc` generation.
  It is out of scope.
- `sync_engine.dart` — does not manage an HLC directly.
- All layers above `KvStoreImpl` (CacheLayer, Query Layer) — they are
  transparent to the clock.

### Checklist

- [ ] `LsmEngine`: remove `_tick()`, replace with `_clock.now()`, replace
      `advanceClock` body with `_clock.update()`
- [ ] `LsmEngine`: replace `Hlc initialHlc` constructor param with `HlcClock clock`
- [ ] `CrashRecovery`: construct `HlcClock(maxClockSkew: config.maxClockSkew)`,
      seed with `update(replayedMax)`, pass to engine
- [ ] `KvStoreConfig.maxClockSkew` doc comment updated
- [ ] `kmdb.dart`: export `HlcClock` and `ClockSkewException`
- [ ] `lsm_engine_test.dart`: add 4 deterministic-clock tests (ordering,
      advance-on-ingest, `ClockSkewException`, flush filename)
- [ ] All existing tests pass (`dart test packages/kmdb`)

## Summary

{Dot points highlighting the work undertaken — to be completed after
implementation}
