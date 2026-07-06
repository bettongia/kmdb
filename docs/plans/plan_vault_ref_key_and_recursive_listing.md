# Fix `$vault` Ref-Count Key Scheme and `VaultStore.listFilesRecursive` Stopgap

**Status**: Investigated

**PR link**: —

## Reviewer feedback (kmdb-plan-reviewer, 2026-07-03)

**Verdict: strong diagnosis, not yet `Investigated`.** I independently verified
every core technical claim against current `main` and they all hold up. The
single most important validation: **nothing scans the flat `$vault` namespace.**
Both deletion authorities enumerate blobs via `store.listAllHashes()` and then do
**point reads** `VaultRefCount.read(kvStore, sha256)` — `VaultGc.sweep`
(`vault_gc.dart:174`) and `VaultRecovery._sweepHashDirs` (`vault_recovery.dart:138`
→ `_classify` → `:180`). The ref count is **never** accessed by scanning the
namespace, so Q1(a)'s namespace-per-blob is safe: no scan, no `listNamespaces`,
no prefix iteration cares about the ref-count namespace. That is the crux that
makes (a) correct, and it checks out. Also confirmed: the four bug-1 sites
(`vault_ref_count.dart:118`; `vault_ref_interceptor.dart:320,345,349`) **are** the
complete read/write/delete surface for the ref-count entry — there is no fifth.
`VaultStore.createStub` (`:483`), `VaultGc` (`:174`), and `VaultRecovery` (`:180`)
all route through the shared `VaultRefCount.read`, so fixing that one reader
covers them. Q1(a) is the right call; ratified.

The plan is **not implementation-ready** as written, for the reasons below.
Blockers B1–B3 are hard gaps; the open questions still need closing.

### B1 (blocker) — Adding a method to `StorageAdapter` breaks 5 unlisted implementers

`StorageAdapter` is a bare `abstract interface class`. Adding
`listFilesRecursive` to it is a **breaking change that fails compilation** for
every class that `implements StorageAdapter`. The plan's bug-2 checklist lists
only the 3 library adapters. The following **test-side** implementers also need
the method or the suite won't compile — and one of them is the plan's own test
vehicle:

- `test/support/faulty_storage_adapter.dart` — `FaultyStorageAdapter` (`:43`).
  **This does NOT wrap an inner adapter** — it owns flat `_live`/`_durable`
  maps. It needs a *real* prefix-scan implementation (like the memory adapter),
  not a forwarding stub. This is the exact harness the plan wants to test bug 2
  against (checklist "Bug 2 → Tests"), so it is load-bearing, not incidental.
- `test/engine/table_cache_integration_test.dart` — `_CountingAdapter` (wraps
  `StorageAdapter _inner`; add a forwarding override).
- `test/engine/table_cache_test.dart` — `_CountingAdapter` (forwarding).
- `test/engine/sstable_meta_tracking_test.dart` — `_CountingReadAdapter` (wraps
  `MemoryStorageAdapter _inner`; forwarding).
- `test/vault/search/vault_search_manager_test.dart` — `_ThrowingWriteAdapter`
  (wraps `MemoryStorageAdapter _delegate`; forwarding).

(The harness `PartitionableAdapter` wraps `SyncStorageAdapter`, a *different*
interface — unaffected. No lib/other-package implementers beyond the 3 adapters.)
The plan must enumerate these six edit sites explicitly; a Sonnet implementer
following the current checklist would hit ~5 compile errors and have to improvise
`FaultyStorageAdapter`'s semantics on the fly.

### B2 (blocker) — The sahpool/web path is under-specified *and* the "does web need it?" question is unresolved

Q3 flags "confirm whether web needs this at all" but leaves it open, and the
recommended web implementation ("a recursive directory walk analogous to the
native case") materially understates the work. The sahpool adapter is a
message-passing bridge to a Worker: `listFiles` sends `{'op':'list'}`
(`storage_adapter_sahpool.dart:340`) handled at `sahpool_worker_source.dart:343`
(`case 'list':`). A recursive variant requires **a new worker op** in
`sahpool_worker_source.dart`, a real recursive OPFS `FileSystemDirectoryHandle`
traversal, keeping the generated `sahpool_worker.js` in sync, and the dart-side
`_send`. None of that can run in the automated suite (needs Chrome → a release-
checklist item). Before this is `Investigated` you must **decide**, not defer:
does `VaultStore` ever run on the sahpool adapter? Vault has a native adapter
with a web *stub* (`local_directory_vault_adapter_stub.dart`) and vault search is
native-only. If vault never wires to sahpool, the correct, honest move is for
sahpool's `listFilesRecursive` to `throw UnsupportedError` (loud, not a silent
`[]` that would re-create exactly the bug-2 failure mode) — which is *less* work
and *safer* than a full OPFS walk for a code path that never executes. If it can
run on web, then the full worker-op implementation plus an RC entry is required.
This is a genuine design decision the implementer must not be left to make.

### B3 (blocker) — The sentinel key must itself be UUIDv7-valid; state it and pin it

