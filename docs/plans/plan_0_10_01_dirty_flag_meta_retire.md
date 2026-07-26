# Move the dirty-open flag off synced `$meta` (WI-14)

**Status**: **Investigated**

**PR link**: _(none yet)_

> **Provenance.** WI-14 of the [0.10.01 hardening track](../roadmap/0_10_01.md).
> Found during **WI-11 Phase 3** (2026-07-23) and classified — not fixed — there,
> under the same "classify here, fix separately" precedent that spun out SC-5/WI-12
> and the tombstone floor/Q-D. This is the mechanical sibling of the tombstone-floor
> move (WI-11/Q-D): a device-local fact currently living in synced `$meta`, moved to a
> local-only `$$` namespace. Code coordinates below were verified against `main`
> (post-WI-12).

## Problem statement

The **dirty-open flag** records that *this device's* previous session did not
`close()` cleanly (process kill or power loss after ≥1 write). On the next open,
a set flag drives `OpenResult.hadUnclosedSession`, which the Query Layer uses to
fire `onIndexRebuildRequired` — the derived secondary/FTS/Vec indexes for
namespaces written in the interrupted session may be stale and must be rebuilt.

It is written to `$meta` under the symbolic key `dirty` (device-**independent**:
`_nameToKey('dirty')` hashes the same on every device). `$meta` **replicates** —
it rides synced SSTables and resolves by plain Last-Write-Wins on HLC. That is
wrong for a device-local fact, in exactly the SC-10 / Q-D shape:

- **False-negative (the dangerous direction).** This device crashes mid-session,
  leaving its `dirty` flag set locally but **not yet read** (the flag is only
  consulted at the *next* open). Before this device reopens, a **peer** closes
  cleanly and its `clearDirty` deletes the `dirty` key with a later HLC. That
  tombstone replicates in, and by LWW erases this device's genuine crash marker.
  This device reopens, `getDirtyFlag()` returns `false`, and
  `onIndexRebuildRequired` **never fires** — the device serves queries against
  stale derived indexes. This is a silent-wrong-results defect (not data loss:
  the underlying documents are intact; only the derived indexes are stale).
- **False-positive.** Symmetrically, a peer's mid-session `setDirty` can mark
  *this* device dirty, forcing an unnecessary index rebuild. Merely wasteful, but
  still incorrect attribution.

The flag is also **inert leakage** in the meantime: every device's private
crash/clean state is uploaded to the shared sync folder for no consumer.

### Why it survived WI-11

WI-11 moved the *other* four device-local `$meta` residents (index/FTS/Vec state,
tombstone floor) to `$$` namespaces. The dirty flag has the identical defect
shape but was found too late in WI-11's Phase 3 to fold in without re-opening the
Phase 2/3 crash-safety test surface (`writebatch_atomicity_test.dart` folds the
dirty-flag write into the first-write WAL frame). It was classified and spun out
to this WI. See `docs/roadmap/0_10_01.md` lines 53, 272, 330.

## Investigation

### The defect and the fix are both one-namespace-deep

`isLocalOnly(ns) => ns.startsWith(r'$$')`
([namespace_codec.dart:148](../../packages/kmdb/lib/src/engine/util/namespace_codec.dart#L148)).
A `$$`-prefixed namespace lands only in `.local.sst`, is never uploaded, and is
never ingested from a peer. The tombstone floor's WI-11 fix (`$$gcstate`,
[meta_store.dart:316-442](../../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L316-L442))
is the exact template: it changed only the **namespace argument** on each
get/set, added a `kGcStateNamespace` constant with a rationale doc comment, and
left the value encoding, key encoding, and call sites untouched.

The four dirty-flag methods all live in
[meta_store.dart:155-289](../../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L155-L289)
and all currently pass `kNamespace` (= `$meta`):

| method | line | role |
| :--- | :--- | :--- |
| `getDirtyFlag()` | 173-176 | presence-only read at open (before encryption bootstrap) |
| `setDirty()` | 185-191 | standalone first-write set |
| `clearDirty()` | 194 | delete on clean `close()` |
| `appendDirtyFlag(batch)` | 283-289 | batch-aware set, folded into the first-write WAL frame |

The fix: introduce `static const String kDirtyStateNamespace = r'$$dirtystate'`
with a doc comment mirroring `kGcStateNamespace`'s (why it moved, LWW hazard, the
false-negative scenario), and change `kNamespace` → `kDirtyStateNamespace` in all
four methods. Nothing else in each method changes — value bytes (`[1]` sentinel),
key (`_nameToKey('dirty')`), and the presence-only read semantics are all
preserved.

