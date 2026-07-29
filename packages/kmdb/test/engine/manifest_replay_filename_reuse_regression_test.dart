// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Engine-level, end-to-end regression for the manifest-replay data-loss bug
/// fixed by `plan_manifest_replay_added_removed_ordering.md`.
///
/// `ManifestReader._fromEdits` folds each `VersionEdit`'s `added` list into
/// `liveMeta[level][filename]` before folding `removed`. Both lists are keyed
/// by `(level, filename)`. When a single edit contains **the same
/// `(level, filename)` pair in both lists** — which happens when a
/// `_compactAll` merge produces an output whose HLC range exactly reproduces
/// one of its own inputs' range (an in-place overwrite: the surviving,
/// unchanged input keeps its original name and level) — the pre-fix ordering
/// (`added` then `removed`) nets that entry to *absent*: the `removed` loop
/// deletes the very entry the `added` loop just inserted. Crash recovery's
/// orphan sweep then deletes the still-live, on-disk SSTable, and every key
/// stored only in that file is unrecoverably lost on reopen.
///
/// ## Why the trigger below (and not a naive "single L1 file" compaction)
///
/// `_compactL0ToL1` always writes to `outputLevel = 1` while its inputs carry
/// `level: 0` (new flush data) or, when pre-existing, `level: 1` — but any
/// contribution from a genuinely new L0 write always advances the HLC
/// maximum (this device's clock is monotonic), so the merged range can never
/// exactly reproduce a pre-existing L1 file's own (older, narrower) range.
/// `_compactL1ToL2` always removes at `level: 1` and adds at `level: 2` —
/// different levels, so even when a single L1 input's name is reused
/// verbatim, `added`/`removed` land in different `liveMeta` buckets and the
/// pre-fix ordering bug never manifests (verified empirically while building
/// this test — see the plan's implementation notes). A genuine
/// `(level, filename)` collision requires `_compactAll`, whose
/// `outputLevel: 2` can coincide with an L2 **input**'s own level, *and*
/// requires that input's range to survive the merge completely unchanged.
///
/// This test constructs exactly that: two keys (A, B) flushed together
/// produce a single L2 file F whose range is `[hlcA, hlcB]`. A third,
/// unrelated key C is then ingested as a foreign L0 SSTable with an HLC
/// **strictly between** `hlcA` and `hlcB` (using an injected, fully
/// controlled clock — no tombstone GC or key-superseding subtlety is
/// needed). Ingesting C immediately triggers `_compactAll` (the
/// single-file-collapse shortcut, `singleFileThresholdBytes`), merging F and
/// C: since C's HLC falls entirely inside F's existing range, the merged
/// output's range is unchanged from F's own — reusing F's exact filename —
/// while F itself is also consumed as an input (`removed`, same level 2).
/// One `VersionEdit` now carries `(level: 2, filename: F)` in both lists.
///
/// The database then crashes (via [FaultyStorageAdapter.crash], simulating a
/// power loss with no further writes) and reopens. Pre-fix, the reopen's
/// manifest replay drops F from `state.allFiles`, and the orphan sweep
/// deletes the still-live `.sst` file from disk — keys A, B, and C (all of
/// which live only in F) become permanently unreadable. Post-fix, F survives
/// replay and its file remains on disk.
///
/// A [FaultyStorageAdapter] is used rather than the in-memory adapter per
/// the 2026-05-22 review (`docs/reviews/code-review-2026-05-22.md`): the
/// orphan sweep's `listFiles` + `deleteFile` sequence must run against a
/// real, crash-consistent directory view, which the in-memory adapter does
/// not model.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/crash_recovery.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/sync/hlc_clock.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _dbDir = '/db';
const _deviceId = 'testdev1';

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);
String _key(int n) => SequentialKeyGenerator(start: n).next();

/// Opens a [KvStoreImpl] against [adapter] with [clock] injected directly, so
/// the wall-clock/HLC values seen by the engine are fully deterministic and
/// under the test's control (needed to place the foreign entry's HLC exactly
/// between two existing keys' HLCs).
Future<KvStoreImpl> _openWithClock(
  FaultyStorageAdapter adapter,
  HlcClock clock, {
  required KvStoreConfig config,
}) async {
  final recovery = CrashRecovery(adapter: adapter, config: config);
  final (engine, recoveryResult) = await recovery.open(
    _dbDir,
    deviceId: _deviceId,
    clock: clock,
  );
  final meta = MetaStore(engine);
  engine.setMetaStore(meta);
  final hadUnclosedSession = await meta.getDirtyFlag();
  return KvStoreImpl.forTesting(
    engine,
    meta,
    config,
    dirtyFlagPresent: hadUnclosedSession || recoveryResult.hadInterruptedWrites,
  );
}

