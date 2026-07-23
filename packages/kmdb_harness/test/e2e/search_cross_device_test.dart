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

/// Cross-device regression test for 0.10.01 WI-11 / SC-10 — the FTS and Vec
/// half of the fix.
///
/// Both `FtsIndexState` and `VecIndexState` carried the identical SC-10
/// defect as the secondary index (see
/// `index_cross_device_test.dart`'s doc comment for the shape): status
/// (`current`) lived in synced `$meta`, so a device that pulled a peer's
/// `$meta` inherited `current` for a search index it never built locally,
/// then scanned its own empty `$$fts:*`/`$$vec:*` namespace and silently
/// returned zero `search()` results for present, matching documents. The fix
/// moves both states to the local-only `$$ftsstate`/`$$vecstate` namespaces.
///
/// This is the regression gate for that half of Phase 2 — folding FTS/Vec
/// into Phase 2 without extending the cross-device test here would leave a
/// live 🔴 in `search()` with no equivalent coverage to the secondary-index
/// case. Runs under `e2e` (Q-E) because it exercises the full sync pipeline.
@Tags(['e2e'])
library;

import 'dart:math' as math;
import 'dart:typed_data';

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

/// A deterministic fake embedding model — assigns a unit vector derived from
/// the input text's hash, so semantically identical text always embeds to
/// the same vector regardless of which device (A or B) runs inference.
final class _FakeEmbeddingModel implements EmbeddingModel {
  @override
  String get modelId => 'fake-model-v1';

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async {
    if (text.isEmpty) return (Float32List(dimensions), false);
    final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
    final rng = math.Random(seed);
    final v = Float32List.fromList(
      List.generate(dimensions, (_) => rng.nextDouble() * 2 - 1),
    );
    return (v, false);
  }

  @override
  void dispose() {}
}

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  test(
    'FTS — a device that pulls a peer\'s synced documents, with the same FTS '
    'index declared locally, returns the same search() results as the peer '
    '(SC-10 regression, lexical half)',
    () async {
      final cloud = MemorySyncAdapter();
      final ftsIndexes = [
        FtsIndexDefinition(collection: 'articles', field: 'body'),
      ];

      // ── Device A: writes docs, builds the FTS index, pushes. ────────────
      final localA = MemoryStorageAdapter();
      final dbA = await KmdbDatabase.open(
        path: '/dbA',
        adapter: localA,
        deviceId: 'aaaaaaaa',
        ftsIndexes: ftsIndexes,
        config: KvStoreConfig.forTesting(),
      );
      final colA = dbA.collection(name: 'articles', codec: _codec);
      await colA.put({
        '_id': '01900000000070008000000000000001',
        'body': 'the quick brown fox jumps',
      });
      await colA.put({
        '_id': '01900000000070008000000000000002',
        'body': 'an unrelated document about gardening',
      });
      await dbA.ftsManager!.ensureBuilt('articles', 'body');

      final aResult = await colA.search(
        'quick',
        fields: ['body'],
        mode: SearchMode.lexical,
      );
      // Sanity check: A must actually find the document — if this assertion
      // itself fails, the test below proves nothing.
      final aIds = aResult.hits.map((h) => h.id).toSet();
      expect(aIds, equals({'01900000000070008000000000000001'}));

      await dbA.store.flush();
      await dbA.push(syncAdapter: cloud, localAdapter: localA);
      await dbA.close();

      // ── Device B: pulls A's data, declares the SAME FTS index, searches. ─
      final localB = MemoryStorageAdapter();
      final dbB = await KmdbDatabase.open(
        path: '/dbB',
        adapter: localB,
        deviceId: 'bbbbbbbb',
        ftsIndexes: ftsIndexes,
        config: KvStoreConfig.forTesting(),
      );
      await dbB.pull(syncAdapter: cloud, localAdapter: localB);

      // B must build its OWN FTS index — the fix makes FTS state
      // device-local, so B never inherits A's `status: current` via sync.
      await dbB.ftsManager!.ensureBuilt('articles', 'body');

      final colB = dbB.collection(name: 'articles', codec: _codec);
      final bResult = await colB.search(
        'quick',
        fields: ['body'],
        mode: SearchMode.lexical,
      );
      final bIds = bResult.hits.map((h) => h.id).toSet();

      expect(
        bIds,
        equals(aIds),
        reason:
            'B must find the same document A does for the same search '
            'query. Before the fix, B inherited FTS status: current from '
            'synced \$meta and scanned its own empty \$\$fts:* namespace, '
            'returning zero results for a present, matching document '
            '(SC-10).',
      );

      await dbB.close();
    },
  );

  test('Vec — a device that pulls a peer\'s synced documents, with the same '
      'Vec index declared locally, returns the same search() results as the '
      'peer (SC-10 regression, semantic half)', () async {
    final cloud = MemorySyncAdapter();
    final vecIndexes = [
      VecIndexDefinition(collection: 'articles', field: 'body'),
    ];

    // ── Device A: writes docs, builds the Vec index, pushes. ────────────
    final localA = MemoryStorageAdapter();
    final dbA = await KmdbDatabase.open(
      path: '/dbA',
      adapter: localA,
      deviceId: 'aaaaaaaa',
      vecIndexes: vecIndexes,
      embeddingModel: _FakeEmbeddingModel(),
      config: KvStoreConfig.forTesting(),
    );
    final colA = dbA.collection(name: 'articles', codec: _codec);
    await colA.put({
      '_id': '01900000000070008000000000000001',
      'body': 'the quick brown fox jumps',
    });
    await colA.put({
      '_id': '01900000000070008000000000000002',
      'body': 'an unrelated document about gardening',
    });
    await dbA.vecManager!.ensureBuilt('articles', 'body');

    final aResult = await colA.search(
      'quick brown fox jumps',
      fields: ['body'],
      mode: SearchMode.semantic,
    );
    // Sanity check: A must actually find at least one document — if this
    // assertion itself fails, the test below proves nothing.
    expect(aResult.hits, isNotEmpty);
    final aIds = aResult.hits.map((h) => h.id).toSet();

    await dbA.store.flush();
    await dbA.push(syncAdapter: cloud, localAdapter: localA);
    await dbA.close();

    // ── Device B: pulls A's data, declares the SAME Vec index, searches. ─
    final localB = MemoryStorageAdapter();
    final dbB = await KmdbDatabase.open(
      path: '/dbB',
      adapter: localB,
      deviceId: 'bbbbbbbb',
      vecIndexes: vecIndexes,
      embeddingModel: _FakeEmbeddingModel(),
      config: KvStoreConfig.forTesting(),
    );
    await dbB.pull(syncAdapter: cloud, localAdapter: localB);

    // B must build its OWN Vec index — the fix makes Vec state
    // device-local, so B never inherits A's `status: current` via sync.
    await dbB.vecManager!.ensureBuilt('articles', 'body');

    final colB = dbB.collection(name: 'articles', codec: _codec);
    final bResult = await colB.search(
      'quick brown fox jumps',
      fields: ['body'],
      mode: SearchMode.semantic,
    );
    final bIds = bResult.hits.map((h) => h.id).toSet();

    expect(
      bIds,
      equals(aIds),
      reason:
          'B must find the same document(s) A does for the same semantic '
          'search query. Before the fix, B inherited Vec status: current '
          'from synced \$meta and scanned its own empty \$\$vec:* '
          'namespace, returning zero results for a present, matching '
          'document (SC-10).',
    );

    await dbB.close();
  });
}
