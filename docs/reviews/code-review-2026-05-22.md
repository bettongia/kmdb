# KMDB Code Review — 2026-05-22

**Reviewer:** Claude (Opus 4.7), full-codebase review
**Scope:** Production-readiness, data-integrity/durability, code quality,
architectural concerns, and `docs/spec` alignment.
**Focus per request:** *Can users trust KMDB not to destroy their data?*

---

## 1. Executive summary

KMDB is an ambitious, well-organised, and in many places genuinely high-quality
LSM document database. The layering is clean, the public API is thoughtful, doc
comments are thorough, the analyzer is clean, and **1264 core tests pass** (9
skipped). On surface metrics it looks close to production-ready.

**However, it is not yet safe to trust with valuable data.** The review found a
**confirmed, reproducible, silent data-loss bug** in crash recovery, plus a
cluster of related durability gaps that all share a single root cause: the
durability/ordering guarantees the design depends on are **not actually
enforced**, and the test suite is **structurally incapable of detecting that**,
because the in-memory test adapter makes every write instantly durable and never
loses buffered data.

In other words: the parts of KMDB that exist to protect data during a crash are
the least-tested and currently the most broken parts of the system.

The headline issues are fixable and mostly localised. None require
re-architecting. But until the durability path is corrected *and* tested against
a fault-injecting adapter, the answer to "can users trust KMDB not to destroy
their data?" is **no**.

### Severity overview

| # | Severity | Issue | Data loss? |
|---|----------|-------|-----------|
| C1 | 🔴 Critical | Post-flush WAL writes silently destroyed on crash recovery (**reproduced**) | Yes, silent |
| C2 | 🔴 Critical | Manifest `VersionEdit` is never fsynced, yet WALs/inputs are deleted assuming it is durable | Yes |
| H1 | 🟠 High | `syncDir` implemented but never called — new files not durably linked on Linux | Yes (power loss) |
| H2 | 🟠 High | `WriteBatch` is not crash-atomic — breaks document/index consistency guarantee | Partial/torn writes |
| H3 | 🟠 High | Vault GC ref-count decode fails *dangerous*: deletes still-referenced blobs on parse hiccup | Yes (vault) |
| H4 | 🟠 High | Compaction never drops tombstones or collapses versions — unbounded space growth | No (bloat) |
| H5 | 🟠 High | Production sync lease CAS is non-atomic; safety only verified with the in-memory test adapter | Corruption risk |
| M1 | 🟡 Medium | SSTable `open()` reads whole file + no reader cache → O(db size) per read | No (perf) |
| M2 | 🟡 Medium | Non-ASCII namespace/collection names corrupt key encoding | Yes (i18n) |
| M3 | 🟡 Medium | `CURRENT` swap not fsynced (tmp + dir) | Yes (power loss) |
| — | 🟢 Low | Several doc/code drifts and dead code (see §6) | No |

---

## 2. What I reviewed

Read in depth: the entire storage engine (`wal_*`, `crash_recovery`,
`lsm_engine`, `manifest_*`, `version_edit`, `sstable_reader`,
`compaction_job`, `merge_iterator`, `storage_adapter_native/memory`,
`key_codec`, `value_codec`), the sync path (`sync_engine`,
`consolidation_coordinator`, `local_directory_adapter`, `highwater`), the vault
GC, and `kv_store_impl`. Spot-checked the query/index/cache layers and the spec
suite. Ran the analyzer (clean) and the `kmdb` test suite (pass). Wrote a
throwaway probe test to confirm C1, then removed it (reproduction included
below — it should become a permanent regression test).

Per your note, `packages/kmdb_ui` was treated as out of scope.

---

## 3. Critical data-integrity findings

### C1 — Post-flush writes are silently lost on crash recovery 🔴 (CONFIRMED)

**Any write that lands after a memtable flush but before the next clean
close/flush is permanently and silently destroyed if the process crashes.**
Because flushes occur roughly every ~30 writes / 64 KB, a long-lived database
spends almost its entire life in the vulnerable state, so in practice *the most
recent batch of writes before any crash is lost* — and `OpenResult` reports
`hadInterruptedWrites: false`, so nothing signals the loss.

**Root cause — an off-by-one in WAL retention combined with premature flush
markers:**

