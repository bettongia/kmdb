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

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

// ── Fake embedding model ────────────────────────────────────────────────────

/// A fake embedding model that assigns semantically meaningful clusters.
///
/// The first component of the output vector is positive for "similar"
/// documents and negative for "dissimilar" ones, based on keywords in
/// the text. This lets the integration tests assert ranking order.
final class _ClusteredEmbeddingModel implements EmbeddingModel {
  @override
  Future<(Float32List, bool)> embed(String text) async {
    final lower = text.toLowerCase();
    // Assign a base direction that reflects the semantic "cluster".
    final v = Float32List(384);

    if (lower.contains('database') || lower.contains('storage')) {
      v[0] = 0.9;
      v[1] = 0.1;
    } else if (lower.contains('machine learning') || lower.contains('neural')) {
      v[0] = -0.9;
      v[1] = 0.1;
    } else {
      // Neutral — random-ish based on hash.
      final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
      final rng = math.Random(seed);
      v[0] = rng.nextDouble() * 0.4 - 0.2;
      v[1] = rng.nextDouble() * 0.4 - 0.2;
    }

    // L2-normalise.
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm > 0) {
      norm = math.sqrt(norm);
      for (var i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }

    return (v, false);
  }

  @override
  void dispose() {}
}

// ── Helpers ─────────────────────────────────────────────────────────────────

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

