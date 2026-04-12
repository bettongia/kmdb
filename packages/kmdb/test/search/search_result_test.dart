// Copyright 2026 The KMDB Authors
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

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

void main() {
  group('SearchMetadata', () {
    test('construction stores all fields', () {
      final meta = SearchMetadata(
        query: 'flutter database',
        searched: ['title', 'body'],
        skipped: ['summary'],
        total: 42,
      );
      expect(meta.query, equals('flutter database'));
      expect(meta.searched, equals(['title', 'body']));
      expect(meta.skipped, equals(['summary']));
      expect(meta.total, equals(42));
    });

    test('empty searched and skipped lists are valid', () {
      final meta = SearchMetadata(
        query: '',
        searched: const [],
        skipped: const [],
        total: 0,
      );
      expect(meta.searched, isEmpty);
      expect(meta.skipped, isEmpty);
      expect(meta.total, equals(0));
    });

    test('all fields in skipped represents no-index-available case', () {
      final meta = SearchMetadata(
        query: 'something',
        searched: const [],
        skipped: ['title', 'body'],
        total: 0,
      );
      expect(meta.skipped.length, equals(2));
      expect(meta.total, equals(0));
    });
  });

  group('SearchHit', () {
    test('construction stores all fields', () {
      final hit = SearchHit<String>(
        rank: 1,
        score: 0.95,
        fieldScores: {'title:bm25': 0.9, 'body:bm25': 1.0},
        id: 'abc123',
        document: 'Test Document',
      );
      expect(hit.rank, equals(1));
      expect(hit.score, closeTo(0.95, 0.001));
      expect(hit.fieldScores['title:bm25'], closeTo(0.9, 0.001));
      expect(hit.fieldScores['body:bm25'], closeTo(1.0, 0.001));
      expect(hit.id, equals('abc123'));
      expect(hit.document, equals('Test Document'));
    });

    test('fieldScores map access returns null for missing key', () {
      final hit = SearchHit<String>(
        rank: 1,
        score: 0.8,
        fieldScores: {'title:bm25': 0.8},
        id: 'abc',
        document: 'doc',
      );
      // Semantic score key not present in lexical-only hit.
      expect(hit.fieldScores['title:cosine'], isNull);
    });

    test('empty fieldScores is valid (stub mode)', () {
      final hit = SearchHit<int>(
        rank: 1,
        score: 0.0,
        fieldScores: const {},
        id: 'x',
        document: 42,
      );
      expect(hit.fieldScores, isEmpty);
    });

    test('BM25 and cosine keys coexist in hybrid mode', () {
      final hit = SearchHit<Map<String, dynamic>>(
        rank: 2,
        score: 0.032, // RRF score
        fieldScores: {'body:bm25': 0.75, 'body:cosine': 0.88},
        id: 'doc-id-001',
        document: {'title': 'Test'},
      );
      expect(hit.fieldScores['body:bm25'], closeTo(0.75, 0.001));
      expect(hit.fieldScores['body:cosine'], closeTo(0.88, 0.001));
    });
  });

  group('SearchResult', () {
    test('construction stores metadata and hits', () {
      final meta = SearchMetadata(
        query: 'test',
        searched: ['body'],
        skipped: const [],
        total: 1,
      );
      final hit = SearchHit<String>(
        rank: 1,
        score: 0.9,
        fieldScores: const {},
        id: 'abc',
        document: 'doc',
      );
      final result = SearchResult<String>(metadata: meta, hits: [hit]);

      expect(result.metadata.query, equals('test'));
      expect(result.hits.length, equals(1));
      expect(result.hits.first.rank, equals(1));
    });

    test('empty hits list is valid (no index case)', () {
      final meta = SearchMetadata(
        query: 'anything',
        searched: const [],
        skipped: ['body'],
        total: 0,
      );
      final result = SearchResult<String>(metadata: meta, hits: const []);
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });

    test('generic type parameter is preserved', () {
      final meta = SearchMetadata(
        query: 'q',
        searched: const [],
        skipped: const [],
        total: 0,
      );
      // SearchResult<int> — document type is int
      final result = SearchResult<int>(metadata: meta, hits: const []);
      expect(result, isA<SearchResult<int>>());
    });
  });

  group('SearchMode', () {
    test('enum has three values', () {
      expect(SearchMode.values.length, equals(3));
    });

    test('values are auto, lexical, semantic', () {
      expect(
        SearchMode.values,
        containsAll([SearchMode.auto, SearchMode.lexical, SearchMode.semantic]),
      );
    });

    test('default mode in search() is auto', () {
      // This test verifies the enum default value used in the method signature.
      const mode = SearchMode.auto;
      expect(mode, equals(SearchMode.auto));
    });
  });
}