The entire bug is that non-UUIDv7 keys throw in `KeyCodec.keyToBytes`
(version-7 nibble at index 12, variant at index 16). Under Q1(a) the sentinel
*key* still passes through `KeyCodec` on every read/write. `kVaultCorpusSentinelKey`
(`01900000000070009000000000000000`) satisfies the structure (index 12 = `7`,
index 16 = `9`), which is why reuse works. But the plan leaves "reuse
`kVaultCorpusSentinelKey` or define a dedicated equivalent" as an open
"low-stakes naming choice" — it is **not** low-stakes: a freshly-invented
sentinel that isn't UUIDv7-structured would silently reintroduce the very bug
being fixed. Decide now, and if a new constant is defined, add a test asserting
`KeyCodec.keyToBytes(sentinel)` does not throw. **My call:** define a dedicated
`kVaultRefCountSentinelKey` next to `kVaultNamespace` in `vault_recovery.dart`
(don't borrow the *search*-layer corpus sentinel — that couples ref counting to
FTS semantics for no reason), and give it a value you have verified is UUIDv7-
shaped. Reusing the identical literal value is fine; sharing the *search*
constant is not.

### Concerns (not blockers, but resolve before handing off)

- **Dead/misleading code cleanup is unscoped.** `vault_store.dart`'s
  `_listSubdirs` / `_listSubdirsFromFiles` / `_collectSubdirsInto` chain
  (`:588`–`:683`) is saturated with stale comments explaining why recursive
  listing "can't" work and why the stopgap returns `[]` — every one of which
  becomes *actively false* once the fix lands. CLAUDE.md forbids leaving dead or
  misleading code. Scope the comment/cruft cleanup explicitly. Separately, note
  (optional) that `listAllHashes` does N+1 recursive walks (`listPrefixDirs`
  then a per-prefix `listSuffixDirs`); a single `listFilesRecursive(blobsDir)`
  scan that derives `{prefix}{suffix}` from each `.../manifest.json` path would
  be simpler and cheaper. Fine to defer, but call the decision out.
- **Memory-adapter real-default coverage.** ~12 test files override
  `listFilesRecursive`, so the *new real default* could go entirely unexercised.
  Ensure at least one test drives the un-overridden real default on both
  `MemoryStorageAdapter` and `FaultyStorageAdapter`. (B1's FaultyStorageAdapter
  impl gives you this for free if you assert on it.)
- **Spec framing overstated.** The plan says the implementation "deviates from
  its own spec." §24:192 actually reads *"The `$vault` system namespace maintains
  a reference count for each vault URI"* (singular namespace) — i.e. the spec is
  ambiguous and arguably describes the flat model. So `24_vault.md:199` is a real
  clarifying **change**, not merely "tightening notation." Already listed as a
  spec edit, which is correct; just don't frame (a) as pre-blessed by the spec.
- **Native `listFilesRecursive` contract detail.** `Directory.list(recursive:
  true)` yields entities whose paths are prefixed by `dirPath`; the callers
  (`_collectSubdirsInto`) require paths **relative** to `dirPath`. State
  explicitly that native must relativise, filter to `File`, and return `[]` when
  the directory doesn't exist (matching `listFiles`' documented not-exist
  behaviour). Otherwise mechanical.

### Open-question dispositions (reviewer)

- **Q1 — ratified: (a) namespace-per-blob.** Verified safe (no `$vault` scan
  exists; all access is point-read). Zero collision risk (`$vault:docref:...`
  can never equal `$vault:{64-hex}`). Close per B3 on the sentinel.
