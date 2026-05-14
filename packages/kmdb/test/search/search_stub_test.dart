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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

// ── Minimal test model and codec ─────────────────────────────────────────���───

final class _Doc {
  const _Doc({required this.id, required this.body});
  final String id;
  final String body;
}

final class _DocCodec implements KmdbCodec<_Doc> {
  const _DocCodec();

  @override
  String keyOf(_Doc value) => value.id;

  @override
  _Doc withKey(_Doc value, String key) => _Doc(id: key, body: value.body);

  @override
  Map<String, dynamic> encode(_Doc value) => {'body': value.body};

  @override
  _Doc decode(Map<String, dynamic> json) =>
      _Doc(id: json['_id'] as String, body: json['body'] as String);
}

// ── Minimal fake embedding model for testing ─────────────────────────────────

final class _FakeEmbeddingModel implements EmbeddingModel {
  @override
  Future<(Float32List, bool)> embed(String text) async =>
      (Float32List(384), false);

  @override
  void dispose() {}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<KmdbDatabase> _openDb({
  List<FtsIndexDefinition> ftsIndexes = const [],
  List<VecIndexDefinition> vecIndexes = const [],
  EmbeddingModel? embeddingModel,
}) {
  return KmdbDatabase.open(
    path: 'test-search-stub',
    adapter: MemoryStorageAdapter(),
    ftsIndexes: ftsIndexes,
    vecIndexes: vecIndexes,
    embeddingModel: embeddingModel,
  );
}

void main() {
  group('KmdbDatabase.open() — text search parameters', () {
    test('opens successfully with empty ftsIndexes and vecIndexes', () async {
      final db = await _openDb();
      addTearDown(() => db.close());
      expect(db, isNotNull);
      expect(db.ftsIndexes, isEmpty);
      expect(db.vecIndexes, isEmpty);
      expect(db.embeddingModel, isNull);
    });

    test('opens successfully with ftsIndexes and no embeddingModel', () async {
      final def = FtsIndexDefinition(collection: 'docs', field: 'body');
      final db = await _openDb(ftsIndexes: [def]);
      addTearDown(() => db.close());
      expect(db.ftsIndexes, hasLength(1));
      expect(db.ftsIndexes.first.collection, equals('docs'));
      expect(db.ftsIndexes.first.field, equals('body'));
    });

    test(
      'opens successfully with both ftsIndexes and embeddingModel',
      () async {
        final fts = FtsIndexDefinition(collection: 'docs', field: 'body');
        final model = _FakeEmbeddingModel();
        final db = await _openDb(ftsIndexes: [fts], embeddingModel: model);
        addTearDown(() => db.close());
        expect(db.ftsIndexes, hasLength(1));
        expect(db.embeddingModel, equals(model));
      },
    );

    test(
      'throws ArgumentError when vecIndexes is non-empty but embeddingModel is null',
      () async {
        final vec = VecIndexDefinition(collection: 'docs', field: 'body');
        await expectLater(
          () => _openDb(vecIndexes: [vec]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('embeddingModel is required'),
            ),
          ),
        );
      },
    );

    test(
      'opens successfully with vecIndexes and provided embeddingModel',
      () async {
        final vec = VecIndexDefinition(collection: 'docs', field: 'body');
        final model = _FakeEmbeddingModel();
        final db = await _openDb(vecIndexes: [vec], embeddingModel: model);
        addTearDown(() => db.close());
        expect(db.vecIndexes, hasLength(1));
        expect(db.embeddingModel, equals(model));
      },
    );

    test('ftsManager returns null (stub)', () async {
      final db = await _openDb();
      addTearDown(() => db.close());
      expect(db.ftsManager, isNull);
    });

    test('vecManager returns null (stub)', () async {
      final db = await _openDb();
      addTearDown(() => db.close());
      expect(db.vecManager, isNull);
    });
  });

  group('KmdbCollection.search() — stub behaviour', () {
    late KmdbDatabase db;
    late KmdbCollection<_Doc> collection;

    setUp(() async {
      db = await _openDb();
      collection = db.collection(name: 'docs', codec: const _DocCodec());
    });

    tearDown(() => db.close());

    test('returns empty hits when no indexes are configured', () async {
      final result = await collection.search('flutter database');
      expect(result.hits, isEmpty);
    });

    test('metadata.total is 0 when no indexes are configured', () async {
      final result = await collection.search('query');
      expect(result.metadata.total, equals(0));
    });

    test('metadata.searched is empty when no indexes are configured', () async {
      final result = await collection.search('query');
      expect(result.metadata.searched, isEmpty);
    });

    test(
      'requested fields appear in metadata.skipped when no indexes available',
      () async {
        final result = await collection.search(
          'query',
          fields: ['title', 'body'],
        );
        expect(result.metadata.skipped, containsAll(['title', 'body']));
        expect(result.hits, isEmpty);
      },
    );

    test('empty query string returns empty result without error', () async {
      final result = await collection.search('');
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });

    test('metadata.query is set to the original query string', () async {
      final result = await collection.search('hello world');
      expect(result.metadata.query, equals('hello world'));
    });

    test('search with no fields argument has empty skipped', () async {
      // When fields is null, there are no requested fields to skip.
      final result = await collection.search('query');
      expect(result.metadata.skipped, isEmpty);
    });

    test('result type parameter matches collection type', () async {
      final result = await collection.search('anything');
      expect(result, isA<SearchResult<_Doc>>());
    });

    test('mode parameter is accepted without error', () async {
      for (final mode in SearchMode.values) {
        final result = await collection.search('query', mode: mode);
        expect(result.hits, isEmpty);
      }
    });

    test('pagination parameters are accepted without error', () async {
      final result = await collection.search(
        'query',
        limit: 5,
        offset: 10,
        candidates: 200,
      );
      expect(result.hits, isEmpty);
    });
  });
}
