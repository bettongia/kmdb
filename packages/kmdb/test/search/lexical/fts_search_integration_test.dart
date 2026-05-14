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

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Opens a fresh in-memory [KmdbDatabase] with one [FtsIndexDefinition].
///
/// [stopWords] enables the English stop-word filter on the index.
Future<KmdbDatabase> _openDb({
  String collection = 'docs',
  String field = 'body',
  bool stopWords = false,
  List<FtsIndexDefinition>? extraIndexes,
}) {
  final indexes = [
    FtsIndexDefinition(
      collection: collection,
      field: field,
      stopWords: stopWords,
    ),
    ...?extraIndexes,
  ];
  return KmdbDatabase.open(
    path: 'fts_int_${Object().hashCode}',
    adapter: MemoryStorageAdapter(),
    ftsIndexes: indexes,
  );
}

/// A minimal [KmdbCodec] for [Map<String, dynamic>] documents.
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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── Single-field ranked search ────────────────────────────────────────────

  group('single-field ranked search', () {
    test('returns results ranked in descending BM25 score order', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      // Insert documents with different frequencies of the query term.
      // 'database' appears 3x in doc1, 1x in doc2 — doc1 should rank higher.
      await col.insert({'body': 'database database database systems'});
      final doc2 = await col.insert({'body': 'database query language'});
      final id2 = doc2['_id'] as String;

      final result = await col.search('database', fields: ['body']);

      expect(result.hits, hasLength(2));
      // Scores must be in descending order.
      expect(result.hits[0].score, greaterThan(result.hits[1].score));
      // doc2 (lower tf) is ranked second.
      expect(result.hits[1].id, equals(id2));
    });

    test('returns empty result for query that matches nothing', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'hello world'});
      final result = await col.search('zzznomatch', fields: ['body']);
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });

    test('metadata.total reflects number of matching documents', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'search engine technology'});
      await col.insert({'body': 'search result ranking'});
      await col.insert({'body': 'database systems'});

      final result = await col.search('search', fields: ['body']);
      expect(result.metadata.total, equals(2));
    });

    test('rank values start at 1 and increment', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'alpha beta gamma'});
      await col.insert({'body': 'alpha delta'});

      final result = await col.search('alpha', fields: ['body']);
      expect(result.hits, hasLength(2));
      expect(result.hits[0].rank, equals(1));
      expect(result.hits[1].rank, equals(2));
    });
  });

  // ── Multi-field search ────────────────────────────────────────────────────

  group('multi-field search', () {
    test('per-field scores in fieldScores with :bm25 suffix', () async {
      final db = await KmdbDatabase.open(
        path: 'fts_multi_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        ftsIndexes: const [
          FtsIndexDefinition(collection: 'articles', field: 'title'),
          FtsIndexDefinition(collection: 'articles', field: 'body'),
        ],
      );
      final col = db.collection(name: 'articles', codec: _codec);

      await col.insert({
        'title': 'search engine',
        'body': 'full text retrieval',
      });

      final result = await col.search('search', fields: ['title', 'body']);
      expect(result.hits, hasLength(1));

      final fieldScores = result.hits.first.fieldScores;
      // 'search' is only in the title field.
      expect(fieldScores.keys, contains('title:bm25'));
      // body did not match, so no body:bm25 entry.
      expect(fieldScores.keys, isNot(contains('body:bm25')));
    });

    test('overall score is the max of per-field scores', () async {
      final db = await KmdbDatabase.open(
        path: 'fts_multimax_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        ftsIndexes: const [
          FtsIndexDefinition(collection: 'docs', field: 'title'),
          FtsIndexDefinition(collection: 'docs', field: 'body'),
        ],
      );
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({
        'title': 'the quick fox',
        'body': 'the quick fox jumped',
      });

      final result = await col.search('quick', fields: ['title', 'body']);
      expect(result.hits, hasLength(1));

      final hit = result.hits.first;
      final perFieldMax = hit.fieldScores.values.fold(
        0.0,
        (a, b) => a > b ? a : b,
      );
      // Overall score equals the max per-field score.
      expect(hit.score, equals(perFieldMax));
    });

    test('empty fields defaults to all indexed fields', () async {
      final db = await KmdbDatabase.open(
        path: 'fts_allfields_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        ftsIndexes: const [
          FtsIndexDefinition(collection: 'docs', field: 'title'),
          FtsIndexDefinition(collection: 'docs', field: 'body'),
        ],
      );
      final col = db.collection(name: 'docs', codec: _codec);

      // Insert with 'engine' in title only.
      await col.insert({'title': 'search engine', 'body': 'general content'});

      // search() with no fields arg defaults to all indexed fields.
      final result = await col.search('engine');
      expect(result.hits, hasLength(1));
      expect(result.metadata.searched, containsAll(['title', 'body']));
    });

    test('unindexed field appears in skipped, does not cause error', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'relevant document'});

      final result = await col.search('relevant', fields: ['body', 'noindex']);
      expect(result.metadata.skipped, contains('noindex'));
      // 'body' is indexed and matched.
      expect(result.hits, hasLength(1));
    });
  });

  // ── Deleted and updated documents ─────────────────────────────────────────

  group('deleted and updated documents', () {
    test('deleted document does not appear in search results', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'to be removed from search'});
      final id = doc['_id'] as String;

      // Verify it's findable before deletion.
      final before = await col.search('removed', fields: ['body']);
      expect(before.hits.map((h) => h.id), contains(id));

      await col.delete(id);

      final after = await col.search('removed', fields: ['body']);
      expect(after.hits.map((h) => h.id), isNot(contains(id)));
    });

    test(
      'updated document reflects new content; old terms are excluded',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        final doc = await col.insert({'body': 'original topic cats'});
        final id = doc['_id'] as String;

        // Update to entirely different content.
        await col.put({...doc, 'body': 'new topic dogs'});

        final dogs = await col.search('dogs', fields: ['body']);
        expect(dogs.hits.map((h) => h.id), contains(id));

        // 'cats' no longer in the document — must not appear in results.
        final cats = await col.search('cats', fields: ['body']);
        expect(cats.hits.map((h) => h.id), isNot(contains(id)));
      },
    );

    test('overlay supersedes stale base entries before compaction', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'stale term here'});

      // Update to remove 'stale' and add 'fresh'.
      await col.put({...doc, 'body': 'fresh term here'});

      // Without calling compact, the overlay must still supersede the base.
      final fresh = await col.search('fresh', fields: ['body']);
      expect(fresh.hits, hasLength(1));

      final stale = await col.search('stale', fields: ['body']);
      expect(stale.hits, isEmpty);
    });
  });

  // ── Filter pre-filtering ──────────────────────────────────────────────────

  group('filter pre-filtering', () {
    test('filter restricts scored documents to matching subset', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final published = await col.insert({
        'body': 'published article',
        'status': 'published',
      });
      final pubId = published['_id'] as String;
      await col.insert({'body': 'draft article', 'status': 'draft'});

      final result = await col.search(
        'article',
        fields: ['body'],
        filter: Field('status').equals('published'),
      );
      expect(result.hits, hasLength(1));
      expect(result.hits.first.id, equals(pubId));
    });

    test('filter that matches no documents returns empty result', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'search me', 'category': 'A'});

      final result = await col.search(
        'search',
        fields: ['body'],
        filter: Field('category').equals('Z'),
      );
      expect(result.hits, isEmpty);
    });

    test(
      'full-scan fallback returns correct results when no secondary index',
      () async {
        // No IndexDefinition — filter resolved via full namespace scan.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        final target = await col.insert({
          'body': 'scan fallback',
          'flag': true,
        });
        final targetId = target['_id'] as String;
        await col.insert({'body': 'scan fallback', 'flag': false});

        final result = await col.search(
          'scan',
          fields: ['body'],
          filter: Field('flag').equals(true),
        );
        expect(result.hits, hasLength(1));
        expect(result.hits.first.id, equals(targetId));
      },
    );
  });

  // ── Pagination ────────────────────────────────────────────────────────────

  group('pagination', () {
    test('limit restricts number of returned hits', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      for (var i = 0; i < 5; i++) {
        await col.insert({'body': 'pagination document $i content'});
      }

      final result = await col.search('pagination', fields: ['body'], limit: 3);
      expect(result.hits, hasLength(3));
      expect(result.metadata.total, equals(5));
    });

    test('offset skips leading hits', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      for (var i = 0; i < 4; i++) {
        await col.insert({'body': 'offset document $i content'});
      }

      final page1 = await col.search(
        'offset',
        fields: ['body'],
        limit: 2,
        offset: 0,
      );
      final page2 = await col.search(
        'offset',
        fields: ['body'],
        limit: 2,
        offset: 2,
      );

      expect(page1.hits, hasLength(2));
      expect(page2.hits, hasLength(2));

      // Pages must not overlap.
      final ids1 = page1.hits.map((h) => h.id).toSet();
      final ids2 = page2.hits.map((h) => h.id).toSet();
      expect(ids1.intersection(ids2), isEmpty);
    });

    test('rank starts at offset+1 on the second page', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      for (var i = 0; i < 4; i++) {
        await col.insert({'body': 'rank page document'});
      }

      final page2 = await col.search(
        'rank',
        fields: ['body'],
        limit: 2,
        offset: 2,
      );
      expect(page2.hits, hasLength(2));
      expect(page2.hits.first.rank, equals(3));
      expect(page2.hits.last.rank, equals(4));
    });
  });

  // ── Stop words ────────────────────────────────────────────────────────────

  group('stop words', () {
    test(
      'query with all stop words returns empty result when filtering on',
      () async {
        final db = await _openDb(stopWords: true);
        final col = db.collection(name: 'docs', codec: _codec);

        await col.insert({'body': 'regular content here'});
        // 'the' and 'is' are stop words.
        final result = await col.search('the is', fields: ['body']);
        expect(result.hits, isEmpty);
      },
    );

    test('stop-word query without filtering returns results', () async {
      // stopWords: false (default) — 'the' is indexed and queryable.
      final db = await _openDb(stopWords: false);
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'the quick brown fox'});
      final result = await col.search('the', fields: ['body']);
      // With no stop-word filtering, 'the' is indexed and found.
      expect(result.hits, hasLength(1));
    });
  });

  // ── Empty query ───────────────────────────────────────────────────────────

  group('empty query', () {
    test('empty string returns empty result', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'some content'});
      final result = await col.search('', fields: ['body']);
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });
  });

  // ── ensureBuilt from pre-existing documents ───────────────────────────────

  group('ensureBuilt', () {
    test('builds index from pre-existing documents on first search', () async {
      // Insert documents before the FTS index is built.
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc1 = await col.insert({
        'body': 'pre-existing document about kittens',
      });
      final id1 = doc1['_id'] as String;
      await col.insert({'body': 'pre-existing document about puppies'});

      // Trigger ensureBuilt implicitly via the first search() call.
      final result = await col.search('kittens', fields: ['body']);
      expect(result.hits.map((h) => h.id), contains(id1));
    });

    test(
      'ensureBuilt is idempotent — calling it twice does not corrupt index',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        await col.insert({'body': 'idempotent test content'});

        await db.ftsManager!.ensureBuilt('docs', 'body');
        await db.ftsManager!.ensureBuilt('docs', 'body');

        final result = await col.search('idempotent', fields: ['body']);
        expect(result.hits, hasLength(1));
      },
    );

    test(
      'documents inserted after ensureBuilt are found immediately',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        await col.insert({'body': 'before build'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Insert after build is complete.
        final late = await col.insert({'body': 'after build document'});
        final lateId = late['_id'] as String;

        final result = await col.search('after', fields: ['body']);
        expect(result.hits.map((h) => h.id), contains(lateId));
      },
    );
  });

  // ── BM25 score properties ─────────────────────────────────────────────────

  group('BM25 score properties', () {
    test('higher term frequency produces higher score', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      // doc1 contains the query term three times; doc2 once.
      // With two docs in the corpus, IDF is the same for both.
      await col.insert({'body': 'alpha alpha alpha supplementary text'});
      final low = await col.insert({'body': 'alpha supplementary text'});
      final lowId = low['_id'] as String;

      final result = await col.search('alpha', fields: ['body']);
      expect(result.hits, hasLength(2));
      expect(result.hits[0].score, greaterThan(result.hits[1].score));
      // Lower-tf document is ranked second.
      expect(result.hits[1].id, equals(lowId));
    });

    test('all matched documents have score > 0', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'positive score document'});
      await col.insert({'body': 'another positive score text'});

      final result = await col.search('positive', fields: ['body']);
      for (final hit in result.hits) {
        expect(hit.score, greaterThan(0));
      }
    });
  });

  // ── applyDelta ────────────────────────────────────────────────────────────

  group('applyDelta', () {
    test('added documents appear in search results after delta', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'seed document'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Simulate a document arriving via sync by writing directly to the store.
      final newId = const UuidV7KeyGenerator().next();
      final newDoc = {'body': 'delta synced content'};
      final batch = WriteBatch()..put('docs', newId, ValueCodec.encode(newDoc));
      await db.store.writeBatchInternal(batch);

      await db.ftsManager!.applyDelta(
        'docs',
        SyncDelta(
          namespace: 'docs',
          changes: [(docId: newId, changeType: DeltaChangeType.added)],
        ),
      );

      final result = await col.search('delta', fields: ['body']);
      expect(result.hits.map((h) => h.id), contains(newId));
    });

    test('deleted documents are excluded from results after delta', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'soon to be synced away'});
      final id = doc['_id'] as String;
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Remove from store (simulating remote delete propagated via sync).
      await db.store.writeBatchInternal(WriteBatch()..delete('docs', id));

      await db.ftsManager!.applyDelta(
        'docs',
        SyncDelta(
          namespace: 'docs',
          changes: [(docId: id, changeType: DeltaChangeType.deleted)],
        ),
      );

      final result = await col.search('synced', fields: ['body']);
      expect(result.hits.map((h) => h.id), isNot(contains(id)));
    });

    test('state transitions: current → syncing → current', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'transition check'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // After ensureBuilt, state must be current.
      final before = await db.ftsManager!.stateFor('docs', 'body');
      expect(before?.status, equals(FtsIndexStatus.current));

      await db.ftsManager!.applyDelta(
        'docs',
        const SyncDelta(namespace: 'docs', changes: []),
      );

      // After a completed delta, state must return to current.
      final after = await db.ftsManager!.stateFor('docs', 'body');
      expect(after?.status, equals(FtsIndexStatus.current));
    });

    test(
      'crash during applyDelta leaves index in stale state after re-open',
      () async {
        // This simulates a crash by artificially setting the state to syncing
        // and then calling checkAndTransitionOnOpen (the crash-recovery path).
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        await col.insert({'body': 'crash recovery test'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Forcibly set state to syncing (as would happen if a crash occurred
        // during applyDelta).
        await db.ftsManager!.forceStateForTesting(
          'docs',
          'body',
          FtsIndexStatus.syncing,
        );

        // Simulate re-open by calling checkAndTransitionOnOpen.
        await db.ftsManager!.checkAndTransitionOnOpen();

        // The index should now be stale (crash recovery path).
        final state = await db.ftsManager!.stateFor('docs', 'body');
        expect(state?.status, equals(FtsIndexStatus.stale));

        // After ensureBuilt is called again (triggered by next search), the
        // index rebuilds and the document is still findable.
        final result = await col.search('crash', fields: ['body']);
        expect(result.hits, hasLength(1));
      },
    );
  });
}
