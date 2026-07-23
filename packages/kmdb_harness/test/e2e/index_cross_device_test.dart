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

/// Cross-device regression test for 0.10.01 WI-11 / SC-10.
///
/// Before the fix, secondary-index state (`status`, `builtThrough`) lived in
/// the synced `$meta` namespace under a device-independent key. A device that
/// pulled a peer's `$meta` inherited `status: current` for an index it never
/// built locally, then scanned its own empty `$$index:*` namespace and
/// silently returned zero rows for present, matching documents. The fix moves
/// this state to the local-only `$$indexstate` namespace (see
/// `IndexManager.kIndexStateNamespace`'s doc comment).
///
/// This is the single-device equivalence test's cross-device sibling (see
/// `packages/kmdb/test/query/index_full_scan_equivalence_test.dart`): rather
/// than comparing the index path against a full scan on one device, it
/// compares one device's index-scan results against a *peer's*, after a real
/// push/pull sync. Runs under `e2e` (Q-E) because it exercises the full sync
/// pipeline, not just in-memory query logic.
@Tags(['e2e'])
library;

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

/// A minimal codec for `Map<String, dynamic>` documents.
final class _MapCodec implements KmdbCodec<Map<String, dynamic>> {
  const _MapCodec();

  @override
  Map<String, dynamic> decode(Map<String, dynamic> json) => json;

  @override
  Map<String, dynamic> encode(Map<String, dynamic> value) =>
      Map.of(value)..remove('_id');

  @override
  String keyOf(Map<String, dynamic> value) => value['_id'] as String;

  @override
  Map<String, dynamic> withKey(Map<String, dynamic> value, String key) => {
    ...value,
    '_id': key,
  };
}

const _codec = _MapCodec();

/// Waits until the `items`/`city` index on [db] reaches [IndexStatus.current],
/// issuing a throwaway warm-up query first so a lazy build is actually
/// triggered (see `index_query_test.dart`'s `openWithCurrentIndex`).
Future<void> _warmCityIndex(
  KmdbDatabase db,
  KmdbCollection<Map<String, dynamic>> col,
) async {
  await col.where(Field('city').equals('__warm__')).get();
  for (var i = 0; i < 50; i++) {
    final state = await db.indexManager.getOrActivate('items', 'city');
    if (state.status == IndexStatus.current) break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  test('a device that pulls a peer\'s synced documents, with the same index '
      'declared locally, returns the same indexed-query row set as the peer '
      '(SC-10 regression)', () async {
    final cloud = MemorySyncAdapter();
    final indexes = [IndexDefinition('items', 'city')];

    // ── Device A: writes docs, builds the index, pushes. ────────────────
    final localA = MemoryStorageAdapter();
    final dbA = await KmdbDatabase.open(
      path: '/dbA',
      adapter: localA,
      deviceId: 'aaaaaaaa',
      indexes: indexes,
      config: KvStoreConfig.forTesting(),
    );
    final colA = dbA.collection(name: 'items', codec: _codec);
    await colA.put({
      '_id': '01900000000070008000000000000001',
      'city': 'London',
    });
    await colA.put({
      '_id': '01900000000070008000000000000002',
      'city': 'Paris',
    });
    await colA.put({
      '_id': '01900000000070008000000000000003',
      'city': 'London',
    });

    await _warmCityIndex(dbA, colA);

    final (aResults, aPlan) = await colA
        .where(Field('city').equals('London'))
        .explainedGet();
    // Sanity check: confirm A actually exercised the index path — if this
    // assertion itself fails, the test below proves nothing.
    expect(aPlan.strategy, ScanStrategy.indexScan);
    final aIds = aResults.map((d) => d['_id'] as String).toSet();
    expect(aIds, hasLength(2));

    await dbA.store.flush();
    await dbA.push(syncAdapter: cloud, localAdapter: localA);
    await dbA.close();

    // ── Device B: pulls A's data, declares the SAME index, and queries. ──
    final localB = MemoryStorageAdapter();
    final dbB = await KmdbDatabase.open(
      path: '/dbB',
      adapter: localB,
      deviceId: 'bbbbbbbb',
      indexes: indexes,
      config: KvStoreConfig.forTesting(),
    );
    await dbB.pull(syncAdapter: cloud, localAdapter: localB);

    final colB = dbB.collection(name: 'items', codec: _codec);
    // B must build its OWN index — the fix makes index state device-local,
    // so B never inherits A's `status: current` via sync.
    await _warmCityIndex(dbB, colB);

    final (bResults, bPlan) = await colB
        .where(Field('city').equals('London'))
        .explainedGet();
    final bIds = bResults.map((d) => d['_id'] as String).toSet();

    expect(
      bIds,
      equals(aIds),
      reason:
          'B must see the same rows A does for the same indexed query. '
          'Before the fix, B inherited status: current from synced '
          '\$meta and scanned its own empty \$\$index:* namespace, '
          'returning zero rows for present, matching documents (SC-10).',
    );
    // B must have actually used its own index, not silently fallen back —
    // otherwise this test would pass by accident via a full scan.
    expect(bPlan.strategy, ScanStrategy.indexScan);

    await dbB.close();
  });
}
