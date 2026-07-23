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

    // Tests for compact() overlay paths when the index is already built.
    // FTS intercept only fires when the index is active (building/current/syncing).
    // So: build first → mutate → compact (without a second ensureBuilt) → overlays.

    test(
      'compact processes tombstone overlay when index was built before delete',
      () async {
        // Build the index with a doc first so the index status becomes current.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Seed a doc and build the index so status transitions to current.
        await col.insert({'body': 'seed content here'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Now insert another doc while index is current (intercept fires).
        final doc = await col.insert({'body': 'to be removed later'});
        // Delete the doc — intercept fires and writes tombstone overlay.
        await col.delete(doc['_id'] as String);

        // compact() should process the tombstone overlay and remove base entries.
        // This exercises compact() lines 825-830 (tombstone branch).
        await db.ftsManager!.compact('docs', 'body');

        // The deleted doc must not appear in search results.
        expect((await col.search('removed', fields: ['body'])).hits, isEmpty);
        // The seed doc is still findable.
        expect((await col.search('seed', fields: ['body'])).hits, hasLength(1));
      },
    );

    test(
      'compact processes map overlay when index was built before update',
      () async {
        // Build the index first so the index status becomes current.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        await col.insert({'body': 'initial alpha beta'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Now insert a new doc and then update it while index is current.
        // The intercept fires and writes a map overlay for the updated doc.
        final doc = await col.insert({'body': 'original gamma delta'});
        await col.put({...doc, 'body': 'updated gamma epsilon'});

        // compact() processes the map overlay and reconciles base entries.
        // This exercises compact() lines 831-858 (map overlay branch).
        await db.ftsManager!.compact('docs', 'body');

        // Updated content is found.
        expect(
          (await col.search('epsilon', fields: ['body'])).hits,
          hasLength(1),
        );
        // Old content from before update is gone.
        expect((await col.search('original', fields: ['body'])).hits, isEmpty);
      },
    );
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

    test(
      'syncing state is transitioned to stale on open (crash recovery)',
      () async {
        // Build an index, force it to syncing (simulates an interrupted
        // applyDelta), then call checkAndTransitionOnOpen.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);
        await col.insert({'body': 'crash recovery test'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Force the index into syncing state — simulates a crash during applyDelta.
        await db.ftsManager!.forceStateForTesting(
          'docs',
          'body',
          FtsIndexStatus.syncing,
        );

        // checkAndTransitionOnOpen should detect the syncing state and
        // transition it to stale.
        await db.ftsManager!.checkAndTransitionOnOpen();

        // A subsequent search triggers ensureBuilt which rebuilds from stale.
        final result = await col.search('crash', fields: ['body']);
        expect(result.hits, hasLength(1));
      },
    );

    test(
      'applyDelta mid-sync: index enters syncing; queries return pre-delta results',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Insert and build the index.
        final doc1 = await col.insert({'body': 'pre-delta document'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Force the index into syncing state before applyDelta runs.
        await db.ftsManager!.forceStateForTesting(
          'docs',
          'body',
          FtsIndexStatus.syncing,
        );

        // Restore to current to allow applyDelta to proceed.
        await db.ftsManager!.forceStateForTesting(
          'docs',
          'body',
          FtsIndexStatus.current,
        );

        // Write a new document and apply a delta to index it.
        final newId = const UuidV7KeyGenerator().next();
        final newDoc = {'body': 'delta applied document'};
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

        // Both pre-delta and delta docs are now searchable.
        final result1 = await col.search('pre-delta', fields: ['body']);
        expect(result1.hits.map((h) => h.id), contains(doc1['_id']));
        final result2 = await col.search('delta', fields: ['body']);
        expect(result2.hits.map((h) => h.id), contains(newId));
      },
    );
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

  // ── FtsIndexState ─────────────────────────────────────────────────────────────

  group('FtsIndexState', () {
    // ── copyWith ──────────────────────────────────────────────────────────────

    test('copyWith overrides status only', () {
      const state = FtsIndexState(
        namespace: 'ns',
        field: 'f',
        status: FtsIndexStatus.current,
        builtThrough: 'abc',
        builtAt: '2026-01-01',
      );
      final updated = state.copyWith(status: FtsIndexStatus.stale);
      expect(updated.status, equals(FtsIndexStatus.stale));
      // Non-overridden fields unchanged.
      expect(updated.namespace, equals('ns'));
      expect(updated.field, equals('f'));
      expect(updated.builtThrough, equals('abc'));
      expect(updated.builtAt, equals('2026-01-01'));
    });

    test('copyWith overrides builtThrough only', () {
      const state = FtsIndexState(
        namespace: 'ns',
        field: 'f',
        status: FtsIndexStatus.building,
      );
      final updated = state.copyWith(builtThrough: 'new-key');
      expect(updated.builtThrough, equals('new-key'));
      expect(updated.status, equals(FtsIndexStatus.building));
    });

    test('copyWith overrides builtAt only', () {
      const state = FtsIndexState(
        namespace: 'ns',
        field: 'f',
        status: FtsIndexStatus.current,
        builtAt: 'old-timestamp',
      );
      final updated = state.copyWith(builtAt: 'new-timestamp');
      expect(updated.builtAt, equals('new-timestamp'));
      expect(updated.status, equals(FtsIndexStatus.current));
    });

    // ── fromBytes round-trip ─────────────────────────────────────────────────

    test('fromBytes round-trips with populated builtThrough and builtAt', () {
      const state = FtsIndexState(
        namespace: 'articles',
        field: 'body',
        status: FtsIndexStatus.current,
        builtThrough: '00112233445566778899aabbccddeeff',
        builtAt: '2026-06-19T12:00:00.000Z',
      );
      final bytes = state.toBytes();
      final restored = FtsIndexState.fromBytes('articles', 'body', bytes);
      expect(restored.namespace, equals('articles'));
      expect(restored.field, equals('body'));
      expect(restored.status, equals(FtsIndexStatus.current));
      expect(restored.builtThrough, equals('00112233445566778899aabbccddeeff'));
      expect(restored.builtAt, equals('2026-06-19T12:00:00.000Z'));
    });

    test('fromBytes with unknown status string falls back to undefined', () {
      // Build a CBOR map with an unknown status string.
      // FtsIndexState.fromBytes falls back to undefined for null or empty bytes.
      final fromNull = FtsIndexState.fromBytes('ns', 'f', null);
      expect(fromNull.status, equals(FtsIndexStatus.undefined));

      final fromEmpty = FtsIndexState.fromBytes('ns', 'f', Uint8List(0));
      expect(fromEmpty.status, equals(FtsIndexStatus.undefined));
    });

    test('fromBytes with corrupt bytes falls back to undefined', () {
      final badBytes = Uint8List.fromList([0xff, 0x00, 0xab]);
      final state = FtsIndexState.fromBytes('ns', 'f', badBytes);
      expect(state.status, equals(FtsIndexStatus.undefined));
    });

    // ── Key generators ───────────────────────────────────────────────────────

    test('baseKey produces expected format', () {
      final key = FtsIndexState.baseKey('ns', 'field', 'term', 'docId');
      expect(key, equals(r'$$fts:ns:field:term:docId'));
    });

    test('overlayKey produces expected format', () {
      final key = FtsIndexState.overlayKey('ns', 'field', 'docId');
      expect(key, equals(r'$$fts:overlay:ns:field:docId'));
    });

    test('corpusKey produces expected format', () {
      final key = FtsIndexState.corpusKey('ns', 'field');
      expect(key, equals(r'$$fts:corpus:ns:field'));
    });

    test('docKey produces expected format', () {
      final key = FtsIndexState.docKey('ns', 'field', 'docId');
      expect(key, equals(r'$$fts:doc:ns:field:docId'));
    });

    test('metaKey produces expected format', () {
      final key = FtsIndexState.metaKey('ns', 'field');
      expect(key, equals('fts:ns:field'));
    });
  });

  // ── search — edge cases ──────────────────────────────────────────────────────

  group('search — edge cases', () {
    test('empty query string returns empty result immediately', () async {
      // Exercises the `if (query.isEmpty)` early exit at line 579.
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);
      await col.insert({'body': 'some content'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      final result = await col.search('', fields: ['body']);
      expect(result.hits, isEmpty);
      expect(result.metadata.searched, isEmpty);
    });

    test('searching a non-indexed field returns empty result', () async {
      // Exercises the `if (searched.isEmpty)` path at line 595.
      final db = await _openDb(); // index is on 'body', not 'title'
      final col = db.collection(name: 'docs', codec: _codec);
      await col.insert({'body': 'some content', 'title': 'my title'});

      final result = await col.search('title', fields: ['title']);
      expect(result.hits, isEmpty);
      // 'title' is not indexed so should be in skipped.
      expect(result.metadata.skipped, contains('title'));
    });

    test(
      'document deleted from store between index read and fetch is skipped',
      () async {
        // Exercises line 665-666 (doc==null branch in search hits loop).
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        final doc = await col.insert({'body': 'phantom document'});
        final id = doc['_id'] as String;
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Remove the document from the store directly (bypasses FTS intercept)
        // so the index still references it but the document no longer exists.
        await db.store.writeBatchInternal(WriteBatch()..delete('docs', id));

        // Search should not crash and should not return the ghost document.
        final result = await col.search('phantom', fields: ['body']);
        expect(result.hits.map((h) => h.id), isNot(contains(id)));
      },
    );
  });

  // ── applyDelta — updated change type ─────────────────────────────────────────

  group('applyDelta — updated change type', () {
    test('updated document reflects new body in results', () async {
      // Exercises DeltaChangeType.updated path (lines 942-952).
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      final doc = await col.insert({'body': 'original text'});
      final id = doc['_id'] as String;
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Update document in the store to have new body text.
      final updatedDoc = {...doc, 'body': 'updated replacement body'};
      final bytes = await ValueCodec.encode(updatedDoc..remove('_id'));
      await db.store.writeBatchInternal(WriteBatch()..put('docs', id, bytes));

      // Apply delta signalling the document was updated.
      await db.ftsManager!.applyDelta(
        'docs',
        SyncDelta(
          namespace: 'docs',
          changes: [(docId: id, changeType: DeltaChangeType.updated)],
        ),
      );

      // applyDelta writes an overlay entry for the new term frequencies.
      // compact() reconciles the overlay into the base so the new terms
      // are reachable via the normal base-index search path.
      await db.ftsManager!.compact('docs', 'body');

      // The updated content should be findable after compaction.
      final result = await col.search('replacement', fields: ['body']);
      expect(result.hits.map((h) => h.id), contains(id));
    });
  });

  // ── compact — overlay and doc-removal paths ───────────────────────────────────

  group('compact — additional paths', () {
    test('compact with no overlay entries is a no-op', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await col.insert({'body': 'stable document'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // compact() when no overlay entries exist should not throw.
      await expectLater(db.ftsManager!.compact('docs', 'body'), completes);

      // Content still searchable after a no-op compact.
      expect((await col.search('stable', fields: ['body'])).hits, hasLength(1));
    });

    test(
      'compact after update removes old base entries and keeps new content',
      () async {
        // Exercises the Map-overlay path in compact (lines 829-864).
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        final doc = await col.insert({'body': 'original phrase content'});
        await col.put({...doc, 'body': 'replacement phrase content'});

        // ensureBuilt writes the overlay; compact merges it to base entries.
        await db.ftsManager!.ensureBuilt('docs', 'body');
        await db.ftsManager!.compact('docs', 'body');

        expect(
          (await col.search('replacement', fields: ['body'])).hits,
          hasLength(1),
        );
        expect((await col.search('original', fields: ['body'])).hits, isEmpty);
      },
    );
  });

  // ── interceptWrite — field removed during update ──────────────────────────────

  group('interceptWrite — field removed during update', () {
    test(
      'FTS field removed in update — doc no longer searchable on that field',
      () async {
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Insert doc with body field.
        final doc = await col.insert({'body': 'searchable text content'});
        final id = doc['_id'] as String;

        // Verify it's findable.
        expect(
          (await col.search(
            'searchable',
            fields: ['body'],
          )).hits.map((h) => h.id),
          contains(id),
        );

        // Update to remove the body field — FTS should tombstone it.
        await col.put({...doc, 'title': 'new title', 'body': null});

        // The doc should no longer be returned by body search.
        final result = await col.search('searchable', fields: ['body']);
        expect(result.hits.map((h) => h.id), isNot(contains(id)));
      },
    );
  });

  // ── stopWords: true paths ─────────────────────────────────────────────────────

  group('stopWords: true', () {
    test(
      'insert with stopWords=true indexes content words, filters stop words',
      () async {
        // Opens a DB with stopWords: true to cover the `defaultStopwords.listing`
        // branch in _interceptInsert (line 231) and _interceptUpdate (line 281).
        final db = await _openDb(stopWords: true);
        final col = db.collection(name: 'docs', codec: _codec);

        // Content word should be searchable; stop words ('the', 'a') should not.
        await col.insert({'body': 'the quick brown fox'});

        // 'quick' is a content word → should be findable.
        expect(
          (await col.search('quick', fields: ['body'])).hits,
          hasLength(1),
        );
        // 'the' is a stop word → should NOT be indexed.
        expect((await col.search('the', fields: ['body'])).hits, isEmpty);
      },
    );

    test(
      'update with stopWords=true covers the stopWords branch in _interceptUpdate',
      () async {
        // Exercises def.stopWords ? defaultStopwords.listing in _interceptUpdate
        // (line 281) when a document is updated and the field still has content.
        final db = await _openDb(stopWords: true);
        final col = db.collection(name: 'docs', codec: _codec);

        final doc = await col.insert({'body': 'original content here'});

        // Update the body — _interceptUpdate is called with stopWords=true.
        await col.put({...doc, 'body': 'updated content there'});

        // The updated content word must be findable.
        expect(
          (await col.search('updated', fields: ['body'])).hits,
          hasLength(1),
        );
        // The old unique word must no longer be ranked.
        expect((await col.search('original', fields: ['body'])).hits, isEmpty);
      },
    );
  });

  // ── BM25 search overlay paths ─────────────────────────────────────────────────

  group('BM25 search — overlay paths', () {
    test(
      'search respects tombstone overlay (deleted doc not returned before compact)',
      () async {
        // Exercises the tombstone branch in BM25 scoring (line 748: continue).
        // A deleted document writes a tombstone overlay; search must skip it
        // even before compact() is run.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Insert and verify findable.
        final doc = await col.insert({'body': 'ephemeral content'});
        final id = doc['_id'] as String;
        expect(
          (await col.search(
            'ephemeral',
            fields: ['body'],
          )).hits.map((h) => h.id),
          contains(id),
        );

        // Delete — writes a tombstone overlay.
        await col.delete(id);

        // Search without running compact(): tombstone overlay must suppress hit.
        final result = await col.search('ephemeral', fields: ['body']);
        expect(result.hits.map((h) => h.id), isNot(contains(id)));
      },
    );

    test(
      'search uses overlay tf for updated doc (overlay path, lines 750-752)',
      () async {
        // Exercises the Map-overlay branch (lines 750-752) in BM25 scoring.
        // When a document is updated, _interceptUpdate writes an overlay with
        // the new term frequencies. The BM25 scorer finds the doc via the BASE
        // term index, then reads the overlay to get the current tf value.
        //
        // To hit lines 750-754: the search term must be present BOTH in the
        // base index (so the doc is found during the term scan) AND in the
        // overlay (so the overlay-map branch is taken). This happens when the
        // doc is updated to a new body that still contains the search term.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Insert a doc with 'alpha' — base entry for 'alpha' is written.
        final doc = await col.insert({'body': 'alpha'});
        final id = doc['_id'] as String;
        expect(
          (await col.search('alpha', fields: ['body'])).hits.map((h) => h.id),
          contains(id),
        );

        // Update the body — 'alpha' is still present but the overlay is written.
        // The overlay map includes 'alpha' with tf=2 (repeated in new content).
        // The base term entry for 'alpha' still exists (compact not run yet).
        await col.put({...doc, 'body': 'alpha alpha extra'});

        // Search for 'alpha': the doc is found via the base term scan.
        // The BM25 scorer reads the overlay (it's a Map) and takes the overlay
        // tf value for 'alpha' (lines 750-754).
        final alphaResult = await col.search('alpha', fields: ['body']);
        expect(alphaResult.hits.map((h) => h.id), contains(id));

        // Also verify tombstone path: delete the doc and search.
        // The tombstone overlay suppresses the hit (line 748).
        await col.delete(id);
        final deletedResult = await col.search('alpha', fields: ['body']);
        expect(deletedResult.hits.map((h) => h.id), isNot(contains(id)));
      },
    );
  });

  // ── search — empty query ────────────────────────────────────────────────────

  group('search — empty query', () {
    test('empty search query returns empty result immediately', () async {
      // Covers fts_manager.dart line 581: `return _emptyResult(...)` for empty
      // query string. The result is returned without touching the index at all.
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);
      await col.insert({'body': 'hello world'});
      await db.ftsManager!.ensureBuilt('docs', 'body');

      // Searching with an empty string must return an empty result.
      final result = await col.search('', fields: ['body']);
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });
  });

  // ── interceptWrite — update when field was previously absent ────────────────

  group('interceptWrite — update adds field that was previously absent', () {
    test(
      'update where old doc had no FTS field is treated as fresh insert',
      () async {
        // Covers fts_manager.dart line 275: `_interceptUpdate` falls into the
        // `oldTokenCount == 0` branch and calls `_interceptInsert` directly.
        // This happens when the doc was previously indexed with an absent field
        // and is then updated to include that field.
        final db = await _openDb();
        final col = db.collection(name: 'docs', codec: _codec);

        // Insert a doc WITHOUT the indexed field so it never gets FTS entries.
        // Build the index (it skips docs with absent field — no FTS entries).
        final doc = await col.insert({'title': 'no body field here'});
        await db.ftsManager!.ensureBuilt('docs', 'body');

        // Now update the doc to ADD the indexed field.
        // _interceptUpdate fires; oldTokenCount == 0 → delegates to _interceptInsert.
        await col.put({...doc, 'body': 'newly added body text'});

        // The updated doc must now be searchable.
        final result = await col.search('newly', fields: ['body']);
        expect(result.hits, hasLength(1));
        expect(result.hits.first.id, equals(doc['_id'] as String));
      },
    );
  });

  // ── SC-10 regression: FTS state is device-local, not $meta ──────────────────

  group('SC-10 — FTS state is device-local (\$\$ftsstate, not \$meta)', () {
    test('a legacy `current` status left in \$meta (e.g. from a peer that '
        'synced before the WI-11 fix) is dead: search() does not trust it and '
        'still rebuilds from the local (empty) index', () async {
      final db = await _openDb();
      addTearDown(db.close);
      final col = db.collection(name: 'docs', codec: _codec);
      await col.insert({'body': 'searchable content'});

      // Simulate the pre-fix (or cross-device-inherited) shape: a `current`
      // FtsIndexState written under the OLD `$meta` symbolic name, with NO
      // corresponding $$ftsstate entry and no local $$fts:* index entries
      // for this document — exactly what a device that pulled a peer's
      // pre-fix `$meta` would have.
      const legacyState = FtsIndexState(
        namespace: 'docs',
        field: 'body',
        status: FtsIndexStatus.current,
      );
      await db.store.meta.putRawByName(
        FtsIndexState.metaKey('docs', 'body'),
        legacyState.toBytes(),
      );

      // search() must not trust the legacy $meta status: it must actually
      // build the index (lazily) rather than treat it as already current
      // with an empty $$fts:* namespace (which would silently return zero
      // results for a present, matching document — the SC-10 shape).
      final result = await col.search('searchable', fields: ['body']);
      expect(
        result.hits,
        isNotEmpty,
        reason:
            'a legacy \$meta entry must not be trusted as this device\'s '
            'index state (SC-10) — the index must actually build and find '
            'the present, matching document',
      );
    });
  });
}
