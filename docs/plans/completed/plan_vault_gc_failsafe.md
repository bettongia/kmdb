# Fix H3: Vault GC / recovery ref-count decoding is fail-dangerous (can delete referenced blobs)

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/22

**Implementation model:** Sonnet, with careful review of the fail-safe default —
the data-destruction risk is reverting to "delete on uncertainty."

**Sequencing**: Independent of C1/C2 (different subsystem — vault, not the LSM
durability path), so it can be implemented in parallel. **It should land before
`plan_document_versioning.md`**, which extends these exact files
(`vault_gc.dart`, `vault_ref_interceptor.dart`) and adds `$ver:` entries as new
vault-reference sources. H3 establishes the single, fail-safe ref-count helper
that the versioning work must reuse rather than re-introducing a hand-rolled
decoder. See "Interaction with document versioning" below.

## Problem statement

The vault deletes blobs based on reference counts. Two of the three code paths
that read a ref count use **hand-rolled partial CBOR parsers that return `0`
("unreferenced") on any byte pattern they do not anticipate**, and both then
**permanently delete the blob** on that result. A corrupt, truncated, or merely
unexpected encoding of a `$vault:{sha256}` entry therefore causes irreversible
loss of user binary content that documents still reference (review finding
**H3**).

This is a fail-*dangerous* default: when uncertain, the code destroys data. A
content store must do the opposite — when it cannot prove an object is
unreferenced, it must keep it. The fix is small and localised, but it is one of
only two outright data-destruction paths in KMDB (the other being C1), so it is
high priority.

## Investigation

### Three ref-count readers, two of them dangerous

