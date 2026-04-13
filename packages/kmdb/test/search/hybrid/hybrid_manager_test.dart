// Copyright 2026 The KMDB Authors.
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

import 'package:kmdb/src/search/hybrid/hybrid_manager.dart';
import 'package:kmdb/src/search/search_result.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

SearchHit<String> _hit({
  required String id,
  required int rank,
  double score = 0.5,
  Map<String, double> fieldScores = const {},
}) => SearchHit<String>(
  rank: rank,
  score: score,
  fieldScores: fieldScores,
  id: id,
  document: 'doc_$id',
);

SearchMetadata _meta({
  String query = 'test',
  List<String> searched = const ['body'],
  List<String> skipped = const [],
  int total = 0,
}) => SearchMetadata(
  query: query,
  searched: searched,
  skipped: skipped,
  total: total,
);

void main() {
  // ── rrfScore ──────────────────────────────────────────────────────────────
  group('rrfScore', () {
    test('returns 1/(k+rank) for default k=60', () {
      expect(rrfScore(1), closeTo(1.0 / 61.0, 1e-10));
      expect(rrfScore(60), closeTo(1.0 / 120.0, 1e-10));
    });

    test('custom k is respected', () {
      expect(rrfScore(1, k: 10), closeTo(1.0 / 11.0, 1e-10));
    });

    test('k=1 is valid and produces finite scores at rank>=1', () {
      final score = rrfScore(1, k: 1);
      expect(score, closeTo(0.5, 1e-10));
      expect(score.isFinite, isTrue);
    });

    test('k=0 throws ArgumentError', () {
      expect(() => rrfScore(1, k: 0), throwsArgumentError);
    });

    test('negative k throws ArgumentError', () {
      expect(() => rrfScore(1, k: -5), throwsArgumentError);
    });

    test('higher rank produces lower score', () {
      final top = rrfScore(1);
      final lower = rrfScore(10);
      expect(top, greaterThan(lower));
    });
  });

  // ── mergeWithRrf ──────────────────────────────────────────────────────────
  group('mergeWithRrf', () {
    test('rrfK=0 throws ArgumentError', () {
      expect(
        () => mergeWithRrf<String>(
          lexicalHits: [],
          semanticHits: [],
          limit: 10,
          offset: 0,
          metadata: _meta(),
          rrfK: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rrfK=1 produces valid scores without error', () {
      final lexHit = _hit(
        id: 'a',
        rank: 1,
        score: 0.9,
        fieldScores: {'body:bm25': 0.9},
      );
      final result = mergeWithRrf<String>(
        lexicalHits: [lexHit],
        semanticHits: [],
        limit: 10,
        offset: 0,
        metadata: _meta(),
        rrfK: 1,
      );
      expect(result.hits.first.score, closeTo(1.0 / 2.0, 1e-10)); // 1/(1+1)
      expect(result.hits.first.score.isFinite, isTrue);
    });

    test('empty both lists returns empty SearchResult', () {
      final result = mergeWithRrf<String>(
        lexicalHits: [],
        semanticHits: [],
        limit: 10,
        offset: 0,
        metadata: _meta(),
      );
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });

    test(
      'document in both lists ranks higher than document in only one list',
      () {
        // doc_both is rank 1 in both lists → RRF = 1/61 + 1/61 ≈ 0.0328
        // doc_lex_only is rank 2 in lexical, absent in semantic → RRF = 1/62
        // doc_vec_only is rank 2 in semantic, absent in lexical → RRF = 1/62
        final lexHits = [
          _hit(
            id: 'both',
            rank: 1,
            score: 0.9,
            fieldScores: {'body:bm25': 0.9},
          ),
          _hit(
            id: 'lex_only',
            rank: 2,
            score: 0.5,
            fieldScores: {'body:bm25': 0.5},
          ),
        ];
        final vecHits = [
          _hit(
            id: 'both',
            rank: 1,
            score: 0.95,
            fieldScores: {'body:cosine': 0.95},
          ),
          _hit(
            id: 'vec_only',
            rank: 2,
            score: 0.7,
            fieldScores: {'body:cosine': 0.7},
          ),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: lexHits,
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(),
        );

        expect(result.hits.length, equals(3));
        expect(result.hits.first.id, equals('both'));
        expect(
          result.hits.first.score,
          closeTo(2.0 / 61.0, 1e-10),
        ); // 1/61 + 1/61
      },
    );

    test('document absent from BM25 list contributes 0 from that leg', () {
      // vec_only: only in semantic at rank 1 → RRF = 1/61
      final vecHits = [
        _hit(
          id: 'vec_only',
          rank: 1,
          score: 0.9,
          fieldScores: {'body:cosine': 0.9},
        ),
      ];

      final result = mergeWithRrf<String>(
        lexicalHits: [],
        semanticHits: vecHits,
        limit: 10,
        offset: 0,
        metadata: _meta(),
      );

      expect(result.hits.length, equals(1));
      expect(result.hits.first.id, equals('vec_only'));
      expect(result.hits.first.score, closeTo(1.0 / 61.0, 1e-10));
    });

    test('document absent from cosine list contributes 0 from that leg', () {
      final lexHits = [
        _hit(
          id: 'lex_only',
          rank: 1,
          score: 0.9,
          fieldScores: {'body:bm25': 0.9},
        ),
      ];

      final result = mergeWithRrf<String>(
        lexicalHits: lexHits,
        semanticHits: [],
        limit: 10,
        offset: 0,
        metadata: _meta(),
      );

      expect(result.hits.length, equals(1));
      expect(result.hits.first.id, equals('lex_only'));
      expect(result.hits.first.score, closeTo(1.0 / 61.0, 1e-10));
    });

    test(
      'fieldScores map contains bm25 and cosine keys for document in both lists',
      () {
        final lexHits = [
          _hit(id: 'doc', rank: 1, score: 0.8, fieldScores: {'body:bm25': 0.8}),
        ];
        final vecHits = [
          _hit(
            id: 'doc',
            rank: 1,
            score: 0.7,
            fieldScores: {'body:cosine': 0.7},
          ),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: lexHits,
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(),
        );

        final hit = result.hits.first;
        expect(hit.fieldScores['body:bm25'], closeTo(0.8, 1e-6));
        expect(hit.fieldScores['body:cosine'], closeTo(0.7, 1e-6));
      },
    );

    test('fieldScores has only bm25 key for document only in lexical list', () {
      final lexHits = [
        _hit(
          id: 'lex_only',
          rank: 1,
          score: 0.8,
          fieldScores: {'body:bm25': 0.8},
        ),
      ];

      final result = mergeWithRrf<String>(
        lexicalHits: lexHits,
        semanticHits: [],
        limit: 10,
        offset: 0,
        metadata: _meta(),
      );

      final hit = result.hits.first;
      expect(hit.fieldScores.containsKey('body:bm25'), isTrue);
      expect(hit.fieldScores.containsKey('body:cosine'), isFalse);
    });

    test(
      'fieldScores has only cosine key for document only in semantic list',
      () {
        final vecHits = [
          _hit(
            id: 'vec_only',
            rank: 1,
            score: 0.9,
            fieldScores: {'body:cosine': 0.9},
          ),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: [],
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(),
        );

        final hit = result.hits.first;
        expect(hit.fieldScores.containsKey('body:cosine'), isTrue);
        expect(hit.fieldScores.containsKey('body:bm25'), isFalse);
      },
    );

    test('fieldScores["{field}"] equals the per-field RRF contribution', () {
      // 'doc' is at position 0 in both lists → rank 1 in each.
      // RRF = 1/(60+1) + 1/(60+1) = 2/61.
      final lexHits = [
        _hit(id: 'doc', rank: 1, score: 0.8, fieldScores: {'body:bm25': 0.8}),
      ];
      final vecHits = [
        _hit(id: 'doc', rank: 1, score: 0.7, fieldScores: {'body:cosine': 0.7}),
      ];

      final result = mergeWithRrf<String>(
        lexicalHits: lexHits,
        semanticHits: vecHits,
        limit: 10,
        offset: 0,
        metadata: _meta(),
      );

      final hit = result.hits.first;
      // Both at rank 1 (position 0 in each list) → RRF = 2 * 1/61.
      final expectedRrf = 2.0 / 61.0;
      expect(hit.fieldScores['body'], closeTo(expectedRrf, 1e-10));
      expect(hit.score, closeTo(expectedRrf, 1e-10));
    });

    test('offset and limit applied after RRF sort', () {
      // 5 documents across both lists; request offset=2, limit=2.
      final lexHits = [
        _hit(id: 'doc1', rank: 1, score: 0.9, fieldScores: {'body:bm25': 0.9}),
        _hit(id: 'doc2', rank: 2, score: 0.7, fieldScores: {'body:bm25': 0.7}),
        _hit(id: 'doc3', rank: 3, score: 0.5, fieldScores: {'body:bm25': 0.5}),
      ];
      final vecHits = [
        _hit(
          id: 'doc1',
          rank: 1,
          score: 0.95,
          fieldScores: {'body:cosine': 0.95},
        ),
        _hit(
          id: 'doc4',
          rank: 2,
          score: 0.6,
          fieldScores: {'body:cosine': 0.6},
        ),
        _hit(
          id: 'doc5',
          rank: 3,
          score: 0.4,
          fieldScores: {'body:cosine': 0.4},
        ),
      ];

      final result = mergeWithRrf<String>(
        lexicalHits: lexHits,
        semanticHits: vecHits,
        limit: 2,
        offset: 2,
        metadata: _meta(total: 5),
      );

      // Total should reflect all 5 unique docs found.
      expect(result.metadata.total, equals(5));
      // Only 2 hits returned due to limit=2.
      expect(result.hits.length, equals(2));
      // Ranks start at offset+1 = 3.
      expect(result.hits.first.rank, equals(3));
      expect(result.hits.last.rank, equals(4));
    });

    test(
      'stable ordering: documents with identical RRF scores sort by docId',
      () {
        // Two documents each appearing in only one list at the same rank.
        // RRF score for each = 1/61. The one with lexicographically smaller id
        // should come first.
        final lexHits = [
          _hit(
            id: 'z_doc',
            rank: 1,
            score: 0.8,
            fieldScores: {'body:bm25': 0.8},
          ),
        ];
        final vecHits = [
          _hit(
            id: 'a_doc',
            rank: 1,
            score: 0.8,
            fieldScores: {'body:cosine': 0.8},
          ),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: lexHits,
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(),
        );

        expect(result.hits.length, equals(2));
        // 'a_doc' < 'z_doc' lexicographically → a_doc ranks first.
        expect(result.hits[0].id, equals('a_doc'));
        expect(result.hits[1].id, equals('z_doc'));
      },
    );

    test(
      'multi-field: per-field scores for different fields tracked independently',
      () {
        // doc_a appears in both field 'title' (BM25) and field 'body' (cosine).
        final lexHits = [
          _hit(
            id: 'doc_a',
            rank: 1,
            score: 0.9,
            fieldScores: {'title:bm25': 0.9},
          ),
        ];
        final vecHits = [
          _hit(
            id: 'doc_a',
            rank: 1,
            score: 0.85,
            fieldScores: {'body:cosine': 0.85},
          ),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: lexHits,
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(searched: ['title', 'body']),
        );

        final hit = result.hits.first;
        // Both component scores present.
        expect(hit.fieldScores['title:bm25'], closeTo(0.9, 1e-6));
        expect(hit.fieldScores['body:cosine'], closeTo(0.85, 1e-6));
        // Per-field RRF keys.
        expect(hit.fieldScores['title'], isNotNull);
        expect(hit.fieldScores['body'], isNotNull);
        // Both field RRF keys equal the overall document RRF score.
        expect(hit.fieldScores['title'], closeTo(hit.score, 1e-10));
        expect(hit.fieldScores['body'], closeTo(hit.score, 1e-10));
      },
    );

    test(
      'multi-field: document in both indexes for one field but only BM25 for another',
      () {
        // doc_a: 'title:bm25' from lex, 'title:cosine' from vec, 'body:bm25'
        // from lex but no 'body:cosine' from vec.
        final lexHits = [
          _hit(
            id: 'doc_a',
            rank: 1,
            score: 0.9,
            fieldScores: {'title:bm25': 0.9, 'body:bm25': 0.6},
          ),
        ];
        final vecHits = [
          _hit(
            id: 'doc_a',
            rank: 1,
            score: 0.85,
            fieldScores: {'title:cosine': 0.85},
            // no 'body:cosine' — body not indexed in vec
          ),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: lexHits,
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(searched: ['title', 'body']),
        );

        final hit = result.hits.first;
        expect(hit.fieldScores.containsKey('title:bm25'), isTrue);
        expect(hit.fieldScores.containsKey('title:cosine'), isTrue);
        expect(hit.fieldScores.containsKey('body:bm25'), isTrue);
        expect(hit.fieldScores.containsKey('body:cosine'), isFalse);
      },
    );

    test('metadata is passed through to the result', () {
      final meta = _meta(
        query: 'my query',
        searched: ['title'],
        skipped: ['summary'],
        total: 5,
      );
      final result = mergeWithRrf<String>(
        lexicalHits: [],
        semanticHits: [],
        limit: 10,
        offset: 0,
        metadata: meta,
      );
      // Empty hits but metadata preserved.
      expect(result.metadata.query, equals('my query'));
      expect(result.metadata.searched, equals(['title']));
      expect(result.metadata.skipped, equals(['summary']));
    });

    test(
      'SearchResult total reflects number of unique docs across both lists',
      () {
        final lexHits = [
          _hit(id: 'a', rank: 1, score: 0.9, fieldScores: {'body:bm25': 0.9}),
          _hit(id: 'b', rank: 2, score: 0.7, fieldScores: {'body:bm25': 0.7}),
        ];
        final vecHits = [
          // 'a' appears in both, 'c' only in vec.
          _hit(
            id: 'a',
            rank: 1,
            score: 0.95,
            fieldScores: {'body:cosine': 0.95},
          ),
          _hit(id: 'c', rank: 2, score: 0.6, fieldScores: {'body:cosine': 0.6}),
        ];

        final result = mergeWithRrf<String>(
          lexicalHits: lexHits,
          semanticHits: vecHits,
          limit: 10,
          offset: 0,
          metadata: _meta(),
        );

        // a, b, c = 3 unique docs.
        expect(result.metadata.total, equals(3));
        expect(result.hits.length, equals(3));
      },
    );
  });
}