1. `LsmEngine.flush()` ([lib/src/engine/kvstore/lsm_engine.dart:486](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L486))
   writes the `VersionEdit` with `logNumber: _walWriter.activeSequence` (the
   *new* active WAL number after rotation). In steady state this means **the
   active WAL's own sequence number equals `maxLogNumber`**.
2. `CrashRecovery.open()` ([lib/src/engine/kvstore/crash_recovery.dart:154](packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L154))
   deletes any WAL file where `seq <= state.maxLogNumber` **without replaying
   it**. Since `activeSeq == maxLogNumber`, the active WAL — the one holding the
   unflushed writes — is deleted on every unclean reopen.
3. Independently, `flush()` writes the flush marker into the retiring WAL during
   `rotate()` *before* the SSTable is written. So even with the off-by-one
   fixed, `replayFromLastFlush` would skip everything before a trailing flush
   marker whose SSTable was never persisted.

**Reproduction** (memory adapter; `files` survive a simulated crash, only the
lock is dropped):

```dart
final adapter = MemoryStorageAdapter();
final (store, _) = await KvStoreImpl.open('/db', adapter,
    config: KvStoreConfig.forTesting(), deviceId: 'testdev1');
await store.put('ns', key1, bytes('flushed'));
await store.flush();                       // key1 -> SSTable, WAL rotated
await store.put('ns', key2, bytes('unflushed')); // key2 only in active WAL
MemoryStorageAdapter.releaseAllLocks();    // crash: no close(), no flush

final (store2, result) = await KvStoreImpl.open('/db', adapter,
    config: KvStoreConfig.forTesting(), deviceId: 'testdev1');
// OBSERVED:
//   result.hadInterruptedWrites == false   (no warning!)
//   get('ns', key1) == 'flushed'           (survived)
//   get('ns', key2) == null                (SILENTLY LOST)
```

**Why the existing tests miss it:** `crash_recovery_test.dart`'s "un-flushed WAL
records restored on reopen" test ([test/engine/crash_recovery_test.dart:79](packages/kmdb/test/engine/crash_recovery_test.dart#L79))
calls `store.close()`, which flushes by default — so it never actually exercises
WAL replay. The only true-crash test writes to the *first* WAL before any flush
(`seq=1 > maxLogNumber=0`), the one case the bug doesn't hit.

**Recommended fix:**
- Treat `logNumber` as "first WAL that may still hold unflushed data" and
  replay files with `seq >= maxLogNumber` (delete only `seq < maxLogNumber`).
- Stop using flush markers to *skip* records during recovery. Replay each
  retained WAL **in full**; re-applying already-flushed records is idempotent
  under HLC last-write-wins, so full replay is safe and removes the
  marker-ordering hazard entirely.
- Add the reproduction above as a permanent regression test, and add the
  symmetric "delete after flush then crash" case (a lost delete *resurrects*
  deleted data — equally bad).

---

### C2 — The Manifest is never fsynced, but the engine deletes data assuming it is durable 🔴

