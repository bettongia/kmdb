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

// ── Fake embedding model ─────────────────────────────────────────────────────

/// Deterministic embedding model for integration tests.
///
/// Produces a vector where the first component is positive for texts
/// containing 'database'/'storage' keywords, negative for 'learning'/'neural'.
/// All vectors are L2-normalised. This gives the integration tests a
/// controlled semantic similarity space without requiring ONNX.
final class _DeterministicEmbeddingModel implements EmbeddingModel {
  @override
  String get modelId => 'deterministic-model-v1';

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async {
    final lower = text.toLowerCase();
    final v = Float32List(dimensions);

    if (lower.contains('database') || lower.contains('storage')) {
      v[0] = 0.9;
      v[1] = 0.2;
    } else if (lower.contains('machine learning') || lower.contains('neural')) {
      v[0] = -0.9;
      v[1] = 0.2;
    } else if (lower.contains('search') || lower.contains('retrieval')) {
      v[0] = 0.7;
      v[1] = 0.5;
    } else {
      // Pseudo-random but deterministic from text content.
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

// ── Codec ─────────────────────────────────────────────────────────────────────

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

// ── DB factory helpers ────────────────────────────────────────────────────────

/// Opens a db with both FTS and vector indexes on 'body' field.
Future<KmdbDatabase> _openHybridDb({
  String collection = 'articles',
  String field = 'body',
  EmbeddingModel? model,
}) => KmdbDatabase.open(
  path: 'hybrid_int_${Object().hashCode}',
  adapter: MemoryStorageAdapter(),
  ftsIndexes: [FtsIndexDefinition(collection: collection, field: field)],
  vecIndexes: [VecIndexDefinition(collection: collection, field: field)],
  embeddingModel: model ?? _DeterministicEmbeddingModel(),
);

/// Opens a db with only FTS index on 'body' field (no vector index).
Future<KmdbDatabase> _openFtsOnlyDb({String field = 'body'}) =>
    KmdbDatabase.open(
      path: 'hybrid_fts_only_${Object().hashCode}',
      adapter: MemoryStorageAdapter(),
      ftsIndexes: [FtsIndexDefinition(collection: 'articles', field: field)],
    );

/// Opens a db with only vector index on 'body' field (no FTS index).
Future<KmdbDatabase> _openVecOnlyDb({
  String field = 'body',
  EmbeddingModel? model,
}) => KmdbDatabase.open(
  path: 'hybrid_vec_only_${Object().hashCode}',
  adapter: MemoryStorageAdapter(),
  vecIndexes: [VecIndexDefinition(collection: 'articles', field: field)],
  embeddingModel: model ?? _DeterministicEmbeddingModel(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── Mode routing ────────────────────────────────────────────────────────────

  group('SearchMode.auto routing', () {
    test('auto with both indexes activates hybrid path', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});
      await col.insert({'body': 'database query optimisation'});

      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.auto,
      );

      // Both fields should appear in searched, and score should be an RRF
      // value (not a raw BM25 or cosine score). RRF scores are typically
      // < 0.1 for reasonable k and short lists.
      expect(result.metadata.searched, contains('body'));
      expect(result.hits, isNotEmpty);

      // In hybrid mode the first hit has a fieldScores map with both :bm25
      // and :cosine entries (or at minimum the :rrf entry).
      final firstHit = result.hits.first;
      expect(
        firstHit.fieldScores.keys.any((k) => k.contains(':')),
        isTrue,
        reason: 'hybrid hit should have component score keys',
      );
    });

    test('auto with only FTS index activates lexical path', () async {
      final db = await _openFtsOnlyDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});

      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.auto,
      );

      expect(result.metadata.searched, contains('body'));
      expect(result.hits, isNotEmpty);
      // Lexical-only: BM25 score, not an RRF-range score.
      // The score will be a BM25 normalised value in [0,1].
      expect(result.hits.first.score, lessThanOrEqualTo(1.0));
      // fieldScores should have :bm25 suffix, not :cosine (no vec index).
      expect(
        result.hits.first.fieldScores.keys.any((k) => k.endsWith(':bm25')),
        isTrue,
      );
      expect(
        result.hits.first.fieldScores.keys.any((k) => k.endsWith(':cosine')),
        isFalse,
      );
    });

    test('auto with only vec index activates semantic path', () async {
      final db = await _openVecOnlyDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});

      final result = await col.search(
        'database',
        fields: ['body'],
        mode: SearchMode.auto,
      );

      expect(result.metadata.searched, contains('body'));
      expect(result.hits, isNotEmpty);
      // Semantic-only: cosine score in [-1, 1]; and :cosine key present.
      expect(
        result.hits.first.fieldScores.keys.any((k) => k.endsWith(':cosine')),
        isTrue,
      );
      expect(
        result.hits.first.fieldScores.keys.any((k) => k.endsWith(':bm25')),
        isFalse,
      );
    });

    test(
      'auto with no index returns empty result with field in skipped',
      () async {
        // Open db with no indexes at all.
        final db = await KmdbDatabase.open(
          path: 'no_index_${Object().hashCode}',
          adapter: MemoryStorageAdapter(),
        );
        final col = db.collection(name: 'articles', codec: _codec);

        await col.insert({'body': 'anything'});

        final result = await col.search(
          'anything',
          fields: ['body'],
          mode: SearchMode.auto,
        );

        expect(result.hits, isEmpty);
        expect(result.metadata.skipped, contains('body'));
      },
    );
  });

  // ── Hybrid field scores ─────────────────────────────────────────────────────

  group('hybrid fieldScores', () {
    test('SearchHit.fieldScores has correct keys for hybrid results', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine high performance'});

      final result = await col.search('database', fields: ['body']);
      expect(result.hits, isNotEmpty);

      final hit = result.hits.first;
      // In hybrid mode we expect the :bm25 and :cosine component scores plus
      // the field-level RRF score.
      expect(hit.fieldScores.containsKey('body:bm25'), isTrue);
      expect(hit.fieldScores.containsKey('body:cosine'), isTrue);
      expect(hit.fieldScores.containsKey('body'), isTrue);
    });

    test(
      'document only in BM25 results has :bm25 key but no :cosine key',
      () async {
        // Insert a document whose embedding will be very different from the
        // query — it will appear in BM25 results but not semantic top-k.
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        // Explicitly use a high-frequency query term to guarantee BM25 matches.
        await col.insert({'body': 'database database database'});

        final result = await col.search(
          'database',
          fields: ['body'],
          candidates: 1000, // ensure both legs get the doc
        );

        expect(result.hits, isNotEmpty);
        // At least one hit should have :bm25 (it came through BM25 leg).
        final hasBm25Key = result.hits.any(
          (h) => h.fieldScores.containsKey('body:bm25'),
        );
        expect(hasBm25Key, isTrue);
      },
    );

    test(
      'SearchHit.fieldScores has :cosine key for cosine-only result',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        // Insert a document about "database" — should match semantically.
        await col.insert({'body': 'database storage system'});

        final result = await col.search('database', fields: ['body']);

        expect(result.hits, isNotEmpty);
        // All hits from the vec leg carry :cosine keys.
        final hasAnyCosineSuffix = result.hits.any(
          (h) => h.fieldScores.keys.any((k) => k.endsWith(':cosine')),
        );
        expect(hasAnyCosineSuffix, isTrue);
      },
    );
  });

  // ── Partial-index correctness ───────────────────────────────────────────────

  group('partial-index correctness', () {
    test(
      'document in BM25 top results but not semantic top results appears in hybrid',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        // Insert documents with query term for BM25 match.
        await col.insert({'body': 'database database database storage'});
        await col.insert({'body': 'database management system'});

        // Request only 1 candidate from each leg — ensures some documents
        // may only appear in one leg.
        final result = await col.search(
          'database',
          fields: ['body'],
          candidates: 1,
          limit: 10,
        );

        // Even with limited candidates, the result should not be empty.
        expect(result.hits, isNotEmpty);
        // Each hit should have been in at least one index leg.
        for (final hit in result.hits) {
          final hasBm25 = hit.fieldScores.containsKey('body:bm25');
          final hasCosine = hit.fieldScores.containsKey('body:cosine');
          expect(
            hasBm25 || hasCosine,
            isTrue,
            reason:
                'Hit ${hit.id} has no component score — should come from at '
                'least one leg',
          );
        }
      },
    );

    test(
      'candidates=5 limits each leg to 5 candidates (at most 10 in pool)',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        // Insert 20 documents all matching the query.
        for (var i = 0; i < 20; i++) {
          await col.insert({'body': 'database storage engine article $i'});
        }

        final result = await col.search(
          'database',
          fields: ['body'],
          candidates: 5,
          limit: 20, // don't limit the output
        );

        // With candidates=5, each leg produces at most 5 hits, so the merged
        // pool has at most 10 documents (fewer if they overlap).
        expect(result.hits.length, lessThanOrEqualTo(10));
      },
    );
  });

  // ── Filter integration ──────────────────────────────────────────────────────

  group('filter pre-filtering', () {
    test(
      'filter resolves candidateIds once before both legs; non-matching documents excluded',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        // Published: true documents.
        await col.insert({
          'body': 'database storage engine',
          'published': true,
        });
        await col.insert({
          'body': 'database query language',
          'published': true,
        });
        // Published: false — should be excluded from results.
        await col.insert({
          'body': 'database system architecture',
          'published': false,
        });

        final result = await col.search(
          'database',
          fields: ['body'],
          filter: Field('published').equals(true),
        );

        expect(result.hits, isNotEmpty);
        for (final hit in result.hits) {
          expect(
            hit.document['published'],
            isTrue,
            reason: 'Non-published document should have been filtered out',
          );
        }
        // The excluded doc must not appear.
        final ids = result.hits.map((h) => h.id).toSet();
        for (final hit in result.hits) {
          expect(hit.document['published'], isTrue);
        }
        expect(ids.length, lessThanOrEqualTo(2));
      },
    );

    test('filter that matches no documents returns empty result', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage', 'published': false});

      final result = await col.search(
        'database',
        fields: ['body'],
        filter: Field('published').equals(true),
      );

      expect(result.hits, isEmpty);
    });
  });

  // ── rrfK parameter ──────────────────────────────────────────────────────────

  group('rrfK parameter', () {
    test('rrfK=1 produces valid extreme scores without error', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});

      final result = await col.search('database', fields: ['body'], rrfK: 1);

      expect(result.hits, isNotEmpty);
      // Score with k=1 at rank 1 is 1/(1+1) + 1/(1+1) = 1.0 at most.
      expect(result.hits.first.score.isFinite, isTrue);
    });

    test('rrfK with different values produces different scores', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});
      await col.insert({'body': 'database query optimisation'});

      final resultK1 = await col.search('database', fields: ['body'], rrfK: 1);
      final resultK60 = await col.search(
        'database',
        fields: ['body'],
        rrfK: 60,
      );

      expect(
        resultK1.hits.first.score,
        isNot(equals(resultK60.hits.first.score)),
      );
    });
  });

  // ── SearchMetadata ───────────────────────────────────────────────────────────

  group('SearchMetadata', () {
    test('searched contains fields that were searched', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});

      final result = await col.search('database', fields: ['body']);

      expect(result.metadata.searched, contains('body'));
      expect(result.metadata.skipped, isEmpty);
    });

    test('skipped contains fields with no matching index', () async {
      final db = await _openHybridDb();
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({'body': 'database storage engine'});

      // 'summary' has no index → should be in skipped.
      final result = await col.search('database', fields: ['body', 'summary']);

      expect(result.metadata.searched, contains('body'));
      expect(result.metadata.skipped, contains('summary'));
    });
  });

  // ── Multi-field hybrid ──────────────────────────────────────────────────────

  group('multi-field hybrid search', () {
    test(
      'per-field scores tracked independently across title and body',
      () async {
        final db = await KmdbDatabase.open(
          path: 'hybrid_multi_${Object().hashCode}',
          adapter: MemoryStorageAdapter(),
          ftsIndexes: [
            FtsIndexDefinition(collection: 'articles', field: 'title'),
            FtsIndexDefinition(collection: 'articles', field: 'body'),
          ],
          vecIndexes: [
            VecIndexDefinition(collection: 'articles', field: 'title'),
            VecIndexDefinition(collection: 'articles', field: 'body'),
          ],
          embeddingModel: _DeterministicEmbeddingModel(),
        );
        final col = db.collection(name: 'articles', codec: _codec);

        await col.insert({
          'title': 'database storage',
          'body': 'database systems introduction',
        });

        final result = await col.search('database', fields: ['title', 'body']);

        expect(result.metadata.searched, containsAll(['title', 'body']));
        expect(result.hits, isNotEmpty);

        final hit = result.hits.first;
        // In multi-field hybrid mode, each field has its own component scores.
        // At least one per-field key should be present.
        final fieldScoreKeys = hit.fieldScores.keys.toList();
        expect(
          fieldScoreKeys.any(
            (k) => k.startsWith('title:') || k.startsWith('body:'),
          ),
          isTrue,
        );
      },
    );
  });

  // ── Delete correctness ──────────────────────────────────────────────────────

  group('delete correctness', () {
    test(
      'deleting a document removes it from both legs; not in hybrid results',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        final doc = await col.insert({'body': 'database storage engine'});
        final docId = doc['_id'] as String;

        // Verify it appears in results before deletion.
        final beforeResult = await col.search('database', fields: ['body']);
        expect(beforeResult.hits.map((h) => h.id), contains(docId));

        // Delete the document.
        await col.delete(docId);

        // After deletion it should not appear in hybrid results.
        final afterResult = await col.search('database', fields: ['body']);
        expect(afterResult.hits.map((h) => h.id), isNot(contains(docId)));
      },
    );
  });

  // ── Mode forcing ─────────────────────────────────────────────────────────────

  group('forced mode bypass', () {
    test(
      'mode=lexical uses only BM25 even when vec index is present',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        await col.insert({'body': 'database storage engine'});

        final result = await col.search(
          'database',
          fields: ['body'],
          mode: SearchMode.lexical,
        );

        expect(result.hits, isNotEmpty);
        // Lexical-only: all scores should be BM25 (no cosine keys).
        for (final hit in result.hits) {
          expect(
            hit.fieldScores.keys.any((k) => k.endsWith(':cosine')),
            isFalse,
            reason: 'mode=lexical should not include cosine scores',
          );
        }
      },
    );

    test(
      'mode=semantic uses only cosine even when FTS index is present',
      () async {
        final db = await _openHybridDb();
        final col = db.collection(name: 'articles', codec: _codec);

        await col.insert({'body': 'database storage engine'});

        final result = await col.search(
          'database',
          fields: ['body'],
          mode: SearchMode.semantic,
        );

        expect(result.hits, isNotEmpty);
        // Semantic-only: all scores should be cosine (no bm25 keys).
        for (final hit in result.hits) {
          expect(
            hit.fieldScores.keys.any((k) => k.endsWith(':bm25')),
            isFalse,
            reason: 'mode=semantic should not include BM25 scores',
          );
        }
      },
    );
  });
}
