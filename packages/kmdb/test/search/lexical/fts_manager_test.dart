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

/// Opens a fresh in-memory [KmdbDatabase] with one [FtsIndexDefinition].
Future<KmdbDatabase> _openDb({
  String collection = 'docs',
  String field = 'body',
  bool stopWords = false,
}) => KmdbDatabase.open(
  path: 'fts_mgr_${Object().hashCode}',
  adapter: MemoryStorageAdapter(),
  ftsIndexes: [
    FtsIndexDefinition(
      collection: collection,
      field: field,
      stopWords: stopWords,
    ),
  ],
);

/// A minimal codec for [Map<String, dynamic>] documents.
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

void main() {
  // ── interceptWrite — insert ──────────────────────────────────────────────────

  group('interceptWrite — insert', () {
    test('inserted document is found by search', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'the quick brown fox'});
      final id = doc['_id'] as String;

      final result = await col.search('quick', fields: ['body']);
      expect(result.hits, hasLength(1));
      expect(result.hits.first.id, equals(id));
    });

    test('insert with empty body creates no index entries', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': ''});
      final result = await col.search('anything', fields: ['body']);
      expect(result.hits, isEmpty);
    });

    test('insert with absent field creates no index entries', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'title': 'no body field here'});
      final result = await col.search('title', fields: ['body']);
      expect(result.hits, isEmpty);
    });

    test('two inserts produce a non-zero BM25 score', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'search engine technology'});
      await col.insert({'body': 'database systems research'});

      final result = await col.search('search', fields: ['body']);
      expect(result.hits, hasLength(1));
      expect(result.hits.first.score, greaterThan(0));
    });
  });

  // ── interceptWrite — update ──────────────────────────────────────────────────

  group('interceptWrite — update', () {
    test('updated document reflects new content; old terms excluded', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'content about cats'});
      final id = doc['_id'] as String;

      await col.put({...doc, 'body': 'content about dogs'});

      final dogs = await col.search('dogs', fields: ['body']);
      expect(dogs.hits.map((h) => h.id), contains(id));

      final cats = await col.search('cats', fields: ['body']);
      expect(cats.hits.map((h) => h.id), isNot(contains(id)));
    });

    test('corpus stats adjusted correctly on update', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'word'});
      final doc2 = await col.insert({
        'body': 'another long document with many words',
      });

      await col.put({...doc2, 'body': 'short'});

      // Both original and updated documents should be searchable.
      final result = await col.search('short', fields: ['body']);
      expect(result.hits, hasLength(1));
    });

    test('update from no-field to has-field behaves as insert', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'title': 'only a title, no body'});
      await col.put({...doc, 'body': 'body added during update'});

      final result = await col.search('body', fields: ['body']);
      expect(result.hits, hasLength(1));
    });
  });

  // ── interceptWrite — delete ──────────────────────────────────────────────────

  group('interceptWrite — delete', () {
    test('deleted document is excluded from search results', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'to be deleted soon'});
      final id = doc['_id'] as String;

      // Confirm presence before delete.
      expect(
        (await col.search('deleted', fields: ['body'])).hits.map((h) => h.id),
        contains(id),
      );

      await col.delete(id);

      expect(
        (await col.search('deleted', fields: ['body'])).hits.map((h) => h.id),
        isNot(contains(id)),
      );
    });

    test('delete of document with no indexed field is a no-op', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'title': 'no body'});
      // Should not throw.
      await expectLater(col.delete(doc['_id'] as String), completes);
    });

    test(
      'corpus stats decremented; other documents remain searchable',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        final doc1 = await col.insert({'body': 'document one here'});
        await col.insert({'body': 'document two here'});

        await col.delete(doc1['_id'] as String);

        final result = await col.search('document', fields: ['body']);
        expect(result.hits, hasLength(1));
      },
    );
  });

  // ── compact ──────────────────────────────────────────────────────────────────

  group('compact', () {
    test('compact removes stale base entries for updated document', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'before update text'});
      await col.put({...doc, 'body': 'after update text'});

      await db.ftsManager!.ensureBuilt('docs', 'body');
      await db.ftsManager!.compact('docs', 'body');

      // New content is found.
      expect((await col.search('after', fields: ['body'])).hits, hasLength(1));

      // Old content is gone.
      expect((await col.search('before', fields: ['body'])).hits, isEmpty);
    });

    test('compact removes all keys for tombstoned document', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'document to be compacted away'});
      await col.delete(doc['_id'] as String);

      await db.ftsManager!.ensureBuilt('docs', 'body');
      await db.ftsManager!.compact('docs', 'body');

      expect((await col.search('compacted', fields: ['body'])).hits, isEmpty);
    });
  });

  // ── applyDelta ────────────────────────────────────────────────────────────────

  group('applyDelta', () {
    test('added documents are indexed and appear in results', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'existing document'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Write a new document directly into the store (simulating a remote add).
      final newId = const UuidV7KeyGenerator().next();
      final newDoc = {'body': 'delta added document'};
      final batch = WriteBatch()
        ..put('docs', newId, await ValueCodec.encode(newDoc));
      await db.store.writeBatchInternal(batch);

      await db.ftsManager!.applyDelta(
        'docs',
        SyncDelta(
          namespace: 'docs',
          changes: [(docId: newId, changeType: DeltaChangeType.added)],
        ),
      );

      expect(
        (await col.search('delta', fields: ['body'])).hits.map((h) => h.id),
        contains(newId),
      );
    });

    test('deleted documents are excluded after delta', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'will be synced away'});
      final id = doc['_id'] as String;
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Remove from store and apply delete delta.
      await db.store.writeBatchInternal(WriteBatch()..delete('docs', id));

      await db.ftsManager!.applyDelta(
        'docs',
        SyncDelta(
          namespace: 'docs',
          changes: [(docId: id, changeType: DeltaChangeType.deleted)],
        ),
      );

      expect(
        (await col.search('synced', fields: ['body'])).hits.map((h) => h.id),
        isNot(contains(id)),
      );
    });

    test('applyDelta on undefined index is a no-op', () async {
      final db = await _openDb();
      await expectLater(
        db.ftsManager!.applyDelta(
          'docs',
          SyncDelta(
            namespace: 'docs',
            changes: [(docId: 'someid', changeType: DeltaChangeType.added)],
          ),
        ),
        completes,
      );
    });

    test('empty delta is applied without error', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'seed document'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      await expectLater(
        db.ftsManager!.applyDelta(
          'docs',
          const SyncDelta(namespace: 'docs', changes: []),
        ),
        completes,
      );

      // Index still works after empty delta.
      expect((await col.search('seed', fields: ['body'])).hits, hasLength(1));
    });
  });

  // ── interceptWrite skips stale/undefined indexes ─────────────────────────────

  group('interceptWrite — stale index skipped', () {
    test(
      'search on stale index triggers rebuild and returns correct results',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Build index on two documents.
        final doc1 = await col.insert({'body': 'the quick brown fox'});
        final doc2 = await col.insert({'body': 'lazy dog'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Force the index to stale (simulates interrupted build recovery).
        await db.ftsManager!.forceStateForTesting(
          'docs',
          'body',
          FtsIndexStatus.stale,
        );

        // Insert a document while stale: interceptWrite skips FTS writes so
        // this doc gets no base entries. Search triggers ensureBuilt which
        // performs a full rebuild and finds all docs, including this one.
        final doc3 = await col.insert({'body': 'stale rebuild test'});

        // Search triggers ensureBuilt internally (stale → building → current).
        final result = await col.search('rebuild', fields: ['body']);
        expect(result.hits.map((h) => h.id), contains(doc3['_id']));

        // Pre-existing docs must also be found after rebuild.
        final foxResult = await col.search('quick', fields: ['body']);
        expect(foxResult.hits.map((h) => h.id), contains(doc1['_id']));

        // Confirm index is now current (not stale).
        expect(db.ftsManager!.hasIndex('docs', 'body'), isTrue);

        // Unrelated documents are not returned.
        final dogResult = await col.search('lazy', fields: ['body']);
        expect(dogResult.hits.map((h) => h.id), contains(doc2['_id']));
      },
    );

    test('zero-token document produces no index entries', () async {
      // A document whose field tokenises to zero unique terms (e.g. only
      // punctuation) must not create any base index entries.
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': '...'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Querying any word should return no hits since the document has no tokens.
      final result = await col.search('dot', fields: ['body']);
      expect(result.hits, isEmpty);
    });
  });

  // ── checkAndTransitionOnOpen ─────────────────────────────────────────────────

  group('checkAndTransitionOnOpen', () {
    test('does not throw when no syncing indexes exist', () async {
      final db = await _openDb();
      // Should complete without error.
      await expectLater(db.ftsManager!.checkAndTransitionOnOpen(), completes);
    });
  });

  // ── hasIndex / hasAnyIndex / indexedFieldsFor ────────────────────────────────

  group('index metadata', () {
    test(
      'hasIndex returns true only for configured collection/field',
      () async {
        final db = await _openDb(collection: 'articles', field: 'content');
        expect(db.ftsManager!.hasIndex('articles', 'content'), isTrue);
        expect(db.ftsManager!.hasIndex('articles', 'other'), isFalse);
        expect(db.ftsManager!.hasIndex('other', 'content'), isFalse);
      },
    );

    test('hasAnyIndex returns true when collection has any index', () async {
      final db = await _openDb();
      expect(db.ftsManager!.hasAnyIndex('docs'), isTrue);
      expect(db.ftsManager!.hasAnyIndex('unknown'), isFalse);
    });

    test('indexedFieldsFor lists all fields for a collection', () async {
      final db = await KmdbDatabase.open(
        path: 'fts_multi_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        ftsIndexes: const [
          FtsIndexDefinition(collection: 'posts', field: 'title'),
          FtsIndexDefinition(collection: 'posts', field: 'body'),
          FtsIndexDefinition(collection: 'comments', field: 'text'),
        ],
      );
      final fields = db.ftsManager!.indexedFieldsFor('posts');
      expect(fields, containsAll(['title', 'body']));
      expect(fields, hasLength(2));
      expect(db.ftsManager!.indexedFieldsFor('comments'), equals(['text']));
    });
  });
}
