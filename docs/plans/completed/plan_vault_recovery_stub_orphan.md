# Fix the vault stub-orphan hazard at its producer (`createStub` must not leave a ref-less manifest)

**Status**: Implemented

**PR link**: _direct commit on `main` (no PR)_

**Origin**: Deferred follow-up **D3** from
[plans/completed/plan_vault_gc_failsafe.md](completed/plan_vault_gc_failsafe.md)
(review finding H3). H3 made the *ref-count decode* fail-safe; it explicitly
left the *sync-ordering* hazard described here for its own analysis because
folding it in would have widened the blast radius of that fix.

**Sequencing**: Should land before, or alongside, the peer-side parts of
`plan_document_versioning.md` and the multi-device tombstone GC in
`plan_compaction_reclamation.md` (H4) — all three depend on a coherent answer
to "what does a vault reference mean on a device that did not author it."

## Problem statement

On every unclean `open()`, `VaultRecovery` deletes any hash directory whose
`manifest.json` is present but whose `$vault:{sha256}` ref count cannot be
proven positive (the H3 fail-safe still retains *undecodable* counters). The
spec endorses this rule explicitly: **a stub always has a KV reference**, and a
ref-less `manifest.json` is defined as an *error state* that recovery must
clean up ([docs/spec/24_vault.md:133-136](../../docs/spec/24_vault.md#L133)).

The bug is that `VaultStore.createStub`
([vault_store.dart:344-348](../../packages/kmdb/lib/src/vault/vault_store.dart#L344-L348))
writes `manifest.json` **without verifying that a `$vault` ref exists for the
hash**. Anyone who calls `createStub` outside the spec-mandated orchestration
— a test, future sync wiring, a CLI tool, a corrupted/incomplete prior
session — leaves the vault in an error state that recovery will dutifully (and
correctly) reap. The hazard is *producer-side*, not recovery-side: the recovery
rule is faithful to the spec, but the only producer of stubs in the codebase
violates the spec's stub invariant.

Today the hazard is latent (no production code calls `createStub`) but it
becomes load-bearing the moment the peer-side sync orchestration in
`plan_document_versioning.md` starts driving stub creation.

## What the prior plan got wrong

The first draft of this plan assumed system (`$`) namespaces were excluded from
sync and therefore that peers never see vault ref counts. Re-reading the code
disproves this:

- [sync_engine.dart:86-88](../../packages/kmdb/lib/src/sync/sync_engine.dart#L86-L88)
  *documents* exclusion ("system `$` namespaces are always excluded") but no
  push/pull/ingest code path filters by namespace. `_syncNamespaces` is held as
  a field, exposed via a getter, and never read again
  ([sync_engine.dart:121-129](../../packages/kmdb/lib/src/sync/sync_engine.dart#L121-L129)).
- `SyncEngine.push` uploads every `.sst` belonging to this device
  ([sync_engine.dart:172-193](../../packages/kmdb/lib/src/sync/sync_engine.dart#L172-L193)).
- `SyncEngine.pull` ingests every peer `.sst` whose `maxHlc` exceeds the peer
  HWM, via `KvStoreImpl.ingestSstable`
  ([kv_store_impl.dart:201-212](../../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L201-L212)),
  which simply registers the file at L0 — no namespace filter on contained
  entries.

So `$vault:{sha}` entries authored by device A travel to device B inside the
SSTables that also carry the referencing documents. **Peer ref counts are
established by SSTable ingest, not by a missing reconstruction mechanism.** The
"systematic deleter of synced content" framing was incorrect.

A second misreading: the prior plan implicitly assumed there is production code
that creates stubs on peers. There is not — `syncVaultMetadata` is invoked
only in tests
(`vault_sync_integration_test.dart`, `vault_storage_adapter_test.dart`); the
production sync path moves SSTables, not vault metadata. The hazard the plan
described therefore cannot fire in current production code at all. It will
become real only once peer-side stub creation is wired up (planned in
`plan_document_versioning.md`).

## Decisions made during investigation

The four open questions from the prior draft are resolved as follows. They are
preserved here as questions only because the plan-reviewer agent should
confirm them before this moves to *Investigated*.

- [x] **Q1 — How is a peer `$vault` ref count established?**
  **By SSTable ingest.** The plan's earlier hypothesis (no rebuild mechanism)
  was wrong; the `$vault` entries authored by the originating device travel
  inside the same SSTables that carry the referencing documents and are
  installed via the standard L0 ingest path.
  _Decision: Confirmed. `SyncEngine.push` uploads every own SSTable without
  namespace filtering (`sync_engine.dart:172-193`). `SyncEngine.pull` ingests
  every peer SSTable via `KvStoreImpl.ingestSstable` (`kv_store_impl.dart:201-212`),
  which writes the file and calls `ingestAt0` with no namespace filter. The
  `_syncNamespaces` field is never read outside its getter
  (`sync_engine.dart:121-129`). The docstring at lines 86-88 is misleading and
  should be removed or corrected — noted in Review 2 below._
- [x] **Q2 — Should recovery delete a ref-less `manifest.json` (stub)?**
  **Yes — that is the spec.** §24.133-136 defines that state as an error, not
  a valid stub. Recovery is correct as written; the *producer* must not
  create that state.
  _Decision: Confirmed. The spec text at `docs/spec/24_vault.md:133-136` is
  unambiguous: "An incomplete local write that leaves `manifest.json` without
  `blob` with no KV reference is an error state and is deleted by crash
  recovery — it is never a valid stub."_
- [x] **Q3 — Hydrated synced blob with no local ref (`manifest + blob + no
  ref`)?**
  **Cannot arise via the documented hydration path.** `hydrateVaultBlob` is
  only reached via `VaultStore.getBytes`, which is reachable only from a
  document that already references the URI — implying the `$vault` ref is
  already present locally (otherwise `WriteAugmentor`-mediated writes would
  have established it on the authoring device before the SSTable was
  produced). If this state is ever observed on a peer it is a sign of a
  separate bug (or out-of-band hydration), and reaping it is again
  spec-correct.
  _Decision: Confirmed as plausible reasoning. The reachability chain from
  `getBytes` through the document reference guarantees the ref already exists
  in the same SSTable that carried the document write. No code change needed._
- [x] **Q4 — Scope.**
  **Narrowed.** No "peer ref-count reconstruction" sub-plan is needed.
  This plan fixes only the producer-side stub-creation invariant; the future
  wiring of `syncVaultMetadata` into production sync stays with
  `plan_document_versioning.md`.
  _Decision: Confirmed. `syncVaultMetadata` has zero production callers —
  only `vault_storage_adapter_test.dart` and `vault_sync_integration_test.dart`
  invoke it. The hazard is latent, not currently live._

## Implementation plan

The fix is a **producer-side contract enforcement** on `VaultStore.createStub`,
plus updates to the surrounding tests and prose. Recovery code is unchanged
beyond removing a now-stale `TODO`.

### Approach (recommended) — make `createStub` refuse to leave the error state

- [ ] Add a precondition to `VaultStore.createStub`: read the `$vault:{sha}`
      ref via the shared `VaultRefCount.read`. Throw `StateError` if the result
      is `RefCountAbsent` or `RefCountValue(0)` (a stub without a positive
      reference is, per spec, an error). On `RefCountUndecodable`, **allow** the
      stub (consistent with the fail-safe rule: an undecodable ref is treated
      as referenced everywhere else).
- [ ] Update `createStub`'s doc comment to state the invariant: "Callers must
      have established a positive `$vault` ref for `manifest.sha256` before
      invoking this method. Calling otherwise is a programmer error."
- [ ] Update `VaultStorageAdapter.syncVaultMetadata`'s contract doc to require
      the same: peer-side orchestration must ingest the SSTable carrying the
      `$vault` entry (or otherwise establish the ref) **before** calling
      `syncVaultMetadata`. (No code change to the adapter — only the docstring.)
- [ ] Remove the `TODO(vault)` block in
      [vault_recovery.dart:158-163](../../packages/kmdb/lib/src/vault/vault_recovery.dart#L158-L163);
      the hazard is now resolved at the producer, not the recovery sweep.

### Alternative considered — leave the contract implicit

Document the invariant in the spec and adapter but do not enforce it at the
`createStub` call site. Rejected: the failure mode (silent data loss at the
next unclean open) is too severe for an unenforced precondition, especially as
`plan_document_versioning.md` is about to start exercising this path in
production.

### Alternative considered — change recovery to use `isHydrated` (the prior plan's Approach A)

Treat `manifest ∧ ¬blob` as a structural "stub" regardless of ref count.
Rejected: it contradicts spec §24.133-136 and weakens recovery's ability to
clean up a real error state. The recovery rule is *fail-safe by design* —
weakening it to accommodate a buggy producer trades a fail-safe for a leak.

### Tests

The existing recovery tests stay as regression guards. The semantics shift
slightly — what they document now is "if a caller violates the `createStub`
contract, the resulting ref-less manifest is correctly reaped on recovery,"
which is still useful.

- [ ] **`createStub` rejects a missing ref** — call `createStub` with no
      `$vault` entry present; assert `StateError`. New test.
- [ ] **`createStub` rejects a zero ref** — write `$vault:{sha}` with
      `refCount: 0`, call `createStub`; assert `StateError`. New test.
- [ ] **`createStub` accepts a positive ref** — write `$vault:{sha}` with
      `refCount: 1`, call `createStub`; assert manifest written, recovery
      retains. New test.
- [ ] **`createStub` accepts an undecodable ref** — write a deliberately
      undecodable `$vault:{sha}` entry, call `createStub`; assert manifest
      written (consistent with the fail-safe rule), recovery retains. New
      test.
- [ ] **Recovery still deletes genuine orphans** — `manifest + blob + no ref`;
      assert deleted. Existing test, retained.
- [ ] **Recovery still deletes incomplete writes** — `blob`, no manifest, no
      ref; assert deleted. Existing test, retained.
- [ ] **Recovery retains undecodable refs** — H3 regression guard. Existing
      test, retained.
- [ ] Delete or rewrite the existing test that constructs a manifest-only stub
      via the `createStub` shortcut and asserts deletion — under the new
      contract, that call now throws, so the test must either (a) bypass the
      contract by writing the manifest directly via the storage adapter (to
      keep recovery coverage) or (b) be removed in favour of the new contract
      tests above. Recommend (a) to preserve recovery coverage.

### Documentation

- [ ] `docs/spec/24_vault.md`: tighten the prose around §24.133-136 to call out
      the producer-side contract: "`syncVaultMetadata` (and any direct use of
      `createStub`) must establish a positive `$vault` ref before writing the
      stub manifest. Failure to do so is an error state that crash recovery
      reaps." Cross-reference H3.
- [ ] `VaultStore.createStub` doc comment: invariant + rationale.
- [ ] `VaultStorageAdapter.syncVaultMetadata` doc comment: ordering requirement.
- [ ] Update the roadmap entry (`docs/roadmap/0_02_01.md`, H3-FU) status when
      complete.

### Out of scope (deliberately)

- Wiring `syncVaultMetadata` into the production sync flow — i.e. the
  orchestration that, after a pull, walks newly-ingested `$vault:{sha} > 0`
  entries and creates a peer-side stub for each. That work is orthogonal to
  document versioning (it depends only on the `$vault` namespace and the
  sync engine) and warrants its own plan; it is **not** owned by
  `plan_document_versioning.md`. This plan ensures that *when* peer-side stub
  creation does start firing, the producer cannot leave the vault in the
  spec-defined error state.
- User-facing soft-delete recovery window for vault objects. This is
  delivered *transitively* by `plan_document_versioning.md`: while any
  `$ver:` entry for a deleting document still holds the URI, its `$vault`
  ref stays positive and the blob is retained until the `$ver:` chain ages
  out (default `retentionDays: 90`). No vault-specific change required here.
- Any change to the crash table or the fail-safe ref-count rule from H3.
- Reconstructing ref counts from ingested documents (the original Q1 sub-plan).
  Not needed; SSTable sync already carries the counts.

## Summary

{To be completed during implementation.}

## Reviews

### Review 2: 2026-05-28

#### Claim verification

All three claims were verified by reading the cited code, not taken on trust.

**Claim 1 — `SyncEngine` does no namespace filtering on push/pull/ingest.**
Confirmed. `SyncEngine.push` (`sync_engine.dart:172-193`) uploads every SSTable
belonging to `_deviceId` without any namespace filter. `SyncEngine.pull`
(`sync_engine.dart:251-278`) downloads peer SSTables and calls
`_store.ingestSstable`, which delegates to `KvStoreImpl.ingestSstable`
(`kv_store_impl.dart:201-212`). That method writes the bytes to disk and calls
`_engine.ingestAt0` — no namespace predicate is applied at any point.
`_syncNamespaces` is stored as a field, surfaced via a getter, and never
consulted on any code path (`sync_engine.dart:121-129`). The constructor
docstring at lines 86-88 ("system `$` namespaces are always excluded") is
aspirational/incorrect and should be removed or corrected independently of this
plan.

**Claim 2 — `syncVaultMetadata` has zero production callers.**
Confirmed. A filesystem search across all packages finds `syncVaultMetadata`
defined in `vault_storage_adapter.dart`, `local_directory_vault_adapter.dart`,
and `local_directory_vault_adapter_stub.dart`, and invoked only from
`vault_storage_adapter_test.dart` and `vault_sync_integration_test.dart`. No
CLI, harness, or library production path calls it.

**Claim 3 — `docs/spec/24_vault.md:133-136` defines `manifest + no ref` as an
error state recovery must reap.**
Confirmed. The text is explicit: "An incomplete local write that leaves
`manifest.json` without `blob` with no KV reference is an error state and is
deleted by crash recovery — it is never a valid stub." The recovery rule is
spec-faithful; the bug is in the producer.

#### Q1–Q4 assessment

All four resolved answers are correct based on the code I read. The decisions
are recorded in the questions block above.

One minor addendum on Q1: the `_syncNamespaces` getter doc comment at
`sync_engine.dart:124-128` says the field is "Used in Phase 6+ to filter which
SSTables are downloaded and ingested." This is forward-looking wording that
contradicts what the field does today (nothing). If Phase 6+ filtering is ever
implemented, care is needed to ensure `$vault:` entries are not accidentally
excluded. This is not a blocker for the current plan, but the implementer should
note it as a landmine.

#### Problem Statement Assessment

Sound. The bug is real: `VaultStore.createStub` writes a `manifest.json`
without asserting a positive `$vault` ref exists, violating the spec's explicit
stub invariant. Recovery will dutifully reap the resulting state. The plan is
correctly scoped: it is latent today (no production caller) but becomes
load-bearing as soon as `plan_document_versioning.md` wires up peer-side stub
creation. Fixing it now, before that wiring lands, is the right sequencing.

#### Proposed Solution Assessment

The producer-side precondition in `createStub` is the correct fix. It is a
small, targeted change: read the ref via the shared `VaultRefCount.read` helper
(already used by recovery and GC), throw `StateError` on `RefCountAbsent` or
`RefCountValue(0)`, allow on `RefCountUndecodable` (consistent with the H3
fail-safe rule). The approach is internally consistent and does not disturb the
recovery path.

The rejection of "use `isHydrated` as a structural discriminator" is also
correct. That approach would have weakened recovery's ability to identify real
orphans in exchange for accommodating a buggy producer — the wrong trade-off.

One implementation note: `VaultStore` holds a `KvStore` reference (used by
`VaultRefCount.read`). The plan assumes this is available at the `createStub`
call site. This is worth a brief verification during implementation; if
`createStub` is called on a `VaultStore` that was constructed without a
`KvStore` (e.g. from a test helper), the precondition read may not be
reachable. Looking at `vault_store.dart:344-348`, the current constructor wiring
is not checked here, but the test plan already covers the contract directly, so
this will surface immediately if there is a problem.

#### Architecture Fit

Tight. The fix reuses `VaultRefCount.read` — the exact helper introduced by H3
to unify all ref-count reading. This is the right abstraction. No new
dependencies, no new types, no interface changes. The docstring updates to
`syncVaultMetadata` correctly record the ordering requirement for future
implementers without touching the adapter's runtime behaviour. Removing the
`TODO(vault)` block in `vault_recovery.dart:158-163` is correct: the comment
describes the hazard as unresolved; once the producer guards against creating
the bad state, the comment is misleading.

The plan does not modify any spec section numbers or introduce a new spec
section, so there is no collision risk with parallel plans.

#### Risk and Edge Cases

**The recovery test at `vault_recovery_test.dart:265`** calls `createStub`
without a KV ref and asserts deletion. Under the new contract that call throws
before the manifest is written, so the test breaks. The plan correctly identifies
this and recommends option (a): bypass `createStub` by writing the manifest
directly via the storage adapter. This is the right call — it keeps recovery
coverage alive without smuggling a contract violation through the public API.
Option (b) (remove the test) would leave a gap in recovery regression coverage
and should not be chosen.

**The test at `vault_recovery_test.dart:243-263`** calls `createStub` with
`kvStore.setRefCount(sha256, 1)` set _after_ the stub is written. Under the new
contract, the ref must exist _before_ `createStub` is called. This test also
needs to reorder those two lines. The plan does not call this out explicitly —
the implementer should be aware.

**`RefCountUndecodable` allow path**: the plan correctly allows stub creation
when the ref is undecodable, consistent with the H3 fail-safe. A quick sanity
check: this means a test that writes a deliberately bad encoding and then calls
`createStub` should succeed — this is covered by the "accepts an undecodable
ref" test case. Good.

**No concurrent-write risk**: the precondition check and the manifest write are
not atomic. A concurrent GC sweep could theoretically decrement the ref to zero
between the check and the write. However, KMDB's concurrency model is
synchronous single-isolate (§18); there is no concurrent GC on the write path.
This is not a real risk in the current architecture.

#### Recommendations

1. In `createStub`, assert the ref before writing, not after — the check should
   gate the `_writeManifest` call, not wrap it.
2. During implementation, verify that the test at line 256 (`createStub` called
   after `setRefCount`) reorders the calls so the ref is present first.
3. The `_syncNamespaces` docstring ("Used in Phase 6+ to filter…") should be
   flagged as a future footgun in a follow-up comment or issue. Not this plan's
   responsibility, but worth noting.
4. The misleading constructor docstring at `sync_engine.dart:86-88` should be
   corrected in a follow-up. Again, not a blocker for this plan.

The plan is ready for implementation. No open questions remain.

- **Open questions**: None.