- **Q2 — recommend: documented no-op, no defensive cleanup.** The public write
  path has never succeeded, the repo is pre-1.0 and days-old-public, and the
  only entries that could exist came from the deliberate test-bypass
  (`db.store.put()`). A one-time `open()`-scan to delete legacy flat
  `$vault:{64-char}` entries would itself need to *read* those keys through
  `KeyCodec` — which throws — so a "cleanup" is awkward to even express and
  guards against a population that effectively cannot exist. Document the
  decision and the reasoning in the plan; don't build migration machinery.
  (Your call to make final — flagging the reasoning so it's on the record.)
- **Q3 — resolve per B2.** The signature (`Future<List<String>>
  listFilesRecursive(String dirPath)`, files-only, paths relative to `dirPath`,
  `[]` when absent, symlinks not followed) is fine. The unresolved part is the
  web decision — decide it.
- **Q4 — ratified: leave the doubles alone** (no tidy-up churn in a durability
  PR), **except** you must still touch all of them to satisfy the new interface
  method (B1) — "leave alone" means "don't consolidate," not "don't compile."
- **Q5 — ratified: bug 2 lands no later than bug 1.** Sound; the compounding
  orphan-manifest analysis (`vault_store.dart` ingest ordering vs. KV commit) is
  correct.

**To reach `Investigated`:** fold B1's six edit sites and B2's web decision into
the Implementation plan, pin the sentinel per B3, scope the dead-code cleanup,
and record the Q2 decision. Then it's ready.

### Dispositions (main session, 2026-07-03)

- **B1 — adopted.** All six edit sites (3 library adapters + `FaultyStorageAdapter`,
  `_CountingAdapter` ×2, `_CountingReadAdapter`, `_ThrowingWriteAdapter`) are now
  enumerated explicitly in the Implementation plan below.
- **B2 — resolved: `UnsupportedError`, not a full OPFS implementation.**
  Verified directly: `VaultStore` takes a generic `StorageAdapter` (not a
  vault-specific type), so nothing in the type system forbids an app from
  constructing one with the sahpool adapter — but there is no first-party
  web vault story today. `LocalDirectoryVaultAdapter` (the vault *sync*
  adapter, a different interface) already throws `UnsupportedError` outright
  on web (`local_directory_vault_adapter_stub.dart`), establishing the
  codebase's own precedent for "not yet supported on web → fail loudly, don't
  stub silently." Building a real recursive OPFS `FileSystemDirectoryHandle`
  walk plus a new worker op is real, untestable-in-CI scope creep for a plan
  about two pre-existing bugs, and reintroducing a silent `[]` would just
  recreate the exact failure mode this plan exists to fix. Sahpool's
  `listFilesRecursive` therefore throws `UnsupportedError` with a clear
  message; a follow-up plan can implement the real OPFS walk if/when local
  vault-on-web storage becomes an actual product requirement.
- **B3 — adopted verbatim.** Define `kVaultRefCountSentinelKey` in
  `vault_recovery.dart` next to `kVaultNamespace` (not reusing the
  search-layer `kVaultCorpusSentinelKey` — ref counting shouldn't couple to
  FTS semantics). Value must be verified UUIDv7-shaped (version nibble `'7'`
  at index 12, variant nibble in `{8,9,a,b}` at index 16); a test must assert
  `KeyCodec.keyToBytes(kVaultRefCountSentinelKey)` does not throw.
- **Dead-code cleanup — scoped.** `vault_store.dart:588-683`'s
  `_listSubdirs`/`_listSubdirsFromFiles`/`_collectSubdirsInto` chain has
  multiple comments explaining why recursive listing "can't" work today —
  all become false once the fix lands. These must be rewritten (not just
  left) to describe the new real behavior.
- **Memory/Faulty-adapter default coverage — added as an explicit test
  requirement** (see Implementation plan): at least one test must exercise
  the real (non-overridden) default on both `MemoryStorageAdapter` and
  `FaultyStorageAdapter`, not just adapters that override the method.
- **Spec framing — corrected.** §24:192 reads "The `$vault` system namespace
  maintains a reference count for each vault URI" (singular, ambiguous) — the
  spec doesn't clearly bless the namespace-per-blob model already; Q1(a)'s
  spec edit is a genuine clarifying *change*, not a restatement of existing
  intent. Framing corrected in the Investigation section below.
- **Native contract detail — added.** `Directory.list(recursive: true)`
  yields paths prefixed by `dirPath`; the implementation must relativise
  them (strip the `dirPath` prefix), filter to `File` entries only, and
  return `[]` when `dirPath` doesn't exist (matching `listFiles`'s existing
  not-found behavior) — added explicitly to the Implementation plan.
- **Q2 — adopted: documented no-op, no migration machinery.** The public
  write path has never succeeded; the only entries that could exist came
  from the deliberate `db.store.put()` test-bypass documented in
  `vault_integration_test.dart:358-359`; the repo is pre-1.0 and only
  recently public. A defensive "delete legacy flat `$vault:{64-char}`
  entries on open()" cleanup would itself need to read those keys through
  `KeyCodec` — which throws — making a migration awkward to even express
  for a population that cannot exist in practice. Documenting this reasoning
  in the plan (done here) is the decision; no migration code is planned.

### Re-review verdict (kmdb-plan-reviewer, 2026-07-03) — Investigated

All three blockers and every concern are closed **to my satisfaction, verified
against current `main`** (not merely asserted):

- **B1 — closed.** `grep` for `implements StorageAdapter` returns exactly the
  eight files the plan now enumerates (3 lib: native/memory/sahpool; 5 test:
  `FaultyStorageAdapter`, both `_CountingAdapter`s, `_CountingReadAdapter`,
  `_ThrowingWriteAdapter`). No unlisted implementer exists. Confirmed
  `FaultyStorageAdapter` owns flat `_live`/`_durable` maps and wraps no inner
  adapter, so the plan is correct that it needs a *real* prefix-scan impl, not a
  forward. `MemoryStorageAdapter.files` is a public `Map<String, Uint8List>`, so
  the memory prefix-scan is trivially implementable. An implementer following
  the checklist will not hit an unlisted compile error.
- **B2 — closed.** Confirmed sahpool is a `_send({'op': ...})` worker bridge with
  no recursive op, and that `LocalDirectoryVaultAdapter`'s web stub already
  throws `UnsupportedError` — so the `UnsupportedError` decision follows the
  codebase's own precedent and is the honest, safer call. No design decision is
  left to the implementer.
- **B3 — closed.** `KeyCodec.keyToBytes` confirmed to require index 12 == `'7'`
  and index 16 ∈ {8,9,a,b} (`key_codec.dart:90,98-102`). The reference literal
  `01900000000070009000000000000000` validates (idx12=`7`, idx16=`9`), so a
  dedicated `kVaultRefCountSentinelKey` reusing that value is safe; the required
  `KeyCodec.keyToBytes` assertion pins it.
