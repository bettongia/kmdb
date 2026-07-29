// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Mandatory cross-device regression for the 0.10.01 WI-14 fix (move the
/// dirty-open flag off synced `$meta` into the local-only `$$dirtystate`
/// namespace — see [MetaStore.kDirtyStateNamespace]'s doc comment).
///
/// ## Why this test, and not a lighter construction-only proof
///
/// The plan's first pass proposed a lighter recipe ("device B writes, closes
/// cleanly, push; reopen device A and assert the flag survives"), which the
/// kmdb-plan-reviewer rejected as vacuous: [MetaStore.getDirtyFlag] is read
/// inside `KvStoreImpl.open()`, strictly *before* any post-open `pull()`/
/// ingest the application performs. A recipe that only ingests the peer's
/// tombstone *after* reopening A never touches the value the flag read
/// already consumed — it passes both before and after the fix and guards
/// nothing.
///
/// The actual failing interleaving (reviewer's second pass) requires the LWW
/// erasure to happen *during A's own live dirty session, before the crash*:
///
/// 1. A opens, writes (dirty flag set at `HLC_A`).
/// 2. **While A is still live**, a synthetic SSTable simulating a peer's
///    clean-close `clearDirty` — a `$meta` delete-tombstone for
///    `MetaStore.symbolicKey('dirty')` at an HLC strictly greater than
///    `HLC_A` — is ingested via [KvStoreImpl.ingestSstable] (the real
///    trust/merge boundary `pull()` uses).
/// 3. A crashes (no clean `close()`).
/// 4. A reopens. Pre-fix, the higher-HLC tombstone won LWW over A's own
///    `dirty` key *before* the crash, so the merged local state has no dirty
///    entry — `getDirtyFlag()` returns `false`, a silent false-negative (the
///    dangerous direction: `onIndexRebuildRequired` never fires and stale
///    derived indexes are served without any error). Post-fix, `dirty` lives
///    in the local-only `$$dirtystate` namespace, the ingested `$meta`
///    tombstone never touches it, and the flag survives.
///
/// This test **must fail** if [MetaStore.kNamespace] is substituted back into
/// `getDirtyFlag`/`setDirty`/`clearDirty`/`appendDirtyFlag` in place of
/// [MetaStore.kDirtyStateNamespace] — that reversion was manually verified
/// during implementation (see the plan's checklist) and must not be
/// re-verified by weakening this test.
///
/// ## Why a custom [KvStoreConfig], not [KvStoreConfig.forTesting]
///
/// `forTesting()`'s `singleFileThresholdBytes: 8 * 1024` is easily exceeded —
/// in the wrong direction — by this test's tiny fixture data, which triggers
/// [LsmEngine]'s "single-file shortcut" (collapse everything to one L2 file)
/// on *every* flush/ingest. That is orthogonal to what this test is proving,
/// but it interacts badly with a single-entry, never-updated local-only
/// SSTable: a second all-levels compaction round recomputes the exact same
/// output filename (identical HLC range) as an *input* to that round, and
/// [VersionEdit] then lists that filename in both `added` and `removed` —
/// which `ManifestReader.replay`'s added-then-removed-per-edit order nets to
/// "removed", silently dropping the file on the next reopen. This is a
/// pre-existing, WI-14-unrelated manifest/compaction edge case (reported
/// separately, not fixed here — out of this plan's scope). Setting
/// `singleFileThresholdBytes: 0` disables that shortcut for this test, so
/// only the ordinary L0→L1 trigger runs and the scenario stays confined to
/// the actual mechanism under test: L0's "search newest-first" read order.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

const _dbDir = '/db';
const _deviceIdA = 'devicea1';

/// See the library doc comment's "Why a custom KvStoreConfig" section for why
/// this does not simply use [KvStoreConfig.forTesting].
const _testConfig = KvStoreConfig(
  singleFileThresholdBytes: 0,
  fsyncOnWrite: false,
  tableCacheSize: 16,
);

