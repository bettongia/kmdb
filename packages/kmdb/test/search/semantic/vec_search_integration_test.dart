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
import 'package:kmdb/src/encryption/encryption_envelope.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/search/semantic/vec_manager.dart'
    show kVecStateNamespace;
import 'package:test/test.dart';

/// Reads the persisted [VecIndexState] for [namespace]/[field] directly from
/// [db]'s local-only [kVecStateNamespace] namespace (moved from `$meta` by
/// 0.10.01 WI-11/SC-10). None of the databases in this test file are
/// encrypted, so no unwrap key is threaded through. Test helper only.
Future<VecIndexState> _readVecState(
  KmdbDatabase db,
  String namespace,
  String field,
) async {
  final key = MetaStore.symbolicKey(VecIndexState.metaKey(namespace, field));
  final bytes = await db.store.get(kVecStateNamespace, key);
  if (bytes == null) return VecIndexState.fromBytes(namespace, field, null);
  final unwrapped = await EncryptionEnvelope.unwrap(bytes, null);
  return VecIndexState.fromBytes(namespace, field, unwrapped);
}

/// Writes [state] directly into [db]'s local-only [kVecStateNamespace]
/// namespace, mirroring [VecManager]'s private `_saveState` for an
/// unencrypted database. Test helper only — used to simulate a crash mid-sync
/// by forcing a specific persisted state ahead of a real write.
Future<void> _writeVecState(KmdbDatabase db, VecIndexState state) async {
  final key = MetaStore.symbolicKey(
    VecIndexState.metaKey(state.namespace, state.field),
  );
  final wrapped = await EncryptionEnvelope.wrap(state.toBytes(), null);
  await db.store.putRaw(kVecStateNamespace, key, wrapped);
}

// ── Fake embedding model ────────────────────────────────────────────────────

/// A fake embedding model that assigns semantically meaningful clusters.
///
/// The first component of the output vector is positive for "similar"
/// documents and negative for "dissimilar" ones, based on keywords in
/// the text. This lets the integration tests assert ranking order.
final class _ClusteredEmbeddingModel implements EmbeddingModel {
  /// The [EmbeddingKind] values seen across all [embed] calls, in call order.
  /// Lets tests assert that document indexing and query search each reach
  /// this model with the expected [EmbeddingKind].
  final List<EmbeddingKind> kindsSeen = [];