void main() {
  test('a filename reused by a same-level _compactAll merge survives a crash '
      'and reopen (data-loss regression)', () async {
    final adapter = FaultyStorageAdapter();
    var wallMs = 1000;
    final clock = HlcClock(wallClock: () => wallMs);

    // Tiny thresholds force determinism: l0CompactionTrigger/l1MaxBytes of
    // 1 collapse every flush straight down to L2 with no merging (so F's
    // range is exactly [hlcA, hlcB], nothing wider); a generous
    // singleFileThresholdBytes makes the _compactAll shortcut fire the
    // moment a second file (the ingested foreign entry) appears.
    final config = KvStoreConfig(
      memtableSizeBytes: 4096,
      l0CompactionTrigger: 1,
      l1MaxBytes: 1,
      l2MaxBytes: 64 * 1024,
      singleFileThresholdBytes: 64 * 1024,
      fsyncOnWrite: true,
      tableCacheSize: 16,
    );
    final store = await _openWithClock(adapter, clock, config: config);

    // A and B land in the same flush -> a single L2 file F, range
    // [hlcA=1000, hlcB=5000].
    final keyA = _key(0);
    final keyB = _key(1);
    await store.put('ns', keyA, _bytes('vA'));
    wallMs = 5000;
    await store.put('ns', keyB, _bytes('vB'));
    await store.flush();

    // Build a foreign SSTable G: one entry for a third, unrelated key C at
    // hlc=3000 -- strictly between hlcA and hlcB. Ingesting it triggers
    // _compactAll, merging F and G. Because C's HLC falls entirely inside
    // F's existing range, the merged output's range is UNCHANGED from F's
    // own -- reusing F's exact filename at the same level (2) that F
    // itself occupied as a `removed` input. One VersionEdit now carries F's
    // (level, filename) pair in both `added` and `removed`.
    final keyC = _key(2);
    const interiorHlc = Hlc(3000, 0);
    final gWriter = SstableWriter();
    final internalKeyC = KeyCodec.encodeInternalKey(
      'ns',
      KeyCodec.keyToBytes(keyC),
      interiorHlc,
      RecordType.put,
    );
    gWriter.add(internalKeyC, _bytes('vC'));
    const gFilename = 'foreign1-0000000000000BB8-0000000000000BB8.sst';
    await store.ingestSstable(gFilename, gWriter.finish());

    // Sanity check: all three keys are readable from the live engine
    // (reads here go through the in-memory `_levels` map maintained
    // directly by the engine, not through manifest replay, so this
    // succeeds regardless of the bug).
    expect(await store.get('ns', keyA), equals(_bytes('vA')));
    expect(await store.get('ns', keyB), equals(_bytes('vB')));
    expect(await store.get('ns', keyC), equals(_bytes('vC')));

    // Simulate a crash immediately after the merge commits -- no further
    // writes, no clean close(). This is the realistic failure window: the
    // compaction's VersionEdit (containing the collision) is the last
    // record in the manifest when the process dies.
    adapter.crash();

    // Reopen: this is where CrashRecovery replays the manifest and runs
    // the orphan sweep (crash_recovery.dart step 4), deleting any `.sst`
    // file not present in the replayed state.
    final store2 = await _openWithClock(adapter, clock, config: config);

    // Pre-fix: `state.allFiles` incorrectly omits the reused filename, so
    // the orphan sweep deletes the still-live SSTable, and A/B/C -- all of
    // which live only in that one file -- become permanently unreadable.
    // Post-fix: the file survives replay and every key is still readable.
    expect(
      await store2.get('ns', keyA),
      equals(_bytes('vA')),
      reason: 'key A lived only in the reused-filename SSTable',
    );
    expect(
      await store2.get('ns', keyB),
      equals(_bytes('vB')),
      reason: 'key B lived only in the reused-filename SSTable',
    );
    expect(
      await store2.get('ns', keyC),
      equals(_bytes('vC')),
      reason: 'key C lived only in the reused-filename SSTable',
    );

    await store2.close();
  });
}