`ManifestWriter.append()` ([lib/src/engine/manifest/manifest_writer.dart:66](packages/kmdb/lib/src/engine/manifest/manifest_writer.dart#L66))
appends the `VersionEdit` and explicitly does **no fsync**. The SSTable is
fsynced first (good), but the manifest record that makes the SSTable *live* is
left in OS buffers. Meanwhile:

- `flush()` deletes the retired WAL files immediately after the un-fsynced
  manifest append ([lsm_engine.dart:556](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L556)).
- Compaction deletes its **input** SSTables immediately after the un-fsynced
  manifest append ([lsm_engine.dart:630](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L630),
  [compaction_job.dart:176](packages/kmdb/lib/src/engine/compaction/compaction_job.dart#L176)).

So there is a crash window where the data's *only* durable copy (the WAL, or the
compaction inputs) is deleted while the manifest entry that points to its
replacement is not yet on disk. On recovery the replacement SSTable is an orphan
(deleted by step 4) and the originals are gone → **total loss of that flush's /
compaction's data.**

This is *worse* for compaction than for flush, because a single compaction can
fold a large fraction of the database into one output file.

The spec's §17 failure table claims "Data loss: None" for exactly these crash
points — see §5 below. That guarantee is not met.

**Recommended fix:** fsync the manifest (and call `syncDir` on the db dir, see
H1) **before** deleting any WAL or compaction-input file. Order must be: write +
fsync new file → append + **fsync** manifest → fsync dir → only then delete old
files.

---

## 4. High-severity findings

### H1 — `syncDir` is implemented but never called 🟠

The native adapter correctly fsyncs a directory fd on Linux
([storage_adapter_native.dart:105](packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart#L105))
and its own doc says this "is required on Linux to durably persist new directory
entries." **Nothing in the engine ever calls it** (grep: only definitions, no
call sites). Consequently, on Linux, newly created SSTables, WAL files, and the
`CURRENT` rename may not survive power loss even though their contents were
fsynced — the directory entry linking them is still volatile. Combine with C2 and
a power-cut during normal operation can lose recently written SSTables that the
manifest already references.

**Fix:** call `syncDir` after creating/renaming files in `flush`, compaction,
WAL rotation, `ingestSstable`, and the `CURRENT` swap.

### H2 — `WriteBatch` is not crash-atomic 🟠

`LsmEngine.writeBatch` ([lsm_engine.dart:209](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L209))
writes each entry as a separate WAL record (each with its own fsync) with **no
begin/commit boundary**. A crash mid-batch leaves a *prefix* of the batch
durable. This directly contradicts the guarantee in `CLAUDE.md` and spec §16
that "All index writes are in the same `WriteBatch` as the document write —
always consistent," and the `writeBatchInternal` doc claim that the batch
"cannot be observed in a partial state"
([kv_store_impl.dart:347](packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L347)).
After a crash you can get a document without its `$index:` entry (or vice
versa), corrupting query results until a full reindex.

(There is also an in-process partial-visibility window: each `await` inside the
batch yields the event loop, so a concurrently scheduled `get()` can observe a
half-applied batch even without a crash.)

**Fix:** frame batches with a single atomic WAL unit — e.g. a length-prefixed
multi-record frame with one trailing checksum, applied all-or-nothing on
replay — or a begin/commit marker pair that recovery only honours when the
commit record is present.

### H3 — Vault GC can delete still-referenced blobs (fail-dangerous) 🟠

`VaultGc.sweep()` re-reads the ref count before deleting (good intent), but
`_readRefCount` returns **0 on any failure**, and `_decodeRefCount`
([vault_gc.dart:138](packages/kmdb/lib/src/vault/vault_gc.dart#L138)) is a
hand-rolled partial CBOR parser that returns `0` on *every* unexpected byte
pattern (wrong major type, key not found, truncation, ints > 16 bits, etc.).
Since `0` means "unreferenced → delete the hash directory," any encoding the
parser doesn't anticipate causes **permanent deletion of a blob that documents
still reference** — unrecoverable data loss of user binary content.

**Fix:** decode via the real `ValueCodec`/CBOR path, and make the default
**fail-safe**: if the ref count cannot be read with certainty, *do not delete*.
Deletion should require an affirmative, validated `refCount == 0`.

### H4 — Compaction never reclaims space (no tombstone drop, no version collapse) 🟠

`MergeIterator` de-duplicates only on the **full internal key**, which embeds the
HLC ([merge_iterator.dart:115](packages/kmdb/lib/src/engine/compaction/merge_iterator.dart#L115),
key layout in [key_codec.dart:152](packages/kmdb/lib/src/engine/util/key_codec.dart#L152)).
Different versions of the same user key have different HLCs, so compaction keeps
**every historical version forever** and **never drops delete tombstones**, even
when compacting to the bottom level. Reads stay correct (the read path collapses
versions at query time), but:

- Storage grows without bound under updates and deletes — a key written N times
  keeps all N copies; deleted keys keep their tombstones permanently.
- Read cost grows with version count, compounding M1.

This defeats the primary purpose of LSM compaction. For a database meant to run
for years on a user's device, this is a serious scalability/footprint problem.

**Fix:** make compaction collapse to the newest version per user key, and drop
tombstones when the output is the bottom-most level and no older version can
exist below it.

### H5 — Production sync lease CAS is non-atomic; safety only tested in memory 🟠

`LocalDirectoryAdapter.compareAndSwap`
([local_directory_adapter.dart:100](packages/kmdb/lib/src/sync/local/local_directory_adapter.dart#L100))
documents itself as a best-effort, **non-atomic** read-check-write, and notes
"tests use `MemorySyncAdapter` which provides true CAS semantics." The
consolidation lease (`ConsolidationCoordinator`) depends on CAS atomicity to
guarantee a single consolidator. So the consolidation safety property is
**verified only against an adapter that is never used in production**. On a real
NAS / SMB / Dropbox / OneDrive folder (the stated deployment targets) two devices
can both win the lease and consolidate concurrently while deleting each other's
inputs. The system is fairly tolerant (LWW + union of SSTables), but layered on
top of C2 (un-fsynced manifest) and direct writes into background-syncing cloud
folders, this is a real corruption surface.

**Fix:** either implement a genuinely atomic claim on the real adapter (e.g.
`O_CREAT|O_EXCL` exclusive-create for the lease file, which POSIX makes atomic),
or document consolidation as unsupported on non-atomic backends and gate it.
Add multi-writer contention tests against the *filesystem* adapter, not just the
memory one.

---

## 5. Performance & medium findings

### M1 — Every read can re-hash entire SSTables; no reader cache 🟡
`SstableReader.open()` validates integrity by reading **the whole file** and
hashing `0..fileSize-8` ([sstable_reader.dart:144](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L144)).
`LsmEngine.get()`/`scan()` open a **fresh reader per file on every call**
(`_openReader`, [lsm_engine.dart:986](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L986))
with no caching of the index/filter or the reader itself. A single point lookup
that falls through to L2 reads a full 20 MB file into memory and XXH64s it. This
is O(database size) per read and contradicts the 4 KB block / Bloom-filter
random-access design; the §18 P99 targets will not hold beyond toy databases.
The benchmark likely only exercises tiny datasets.
**Fix:** cache open readers (index + filter in memory), validate the footer
checksum only (cheap, 48 bytes) on open, and rely on per-block checksums
(already present) for read-time integrity.

### M2 — Non-ASCII namespace/collection names corrupt keys 🟡
`KeyCodec._toUtf8` uses `s.codeUnits` with the comment *"ASCII-safe; full UTF-8
for Phase 8"* ([key_codec.dart:213](packages/kmdb/lib/src/engine/util/key_codec.dart#L213)) —
but the project is at Phase 10. Code units > 0xFF are truncated when packed into
the namespace bytes, so a collection named with non-Latin characters produces a
corrupted, ambiguous namespace prefix (and the 255-byte length check is wrong for
multibyte). Given Bettongia's explicit i18n focus, this is a latent data-integrity
bug. **Fix:** use real `utf8.encode`/`utf8.decode`.

### M3 — `CURRENT` swap not fully fsynced 🟡
`CurrentFile.write` ([current_file.dart:67](packages/kmdb/lib/src/engine/manifest/current_file.dart#L67))
writes the temp file (the native `writeFile` uses `flush: false`) and renames,
but never fsyncs the temp before rename nor the directory after. The rename is
atomic but not durable; after power loss `CURRENT` may revert or point to a
manifest whose bytes aren't on disk. Same gap in the manifest-rotation path
([lsm_engine.dart:782](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L782)).

### Other medium notes
- `SyncEngine.sync()` ([sync_engine.dart:302](packages/kmdb/lib/src/sync/sync_engine.dart#L302))
  is documented as "on failure in push, pull is still attempted," but the code
  is `await push(); await pull();` — a push failure skips pull. Fix code or doc.
- Consolidation epoch is the wall clock ([consolidation_coordinator.dart:469](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L469)),
  which is not monotonic; the fencing token can regress across clock changes.

---

## 6. Low-severity / cleanup
- Dead code in `LsmEngine.get()`: the second `if (result != null && result.$2)`
  branches are unreachable ([lsm_engine.dart:289](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L289),
  [L301](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L301)); the
  `found` tuple flag is never used.
- `encodeInternalKey` doc says HLC is ordered "descending … emitted first"
  ([key_codec.dart:149](packages/kmdb/lib/src/engine/util/key_codec.dart#L149)),
  but it's encoded big-endian *ascending* (newest sorts last; the read path
  takes the last entry). The code is correct; the comment is misleading in a
  correctness-critical spot.
- `SyncEngine.pull` has a no-op `hwm = hwm.withCurrentHlc(hwm.currentHlc)`
  ([sync_engine.dart:290](packages/kmdb/lib/src/sync/sync_engine.dart#L290)).
- Manifest-rotation snapshot writes empty `minKey/maxKey/entryCount` for every
  file ([lsm_engine.dart:760](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L760));
  harmless today (diagnostic-only fields) but loses metadata permanently after a
  rotation.

---

## 7. Spec alignment (`docs/spec`)

Your concern is well-founded. The specs are not catastrophically stale, but they
have drifted in ways that matter — and in one case the spec actively documents a
bug.

- **§17 Crash Recovery encodes the C1 bug.** Step 5 says to "Skip any WAL file
  whose sequence number ≤ the highest `logNumber`" and replay "from their last
  flush marker" — exactly the broken rule. Its failure table claims "Data loss:
  None" for *"After SSTable fsync, before VersionEdit appended"* and for the
  compaction crash points, which C1/C2 disprove. The spec needs correcting in
  lockstep with the fix, and the durability ordering (fsync manifest + dir
  before deleting WAL/inputs) must be made explicit.
- **Durability requirements are underspecified.** Neither the spec nor the code
  requires fsyncing the manifest or calling `syncDir`; §17's "orphan cleanup
  handles it" reasoning assumes the WAL is still present, which `flush()`
  violates by deleting it first. The integrity story (§09) should state the
  required fsync ordering as a hard invariant.
- **§12 Sync** references a `.consolidation-manifest` recovery file that is
  intentionally **not implemented** (acknowledged in
  [consolidation_coordinator.dart:442](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L442)).
  Reconcile: either spec the idempotent-deletion approach actually used, or
  implement the manifest.
- **Index drift:** the `00_index.md` abstract's version history stops at v2.2
  (§24 vault); it does not mention §25 collection schemas or §27 test harness,
  both of which exist as spec files and implementations.
- **Staleness signal:** §06 storage engine, §07 WAL, §09 integrity, and §18
  concurrency were last touched 2026-03-28, while the engine changed through
  2026-05-21 (e.g. the HlcClock rewire). These are the documents most likely to
  have silently drifted and are worth a focused re-read.

What's *good*: §17 step 9 (vault recovery) is genuinely wired
([kmdb_database.dart:313](packages/kmdb/lib/src/query/kmdb_database.dart#L313));
the dirty-open flag behaviour matches the spec; the query/index/schema specs
(§13/§16/§25, updated April–May) track the code well.

---

## 8. Testing assessment — the root cause behind the durability bugs

The suite is large and passes (1264 `kmdb` tests, analyzer clean), and the
golden-path coverage is good. But it has a **structural blind spot that hides the
entire class of bugs in §3–§4**:

- `MemoryStorageAdapter` makes `syncFile`/`syncDir` no-ops and **never loses
  buffered data** — a "crash" only clears the lock. So WAL/manifest fsync
  ordering, directory durability, and "deleted-the-WAL-too-early" bugs are all
  *invisible* by construction. The tests can prove logical correctness but not
  durability.
- Crash tests don't model the realistic failure: write → flush → write → crash.

**Highest-leverage testing recommendation:** build a fault-injecting storage
adapter that (a) buffers un-fsynced writes and can discard them on a simulated
crash, (b) can reorder/lose directory entries when `syncDir` wasn't called, and
(c) can crash at arbitrary points (after SSTable write, before manifest, after
WAL delete, mid-batch, mid-compaction). Replay the §17 failure table against it
as executable assertions. This single harness would have caught C1, C2, H1, H2,
and M3.

(Coverage is claimed >90%; I did not run the full `make coverage` pass. Note that
high line coverage here coexists with zero *durability* coverage — they measure
different things.)

---

## 9. Prioritised recommendations

**Must-fix before any "production-ready" / data-trust claim:**
1. C1 — correct WAL retention (`seq < maxLogNumber`) and replay WALs in full;
   add the regression tests (put-after-flush, delete-after-flush).
2. C2 + H1 + M3 — enforce the fsync ordering invariant: write+fsync file →
   append+**fsync** manifest → **syncDir** → only then delete WAL/inputs/tmp.
3. H3 — make vault GC fail-safe (decode via real codec; never delete on
   uncertainty).
4. Build the fault-injection adapter (§8) and gate the durability fixes on it.

**Should-fix before scaling / multi-device GA:**
5. H2 — atomic `WriteBatch` framing in the WAL.
6. H4 — real compaction (version collapse + tombstone drop).
7. H5 — atomic lease on the real adapter, or gate consolidation.
8. M1 — reader caching + footer-only validation on open.
9. M2 — real UTF-8 namespace encoding.

**Housekeeping:**
10. Rewrite §17 (and tighten §09/§12) to match the corrected behaviour; refresh
    the spec index version history; clear the §6 dead code/doc drifts.

### Implementation work

Plans are being authored in `plans/` (per `plans/README.md`) to resolve the
findings above, in priority order. Status of each, with notes that surfaced
while preparing them:

1. **C1 — crash-recovery WAL replay** →
   [plans/plan_crash_recovery_wal_replay.md](plans/plan_crash_recovery_wal_replay.md)
   *(Status: Investigated — ready to implement first).*
   - The fix is **recovery-side only**; the write path (the WAL itself) is
     correct, so no change to how data is logged is needed — recovery just has to
     stop deleting and start replaying the active WAL.
   - The trigger surface is **broader than flush**: every `VersionEdit` records
     `logNumber = activeSequence`, so compaction, sync **ingest** (a sync *pull*
     can lose local unflushed writes), and manifest rotation all arm the same
     bug. The plan's regression suite covers each trigger.
   - Two combining defects: the `<=`/`<` off-by-one **and** flush markers being
     written before their SSTable is durable. The fix removes marker-based
     skipping in favour of full WAL replay (idempotent under HLC LWW).
   - **Testable with the existing in-memory adapter** — the bug is recovery
     deleting genuinely-durable data, which the memory adapter models faithfully.
     So C1 and its tests can land immediately, without waiting on the harness
     below.

2. **C2 + H1 + M3 — manifest fsync & durability ordering** →
   [plans/plan_manifest_fsync_ordering.md](plans/plan_manifest_fsync_ordering.md)
   *(Status: Investigated — sequenced **after** C1).*
   - H1 (`syncDir` never called) and M3 (`CURRENT` swap not fsynced) are folded
     in deliberately: fsyncing the manifest is meaningless on Linux unless the
     directory entry is also synced, so the three cannot be correctly fixed
     apart. They share one root cause and one fix.
   - Most of the work is **inserting missing `syncFile`/`syncDir` calls** — flush
     and compaction already order *append-before-delete*; the only genuine
     re-ordering hazard is manifest rotation (publish `CURRENT` only after the new
     manifest is durable, else a crash loses the entire level map). No
     `StorageAdapter` interface change is needed.
   - **Caveat — this plan cannot use the in-memory adapter.** Its
     `syncFile`/`syncDir` are no-ops and a "crash" never loses buffered data, so
     the entire C2/H1/M3 bug class is invisible to it. The plan therefore makes
     **building a `FaultyStorageAdapter`** (the fault-injection harness from §8)
     its Step 0 — modelling pending-vs-fsynced content, directory-entry
     durability, and a `crash()` that discards un-synced state. This harness is
     the gating dependency for all durability testing and is reusable for C1's
     mid-flush case and any future ordering work; each C2 regression test is
     specified to be confirmed *failing before the fix, passing after*.
   - One accepted cost: an extra manifest `syncFile` plus one or two `syncDir`
     calls per flush/compaction/ingest. Marginal against the fsyncs already on
     those paths; can be batched later if profiling demands.

3. **H3 — vault GC / recovery fail-safe ref counts** →
   [plans/plan_vault_gc_failsafe.md](plans/plan_vault_gc_failsafe.md)
   *(Status: Investigated — independent of C1/C2; land before document
   versioning).*
   - Investigation found the ref count is decoded in **three** places: the
     interceptor already uses the real `ValueCodec` (correct), while `VaultGc`
     **and** `VaultRecovery` each hand-roll their own CBOR micro-parser that
     returns `0`/"no ref" on any surprise — and both then permanently delete.
     `VaultRecovery._hasKvRef` is worse: it `catch (_) => false`, so a decode
     *exception* also reads as "unreferenced," and this runs on every unclean
     open.
   - The fix unifies all readers on **one fail-safe helper** and inverts the
     default: deletion requires a positive determination of zero references
     (absent counter, which the protocol guarantees means zero, or a decoded
     `refCount == 0`); an **undecodable** counter is treated as *referenced* and
     retained. Removes ~120 lines of duplicated hand-rolled CBOR.
   - **Coordinates with document versioning**
     ([plans/plan_document_versioning.md](plans/plan_document_versioning.md)),
     which edits the same files and adds `$ver:` entries as new ref sources with
     compaction-time decrements. H3 should land first so versioning reuses the
     shared helper instead of adding a fourth decoder; the versioning plan's
     "scan `$ver:` for refs" wording should be reconciled to the counter-based
     model.
   - Flags a **related, separately-scoped** risk: `VaultRecovery` deletes
     "manifest present, no ref" objects as orphans, which also matches a
     freshly-synced stub whose referencing document hasn't arrived yet — a
     sync-ordering data-loss to address in its own follow-up.

4. **H5 — sync lease CAS atomicity** →
   [plans/plan_sync_cas_atomicity.md](plans/plan_sync_cas_atomicity.md)
   *(Status: Investigated)*, plus its testing companion
   **harness mixed-storage + behavioural cloud simulation** →
   [plans/plan_harness_mixed_storage.md](plans/plan_harness_mixed_storage.md)
   *(Status: Investigated)*.
   - Investigation reframed H5: CAS atomicity is a property of the *backend's
     consistency model*, not just adapter code — the same `LocalDirectoryAdapter`
     can be atomic on a real disk (via `O_EXCL` / advisory locks) but **cannot**
     be on a cloud-synced folder. So the fix is a written CAS contract, an honest
     per-adapter atomic-CAS capability, and a coordinator that **skips
     consolidation** (loss-free, since it is only an optimisation) when atomicity
     isn't guaranteed — backed by a reusable conformance/**contention** test
     every adapter must pass.
   - These two plans directly answer the review's §8 testing gap: H5 ships the
     adapter contention test; the harness plan adds per-device adapters, a
     `CloudProfile` abstraction, and a **behavioural cloud-API simulator**
     framework (fake `http.Client` driving the *real* adapter) so eventual
     consistency and CAS atomicity are tested deterministically in CI, with real
     services reserved for pre-release. The framework is **general across
     providers** (Drive, Dropbox, iCloud, …).
   - Sequenced **H5 → harness mixed-storage → `plan_google_drive_sync.md`**; the
     Drive plan was updated to depend on both, ship a Drive simulator +
     `CloudProfile`, and verify the open atomicity risk that **Drive permits
     duplicate filenames**, so a name-keyed lease create may not be exclusive.

5. **H2 — atomic `WriteBatch`** →
   [plans/plan_writebatch_atomicity.md](plans/plan_writebatch_atomicity.md)
   *(Status: Investigated — sequenced after C1; complements C2).*
   - Confirmed the batch is non-atomic two ways: across a crash (each entry is a
     separate, separately-fsynced WAL record with no group boundary) **and**
     in-process (the loop awaits between memtable mutations, so a concurrent
     `get()` can see a half-applied batch). Also found the surrounding
     generation-counter and namespace-registry writes are *separate* engine ops,
     so a single user write is up to four un-grouped WAL records today.
   - Fix is a single **batch frame** (one checksum, one append, **one fsync**) +
     synchronous memtable application — which makes the batch all-or-nothing and,
     as a bonus, collapses N fsyncs into one. Recommends folding the meta-writes
     into the same frame so a user write is one atomic unit, and keeps the WAL
     decoder back-compatible with legacy individual records.
   - Fully **CI-testable** with the in-memory adapter (truncate the frame →
     recovery drops the whole batch), so no §28 release-checklist entry is needed.

6. **H4 — compaction space reclamation** →
   [plans/plan_compaction_reclamation.md](plans/plan_compaction_reclamation.md)
   *(Status: Investigated).*
   - Investigation split this into two operations with very different safety,
     which the review's one-line fix had conflated. **Version collapse** (drop
     superseded versions per key) is safe at *any* compaction level because reads
     re-merge all levels — a large, low-risk win. **Tombstone GC** is *not*: it is
     only safe in an all-levels compaction (KMDB levels do not imply recency, so
     "bottom level" is insufficient) **and**, in a synced database, only past a
     sync horizon — otherwise dropping a tombstone lets a late-syncing peer
     resurrect deleted data.
   - The principled horizon is `min(currentHlc)` across all devices' high-water
     marks (everyone has synced past it); compaction must be *given* that horizon
     since it doesn't read the sync folder today. Plan sequences collapse first,
     gated tombstone GC second.
   - It is the **general reclamation framework** the document-versioning feature
     plugs into: `$ver:` namespaces are exempt from collapse and use a keep-N /
     retention policy instead. That feature's plan was hardened in lockstep —
     dependencies on H2 (atomic `$ver:` writes), H3 (fail-safe vault refs), and
     H4; a soft-delete model (delete recorded as a `$ver:` version); and an
     explicit **full-drain guarantee** (keep-N is a floor for *live* docs only, so
     deleted documents reclaim to zero residue rather than leaking storage).
   - Core no-resurrection case is **CI-testable** (drop a tombstone, ingest a
     crafted older-HLC SSTable, assert no resurrection); the multi-device case is
     covered by the harness once `plan_harness_mixed_storage.md` lands.

7. **M1 — SSTable reader caching** →
   [plans/plan_sstable_reader_cache.md](plans/plan_sstable_reader_cache.md)
   *(Status: Investigated).*
   - The fix splits cleanly: a **table cache** of open readers (footer + index +
     filter) is the high-value, **format-change-free, backward-compatible** part —
     it turns the whole-file hash from a per-*read* cost into a one-time
     per-*file* cost. "Footer-only cheap open" is deferred to a second phase
     because the footer/index/filter are currently covered only by the whole-file
     hash, so skipping it would need per-section checksums (a format change).
   - Distinct from the §15 query-layer cache; named `TableCache` to avoid
     confusion. Eviction is tied to level-map mutations (flush/compaction/ingest/
     rotation/rename). Benchmark-measured; no §28 entry needed.

8. **M2 — real UTF-8 namespace encoding** →
   [plans/plan_utf8_namespace_encoding.md](plans/plan_utf8_namespace_encoding.md)
   *(Status: Investigated).*
   - Investigation found the namespace is encoded to bytes in **three divergent
     paths** (`KeyCodec._toUtf8`, `WalRecord._toUtf8`, and `LsmEngine`'s prefix
     builders calling `codeUnits` directly) that must be unified on one UTF-8
     helper or non-ASCII scans silently miss. Keys are ASCII UUIDv7 hex and are
     unaffected — only namespaces (collection names) carry the bug.
   - **Backward-compatible by construction:** ASCII namespaces are byte-identical
     under `utf8.encode`, so every working database is unchanged (no migration);
     only the currently-corrupted non-ASCII case changes. The one new design
     choice is NFC normalisation of namespaces at the boundary (recommended).

9. **§6 code & doc tidy-up** →
   [plans/plan_code_doc_tidyup.md](plans/plan_code_doc_tidyup.md)
   *(Status: Investigated).*
   - Clears the §6 dead-code / doc-drift items in one small PR. Two carry
     subtleties flagged in the plan: the `LsmEngine.get()` `found` flag must keep
     its three-state (absent vs tombstone vs hit) semantics — collapsing it to a
     plain `Uint8List?` would resurrect deleted data — and the manifest-rotation
     metadata loss is documented now, with the proper fix (track `SstableMeta`)
     deferred as it exceeds tidy-up.
   - (The earlier §26 spec-number collision is avoided going forward by a
     convention in `plans/README.md`: spec section numbers are assigned at
     creation time, not pre-reserved in plans.)

---

## 10. Note on `packages/kmdb_ui`

Not reviewed in depth per your direction. Given the durability work above is
where the engineering risk concentrates, extracting the UI into its own
repository and keeping the CLI as the primary management tool is a reasonable
call — it would let the core + CLI move at their own cadence and shrink the
surface that any future durability/migration changes have to keep in step with.

---

### Closing

The bones of KMDB are good and the bugs above are localised and fixable. The gap
between "looks production-ready" and "is production-ready" here is almost entirely
the durability path — and the reason it went unnoticed is that the test
infrastructure cannot see it. Fix the recovery/fsync ordering, make the vault GC
fail-safe, and stand up a fault-injection harness, and the data-trust story
becomes defensible. Until then, treat KMDB as not-yet-crash-safe.
