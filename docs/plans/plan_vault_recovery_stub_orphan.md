# Fix the vault stub-orphan recovery hazard (recovery can delete freshly-synced stubs)

**Status**: Questions

**PR link**: {pending}

**Origin**: Deferred follow-up **D3** from
[plans/completed/plan_vault_gc_failsafe.md](completed/plan_vault_gc_failsafe.md)
(review finding H3). H3 made the *ref-count decode* fail-safe; it explicitly left
the *sync-ordering* hazard described here for its own analysis because folding it
in would have widened the blast radius of that fix.

**Sequencing**: Should land before, or alongside, the peer-side parts of
`plan_document_versioning.md` and the multi-device tombstone GC in
`plan_compaction_reclamation.md` (H4) — all three depend on a coherent answer to
"what does a vault reference mean on a device that did not author it."

## Problem statement

On every unclean `open()`, `VaultRecovery` sweeps the vault and **deletes any
hash directory that has a `manifest.json` but no positive `$vault` reference
count**, treating it as an orphaned object (the `WriteBatch` that should have
created the ref never committed).

A freshly **synced stub** has exactly that shape: `VaultStore.createStub` writes
`manifest.json` with **no blob and no `$vault` ref count**. So recovery cannot
tell a genuine local orphan from a valid remote stub, and an unclean open can
**delete a stub whose referencing document has not yet arrived on this device**
(or whose reference count was never established here at all). The next
`getBytes()` then throws `VaultObjectNotFoundException` instead of hydrating the
blob from the remote — an availability/data loss in the same *fail-dangerous*
family as H3: when uncertain, the code destroys state it cannot prove is dead.

The trigger is routine, not exotic: device A adds a file and a document
referencing it; device B pulls the vault metadata (creating a stub) and is
restarted uncleanly before — or independently of — the document/ref state
settling locally. Recovery deletes B's stub.

## Open questions

These must be answered before the implementation approach can be fixed; Q1 is
the gating one because it decides whether this is a narrow timing race or a
systematic defect.