Future<KmdbDatabase> _openDb({
  EmbeddingModel? model,
  MemoryStorageAdapter? adapter,
  String? path,
}) => KmdbDatabase.open(
  path: path ?? 'vec_int_${Object().hashCode}',
  adapter: adapter ?? MemoryStorageAdapter(),
  vecIndexes: [VecIndexDefinition(collection: 'articles', field: 'body')],
  embeddingModel: model ?? _ClusteredEmbeddingModel(),
);

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── Basic search ranking ─────────────────────────────────────────────────

  group('semantic search ranking', () {
    test('semantically similar document ranks above dissimilar one', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'relational database storage engine'});
      await col.insert({'body': 'neural network machine learning model'});

      final result = await col.search(
        'database storage system',
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      expect(result.hits, hasLength(2));
      // The database-related document should rank first.
      expect((result.hits.first.document as Map)['body'], contains('database'));
      // The first hit should have a higher score than the second.
      expect(result.hits[0].score, greaterThan(result.hits[1].score));

      await db.close();
    });

    test('empty query returns empty SearchResult without error', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'some document'});

      final result = await col.search(
        '',
        fields: ['body'],
        mode: SearchMode.semantic,
      );
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));

      await db.close();
    });

    test('deleted document does not appear in results', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      final doc = await col.insert({'body': 'database storage engine'});
      final id = doc['_id'] as String;
      await col.insert({'body': 'another database article'});

      // Delete the first document.
      await col.delete(id);

      final result = await col.search(
        'database storage',
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      final ids = result.hits.map((h) => h.id).toList();
      expect(ids, isNot(contains(id)));

      await db.close();
    });

    test('updated document uses new embedding', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      // Start with a database document.
      final doc = await col.insert({'body': 'relational database storage'});
      final id = doc['_id'] as String;
      await col.insert({'body': 'another database article'});

      final before = await col.search(
        'database storage',
        fields: ['body'],
        mode: SearchMode.semantic,
      );
      // Confirm the document was in the results.
      expect(before.hits.any((h) => h.id == id), isTrue);

      // Update it to a machine learning topic — should now rank lower for
      // database queries.
      await col.put({...doc, 'body': 'neural network machine learning'});

      final after = await col.search(
        'database storage',
        fields: ['body'],
        mode: SearchMode.semantic,
      );
      // The updated document should rank lower (or possibly not appear as top)
      // compared to the remaining "another database article".
      if (after.hits.length >= 2) {
        expect(after.hits.last.id, equals(id));
      }

      await db.close();
    });

    test('field not indexed appears in SearchMetadata.skipped', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'some content'});

      final result = await col.search(
        'query',
        fields: ['body', 'title'], // 'title' is not indexed
        mode: SearchMode.semantic,
      );

      expect(result.metadata.skipped, contains('title'));

      await db.close();
    });

    test('offset and limit are applied correctly', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      for (var i = 0; i < 5; i++) {
        await col.insert({'body': 'database storage engine article $i'});
      }

      final all = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
        limit: 10,
      );
      expect(all.hits.length, equals(5));

      final page1 = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
        limit: 2,
        offset: 0,
      );
      expect(page1.hits.length, equals(2));
      expect(page1.hits.first.rank, equals(1));

      final page2 = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
        limit: 2,
        offset: 2,
      );
      expect(page2.hits.length, equals(2));
      expect(page2.hits.first.rank, equals(3));

      // Pages should contain different documents.
      final ids1 = page1.hits.map((h) => h.id).toSet();
      final ids2 = page2.hits.map((h) => h.id).toSet();
      expect(ids1.intersection(ids2), isEmpty);

      await db.close();
    });

    test('fieldScores carries :cosine suffix', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage'});

      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      expect(result.hits, isNotEmpty);
      expect(result.hits.first.fieldScores, contains('body:cosine'));

      await db.close();
    });
  });

  // ── Filter pre-filtering ──────────────────────────────────────────────────

  group('filter pre-filtering', () {
    test('filter restricts candidate set', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine', 'published': true});
      await col.insert({'body': 'another database', 'published': false});

      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
        filter: Field('published').equals(true),
      );

      expect(result.hits, hasLength(1));
      expect((result.hits.first.document as Map)['published'], isTrue);

      await db.close();
    });

    test('filter that matches no documents returns empty result', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database article', 'category': 'tech'});

      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
        filter: Field('category').equals('sport'),
      );

      expect(result.hits, isEmpty);

      await db.close();
    });
  });

  // ── ensureBuilt ───────────────────────────────────────────────────────────

  group('ensureBuilt', () {
    test('indexes pre-existing documents correctly', () async {
      // Insert documents into a database without any vec index, then re-open
      // with the vec index to simulate the "pre-existing docs" case.
      // (Since MemoryStorageAdapter doesn't persist, we'll use a fresh db
      //  and insert before triggering ensureBuilt.)
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      // Insert documents before ensuring the index is built.
      await col.insert({'body': 'database storage engine'});
      await col.insert({'body': 'machine learning neural'});

      // Force a rebuild (as if the index was undefined/stale).
      await db.vecManager!.ensureBuilt('articles', 'body');

      // Now search should work correctly.
      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      expect(result.hits, isNotEmpty);
      expect((result.hits.first.document as Map)['body'], contains('database'));

      await db.close();
    });
  });

  // ── applyDelta ───────────────────────────────────────────────────────────

  group('applyDelta', () {
    test(
      'added documents run inference and appear in search results',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'articles', codec: _codec);

        // Insert a document normally.
        await col.insert({'body': 'database storage'});

        // Simulate a sync delta adding a new document.
        final newDocId = const UuidV7KeyGenerator().next();
        await db.store.writeBatchInternal(
          WriteBatch()..put(
            'articles',
            newDocId,
            ValueCodec.encode({'body': 'relational database management'}),
          ),
        );

        final delta = SyncDelta(
          namespace: 'articles',
          changes: [(docId: newDocId, changeType: DeltaChangeType.added)],
        );
        await db.vecManager!.applyDelta('articles', delta);

        final result = await col.search(
          'database',
          fields: ['body'],
          mode: SearchMode.semantic,
        );
        final ids = result.hits.map((h) => h.id).toList();
        expect(ids, contains(newDocId));

        await db.close();
      },
    );

    test('deleted documents removed from index via delta', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      final doc = await col.insert({'body': 'database storage engine'});
      final id = doc['_id'] as String;

      // Verify it appears in search first.
      final before = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
      );
      expect(before.hits.any((h) => h.id == id), isTrue);

      // Now apply a sync delta that deletes this document.
      final delta = SyncDelta(
        namespace: 'articles',
        changes: [(docId: id, changeType: DeltaChangeType.deleted)],
      );
      await db.vecManager!.applyDelta('articles', delta);

      // The document should no longer appear in results.
      final after = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.semantic,
        candidates: 1000,
      );
      expect(after.hits.any((h) => h.id == id), isFalse);

      await db.close();
    });

    test('applyDelta transitions index current → syncing → current', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);
      await col.insert({'body': 'initial document'});

      // Trigger ensureBuilt to set status to current.
      await db.vecManager!.ensureBuilt('articles', 'body');

      // Apply an empty delta — should still transition through syncing.
      final delta = SyncDelta(namespace: 'articles', changes: []);
      await db.vecManager!.applyDelta('articles', delta);

      // Index should be current after applyDelta completes.
      final state = VecIndexState.fromBytes(
        'articles',
        'body',
        await db.store.meta.getRawByName(
          VecIndexState.metaKey('articles', 'body'),
        ),
      );
      expect(state.status, equals(VecIndexStatus.current));

      await db.close();
    });

    test('checkAndTransitionOnOpen transitions syncing → stale', () async {
      // Use a shared adapter and path so the second open sees the state
      // written by the first open (simulating close + re-open with persistent
      // storage).
      final sharedAdapter = MemoryStorageAdapter();
      const sharedPath = 'vec_transition_test';

      final db = await _openDb(adapter: sharedAdapter, path: sharedPath);
      final col = db.collection(name: 'articles', codec: _codec);
      await col.insert({'body': 'article body'});

      // Force the index into syncing state.
      final syncingState = VecIndexState(
        namespace: 'articles',
        field: 'body',
        status: VecIndexStatus.syncing,
      );
      await db.store.meta.putRawByName(
        VecIndexState.metaKey('articles', 'body'),
        syncingState.toBytes(),
      );
      await db.close(flush: false);

      // Re-open with the same adapter and path — checkAndTransitionOnOpen
      // should flip syncing → stale because a crash is simulated.
      final db2 = await _openDb(adapter: sharedAdapter, path: sharedPath);
      final state = VecIndexState.fromBytes(
        'articles',
        'body',
        await db2.store.meta.getRawByName(
          VecIndexState.metaKey('articles', 'body'),
        ),
      );
      // After re-open, index that was syncing is now stale.
      expect(state.status, equals(VecIndexStatus.stale));

      await db2.close();
    });
  });

  // ── auto mode routing ──────────────────────────────────────────────────────

  group('auto mode routing', () {
    test('auto mode uses semantic when only vec index is available', () async {
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage'});

      // auto mode, no FTS index → should route to semantic.
      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.auto, // default
      );

      expect(result.hits, isNotEmpty);
      expect(result.hits.first.fieldScores, contains('body:cosine'));

      await db.close();
    });
  });
}