Ref counts are stored as `ValueCodec.encode({'refCount': N})` under
`$vault:{sha256}` ([vault_ref_interceptor.dart:36-38](../packages/kmdb/lib/src/vault/vault_ref_interceptor.dart#L36)).
There are **three** independent readers of that format:

1. **`VaultRefInterceptor._readRefCount`**
   ([vault_ref_interceptor.dart:130](../packages/kmdb/lib/src/vault/vault_ref_interceptor.dart#L130)) —
   uses the real `ValueCodec.decode` and reads `decoded['refCount']`. **Correct.**
   This is the model the other two should follow.

2. **`VaultGc._decodeRefCount`**
   ([vault_gc.dart:138](../packages/kmdb/lib/src/vault/vault_gc.dart#L138)) —
   a hand-rolled CBOR map parser. Returns `0` on every unanticipated shape
   (wrong major type, key absent, value > uint16, truncation, …). `_readRefCount`
   ([vault_gc.dart:126](../packages/kmdb/lib/src/vault/vault_gc.dart#L126))
   forwards that `0`, and `sweep()`
   ([vault_gc.dart:88](../packages/kmdb/lib/src/vault/vault_gc.dart#L88))
   then calls `store.deleteHashDir(sha256)` — **permanent blob + manifest
   deletion.**

3. **`VaultRecovery._decodeRefCount` / `_extractRefCountFromCborMap`**
   ([vault_recovery.dart:168](../packages/kmdb/lib/src/vault/vault_recovery.dart#L168)) —
   a *second* hand-rolled copy with the same failure mode, **plus** `_hasKvRef`
   ([vault_recovery.dart:150](../packages/kmdb/lib/src/vault/vault_recovery.dart#L150))
   wraps it in `try { … } catch (_) { return false; }` — so a decode *exception*
   is also read as "no reference," and `_sweepHashDirs` deletes the hash
   directory. This path runs on **every unclean open** (it is step 9 of crash
   recovery), so a single malformed ref entry can wipe a referenced blob on
   restart.

So the same one-line decode is implemented three times, two of them wrong and
data-destructive. This is also a code-health smell (the review's "weak code"
category): a private CBOR re-implementation living next to the real codec.

### The reference-count protocol (why "absent" is safe but "undecodable" is not)

`VaultRefInterceptor._decrement`
([vault_ref_interceptor.dart:158](../packages/kmdb/lib/src/vault/vault_ref_interceptor.dart#L158))
**deletes** the `$vault:{sha256}` entry when the count reaches zero (and writes a
tombstone), specifically so that "absence of entry == zero references" is a
reliable signal. The corollary the current code misses:

- **Absent entry** → genuinely zero refs (by protocol) → eligible for deletion.
- **Present entry** → refs ≥ 1 (a zero would have been deleted). So a present
  entry that decodes to a positive count means *keep*, and a present entry that
  **cannot be decoded must be treated as referenced (keep)** — never as zero.

The hand-rolled parsers violate exactly this: they map "present but
unexpected" → `0` → delete. With `ValueCodec.decode`, a present, well-formed
entry decodes to its true count; a present, malformed entry throws, which the
fail-safe wrapper must treat as "referenced, do not delete."

### Data-loss scenarios this enables

- A `$vault` value written by a future/older codec version, or partially
  written, decodes as `0` → GC sweep deletes a blob with live document refs.
- During crash recovery, a single corrupt `$vault` entry → `_hasKvRef` returns
  `false` → the manifest+blob are deleted as "orphaned," breaking every document
  that references that hash.

### Related risk (flag, scope decision needed — see D3)

`VaultRecovery._shouldDelete`
([vault_recovery.dart:126](../packages/kmdb/lib/src/vault/vault_recovery.dart#L126))
deletes any object with `manifest present, no KV ref` as "orphaned." But a
freshly **synced stub** (peer uploaded the blob/manifest; the referencing
document hasn't synced to this device yet) also looks like "manifest, no ref."
Deleting it loses a blob the about-to-arrive document needs. This is a distinct
sync-ordering bug in the same fail-dangerous family; it is not strictly the H3
decode issue. D3 decides whether to fix it here or split it out.

### Interaction with document versioning (`plan_document_versioning.md`)

That plan (Status: Investigated) touches the same machinery:

- It extends `VaultRefInterceptor` so `$ver:` (version history) entries also
  inc/dec vault ref counts, and decrements at **compaction-time** version
  trimming — a *new* path that mutates ref counts.
- Its file table lists `lib/src/vault/vault_gc.dart — scan $ver: for refs`.

Two coordination points:

1. **Shared helper.** H3 should extract one fail-safe ref-count reader; the
   versioning work must reuse it for its compaction-trim decrements rather than
   adding a fourth decoder. Land H3 first so that helper exists.
2. **Model consistency.** The current design is **counter-based** (read the
   stored `$vault` count), not scan-based. The versioning plan's "scan `$ver:`
   for refs" wording should be reconciled to "adjust the counter when version
   entries are written/trimmed" (its own prose already says this). H3 does not
   change the counter model; it only makes reads of the counter safe. The
   versioning plan should add a cross-reference to H3 and depend on its helper.

No change to H3 is required *for* versioning, but versioning's correctness
depends on H3's fail-safe default once version trimming can drive a count to
zero at compaction.

### Files to change

| File | Change |
|------|--------|
| `lib/src/vault/vault_ref.dart` *(or a new `vault_ref_count.dart`)* | Add a single `VaultRefCount` helper: `read(kvStore, sha256) -> RefCountReadResult` using `ValueCodec.decode`, distinguishing `absent` / `value(n)` / `undecodable` |
| `lib/src/vault/vault_gc.dart` | Delete `_decodeRefCount`/`_skipValue`; use the helper; **only delete on `absent` or `value(0)`; skip + report on `undecodable`** |
| `lib/src/vault/vault_recovery.dart` | Delete `_decodeRefCount`/`_extractRefCountFromCborMap`/`_skipCborValue`; use the helper in `_hasKvRef`; **treat `undecodable` as referenced (do not delete)** |
| `lib/src/vault/vault_ref_interceptor.dart` | Optionally route `_readRefCount` through the same helper for consistency (behaviour already correct) |
| `docs/spec/24_vault.md` | State the fail-safe rule explicitly: deletion requires a positive determination of zero references; undecodable ⇒ retain |
| `test/vault/vault_gc_test.dart`, `test/vault/vault_recovery_test.dart` | Add malformed/edge ref-count tests (below) |

## Decisions (recommended answers — confirm before implementation)

- [x] **D1 — Shared helper shape.** **Accepted (recommended).** A small result
  type `sealed RefCountReadResult { Absent; Value(int n); Undecodable; }`
  returned by `VaultRefCount.read(...)`, so each caller decides policy
  explicitly. Avoids the ambiguous "0 means both zero and error" overload that
  caused the bug.
- [x] **D2 — Use `ValueCodec.decode` directly?** **Accepted (recommended): yes**
  — it is already the writer and is used by the interceptor. Wrap in try/catch to
  map failure to `Undecodable`. Removes the hand-rolled CBOR across two files.
- [x] **D3 — Scope of the stub-orphan risk.** **Accepted (recommended): note
  here, fix separately.** The decode fail-safe is a clean, self-contained change;
  the stub/sync-ordering ambiguity in `_shouldDelete` deserves its own analysis
  (e.g. gating orphan deletion on an age/grace window or a "seen during this
  session" marker). Folding it in widens the blast radius of this fix. Recorded
  as a follow-up finding (see Summary).
- [x] **D4 — Telemetry on retained-undecodable.** **Accepted (recommended).**
  Surface a count of skipped-undecodable objects in `VaultGcResult` /
  `VaultRecoveryResult` so a corrupt ref entry is visible rather than silently
  retained forever.

## Implementation plan

### Step 1 — Extract the fail-safe ref-count reader
- [x] Add `VaultRefCount.read(KvStore, String sha256) async -> RefCountReadResult`
      using `ValueCodec.decode`; `null` bytes ⇒ `Absent`, a valid map ⇒
      `Value(refCount)`, any decode error or missing/!int `refCount` ⇒
      `Undecodable`. *(New file `lib/src/vault/vault_ref_count.dart` with a
      `sealed RefCountReadResult` = `RefCountAbsent | RefCountValue | RefCountUndecodable`.
      Negative stored counts clamp to 0.)*
- [x] Unit-test the helper directly: well-formed counts (0–23, uint8, uint16
      ranges), absent, truncated bytes, wrong-major-type, missing key, non-int
      value. *(New `test/vault/vault_ref_count_test.dart`, 18 cases.)*

### Step 2 — Make `VaultGc` fail-safe
- [x] Replace `_readRefCount`/`_decodeRefCount`/`_skipValue` with the helper.
- [x] In `sweep()`: delete only on `Absent` or `Value(0)`; on `Value(n>0)` remove
      the tombstone (existing re-reference behaviour); on `Undecodable` **skip
      the object, leave the tombstone, increment a `retainedUndecodable` counter**.
- [x] Add `retainedUndecodable` to `VaultGcResult` (D4) (defaulted to 0 so
      existing const constructions stay valid).

### Step 3 — Make `VaultRecovery` fail-safe
- [x] Replace `_decodeRefCount`/`_extractRefCountFromCborMap`/`_skipCborValue`
      and the `catch (_) => false` in `_hasKvRef` with the helper.
- [x] Recovery decision (`_classify`, replacing `_shouldDelete`): treat
      `Undecodable` as **referenced** (do not delete); keep current behaviour for
      `Absent` (no ref) and `Value(n>0)` (referenced).
- [x] Add `retainedUndecodable` to `VaultRecoveryResult` (D4).
- [x] (D3) Add a `TODO(vault)` in `_classify` cross-referencing the stub-orphan
      follow-up.

### Step 4 — Consolidate the interceptor (optional)
- [x] Route `VaultRefInterceptor._readRefCount` through the helper so all four
      call sites share one implementation. Behaviour is unchanged for valid data
      (absent/value → same int); an undecodable entry maps to `0` here, with a
      doc comment noting the deletion authorities (GC/recovery) are the fail-safe
      readers.

### Step 5 — Tests
- [x] **GC keeps a blob with a corrupt ref entry** — tombstone present,
      `$vault` entry present but malformed; assert the hash dir is **not** deleted
      and `retainedUndecodable == 1`. (Two variants: CBOR-int-not-map, and
      garbage bytes.)
- [x] **GC deletes a genuinely zero-ref object** — covered for both `Absent`
      (existing test) and explicit `Value(0)` (new test).
- [x] **GC un-tombstones a re-referenced object** — `Value(n>0)` (existing TOCTOU
      guard test).
- [x] **Recovery keeps an object whose ref entry is corrupt** — manifest present,
      `$vault` entry present but malformed; assert the hash dir survives recovery
      and `retainedUndecodable == 1`. (Two variants.)
- [x] **Recovery deletes a true orphan** — manifest present, no `$vault` entry;
      assert deletion (happy-path regression guard).
- [x] **Helper round-trips** all integer encodings the interceptor can produce.

### Step 6 — Documentation
- [x] `docs/spec/24_vault.md`: documented the invariant — deletion requires a
      positive determination of zero references (absent counter or decoded
      `refCount == 0`); an undecodable counter is treated as referenced and
      retained. Added a "Fail-safe ref-count rule" subsection, a crash-table row
      for the undecodable case, and a historical note.
- [x] Updated doc comments on `VaultGc.sweep`, `VaultRecovery` (class +
      `_classify`), `VaultRefInterceptor`, and the new helper to state the
      fail-safe contract.
- [x] (D3) Recorded the stub-orphan risk as a follow-up in
      `docs/roadmap/0_02_01.md` (H3 entry) and an inline `TODO(vault)`.

### Step 7 — Verify
- [x] `dart test packages/kmdb` — all pass (1311 pass, ~9 E2E skipped),
      including the new `vault_ref_count_test.dart` and the fail-safe GC/recovery
      cases.
- [x] `cd packages/kmdb_cli && dart test` — all pass (839).
- [x] `make analyze` — clean across all packages.

> Worktree note: native-asset build hooks (`betto_zstd`) only fire when `dart
> test` is first run from *inside* a package directory (e.g.
> `cd packages/kmdb && dart test`), not from the workspace root in a fresh
> worktree. After that first run populates `.dart_tool/native_assets.yaml` +
> `hooks_runner/`, root-level `dart test packages/kmdb` and `make pre_commit`
> work normally. This matches the existing CLAUDE.md note about `kmdb_cli` build
> hooks.

## Summary

- **New single fail-safe reader.** Added `lib/src/vault/vault_ref_count.dart`
  with a `sealed RefCountReadResult` (`RefCountAbsent` / `RefCountValue(int)` /
  `RefCountUndecodable`) and `VaultRefCount.read(KvStore, sha256)`. It decodes
  via the real `ValueCodec.decode` (the same codec that writes the entries), maps
  any decode failure or missing/non-int `refCount` to `Undecodable`, and clamps a
  negative stored count to `0`. This replaces the two hand-rolled partial CBOR
  parsers that returned `0` ("unreferenced") on any surprise.
- **GC is now fail-safe.** `VaultGc.sweep` deletes only on a positive
  determination of zero references (`Absent` or `Value(0)`), un-tombstones on
  `Value(n>0)`, and on `Undecodable` retains the object (tombstone left in place)
  and counts it in the new `VaultGcResult.retainedUndecodable`.
- **Recovery is now fail-safe.** `VaultRecovery` reads through the helper; the
  decision logic (`_classify`, replacing `_shouldDelete`) treats an undecodable
  ref entry as *referenced* (retain) instead of the previous
  `catch (_) => false` "no reference" → delete. Undecodable retentions are
  reported via the new `VaultRecoveryResult.retainedUndecodable`. This path runs
  on every unclean open, so the old behaviour could wipe a referenced blob on
  restart.
- **Interceptor consolidated.** `VaultRefInterceptor._readRefCount` now routes
  through the shared helper, removing the last divergent reader and giving the
  document-versioning work (`$ver:` ref counting) a single seam to reuse.
- **~150 lines of duplicated hand-rolled CBOR removed** across `vault_gc.dart`
  and `vault_recovery.dart`.
- **Tests.** New `test/vault/vault_ref_count_test.dart` (18 cases: round-trips
  for inline/uint8/uint16 counts, absent, empty, truncated, wrong-major-type,
  unknown flag, missing key, non-int, negative-clamp). New fail-safe cases in
  `vault_gc_test.dart` and `vault_recovery_test.dart` proving a corrupt ref entry
  is **retained, not deleted**, plus happy-path regression guards and
  `retainedUndecodable` result-field tests.
- **Docs.** `docs/spec/24_vault.md` gains a "Fail-safe ref-count rule" section, a
  crash-table row for the undecodable case, and a historical note; doc comments
  on the affected classes state the contract.
- **D3 follow-up (deferred, as recommended).** The stub-orphan / sync-ordering
  risk in recovery — a freshly synced stub (manifest present, no ref yet) looks
  like an orphan and is deleted before its referencing document arrives — is left
  as a separately-scoped follow-up. Recorded in the H3 entry of
  `docs/roadmap/0_02_01.md` and as an inline `TODO(vault)` in
  `VaultRecovery._classify`.
- **Verification note.** Done in a git worktree. The workspace's native
  dependencies (`betto_zstd`, ICU, ONNX) are path-resolved relative to the repo
  root, so the worktree was relocated to a sibling of `kmdb/` so those paths
  resolve to the real packages. The native-asset build hook only fires when
  `dart test` is first run from *inside* a package directory (`cd packages/kmdb
  && dart test`); once that populates `.dart_tool/native_assets.yaml` +
  `hooks_runner/`, the full `packages/kmdb` (1311) and `packages/kmdb_cli` (839)
  suites and `make analyze` all pass from the worktree.