- [ ] **Q1 — How is a `$vault` reference count established on a peer device?**
  System (`$`) namespaces are **excluded from sync**
  ([sync_engine.dart:86-88](../../packages/kmdb/lib/src/sync/sync_engine.dart#L86)),
  and `VaultRefInterceptor` only adjusts counts on the **local query-layer write
  path** — not on SSTable ingest. No code was found that rebuilds vault ref
  counts from ingested documents. So today a synced object appears to have **no
  local ref count ever**, which would make recovery's orphan rule delete *all*
  synced stubs (and, see Q3, even hydrated synced blobs) on the next unclean
  open. Is there an intended rebuild-on-ingest mechanism, or is the counter
  meant to be local-origin only? *(Recommended: ref counts must be reconstructed
  on the receiving device from the documents it ingests — otherwise GC and
  recovery have no meaning for synced content. This likely warrants its own
  small sub-plan; see Q4.)*
- [ ] **Q2 — Should recovery ever delete a manifest-without-blob (stub)?**
  *(Recommended: **no.** A stub is a valid, hydrate-on-demand state; cleaning up
  a genuinely dereferenced stub is the tombstone-gated GC's job, not crash
  recovery's. Retain all stubs during recovery.)*
- [ ] **Q3 — Orphan deletion for hydrated synced blobs (`manifest + blob +
  no ref`).** If peer ref counts are not established (Q1), the existing orphan
  rule would also delete hydrated synced blobs, not just stubs. Should orphan
  deletion be gated until references are known for the object (e.g. only after a
  successful sync/ref-rebuild), or restricted to objects this device authored?
- [ ] **Q4 — Scope of this plan.** Fix `VaultRecovery` only, or also specify the
  peer ref-count lifecycle (which overlaps H4 and document versioning)?
  *(Recommended: this plan owns the recovery-side fail-safe (Q2) and the
  decision in Q3; if Q1 confirms a missing rebuild mechanism, split that into a
  dedicated "peer vault ref-count reconstruction" plan and make this one depend
  on it.)*

## Investigation

### The exact rule that misfires

`VaultRecovery._classify`
([vault_recovery.dart](../../packages/kmdb/lib/src/vault/vault_recovery.dart),
post-H3) reads the ref count via the fail-safe `VaultRefCount.read` and then:

- `Undecodable` → retain (H3 fix).
- otherwise `hasRef = Value(n > 0)`; `hasManifest = store.exists(sha256)`.
- `manifest present, no ref` → `delete` (orphan).
- `manifest absent, no ref` → `delete` (incomplete write); `manifest absent,
  ref` → retain (defensive).

The "`manifest present, no ref → delete`" branch is the hazard. It is correct
for a genuine local orphan but indistinguishable from a synced stub.

### Why `manifest ∧ ¬blob` uniquely identifies a stub

Local ingest writes the **blob before the manifest**
([vault_store.dart:229-243](../../packages/kmdb/lib/src/vault/vault_store.dart#L229)):
rename staging→`blob` (step 4) **then** write `manifest.json` (step 5). So a
crash during a *local* ingest can leave staging-only, or `blob` without manifest
— but **never a manifest without a blob**. The only producer of "manifest, no
blob" is `VaultStore.createStub`
([vault_store.dart:344-348](../../packages/kmdb/lib/src/vault/vault_store.dart#L344)),
called by `LocalDirectoryVaultAdapter.syncVaultMetadata`
([local_directory_vault_adapter.dart:151-168](../../packages/kmdb/lib/src/vault/local_directory_vault_adapter.dart#L151)).

**Therefore `manifest present ∧ blob absent ⟺ stub`**, a clean structural
discriminator already available via `store.isHydrated(sha256)`
([vault_store.dart:140-141](../../packages/kmdb/lib/src/vault/vault_store.dart#L140)).
`_classify` does not currently consult it.

### The deeper issue: references are not established on peers

`$vault` is a system namespace and excluded from sync, and `VaultRefInterceptor`
is a `WriteAugmentor` on the query-layer write path only — SSTable ingest
bypasses it. No post-ingest scan rebuilds vault ref counts (searched:
`createStub` / `syncVaultMetadata` / `hydrateVaultBlob` call sites, sync engine).
Consequences:

- A synced object may have **no `$vault` ref on the receiving device, ever** —
  not merely "not yet." That turns the orphan rule from a race into a systematic
  deleter of synced content on unclean open (Q1/Q3).
- Conversely, GC only acts on **tombstoned** objects, so it does not spuriously
  delete synced blobs; recovery's blanket orphan rule is the dangerous path.

This is why the surface fix (retain stubs) is necessary but possibly not
sufficient — the orphan rule's core assumption ("a referenced object always has
a local `$vault` count") does not hold for synced content until Q1 is resolved.

### Recovery timing

`VaultRecovery.recover()` runs at `open()` after LSM recovery, before normal
operation
([kmdb_database.dart:307-316](../../packages/kmdb/lib/src/query/kmdb_database.dart#L307)).
A stub written in a previous session is on disk with no local ref; at the next
unclean open it is indistinguishable from an orphan under the current rule.

### An existing test encodes the dangerous behaviour

`vault_recovery_test.dart` has **`stub (manifest-only) without KV ref is
deleted`**, which asserts `hashDirsDeleted == 1` for exactly the synced-stub
shape. The fix must flip this expectation (stub retained) and add positive
coverage. Note this test pre-dates H3 and documents the behaviour we now consider
wrong.

### §24 crash table

The crash table
([docs/spec/24_vault.md](../../docs/spec/24_vault.md), Crash Recovery) currently
lists only local-crash rows. It needs a row clarifying that a **stub
(`manifest`, no `blob`) is retained** by recovery, and (pending Q3) how synced
hydrated blobs are treated.

## Implementation plan

> Provisional — finalise after the open questions are answered. The steps below
> assume the recommended answers (Q2 = retain stubs; Q1 = a rebuild mechanism is
> required and may be split out per Q4).

### Approach A (recommended) — structural stub/orphan discriminator
- [ ] In `VaultRecovery._classify`, consult `store.isHydrated(sha256)`. Treat
      `manifest ∧ ¬blob` as a **stub → retain** (never an orphan). Restrict
      orphan deletion to `manifest ∧ blob ∧ no ref` (the genuine crash-after-
      step-4 case from the §24 table). Reuse the H3 `RefCountReadResult` helper
      unchanged.
- [ ] Decide Q3 for the `manifest ∧ blob ∧ no ref` case on peers (gate on
      "refs known" vs. local-origin) — may require Q1's outcome.

### Approach B (alternative / complementary) — grace window
- [ ] Defer orphan deletion for objects whose `VaultManifest.createdAt` (HLC) is
      within a grace horizon. Weaker (time-based, and `createdAt` is the *origin*
      device's HLC), but composable with A. Recorded for completeness; not
      recommended as the primary mechanism.

### Approach C (alternative) — sync-horizon gating
- [ ] Only run orphan deletion past a sync horizon (cf. H4's `min(currentHlc)`
      across high-water marks), so an object cannot be reaped before peers have
      had a chance to deliver its reference. Heavier; couples recovery to the
      sync folder.

### Tests
- [ ] **Synced stub survives recovery** — `createStub`, no ref, no blob; assert
      retained (replaces the current "stub deleted" test).
- [ ] **Genuine orphan still deleted** — `manifest + blob + no ref`; assert
      deleted (regression guard for the §24 step-4 row).
- [ ] **Incomplete local write still deleted** — `blob`, no manifest, no ref.
- [ ] (pending Q3) Hydrated synced blob with no local ref — behaviour per the
      Q3 decision.
- [ ] Two-device flow in the harness: A authors + uploads, B stubs, B unclean
      open → stub retained → later `getBytes` hydrates.

### Documentation
- [ ] `docs/spec/24_vault.md`: add the stub-retention rule to the crash table and
      prose; cross-reference H3's fail-safe rule.
- [ ] Update `VaultRecovery` doc comments and remove the resolved `TODO(vault)`
      in `_classify`.
- [ ] Update the roadmap entry status when complete.

## Summary

{To be completed during implementation.}