### The open-path read still works from `$$dirtystate`

`getDirtyFlag()` is called at
[kv_store_impl.dart:211](../../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L211),
**after** engine recovery (`recoveryResult` is already computed) and **before**
the `EncryptionProvider` is assigned. Both properties are preserved by the move:

- The `$$dirtystate` namespace is fully queryable at that point — engine recovery
  replays the manifest and WAL and reconstructs all namespaces, local-only ones
  included (the tombstone floor is read from `$$gcstate` post-open the same way).
- It remains a **presence-only** check (`bytes != null && bytes.isNotEmpty`), so
  it still needs no decryption. The doc comment's encryption-bootstrap rationale
  carries over verbatim; only the namespace name in the prose changes.

### The first-write WAL-frame folding is unaffected

`appendDirtyFlag` is folded into the same `WriteBatch` as the first document
write, the gen-counter bump, and the namespace-registry put
([kv_store_impl.dart:448,622](../../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L448)).
A `WriteBatch` already spans multiple namespaces (`$meta` + user namespace +
`$$index...`), and `$$`-routing to `.local.sst` happens at flush/compaction time
in `compaction_job.dart`/`lsm_engine.dart` (that is how `$$gcstate`/`$$indexstate`
already ride batches). Moving `dirty` from `$meta` to `$$dirtystate` keeps it in
the same atomic frame — the crash-safety invariant (`writebatch_atomicity_test`:
"first-write crash leaves dirty flag set") is preserved because atomicity is a
property of the WAL frame, not of the namespace.

### Test surface

The dirty API is namespace-agnostic to callers — every existing test drives it
through `getDirtyFlag`/`setDirty`/`clearDirty` (public methods), never by
asserting a raw `$meta` key. So the existing tests
(`meta_store_test.dart` dirty groups, `writebatch_atomicity_test.dart`,
`meta_store_encryption_test.dart` dirty round-trip, `lsm_engine_test.dart`)
**pass unchanged** after the move and continue to guard the behaviour.

Two things must be **added** to prove the move actually closed the defect (a
green existing suite proves only that behaviour was preserved, not that the leak
was stopped — the same rigour WI-11 applied):

1. **Device-local isolation (the leak is stopped).** After a first write, assert
   the `dirty` sentinel is present under `MetaStore.symbolicKey('dirty')` in
   `$$dirtystate` and **absent** from `$meta` — i.e. `_engine.get($meta,
   symbolicKey('dirty'))` is `null`. This is the direct analogue of WI-12's
   SC-5 absence assertion.
2. **Cross-device false-negative is closed (deterministic in-process
   regression — mandatory).** Resolved under **Q1** below. The proof reproduces
   the *real* LWW-erasure interleaving in-process via the ingest surface, and
   **must be verified to fail with the namespace change reverted**:
   - Open store A; first write → dirty flag set (pre-fix: `$meta`; post-fix:
     `$$dirtystate`), landing in A's local state at `HLC_A`.
   - **During A's live session**, `ingestSstable` a synthetic SSTable containing
     a `$meta` **delete-tombstone** (`RecordType.delete`, empty value) for
     `MetaStore.symbolicKey('dirty')` at an HLC **strictly greater than `HLC_A`**
     and **above the tombstone floor** — simulating A pulling peer B's
     clean-close `clearDirty`. `$meta` is single-`$` (synced/ingestable), which
     is the entire basis of the defect; `$$dirtystate` is `$$` (never ingested).
     The *same* bytes are therefore a genuine LWW erasure pre-fix and an inert
     no-op on the real flag post-fix.
   - Simulate crash: reopen A **without** a clean `close()`.
   - Assert `getDirtyFlag()` / `OpenResult.hadUnclosedSession` is still `true`.

   Pre-fix (reverted change): step 2 overwrites A's `$meta` `dirty` with the
   higher-HLC tombstone → reopen reads `false` → assertion **fails** (defect
   exposed). Post-fix: `dirty` lives in `$$dirtystate`, the ingested `$meta`
   tombstone doesn't touch it → reopen reads `true` → **passes**.

   The lighter construction-only proof (isolation + "reads from `$$dirtystate`")
   is **rejected as the sole cross-device proof** — it never exercises the
   LWW-erasure path that is the actual defect. Isolation test (1) is retained as
   a **complementary** device-local check, not a substitute.

   *Ingest-surface confirmation (reviewer, 2026-07-27):* the in-repo surface
   drives step 2 exactly as specified. `KvStore.ingestSstable(filename, bytes)`
   (`kv_store_impl.dart:306`) can be called on a live, open store; a synthetic
   SSTable is built via `SstableWriter` + `KeyCodec.encodeInternalKey('$meta',
   keyBytes, hlc, RecordType.delete)` (`buildValidSstable` in
   `test/util/hostile_sstable.dart` is the template — it does the same with
   `RecordType.put`); `RecordType.delete` (0x02, empty value,
   `key_codec.dart:30`) is a real tombstone at an arbitrary HLC; and the 16 key
   bytes come from hex-decoding `MetaStore.symbolicKey('dirty')` (`meta_store.dart:467`),
   which is exactly what `setDirty` wrote.