- **Concerns — closed.** Verified the `_listSubdirs`/`_listSubdirsFromFiles`/
  `_collectSubdirsInto` chain (`vault_store.dart:588-683`) is indeed saturated
  with now-false comments (cleanup correctly scoped). Default-coverage test
  requirement, corrected spec framing, and Q2 no-op decision all present.
- **Bonus verification.** Both `listNamespaces` consumers in
  `kmdb_database.dart` (:654, :898) filter `!ns.startsWith(r'$')`, so the new
  `$vault:{sha256}` per-blob namespaces stay excluded from user-collection
  enumeration and sync-namespace resolution — no regression, and this mirrors
  the existing per-blob `$vault:docref:{sha256}` namespace pattern (no new
  scaling characteristic introduced).
- **One sharpening I added** (native/memory relativisation must strip the
  trailing separator, no leading slash) — the precise vector by which a naive
  impl would silently re-break bug 2 via `_collectSubdirsInto`'s `slash > 0`
  guard. Folded into the Bug 2 checklist with a matching test assertion.

The plan clears the implementation-readiness bar: named files/methods, exact
edit sites, decided web behavior, pinned sentinel, scoped cleanup, and a
testing strategy covering fault injection and the real (non-overridden)
defaults. Promoting to **Investigated**. Ready for `kmdb-plan-implement`.

## Problem statement

Two pre-existing, unrelated bugs in `package:kmdb`'s vault subsystem were
discovered incidentally while implementing WI-8
(`docs/plans/completed/plan_0_06_wi8_pdf_extractor.md`), and independently
confirmed against current `main` by both `kmdb-qa` and `kmdb-architect`:

1. **`$vault` ref-count key-length mismatch.** `VaultRefInterceptor` and
   `VaultRefCount` store a blob's reference count under its full 64-character
   SHA-256 hex digest as the KV **key** in a flat `$vault` namespace — but
   `KeyCodec.keyToBytes` requires exactly 32 hex characters with UUIDv7
   structure. Every write to `$vault` therefore throws a `FormatException`.
   Concretely: **no document containing a `kmdb-vault://<sha256>` URI field
   can currently be written through the public `KmdbCollection.insert`/`put`
   API** whenever a `VaultStore` + `VaultGc` are configured — i.e. the normal
   vault-enabled setup. The write-interception logic itself is otherwise
   correct; only the ref-count entry's key shape is wrong.