  @override
  String get modelId => 'clustered-model-v1';

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async {
    kindsSeen.add(kind);
    final lower = text.toLowerCase();
    // Assign a base direction that reflects the semantic "cluster".
    final v = Float32List(dimensions);

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

/// A fake embedding model that simulates a mandatory prefix by biasing the
/// output vector differently depending on [EmbeddingKind] — mirroring how a
/// real model like `multilingual-e5-small` would produce a different vector
/// for `"passage: hello"` versus `"query: hello"` even though the
/// *unprefixed* input text is identical.
///
/// Used to prove that [VecManager] actually threads [EmbeddingKind] through
/// to the model rather than embedding every call the same way (which would
/// make index-time and query-time text indistinguishable regardless of what
/// the model does with that information).
final class _PrefixSimulatingEmbeddingModel implements EmbeddingModel {
  /// The [EmbeddingKind] values seen across all [embed] calls, in call order.
  final List<EmbeddingKind> kindsSeen = [];

  @override
  String get modelId => 'prefix-simulating-model-v1';

  @override
  int get dimensions => 4;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async {
    kindsSeen.add(kind);
    final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
    final v = Float32List(dimensions);
    // Base direction from text content, offset differently per EmbeddingKind
    // — simulating the effect of a "passage: "/"query: " prefix without
    // needing real tokenization/inference.
    final kindOffset = kind == EmbeddingKind.query ? 0.5 : -0.5;
    for (var i = 0; i < dimensions; i++) {
      v[i] = ((seed ^ i) % 7).toDouble() + kindOffset;
    }
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    for (var i = 0; i < v.length; i++) {
      v[i] /= norm;
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
            await ValueCodec.encode({'body': 'relational database management'}),
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
      final state = await _readVecState(db, 'articles', 'body');
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
      await _writeVecState(db, syncingState);
      await db.close(flush: false);

      // Re-open with the same adapter and path — checkAndTransitionOnOpen
      // should flip syncing → stale because a crash is simulated.
      final db2 = await _openDb(adapter: sharedAdapter, path: sharedPath);
      final state = await _readVecState(db2, 'articles', 'body');
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

  // ── EmbeddingKind wiring (WI-4 Phase 3) ─────────────────────────────────────

  group('EmbeddingKind wiring', () {
    test('indexing passes EmbeddingKind.document, querying passes '
        'EmbeddingKind.query', () async {
      final model = _ClusteredEmbeddingModel();
      final db = await _openDb(model: model);
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'relational database storage engine'});
      // The vector index is lazily built on first query (spec §22) — a plain
      // insert before the index has ever been built does not call embed() at
      // all (interceptWrite skips `undefined`/`stale` indexes). So no embed
      // calls have happened yet.
      expect(model.kindsSeen, isEmpty);

      await col.search(
        'database storage system',
        fields: ['body'],
        mode: SearchMode.semantic,
      );
      // ensureBuilt's full-namespace scan embeds the one existing document
      // with EmbeddingKind.document, then the query is embedded last with
      // EmbeddingKind.query.
      expect(
        model.kindsSeen,
        equals([EmbeddingKind.document, EmbeddingKind.query]),
      );

      await db.close();
    });

    test(
      'reindex() re-embeds existing documents with EmbeddingKind.document',
      () async {
        final model = _ClusteredEmbeddingModel();
        final db = await _openDb(model: model);
        final col = db.collection(name: 'articles', codec: _codec);
        await col.insert({'body': 'relational database storage engine'});
        model.kindsSeen.clear();

        await db.reindex();

        expect(model.kindsSeen, everyElement(equals(EmbeddingKind.document)));
        expect(model.kindsSeen, isNotEmpty);

        await db.close();
      },
    );

    test('a model that varies its output by EmbeddingKind (simulating a '
        'passage:/query: prefix) yields different vectors for identical '
        'index-time and query-time text', () async {
      final model = _PrefixSimulatingEmbeddingModel();
      final db = await _openDb(model: model);
      final col = db.collection(name: 'articles', codec: _codec);

      // Same literal text on both sides — any scoring difference must come
      // from EmbeddingKind reaching the model, not from different input.
      const sharedText = 'hello world';
      await col.insert({'body': sharedText});

      final result = await col.search(
        sharedText,
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      expect(result.hits, hasLength(1));
      // A model that actually applies a passage:/query: style prefix would
      // never produce a perfect (cosine == 1.0) self-match for identical
      // unprefixed text, because the document and query vectors differ.
      final score = result.hits.first.fieldScores['body:cosine']!;
      expect(score, isNot(closeTo(1.0, 1e-9)));
      expect(
        model.kindsSeen,
        equals([EmbeddingKind.document, EmbeddingKind.query]),
      );

      await db.close();
    });

    test('a model that ignores EmbeddingKind (e.g. bge-small-en-v1.5, no '
        'prefix keys) is byte-for-byte unchanged: identical index-time and '
        'query-time text yields a perfect self-match', () async {
      // Any of the plain fakes used elsewhere in this file (which do not
      // branch on `kind` at all) stands in for a no-prefix model like
      // bge-small-en-v1.5 — the default `kind` parameter is a no-op for
      // them, so behaviour is identical to before EmbeddingKind existed.
      final db = await _openDb();
      final col = db.collection(name: 'articles', codec: _codec);

      const sharedText = 'relational database storage engine';
      await col.insert({'body': sharedText});

      final result = await col.search(
        sharedText,
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      expect(result.hits, hasLength(1));
      // Not an exact 1.0: the stored document vector is SQ8-quantised
      // (spec §22, ≈0.004 max per-element error) while the query vector
      // stays full-precision float32, so a small quantisation gap is
      // expected even for byte-identical input text. The tolerance here is
      // well inside that quantisation noise floor and far tighter than the
      // `_PrefixSimulatingEmbeddingModel` test's deliberately-different
      // vectors above, which is the actual behaviour being distinguished.
      final score = result.hits.first.fieldScores['body:cosine']!;
      expect(score, closeTo(1.0, 0.01));

      await db.close();
    });
  });
}