### Documentation touch-points

Prose that currently pins the flag to `$meta` must move with it. Grep-verified
sites:

- **Registry** [03a_attribute_registry.md:49,58](../spec/03a_attribute_registry.md):
  update the `dirty` row — drop the `⚠`, set storage to `$$dirtystate`, finalise.
  This is the registry-coordination step the `$meta` end-state note calls for.
- **§11** [11_kv_store.md:176](../spec/11_kv_store.md#L176): the `$meta` responsibility
  table lists "dirty-open flag" — move it to a `$$dirtystate` local-only entry
  (§11 already has the `device_id`-is-not-here precedent to copy).
- **§17** [17_crash_recovery.md:43](../spec/17_crash_recovery.md#L43): "Set the
  dirty-open flag in `$meta`" → `$$dirtystate`.
- **§31** [31_encryption.md:579,757](../spec/31_encryption.md): two mentions
  place the dirty flag "currently in `$meta`" — correct to `$$dirtystate`.
- **§12** [12_sync.md:494](../spec/12_sync.md#L494): already records the WI-14
  spin-out; update from "found mis-placed / spun out" to "moved" once landed.
- **§07** [07_wal.md:139](../spec/07_wal.md#L139) and **§26**
  [26_document_versioning.md:111](../spec/26_document_versioning.md#L111) mention
  the dirty flag in the WAL frame **location-neutrally** — verify they need no
  change (expected: no change).

Spec edits are routed through `kmdb-architect` per the pipeline, as WI-11's §16/§20
corrections were. §04/§08 are **not** touched here (that Keychain prose is WI-2's).

## Reviewer feedback (2026-07-27, kmdb-plan-reviewer)

**Verdict: the code-move half of this plan is correct and implementation-ready;
the test-strategy half contains a load-bearing error that must be fixed before
`Investigated`.**

### What checks out (verified against `main`, HEAD 13a143b)

- **All four method coordinates are accurate.** `getDirtyFlag` (173-176),
  `setDirty` (185-191), `clearDirty` (194), `appendDirtyFlag` (283-289) all pass
  `kNamespace` (`$meta`) and all preserve the `[1]` sentinel / `_nameToKey('dirty')`
  key. The move is genuinely a one-argument change per method, exactly mirroring
  the `$$gcstate` template (`kGcStateNamespace`, 316-442). `MetaStore.symbolicKey`
  is a public static (467), so the isolation assertion is writable.
- **Open-path read (kv_store_impl.dart:211) survives the move.** `getDirtyFlag`
  is called after `recoveryResult` is computed and before the
  `EncryptionProvider` is assigned; engine recovery reconstructs local-only
  namespaces too, and the check stays presence-only. Claim holds.
- **WAL-frame folding survives the move.** `appendDirtyFlag` is folded at
  kv_store_impl.dart:448 (`createNamespace`) and :622 (`_appendMetaWrites`).
  Atomicity is a WAL-frame property; a batch already spans `$meta` + user-ns +
  `$$index`, and `$$`-routing to `.local.sst` happens at flush, not commit.
  Claim holds.
- **Documentation touch-point list is accurate and complete.** Registry rows,
  §11:176, §17 step 8, §31 (×2), §12:494 all verified; §07:139 and §26:111 are
  genuinely location-neutral and correctly marked no-change. Roadmap lines 53,
  272, 330 and the end-state table verified. `$$dirtystate` is consistent with
  the `$$gcstate`/`$$indexstate`/`$$ftsstate`/`$$vecstate` naming (roadmap left
  the name unpinned; pinning it here is fine).

### 🔴 The cross-device test recipe (Test surface item 2) is vacuous as written

`getDirtyFlag()` is read **inside `open()` (kv_store_impl.dart:211), before any
post-open `pull()`**. `pull()` / ingest is a separate operation the app invokes
*after* `open()` returns. The plan's recipe — "device B … writes, closes cleanly;
**reopen device A and assert** `getDirtyFlag()` is still true" — has A ingest B's
tombstone only *after* A has reopened, i.e. after the flag was already read. So
the read returns `true` **even pre-fix**, and `onIndexRebuildRequired` has already
fired. The proposed test therefore passes both before and after the fix and
**guards nothing** — precisely the trap `index_cross_device_test.dart` defends
against with its `expect(bPlan.strategy, ScanStrategy.indexScan)` sanity guard.

The bug is real, but the *actual* failing interleaving is more intricate than the
plan states, and it is **not** a mechanical mirror of the WI-11 index test:

1. A session 1: open (fresh, flag false) → first write (`dirty=1` @ `HLC_A`) →
   push A's **documents** (this carries `HLC_A` into the sync folder).
2. B: open → pull A's docs (B's HLC clock advances past `HLC_A`) → **B must
   actually write** (not merely pull), because `close()` only issues `clearDirty`
   when `_dirtyFlagPresent` is true (kv_store_impl.dart:374) → clean close emits
   the `clearDirty` **delete @ `HLC_B` > `HLC_A`** → reopen + push (a `close()` is
   terminal, so the tombstone SSTable only uploads on a subsequent live push).
3. A session 1 **still running**: pull → ingest B's tombstone (`HLC_B` > `HLC_A`)
   → A's own `dirty` key is erased *mid-session by LWW* → A **crashes** (no close).
4. A session 2: open → `getDirtyFlag()` reads the merged local state, sees the
   key deleted → returns **false**. This is the false-negative. Pre-fix: bug.
   Post-fix: A's `dirty` lives in local-only `$$dirtystate`, was never uploaded
   and B's tombstone was never ingested, so it survives A's crash → returns
   **true**. Correct.

Any cross-device regression test **must** reproduce this ordering (the erasure
happens during A's *own dirty session, before the crash*) and **must be shown to
fail with the namespace change reverted**, or it is not a regression test.

### The "upload-exclusion" fallback is too weak to be the sole cross-device proof

Asserting that `$$dirtystate` entries are absent from the synced-SSTable upload
set is very nearly axiomatic given `isLocalOnly` is a one-line prefix check that
is already exercised wherever `.local.sst` partitioning is tested. It does not
exercise the LWW-erasure mechanism at all, so it adds almost nothing beyond
isolation test (1). Drop it as the justification for closing the false-negative.

### The atomicity test's dirty-specific guard silently weakens (coverage erosion)

`writebatch_atomicity_test.dart:137-143` asserts only that *some* record in the
first-write frame has `namespace == r'$meta'`. After the move, `gen`/`namespace`
registry writes still satisfy that — so the test passes unchanged, **but it no
longer guards that the dirty flag itself was folded into the frame** (it would
pass even if `appendDirtyFlag` were dropped entirely). The plan's claim that the
existing tests "continue to guard the behaviour" is therefore not fully true for
this one. `WalRecord` exposes `.namespace`, so the fix is cheap: add an assertion
that a record with `namespace == r'$$dirtystate'` is present in the same frame.
This is the faithful post-move guard of the "first-write crash leaves the dirty
flag set" invariant and should be part of the plan, not optional.

### Minor: keep the class-doc encryption prose consistent

The checklist updates the class-doc bullet at meta_store.dart:34. Also confirm
the encryption section (meta_store.dart:50-67), which enumerates `$meta`
encryption behaviour, does not leave the reader thinking `dirty` is still a
`$meta` resident — `setDirty`/`appendDirtyFlag` still `EncryptionEnvelope.wrap`
the sentinel, just into `$$dirtystate` now.

## Reviewer follow-up (2026-07-27, second pass — resolves Q1, promotes to Investigated)

The user answered Q1 and accepted the three findings from the first pass. All
open questions are now resolved; the plan clears the implementation-readiness
bar and is promoted to **Investigated**.

- **Q1 resolved — mandate option (a), the gold-standard reproduction, but
  constructed deterministically in-process rather than via the full multi-host
  harness.** The mandatory cross-device regression reproduces the *real* failing
  interleaving (LWW erasure of A's own `dirty` key *during A's live session,
  before the crash*) via `ingestSstable` of a synthetic `$meta` delete-tombstone,
  and **must be verified to fail with the namespace change reverted**. Full
  recipe folded into Test surface item 2 above. Rationale for deterministic
  in-process over `kmdb_harness`: it reproduces the exact interleaving without
  multi-host timing flakiness, using the synthetic-ingest technique already in
  the suite. The lighter construction-only proof is **rejected** as the sole
  cross-device proof (never exercises the erasure path); the isolation assertion
  is kept as a complementary test only.
- **Ingest-surface point confirmed** — see the confirmation note in Test surface
  item 2. `ingestSstable` on a live store + `SstableWriter` +
  `KeyCodec.encodeInternalKey(..., RecordType.delete)` + hex-decoded
  `symbolicKey('dirty')` is sufficient; no harness fallback needed. Two
  implementer notes: the tombstone HLC must be strictly greater than A's
  `setDirty` HLC (so it wins LWW) and above the tombstone floor (so ingest does
  not reject it).
- **Finding (i) accepted — upload-exclusion fallback dropped entirely.** No
  longer offered as a substitute for the cross-device proof.
- **Finding (ii) accepted — WAL-frame `$$dirtystate` assertion added** to replace
  the guard `writebatch_atomicity_test.dart:137-143` silently loses when the
  dirty write leaves `$meta`.

## Implementation plan

- [ ] Add `kDirtyStateNamespace = r'$$dirtystate'` to `meta_store.dart` with a
      doc comment mirroring `kGcStateNamespace`'s (why it moved off `$meta`, the
      LWW false-negative hazard, local-only guarantee).
- [ ] Change `kNamespace` → `kDirtyStateNamespace` in `getDirtyFlag`, `setDirty`,
      `clearDirty`, `appendDirtyFlag`. Update each method's doc comment that says
      "written to `$meta`" to name the new namespace and reference WI-14.
- [ ] Update the class-level doc comment (meta_store.dart:34) that lists the
      dirty-open flag among `$meta`'s residents, and confirm the encryption
      section (meta_store.dart:50-67) does not still imply `dirty` is a `$meta`
      value — it stays `EncryptionEnvelope`-wrapped, now into `$$dirtystate`.
- [ ] Add the **complementary** device-local isolation test (sentinel present in
      `$$dirtystate`, absent from `$meta` via `_engine.get($meta,
      symbolicKey('dirty')) == null`). This is a companion to — **not** a
      substitute for — the cross-device regression below.
- [ ] Add the **mandatory** deterministic in-process cross-device regression
      (resolved **Q1**, option (a) constructed in-process): open A → first write
      (dirty set @ `HLC_A`) → `ingestSstable` a synthetic SSTable carrying a
      `$meta` **delete-tombstone** (`RecordType.delete`) for `symbolicKey('dirty')`
      at an HLC strictly `> HLC_A` and above the tombstone floor → simulate crash
      (reopen without clean `close()`) → assert `getDirtyFlag()` /
      `OpenResult.hadUnclosedSession` is still `true`. Build the SSTable with
      `SstableWriter` + `KeyCodec.encodeInternalKey` (template:
      `buildValidSstable` in `test/util/hostile_sstable.dart`), key bytes from
      hex-decoding `MetaStore.symbolicKey('dirty')`. **Verify it fails with the
      namespace change reverted** (dirty back in `$meta`) — a regression test
      that passes pre-fix guards nothing. The "upload-exclusion" fallback is
      **dropped**; do not use it.
- [ ] Strengthen `writebatch_atomicity_test.dart` (the "single put folds
      document + meta writes into one batch frame" test, ~line 137) to assert a
      record with `namespace == r'$$dirtystate'` is present in the first-write
      frame — otherwise the dirty-flag fold is no longer guarded after the move.
- [ ] Confirm the existing dirty tests still pass unchanged
      (`meta_store_test`, `writebatch_atomicity_test`, `meta_store_encryption_test`,
      `lsm_engine_test`).
- [ ] Spec/doc updates via `kmdb-architect`: registry row (drop `⚠`), §11 table,
      §17 step 8, §31 (×2), §12 status; verify §07/§26 need no change.
- [ ] Update `docs/roadmap/0_10_01.md`: mark WI-14 complete; update the `$meta`
      end-state table's `dirty` row.
- [ ] `kmdb-qa` sign-off, then `kmdb-pre-commit`; open PR; move plan to
      `docs/plans/completed/`.

## Summary

_(to be written on completion)_