2. **`VaultStore.listFilesRecursive` v1 stopgap.** The default implementation
   unconditionally returns `[]`. Its own doc comment calls this out as a
   stopgap and even names the fix ("expose `listFilesDeep` to the
   interface"). Every consumer of blob enumeration —
   `VaultGc.sweep`, `VaultRecovery`, `VaultSearcher`, and
   `VaultSearchManager` (`vaultIndexingStatus`/reindex) — silently sees zero
   blobs for any real native `VaultStore` that doesn't subclass/override it.
   No exception, no log — just silent no-ops. This is exactly the class of
   problem CLAUDE.md already flags: "in-memory test adapters hide an entire
   class of data-loss bugs" — roughly 30 test doubles across the suite
   override this method, which is why the whole test suite is green despite
   the broken default.

**These two bugs compound.** Today, bug 1 means the public write path never
succeeds, so real native databases rarely accumulate vault-referencing
documents — which incidentally masks bug 2. Fix bug 1 alone, and real
databases start accumulating blobs that bug 2 then makes invisible to GC
(unbounded disk leak) and crash recovery (orphan manifests never reaped, a
§17/§24 crash-safety gap). **Fix both together, with bug 2 landing no later
than bug 1**, so newly-exercised blob population is immediately GC/recovery-safe.

This plan is scoped as a standalone core `kmdb`/vault correctness-and-durability
fix, independent of any 0.06 roadmap work item (it predates and is orthogonal
to WI-0/WI-3/WI-8's scope).

## Open questions

- [x] **Q1 — Bug 1 fix approach. Resolved: (a), ratified by `kmdb-plan-reviewer`**
      (verified no code path scans the flat `$vault` namespace — all access is
      point-read by sha256 — so moving the hash into the namespace is safe).
  - **(a) Namespace-per-blob (recommended).** Change `$vault` ref-count
    storage from `(namespace='$vault', key=sha256)` to
    `(namespace='$vault:{sha256}', key=<fixed sentinel>)`. This mirrors
    **three existing sibling patterns** in `vault_namespaces.dart` that
    already solve the identical "sha256 doesn't fit in a 32-char key"
    problem: `kVaultDocRefPrefix` (`$vault:docref:{sha256}`, key=docId),
    `kVaultFtsCorpusPrefix` (`$$vault:fts:corpus:{sha256}`,
    key=`kVaultCorpusSentinelKey`), and `kVaultExtractPrefix`
    (`$$vault:extract:{sha256}`, key=`kVaultCorpusSentinelKey`). It also
    matches §24_vault.md's own documented notation for this entry —
    `` `$vault:{sha256}` → integer reference count `` (§24:199-202) — which
    already reads as a namespace-per-blob shape; the *implementation*
    deviates from its own spec's notation, not the other way around. The
    fix touches exactly four lines: `vault_ref_count.dart:118` (the single
    shared reader — also used by `VaultGc`, `VaultRecovery`, and
    `VaultStore.createStub`, so fixing it here covers all of them) and
    `vault_ref_interceptor.dart:320,345,349` (`_increment`/`_decrement`
    write/delete). `kVaultNamespace`'s exported *value* (`r'$vault'`,
    `kmdb.dart:131`) is unchanged — only its use as a namespace-prefix
    building block changes, so no consumer holding the constant breaks.
    **Resolved (per B3): define a dedicated `kVaultRefCountSentinelKey`**
    in `vault_recovery.dart`, not a reuse of the search-layer
    `kVaultCorpusSentinelKey` — ref counting shouldn't couple to FTS
    semantics. The sentinel's value must itself pass `KeyCodec.keyToBytes`
    (UUIDv7-shaped: version nibble `'7'` at index 12, variant nibble in
    `{8,9,a,b}` at index 16) — this is not a cosmetic naming choice, since a
    non-conforming sentinel would silently reintroduce the exact bug being
    fixed. A test must assert `KeyCodec.keyToBytes(kVaultRefCountSentinelKey)`
    does not throw.
  - **(b) Derived UUIDv7-shaped key.** Keep the flat `$vault` namespace;
    deterministically reshape the sha256 into a 32-char UUIDv7-structured key
    (mirroring `kVaultChunkKey`'s pattern: fixed version/variant nibbles at
    positions 12/16, real entropy elsewhere). Workable, but introduces a
    bespoke derivation scheme with a (vanishingly small but nonzero)
    collision surface, where (a) has none — the namespace approach preserves
    the full 256 bits of the hash losslessly (namespace strings have no
    length/format constraint beyond ≤255 UTF-8 bytes, `key_codec.dart:138`).
    Also diverges from three existing sibling patterns rather than
    following them.
  - **Rejected: relax `KeyCodec` to accept arbitrary-length hex keys.** The
    32-char UUIDv7 structure is load-bearing — the embedded 48-bit timestamp
    drives SSTable write-locality (`key_codec.dart:49-55`). Relaxing it
    weakens sort/locality guarantees for *all* keys, not just vault's.
- [x] **Q2 — Migration/compatibility. Resolved: documented no-op, no
      migration machinery.** `$vault` uses a single `$` prefix (syncs
      normally, `vault_ref_interceptor.dart:49-51`, §24:135), so changing the
      key/namespace scheme does change what's on disk and on the wire — but
      because the public write path has never succeeded, no valid `$vault`
      entries should exist from real usage of the public API; the only
      entries that could exist came from the documented test-bypass
      (`vault_integration_test.dart:358-359`, `db.store.put()` directly). A
      defensive "delete legacy flat `$vault:{64-char}` entries on `open()`"
      cleanup would itself need to read those keys through `KeyCodec` —
      which throws — making a migration awkward to even express for a
      population that cannot exist in practice. No migration code is
      planned; this reasoning is the documented decision.
- [x] **Q3 — Bug 2 fix approach and exact signature. Resolved.** Add
      `Future<List<String>> listFilesRecursive(String dirPath)` to the
      `StorageAdapter` interface: paths relative to `dirPath`, files only
      (no directory entries), symlinks not followed, returns `[]` when
      `dirPath` doesn't exist (matching `listFiles`'s existing not-found
      behavior). Per backend:
      - **Native** (`storage_adapter_native.dart`): `Directory(dirPath)
        .list(recursive: true)` filtered to `File` entries, with each
        resulting path relativised by stripping the `dirPath` prefix (the
        raw `Directory.list` output is prefixed by `dirPath`, which the
        existing `_collectSubdirsInto` caller does not expect).
      - **Memory** (`storage_adapter_memory.dart`): scan the flat key map by
        prefix (all paths are already flat keys internally).
      - **Sahpool/OPFS (web)** (`storage_adapter_sahpool.dart`): **throws
        `UnsupportedError`**, not a real OPFS recursive walk. Verified
        directly that `VaultStore` takes a generic `StorageAdapter` (nothing
        in the type system forbids constructing one against the sahpool
        adapter), but there is no first-party web vault story today —
        `LocalDirectoryVaultAdapter` (the vault *sync* adapter, a different
        interface) already throws `UnsupportedError` outright on web
        (`local_directory_vault_adapter_stub.dart`), establishing this
        codebase's own precedent: not-yet-supported-on-web fails loudly
        rather than silently stubbing `[]` (which would just recreate the
        exact bug this plan fixes). A real OPFS `FileSystemDirectoryHandle`
        recursive walk + new worker op is untestable in the automated suite
        and out of scope here; a follow-up plan can add it if/when local
        vault-on-web storage becomes an actual product requirement.
