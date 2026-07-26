# Retire the `$meta` `device_id` copy (SC-5 / WI-12)

**Status**: **Complete** (2026-07-27) — `kmdb-qa` signed off; `make pre_commit`
green. Implemented on `main`-based branch `20260727_plan_0_10_01_device_id_meta_retire`.

**PR link**: _(none yet)_

> **Provenance.** WI-12 of the [0.10.01 hardening track](../roadmap/0_10_01.md),
> closing **SC-5** of the 2026-07-18 release-readiness review. Re-scoped
> 2026-07-21 (SC-5 severity revised 🟡→🟢): the authoritative device identity is
> already the local `DEVICE_ID` file — see the
> [attribute registry](../spec/03a_attribute_registry.md#device_id) — so this is a
> cleanup, not an identity migration. Code coordinates below were verified against
> `main` (post-WI-11).

## Problem statement

`device_id` is written to `$meta` in two places, and `$meta` **replicates** (it
rides synced SSTables). That copy is:

- **the SC-5 defect** — `$meta` is Last-Write-Wins across all synced devices, so
  reading it back can resolve to a **peer's** identity, not this device's; and
- **inert dead weight** — every open already prefers the local `DEVICE_ID` file
  (`ensureDeviceId` reads it *first*), so nothing correct depends on the `$meta`
  copy. It only leaks each device's `device_id` into the sync folder.

The authoritative store is the plaintext `DEVICE_ID` file in the db root
(written via the StorageAdapter — a `dart:io` file on native, OPFS on web — and
never uploaded because it is outside `sst/`).

**Scope (maintainer, 2026-07-24): remove the `$meta` `device_id` path entirely —
read *and* write.** This is a greenfield, unreleased project, so there are **no
legacy databases** whose `$meta` copy must be read as a fallback. Removing the
whole path (rather than "stop writing, keep reading") is simpler and eliminates
the resulting dead code.

## Goals

1. `device_id` no longer touches `$meta` — the `DEVICE_ID` file is the sole store.
2. No dead code left behind (`putDeviceId`/`getDeviceId`/`deviceIdKey` removed).
3. SC-5 fully closed: a device can never adopt a peer's identity via `$meta` LWW.

## Non-goals

- **Durable platform storage** for the identity (Keychain / persistent OPFS so it
  survives app reinstall or a site-data clear). That is the §08 "secure storage"
  enhancement — a separate, larger design that crosses into `kmdb_flutter` and the
  platform layer. This plan deliberately leaves the file as a co-located plain
  file and documents the consequence (below).
- Correcting §04/§08's stale "Keychain/SharedPreferences" prose — that is **WI-2**.
  This plan updates the **registry** entry (which already describes reality).

## Open questions

- [x] **Q1 — `DeviceId.load` shape.** After dropping `$meta`, `DeviceId.load(meta)`
      loses its reason to exist (it was get-`$meta`-or-generate-and-put-`$meta`).
      **Resolved (reviewer, 2026-07-24): add a static `DeviceId.generate()`** (no
      `MetaStore` param) — houses the UUIDv4 rationale comment, and the CLI's
      duplicated algorithm (`new_device_id_command.dart:74-77`) redirects to it.
      Inline the file resolution in `ensureDeviceId` (read `DEVICE_ID`; if
      absent/invalid, `DeviceId.generate()` + write the file). No `$meta`.
- [x] **Q2 — `storeInfo()`'s read site — RESOLVED: one-line redirect to
      `_engine.deviceId` is correct; it is *not* a hidden gap.** Verified against
      `main`:
      - `_engine.deviceId` is authoritative in **every production path**:
        - **CLI** — `DatabaseOpener.open` is two-phase: Phase 1 opens with the
          `'00000000'` default and calls `ensureDeviceId()`; if the resolved id
          differs it closes without flush and Phase 2 reopens passing
          `deviceId: <resolved>` into `KmdbDatabase.open` → `KvStoreImpl.open` →
          `engine._deviceId`. `ctx.store` is the Phase-2 store
          (`cli_runner.dart:401-437`), so `ctx.store.storeInfo()` reads the
          resolved id.
        - **In-session reassign** — `LsmEngine.reassignDeviceId` sets
          `_deviceId = newDeviceId` (`lsm_engine.dart:1524`).
        - **Reassign + reopen** — reassign also rewrites the `DEVICE_ID` file
          (`kv_store_impl.dart:342-347`); the next `DatabaseOpener` open re-reads
          it and threads it into Phase 2.
      - The **only** case where `_engine.deviceId` is *not* the resolved id is the
        single-phase pattern `KmdbDatabase.open()` (default `'00000000'`) followed
        by a bare `db.ensureDeviceId()` **with no reopen**. `ensureDeviceId` does
        **not** rebind the running engine — so that engine genuinely names its
        SSTables `'00000000'`. Today `storeInfo` reads `$meta` and reports the
        *resolved* id, which **masks** that the engine is really using
        `'00000000'`. After the redirect, `storeInfo` honestly reports
        `'00000000'`, matching the SSTables. So the redirect **surfaces a
        pre-existing latent inconsistency; it does not create a regression.**
      - **Consequence for the implementer:** resolve `storeInfo` from
        `_engine.deviceId` — **do not** resolve it from the `DEVICE_ID` file (that
        would re-create the same mask in the opposite direction: reporting the
        file's id while the engine writes `'00000000'`). No production caller uses
        the single-phase pattern (`kmdb_harness` passes explicit `deviceId`s; the
        CLI is two-phase), so the honest `'00000000'` in that pattern is a
        cosmetic change to an already-semantically-broken usage, not a functional
        break. This is **not** a gap large enough to split out.

## Investigation

### The `$meta` `device_id` call graph (verified against `main`)

**Write sites (remove):**

- `device_id.dart:65` — `DeviceId.load` generation path calls `meta.putDeviceId(id)`.
- `kv_store_impl.dart:337` — `reassignDeviceId` calls `_meta.putDeviceId(newDeviceId)`.

**Read sites (remove / redirect):**

- `device_id.dart:54` — `DeviceId.load` calls `meta.getDeviceId()` (the fallback).
- `kv_store_impl.dart:420` — `ensureDeviceId` calls `DeviceId.load(_meta)` (fallback
  when the file is absent).
- `kv_store_impl.dart:495` — `storeInfo()` reads `_meta.getDeviceId() ?? _engine.deviceId`
  (Q2).

**`MetaStore` surface that goes dead (delete):** `putDeviceId` (`:217`),
`getDeviceId` (`:207`), `deviceIdKey` (`:204`). Confirm no other caller before
deleting.

### The `DEVICE_ID` file is the sole store — consequences (document, don't fix)

Post-cleanup the identity's durability equals the `DEVICE_ID` file's durability:

- **Native/mobile:** a plain file in the db dir. Survives app updates and normal
  backup/restore (it is inside the app data dir), but **not** a data-clear or an
  uninstall-without-restore.
- **Web:** OPFS — per-origin and persistent, but cleared with site data and
  evictable under storage pressure unless the host has called
  `navigator.storage.persist()`.

**A lost `DEVICE_ID` file correctly yields a fresh id + a one-time SSTable
re-upload (identity churn)** — which is *safer* than the removed `$meta` fallback,
because that fallback could silently adopt a peer's identity (SC-5). Churn-
avoidance across a wipe is exactly what the §08 durable-storage enhancement is
for; it is out of scope here. **The plan records this trade-off in the registry
entry so it is not lost.**

### Existing dev databases

Greenfield: no released databases. Existing dev/test fixtures (and `demodb`)
created by pre-WI-12 code still contain an inert `$meta` `device_id` key; nothing
reads it after this change, so **no migration or cleanup pass is required** — they
regenerate cleanly. (Do not add a delete-on-open sweep; it is unnecessary code.)

## Implementation plan

### Phase 1 — remove the `$meta` `device_id` path

- [x] Delete `MetaStore.putDeviceId`, `getDeviceId`, `deviceIdKey`
      (`meta_store.dart:204/207/217`) after confirming no remaining callers.
- [x] Per Q1, replace `DeviceId.load(meta)` with a pure generator (recommend
      `DeviceId.generate()`), and make `ensureDeviceId` file-only: read the
      `DEVICE_ID` file; if absent/invalid, generate a fresh id and write the file.
      No `$meta` interaction.
- [x] Remove the `_meta.putDeviceId(newDeviceId)` call in `reassignDeviceId`
      (`kv_store_impl.dart:337`). Reassign now rewrites **only** the `DEVICE_ID`
      file + renames SSTables + the manifest VersionEdit (the load-bearing chain —
      leave it untouched).
- [x] Per Q2, redirect `storeInfo()` (`kv_store_impl.dart:495`) to
      `_engine.deviceId`. **Do not** resolve from the `DEVICE_ID` file (see Q2 —
      that re-creates the mask). The honest `'00000000'` in the single-phase
      `open()+ensureDeviceId()` pattern is expected and correct.
- [x] Point `new_device_id_command.dart`'s duplicated generation
      (`:74-77`) at the shared `DeviceId.generate()` (Q1) so there is one
      algorithm. (Required adding `export 'src/engine/kvstore/device_id.dart'
      show DeviceId;` to `kmdb.dart`'s public surface — `DeviceId` was
      previously package-private to `kmdb` and unreachable from `kmdb_cli`.)

- [x] **Doc-comment / prose cleanup (do not skip — dangling `[symbol]` links
      are analyzer warnings, and stale "stored in `$meta`" prose directly
      contradicts this change; verified against `main`):**
  - `device_id.dart` class doc — rewrite `:19-39`: `:21` "persisted in `$meta`",
    `:22-23` "generates … from a UUIDv7" (Finding-C: code uses **UUIDv4**), and
    `:36-39` "`$meta` is the sole persistence mechanism" are all now false. State
    the `DEVICE_ID` file is the sole store. (This absorbs the `device_id.dart:23`
    and `:37-38` items the roadmap had parked under WI-2 — see Phase 3.)
  - `meta_store.dart` class doc `:38-39` — remove the **Device identity
    (`device_id`)** bullet from the list of `$meta` state families.
  - `meta_store.dart:492` (`symbolicKey` doc) and `:543` (`encryptionBlobKey`
    doc) — both reference `[deviceIdKey]` as an exemplar; retarget to `[genKey]`
    (which survives) so the dartdoc links do not dangle after deletion.
  - `kv_store_impl.dart:107` — the `open` doc references `[DeviceId.load]`;
    retarget to `[ensureDeviceId]`.
  - `kv_store_impl.dart` `ensureDeviceId` doc `:387-406` — delete the whole
    "stored in **two** places / `$meta` retained for backward compatibility"
    section; describe the file as the sole store. Fix the inline comments at
    `:419` ("Fall back to `$meta`") and `:422-425` ("a lost DEVICE_ID falls back
    to `$meta`").
  - `kv_store_impl.dart` `reassignDeviceId` doc/comments `:332-341` — drop the
    "persist the new device ID to `$meta`" paragraph.

  **Verification:** `dart analyze` in `packages/kmdb` after Phase 1 shows zero
  errors/warnings in `lib/` — the only 22 remaining issues are the expected
  `test/` failures Phase 2 rewrites (undefined `DeviceId.load`/
  `MetaStore.putDeviceId`/`getDeviceId`/`deviceIdKey` references).

### Phase 2 — tests

- [x] **`device_id_test.dart` is a rewrite, not an edit.** The whole file
      exercises `DeviceId.load(meta)` and `$meta` persistence (persistence
      across reopen, "does not overwrite stored id", "survives flush/compaction"
      — all via `$meta`). Re-point it at `DeviceId.generate()` (format/shape)
      **and** at `ensureDeviceId` for the file-based persistence semantics that
      replace the deleted `$meta` ones — in particular a close/reopen round-trip
      that returns the same id **via the `DEVICE_ID` file** (the property the old
      `$meta` tests guaranteed must not be lost).
- [x] Update `meta_store_test.dart` (`:216-238`) and
      `meta_store_encryption_test.dart` (`:153-156`, `:233-242`, `:381`,
      `:426-437`) to drop the removed `getDeviceId`/`putDeviceId`/`deviceIdKey`
      surface.
- [x] Fix the stale comment at `reassign_device_id_test.dart:239` ("storeInfo
      reads from `$meta` …") — after this change it reads `_engine.deviceId`; the
      test still passes because the reopen is given the reassigned id, but the
      rationale comment must be corrected.
- [x] **New/updated coverage (exercise the real behaviour, not the golden path):**
  - **SC-5 regression (primary, deterministic):** a fresh DB writes the
    `DEVICE_ID` file and **`$meta` holds no `device_id` entry**. Assert by reading
    `store.get(MetaStore.kNamespace, MetaStore.symbolicKey('device_id'))` and
    expecting `null`. `symbolicKey` is the generic encoder that survives the
    deletion and computes the *exact* key the deleted `deviceIdKey` did — this is
    how the test locates the (now-absent) key. Prefer this over scanning raw
    SSTable bytes for the 8-char value, which is fragile (coincidental hex).
    Done in `device_id_test.dart`, `meta_store_test.dart`,
    `meta_store_encryption_test.dart` (incl. under encryption), and
    `reassign_device_id_test.dart`.
  - **SC-5 regression (secondary, illustrative):** optionally flush and confirm a
    produced SSTable body does not contain a `device_id` entry — mirrors how the
    copy was found empirically in `demodb`, but keep the `$meta`-key-absence
    assertion above as the load-bearing one. Done in `device_id_test.dart`.
  - `DEVICE_ID` file absent on open → a fresh id is generated and the file written;
    it does **not** consult `$meta`. Done in `device_id_test.dart`.
  - `reassignDeviceId` rewrites the file and renames SSTables, and writes no
    `device_id` to `$meta` (`symbolicKey('device_id')` → `null`). Done in
    `reassign_device_id_test.dart`.
  - `storeInfo().deviceId` returns the resolved id. **Scope this against a store
    that received its id via the open-time `deviceId:` param, the two-phase
    `DatabaseOpener` flow, or post-reassign — NOT the single-phase
    `KmdbDatabase.open()+ensureDeviceId()` pattern, where `'00000000'` is now the
    correct answer** (see Q2). Asserting "not `'00000000'`" against the
    single-phase pattern would enshrine the masking behaviour this change removes.
    Done: new open-time-param test in `device_id_test.dart`; existing
    post-reassign coverage in `reassign_device_id_test.dart` already exercises
    this scope and needed no change.
  - Two-device sync: device B never observes device A's `device_id` in its `$meta`
    (the SC-5 leak is gone). A unit `$meta`-key-absence assertion covers the
    regression; the harness case is a stronger end-to-end confirmation but is
    **optional** here, not required to close SC-5. **Deferred** — the unit
    assertion above closes SC-5; no `kmdb_harness` case added.

### Phase 3 — registry + docs

- [x] Update the `device_id`
      [registry entry](../spec/03a_attribute_registry.md#device_id): drop the `⚠`
      and the "legacy `$meta` copy" from Storage/Scope/Encrypted; state the
      `DEVICE_ID` file is the sole store; record the durability trade-off and the
      §08 durable-storage enhancement as the churn-avoidance follow-up. Update the
      register table row and remove `device_id` from the `⚠` mid-change set.
- [x] Tick WI-12 on the roadmap **and reconcile its now-stale description.** The
      roadmap (`docs/roadmap/0_10_01.md`) still describes WI-12 as the *old* scope
      — "stop writing the synced `$meta` copy, **keep the legacy read-fallback**"
      (`:51`, `:368`, `:680`). The maintainer's 2026-07-24 decision is a **full
      deletion (read *and* write)**; update those lines so the roadmap does not
      contradict the shipped change. Confirm the `$meta` end-state table/note
      (`:289-323`) reflect that `device_id` has left `$meta`.
- [x] **Claim the two `device_id.dart` doc items the roadmap parked under WI-2.**
      Lines `:312` (`device_id.dart:23` UUIDv7 comment) and `:373-374`
      (`device_id.dart:37-38` "`$meta` is the sole persistence mechanism") are
      assigned to WI-2 in the roadmap, but this plan rewrites that file (Phase 1),
      so it fixes them here. Remove those two items from WI-2's list so WI-2 does
      not later re-touch now-correct comments.
- [x] Confirm no spec section still asserts `device_id` lives in `$meta` (§04/§08's
      *Keychain / platform secure storage* prose is a different, WI-2 claim — do
      **not** touch it here; the durable-storage enhancement remains a non-goal).
      Found and fixed three additional sites beyond the plan's enumerated
      coordinates: `04_keys.md` (reassign step 4 said "persists to `$meta`"),
      `11_kv_store.md` (`$meta` namespace table listed "device ID"), and
      `31_encryption.md` (two sites: the confidentiality-coverage bullet list,
      and the Gap 3 "Update" callout that said "device ID … remain in `$meta`").
      §04/§08's Keychain/SharedPreferences/localStorage prose (`04_keys.md`
      "Device Identity" intro) was left untouched per the plan's non-goal.

**Final step — QA sign-off and pre-commit:**

- [x] `make coverage` — judge the seam (the SC-5 "no device_id in synced `$meta`"
      assertion is the point), not just the percentage. Result: 94.8% overall
      (11182/11801 lines); `meta_store.dart` 133/133 (100%), `device_id.dart`
      2/2 (100%), `kv_store_impl.dart` 171/174 (98.3%) — the SC-5 seam
      (`symbolicKey('device_id')` absence assertions) is exercised in
      `device_id_test.dart`, `meta_store_test.dart`,
      `meta_store_encryption_test.dart`, and `reassign_device_id_test.dart`.
      `packages/kmdb_cli && dart test` also green (1176 tests, incl.
      `new_device_id_command_test.dart`'s 6 tests).
- [x] **`kmdb-qa` signed off (2026-07-27): ✅ ready.** All six judgement questions
      passed (DeviceId export sound; SC-5 closed at the seam via deterministic
      `symbolicKey('device_id')` absence across four test files; the
      `device_id_test.dart` rewrite preserves the close/reopen persistence property,
      re-homed onto the `DEVICE_ID` file; the Q2 `storeInfo` honesty change has no
      masked-behaviour dependency; the §04/§11/§31 doc fixes are correct and the
      WI-2 Keychain boundary held). QA found and fixed inline **four further stale
      `$meta` doc-comments the plan's enumerated list missed** — `kv_store.dart:190`
      (`storeInfo` doc), `:198` (`reassignDeviceId` doc), `:353` (`StoreInfo.deviceId`
      field), and `lsm_engine.dart:1425` (internal crash-safety note) — three on the
      public API surface. `make pre_commit` re-run green after those edits.

## Reviewer notes (2026-07-24)

Verified every code claim against `main` by symbol. Status → **Investigated**.

- **Call graph (dead-code claim): CONFIRMED.** No missed production/lib callers of
  `putDeviceId`/`getDeviceId`/`deviceIdKey`/`DeviceId.load` beyond the five the
  plan lists (`device_id.dart:54,65`; `kv_store_impl.dart:337,420,495`). The only
  *other* references are doc-comment cross-links and stale prose — now enumerated
  in Phase 1; leaving them would produce dangling `[deviceIdKey]`/`[DeviceId.load]`
  dartdoc links and self-contradictory docs.
- **Q2: settled as a one-line redirect — see the resolved Q2 above.** Not a
  hidden gap; the redirect makes `storeInfo` honest and does not regress any
  production caller.
- **Q3 (migration): CONFIRMED safe, no cleanup pass needed.** The format-version
  gate scans `$meta` for *emptiness only* (`kv_store_impl.dart:177-181`), reading
  raw bytes and never interpreting `device_id`; its own comment (`:168-170`)
  explicitly anticipates "a bare `device_id`" as a handled scenario. Consolidation
  treats `$meta` entries as opaque LWW payload. Nothing trips over an orphan key.
  An existing dev DB's inert copy simply ages out of the LSM (never rewritten,
  never read).
- **Q4 (test): meaningful and achievable, but the plan under-specified *how*.** The
  deterministic assertion is `$meta`-key **absence** via
  `MetaStore.symbolicKey('device_id')` (the raw-byte scan the maintainer used on
  `demodb` is fine as illustration but fragile as an automated assertion). Phase 2
  now specifies this, including that `symbolicKey` — unlike the deleted
  `deviceIdKey` — survives and computes the same key.
- **Q5 (scope): correct, with one reconciliation added.** §04/§08 Keychain prose
  is correctly left to WI-2; durable platform storage is correctly a non-goal; the
  registry update is correctly WI-12's. The one gap: the **roadmap's WI-12
  description is stale** (still says "keep the legacy read-fallback"), and two
  `device_id.dart` doc items were parked under WI-2 that this plan now rewrites —
  both folded into Phase 3.

Nothing here forces the implementer to make a significant design decision; the
remaining work is mechanical against the enumerated coordinates.

## Summary

Closed **SC-5** by removing the `$meta` `device_id` path entirely (greenfield → no
read-fallback to keep). The local `DEVICE_ID` file is now the sole identity store,
so `device_id` never reaches synced `$meta` and a device can no longer adopt a
peer's identity via `$meta` LWW.

- **Deletion:** removed `MetaStore.putDeviceId`/`getDeviceId`/`deviceIdKey`;
  replaced `DeviceId.load(meta)` with a pure static `DeviceId.generate()`
  (now exported from `kmdb.dart` so the CLI shares one algorithm); made
  `ensureDeviceId` file-only; dropped the `$meta` write from `reassignDeviceId`;
  redirected `storeInfo()` to `_engine.deviceId` (Q2). No `$meta` device_id
  reference remains in code or dartdoc.
- **Q2 (settled in review):** `storeInfo` reads the engine's id, not the file. In
  the single-phase `open()+bare ensureDeviceId()` pattern (no production caller)
  it now honestly reports `'00000000'`, matching the SSTables — the old `$meta`
  read had *masked* that. Not a regression.
- **Tests:** rewrote `device_id_test.dart` (persistence re-homed onto the file);
  updated `meta_store_test.dart`, `meta_store_encryption_test.dart`,
  `reassign_device_id_test.dart`. The SC-5 regression asserts the key's *absence*
  deterministically via `MetaStore.symbolicKey('device_id')` across four files,
  including under an encryption provider and post-reassign.
- **Docs:** rewrote the `device_id` registry entry (`$$`-free sole-store, with the
  durability trade-off + §08 durable-storage enhancement noted); fixed
  now-falsified "device_id in `$meta`" claims in §04/§11/§12/§31; ticked WI-12 on
  the roadmap. §04/§08's aspirational "Keychain" prose was deliberately left to
  **WI-2**.
- **QA** additionally fixed four stale `$meta` doc-comments the plan's enumerated
  list missed (three on the public API surface).

**Verification:** `make pre_commit` green (2419 kmdb tests, analyze clean across 7
packages, license_check); `kmdb_cli` 1176 tests green; `make coverage` 94.8%
(`meta_store.dart`/`device_id.dart` 100%, `kv_store_impl.dart` 98.3%). `kmdb-qa`
signed off.