Future<(KvStoreImpl, OpenResult)> _openA(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: _testConfig,
      deviceId: _deviceIdA,
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('MetaStore dirty-open flag — cross-device LWW erasure (WI-14)', () {
    test(
      'a peer tombstone for the dirty key, ingested during A\'s own live '
      'session, must not erase A\'s dirty flag across a subsequent crash',
      () async {
        final adapter = MemoryStorageAdapter();
        final (storeA, openResultA1) = await _openA(adapter);
        expect(openResultA1.hadUnclosedSession, isFalse);

        // A's first write sets its dirty flag at an internal HLC ("HLC_A")
        // generated from the engine's wall-clock HLC. We don't observe
        // HLC_A directly, but it is bounded above by "now".
        await storeA.put('tasks', KeyCodec.generate(), _bytes('v'));
        expect(await storeA.meta.getDirtyFlag(), isTrue);

        // Flush the memtable to an L0 SSTable before ingesting the peer's
        // tombstone below. This is load-bearing, not incidental:
        // LsmEngine.get() checks the *active memtable first* and returns
        // immediately on a hit — it never compares HLCs against L0 at read
        // time. If A's dirty entry were still sitting in the (unflushed)
        // memtable when the tombstone is ingested as a separate L0 file, the
        // memtable entry would shadow the ingested tombstone unconditionally,
        // regardless of which HLC is higher, and the erasure this test
        // exists to catch would never occur — a false pass that would make
        // this test vacuous in exactly the way the plan's first-pass recipe
        // was. Flushing moves A's own entry onto disk as an L0 file *before*
        // the tombstone's L0 file is appended, so LsmEngine.get()'s "L0 —
        // search newest-first (last in list)" rule (see lsm_engine.dart)
        // finds the just-ingested tombstone first and shadows A's entry
        // underneath it — the actual LWW-by-append-order mechanism the real
        // sync/ingest path exercises.
        await storeA.flush();

        // Build a synthetic SSTable carrying a $meta delete-tombstone for the
        // `dirty` symbolic key, at an HLC ahead of "now" by an offset large
        // enough to be strictly greater than HLC_A regardless of exact
        // wall-clock timing between the two calls above, but comfortably
        // under LsmEngine's ClockSkewException tolerance (60s — see
        // HlcClock.update, which advanceClock/ingestAt0 goes through). It is
        // also (trivially) above the tombstone floor — Hlc(0, 0) on a fresh
        // database that has never GC'd a tombstone, so the floor check in
        // LsmEngine.ingestAt0 is skipped entirely (floor.encoded == 0).
        final tombstoneHlc = Hlc(
          DateTime.now().millisecondsSinceEpoch + 30000,
          0,
        );
        final dirtyKeyBytes = KeyCodec.keyToBytes(
          MetaStore.symbolicKey('dirty'),
        );
        final internalKey = KeyCodec.encodeInternalKey(
          MetaStore.kNamespace, // '$meta' — the synced namespace the pre-fix
          // code stored `dirty` in. This must stay '$meta' regardless of the
          // fix, because the whole point is to simulate a peer's synced
          // clearDirty landing in the *synced* namespace — $$dirtystate is
          // never ingested (isLocalOnly), so a tombstone written there would
          // not even reach this test's assertion.
          dirtyKeyBytes,
          tombstoneHlc,
          RecordType.delete,
        );
        final writer = SstableWriter()..add(internalKey, Uint8List(0));
        final tombstoneSstable = writer.finish();
        final tombstoneFilename = SstableInfo.flushName(
          'peerdev1', // a different device's ID — this is simulating a pull.
          tombstoneHlc,
          tombstoneHlc,
        );

        // Ingest while A's session is still live. This ordering is
        // load-bearing (see the library doc comment): the erasure this test
        // proves is closed must be attempted *during* A's own dirty session,
        // before the crash — not after A reopens, by which point
        // getDirtyFlag() would already have consumed the pre-ingest value.
        await storeA.ingestSstable(tombstoneFilename, tombstoneSstable);

        // Simulate a crash: release the lock without calling close(), so no
        // clearDirty is ever issued by A itself.
        MemoryStorageAdapter.releaseAllLocks();

        // Reopen A.
        //
        // Pre-fix (dirty flag stored in $meta): the ingested tombstone, at a
        // higher HLC than A's own setDirty, wins plain last-write-wins over
        // A's own `dirty` entry — the merged local state has no `dirty` key,
        // so getDirtyFlag() reads false. This is the silent false-negative:
        // onIndexRebuildRequired never fires and A serves queries against
        // stale derived indexes without any error.
        //
        // Post-fix (dirty flag stored in the local-only $$dirtystate
        // namespace): the ingested $meta tombstone never touches it — A's own
        // dirty flag survives the crash untouched.
        final (storeA2, result) = await _openA(adapter);
        expect(
          await storeA2.meta.getDirtyFlag(),
          isTrue,
          reason:
              'the dirty flag must survive an ingested \$meta tombstone for '
              'the same symbolic key — it must live in a local-only '
              'namespace (\$\$dirtystate), never in synced \$meta',
        );
        expect(result.hadUnclosedSession, isTrue);
        await storeA2.close();
      },
    );
  });
}