- [x] **Q4 — Test-double cleanup scope. Resolved: leave existing overrides
      alone, but every `StorageAdapter` implementer must still gain the new
      method to compile.** "Leave alone" means don't consolidate/simplify
      existing fakes now that a real default exists — it does not mean
      "don't touch." `kmdb-plan-reviewer` identified that adding
      `listFilesRecursive` to the `StorageAdapter` interface is a breaking
      change for every class that `implements` it, including test-side
      wrapper doubles beyond the 3 library adapters (see the Implementation
      plan's explicit Bug 2 edit-site list).
- [x] **Q5 — Implementation order. Resolved and ratified: Bug 2 lands no
      later than Bug 1** (in the same PR, Bug 2's changes ordered first in
      the checklist below), so there is never a window where Bug 1 unblocks
      real vault-referencing writes while Bug 2 is still silently blind to
      the blobs they create.

## Investigation

### Bug 1 — mechanism, confirmed against current source

`KeyCodec.keyToBytes` (`packages/kmdb/lib/src/engine/util/key_codec.dart:79-113`):
requires **exactly 32 hex characters** (throws `FormatException` otherwise),
plus UUIDv7 structural validation (version nibble `'7'` at index 12; variant
nibble `8/9/a/b` at index 16). This runs on every key on every write/read path
through `LsmEngine` (`lsm_engine.dart:290,311,363,433,496,499,589`) — there is
no way for a caller to route a key around it.

`VaultRefCount` (`packages/kmdb/lib/src/vault/vault_ref_count.dart`) is the
single, shared reader used by all four production call sites:

- `vault_ref_count.dart:118` — `kvStore.get(kVaultNamespace, sha256)` (the
  read implementation itself).
- `vault_ref_interceptor.dart:320` — `_increment`'s `batch.put(kVaultNamespace,
  sha256, ...)`.
- `vault_ref_interceptor.dart:345,349` — `_decrement`'s `batch.delete(...)`
  (count reaches zero) / `batch.put(...)` (count still positive).
- `VaultStore.createStub` (`vault_store.dart:477-511`) calls
  `VaultRefCount.read` for its "stub requires a positive reference" guard —
  already centralized through the same reader, so fixing `VaultRefCount.read`
  covers this call site automatically. Likewise `VaultGc` and `VaultRecovery`
  read through `VaultRefCount.read`, not a separate decoder.

`kVaultNamespace = r'$vault'` is defined in `vault_recovery.dart:261` and
publicly exported via `kmdb.dart:131`.

**Blast radius:** any document write (`insert`/`put`/update) containing a
`kmdb-vault://` URI field, whenever `VaultRefInterceptor` is wired — which
happens whenever both `vaultStore` and `vaultGc` are supplied to
`KmdbDatabase.open` (`kmdb_database.dart:160,547`), i.e. the normal
vault-enabled configuration. Documents with no vault URIs are unaffected
(`VaultRefInterceptor`'s added/removed URI sets are empty, so `_increment`/
`_decrement` are never called). The `$vault:docref:{sha256}` index
(`vault_ref_interceptor.dart:161-164`) is **not** affected — it already keys
by `docKey` (a real 32-char UUIDv7), with the sha256 living only in the
namespace string, which has no length constraint. So the bug is narrowly the
ref-count entry's key shape, not the whole `$vault` family.

**Why the whole test suite is green despite this:** every in-memory KV-store
test double (`test_kv_store.dart`, `vault_ref_count_test.dart`,
`vault_write_interception_test.dart`, `vault_docref_test.dart`,
`vault_gc_search_integration_test.dart` — all grepped for `kVaultNamespace`
usage) implements a flat `Map<namespace, Map<key, bytes>>` that never runs the
real `KeyCodec` validation. Tests exercise the interceptor's *logic* without
ever hitting the key-format gate that only the real `KvStore`/`LsmEngine`
enforces — precisely the class of gap CLAUDE.md calls out regarding
in-memory test adapters.

**Existing precedent for the recommended fix.** `vault_namespaces.dart`
already solves "a sha256 doesn't fit in a 32-char key" three times over by
moving the hash into the **namespace** instead of the key:

```dart
const String kVaultDocRefPrefix = r'$vault:docref:';        // key: docId (32-char UUIDv7)
const String kVaultFtsCorpusPrefix = r'$$vault:fts:corpus:'; // key: kVaultCorpusSentinelKey
const String kVaultExtractPrefix = r'$$vault:extract:';      // key: kVaultCorpusSentinelKey
const String kVaultCorpusSentinelKey = '01900000000070009000000000000000';
```

**Spec framing correction (per reviewer):** §24_vault.md:192 actually reads
"The `$vault` system namespace maintains a reference count for each vault
URI" (singular namespace) — the current spec text is ambiguous and arguably
describes the flat model, not a namespace-per-blob one. Q1(a)'s spec edit is
therefore a genuine clarifying **change** to the spec, matching it to the
implementation's new, corrected behavior — not merely restating an intent the
spec already had. The edit should still land (see Spec sections below), just
without over-claiming that the old implementation contradicted a settled spec.

### Bug 2 — mechanism, confirmed against current source

`VaultStore.listFilesRecursive` (`vault_store.dart:677-708`) — the doc comment
walks through exactly why it's a stopgap and names its own fix:

> "The cleanest solution: expose `listFilesDeep` to the interface. As a
> stopgap for v1, fall back to an empty list (recovery/GC will need a
> subclass or native adapter that can enumerate)."

Every consumer goes through `VaultStore.listAllHashes`, which depends on it:

- `VaultGc.sweep` (`vault_gc.dart:163`) — tombstoned blobs are never deleted:
  **unbounded vault disk leak**.
- `VaultRecovery` (`vault_recovery.dart:138`) — orphan manifests/stubs are
  never reaped: a **§17/§24 crash-recovery gap**.
- `VaultSearcher` (`vault_searcher.dart:257`) and `VaultSearchManager`
  (`vault_search_manager.dart:287,366,440`) — vault search and
  `vaultIndexingStatus()` silently report zero blobs.

All four are **silent no-ops** — no exception, no log — which is what makes
this dangerous rather than merely broken.

**Root cause:** `StorageAdapter` (`storage_adapter_interface.dart:22-92`) has
only a single-level `listFiles(dirPath, {extension})` primitive; the native
implementation (`storage_adapter_native.dart:153`) uses non-recursive
`Directory.list()`. No recursive-listing primitive exists anywhere in
production code — only in ~30 test doubles — so `VaultStore`'s default had
nothing real to delegate to.

**Fix:** add a recursive-listing primitive to `StorageAdapter` per Q3, and
have `VaultStore.listFilesRecursive` delegate to it. Per CLAUDE.md's explicit
emphasis on fault injection over in-memory-only testing, `VaultGc.sweep` and
`VaultRecovery` — the two crash-safety consumers — must be tested against the
`FaultyStorageAdapter` harness, not just `MemoryStorageAdapter`.

### Interaction between the two bugs

Independent defects, but coupled in urgency: fixing Bug 1 alone turns Bug 2
from a currently-inert gap (few real databases accumulate vault-referencing
documents today, since the public path always threw) into an active one
(every newly-writable vault-referencing document's blob becomes invisible to
GC and recovery). There is also a compounding failure mode: if Bug 1's fix
still allowed a throw *after* `VaultStore.ingest` already wrote
staging→blob→manifest (`vault_store.dart:200-301`) but before the KV batch
committed, the result is an orphan manifest with no ref — exactly the state
`VaultRecovery` exists to reap, which Bug 2 currently prevents it from seeing.
Land Bug 2's fix no later than Bug 1's (Q5).

### Spec sections to update

- `docs/spec/24_vault.md:199-202` — the `$vault:{sha256}` ref-count notation;
  tighten to state precisely that `{sha256}` is part of the namespace, not
  the key (matching Q1(a)), and cross-reference the `kVaultCorpusSentinelKey`
  pattern it now shares with `docref`/`extract`.
- `docs/spec/04_keys.md` — if Q1(a) is adopted, no change needed (key format
  is untouched); if Q1(b) is adopted instead, document the derivation.
- `docs/spec/17_crash_recovery.md` / `docs/spec/24_vault.md` — note the fixed
  `listFilesRecursive` behavior as part of the recovery/GC enumeration story.
- `docs/spec/99_glossary.md` and `docs/spec/32_vault_search.md` — light
  cross-reference touch-ups if the `$vault` notation changes.
- Run `make site` after spec edits.

## Implementation plan

- [x] Resolve Q1–Q5 above (`kmdb-plan-reviewer` pass, 2026-07-03).
- [ ] **Bug 2 first (per Q5):**
  - [ ] Add `Future<List<String>> listFilesRecursive(String dirPath)` to the
        `StorageAdapter` interface (`storage_adapter_interface.dart`) per
        the Q3 resolution. **This is a breaking change for every class that
        `implements StorageAdapter` — every implementer below must be
        updated or the suite will not compile:**
        - `storage_adapter_native.dart` — real implementation:
          `Directory(dirPath).list(recursive: true)` filtered to `File`
          entries, each path relativised (strip the `dirPath` prefix — raw
          `Directory.list` output is prefixed by it), return `[]` if
          `dirPath` doesn't exist. **The returned paths must have no leading
          path separator** — strip `dirPath` *and* the following `/`, yielding
          e.g. `ab/cd/manifest.json`, not `/ab/cd/manifest.json`. This is
          load-bearing: `_collectSubdirsInto` (`vault_store.dart:678-680`)
          extracts the first segment via `path.indexOf('/')` guarded by
          `slash > 0`, so a leading slash makes it silently skip every entry —
          re-creating the exact silent-empty failure mode (bug 2) this plan
          fixes. Apply the same no-leading-separator rule to the memory backend.
          The Bug 2 native test below must assert on the returned path shape (or
          drive `listAllHashes` on a real native `VaultStore` and assert blobs
          are found) so a leading-slash regression fails loudly.
        - `storage_adapter_memory.dart` — real implementation: prefix scan
          over the flat key map (all paths are already flat keys
          internally).
        - `storage_adapter_sahpool.dart` — **`throw UnsupportedError(...)`**
          per the Q3/B2 resolution (not a real OPFS walk).
        - `test/support/faulty_storage_adapter.dart` (`FaultyStorageAdapter`)
          — **real implementation required, not a forwarding stub**: this
          class owns its own flat `_live`/`_durable` maps (it does not wrap
          an inner adapter), and it is the fault-injection harness this
          plan's own Bug 2 tests exercise `VaultGc`/`VaultRecovery` against —
          give it a genuine prefix-scan implementation mirroring
          `MemoryStorageAdapter`'s.
        - `test/engine/table_cache_integration_test.dart`'s `_CountingAdapter`
          — forwards to its wrapped inner adapter.
        - `test/engine/table_cache_test.dart`'s `_CountingAdapter` — forwards.
        - `test/engine/sstable_meta_tracking_test.dart`'s
          `_CountingReadAdapter` — forwards to its wrapped
          `MemoryStorageAdapter`.
        - `test/vault/search/vault_search_manager_test.dart`'s
          `_ThrowingWriteAdapter` — forwards to its wrapped
          `MemoryStorageAdapter`.
        - (`PartitionableAdapter` in the harness package wraps
          `SyncStorageAdapter`, a different interface — unaffected, no
          change needed.)
  - [ ] Update `VaultStore.listFilesRecursive` (`vault_store.dart:693-708`)
        to delegate to `_adapter.listFilesRecursive` instead of returning
        `[]`.
  - [ ] Rewrite the stale comments in the
        `_listSubdirs`/`_listSubdirsFromFiles`/`_collectSubdirsInto` chain
        (`vault_store.dart:588-683`) that currently explain why recursive
        listing "can't" work / why the stopgap returns `[]` — every one of
        these becomes actively false once the fix lands, and CLAUDE.md
        forbids leaving dead/misleading code or comments.
  - [ ] Tests: `VaultGc.sweep` and `VaultRecovery` against
        `FaultyStorageAdapter` (fault-injection, not just
        `MemoryStorageAdapter`) — confirm blobs are actually enumerated and
        that GC/recovery behave correctly under real (and faulty)
        filesystem I/O. Cover native and memory backends (web is the
        `UnsupportedError` path — no positive-path test needed there beyond
        confirming the throw).
  - [ ] **Explicit default-coverage test:** at least one test must exercise
        the real, non-overridden `listFilesRecursive` default on both
        `MemoryStorageAdapter` and `FaultyStorageAdapter` directly (not only
        through a test double that overrides it) — otherwise the new real
        implementation could ship entirely unexercised, since ~30 existing
        test doubles override this method (see Q4).
- [ ] **Bug 1 next:**
  - [ ] Define `kVaultRefCountSentinelKey` in `vault_recovery.dart`, next to
        `kVaultNamespace` — a UUIDv7-shaped 32-char hex constant (version
        nibble `'7'` at index 12, variant nibble in `{8,9,a,b}` at index 16).
        Do not reuse the search-layer `kVaultCorpusSentinelKey`.
  - [ ] Test: assert `KeyCodec.keyToBytes(kVaultRefCountSentinelKey)` does
        not throw — this is the load-bearing guarantee the whole fix rests
        on.
  - [ ] Change `$vault` ref-count storage to `(namespace='$vault:{sha256}',
        key=kVaultRefCountSentinelKey)`.
  - [ ] Update `vault_ref_count.dart:118` (the shared reader).
  - [ ] Update `vault_ref_interceptor.dart:320,345,349` (`_increment`/
        `_decrement`).
  - [ ] Confirm `VaultStore.createStub`'s guard read
        (`vault_store.dart:477-511`) is covered automatically via the shared
        reader — no separate change expected, but verify with a test.
  - [ ] No migration code (per the Q2 resolution) — just ensure the plan's
        Summary documents the reasoning once implemented.
  - [ ] Tests: a document containing a `kmdb-vault://` URI field can now be
        written through the **public** `KmdbCollection.insert`/`put`/update
        API without bypassing it (the exact scenario
        `vault_integration_test.dart:358-359` currently documents as broken
        and works around) — increment, decrement to zero (tombstone/GC
        interaction), decrement below zero guard, undecodable-entry
        fail-safe (`RefCountUndecodable` → retain), and multi-reference
        (two documents referencing the same blob) scenarios.
  - [ ] Update/remove the now-stale workaround comment and test structure in
        `vault_integration_test.dart` once the public path works directly.
- [ ] End-to-end test: a document with a vault URI field, written via the
      public API, survives a GC sweep while referenced and is correctly
      GC'd once unreferenced — exercising both fixes together.
- [ ] Update `docs/spec/24_vault.md` (and other spec files per the
      Investigation's list) to match the shipped behavior.
- [ ] `make site` after spec edits.
- [ ] Coverage: confirm new/changed lines meet the ≥90% floor (target ≥95%).

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new/changed files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy — including fault-injection coverage
      per CLAUDE.md's durability emphasis — code health). Resolve every
      blocking item before proceeding. Do not open a PR until sign-off is
      received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new/changed files (2026).

## Summary

_(To be completed after implementation.)_
