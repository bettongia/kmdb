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

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/index/index_manager.dart';
import 'package:kmdb/src/query/index/index_reader.dart';
import 'package:kmdb/src/query/index/index_writer.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Contact {
  const _Contact({required this.id, required this.city, this.tags = const []});
  final String id;
  final String city;
  final List<String> tags;
}

final class _ContactCodec implements KmdbCodec<_Contact> {
  const _ContactCodec();

  @override
  String keyOf(_Contact v) => v.id;

  @override
  _Contact withKey(_Contact v, String key) =>
      _Contact(id: key, city: v.city, tags: v.tags);

  @override
  Map<String, dynamic> encode(_Contact v) => {
    'id': v.id,
    'city': v.city,
    'tags': v.tags,
  };

  @override
  _Contact decode(Map<String, dynamic> j) => _Contact(
    id: j['id'] as String,
    city: j['city'] as String,
    tags: (j['tags'] as List?)?.cast<String>() ?? [],
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _codec = _ContactCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

final _cityIndex = IndexDefinition('contacts', 'city');
final _tagsIndex = IndexDefinition('contacts', 'tags[]');

Future<(KmdbDatabase, KmdbCollection<_Contact>)> _openWithIndexes() async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    indexes: [_cityIndex, _tagsIndex],
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(name: 'contacts', codec: _codec));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── IndexWriter — value encoding ──────────────────────────────────────────

  group('IndexWriter.encodeValueHex', () {
    test('string produces non-empty hex', () {
      final h = IndexWriter.encodeValueHex('London');
      expect(h, isNotNull);
      expect(h!.length, greaterThan(0));
    });

    test('different strings produce different hex', () {
      expect(
        IndexWriter.encodeValueHex('London'),
        isNot(equals(IndexWriter.encodeValueHex('Paris'))),
      );
    });

    test('int encoding preserves sort order (positive)', () {
      final h1 = IndexWriter.encodeValueHex(1)!;
      final h2 = IndexWriter.encodeValueHex(2)!;
      expect(h1.compareTo(h2), lessThan(0));
    });

    test('int encoding: negative sorts before positive', () {
      final hNeg = IndexWriter.encodeValueHex(-1)!;
      final hPos = IndexWriter.encodeValueHex(1)!;
      expect(hNeg.compareTo(hPos), lessThan(0));
    });

    test('double encoding preserves sort order', () {
      final h1 = IndexWriter.encodeValueHex(1.5)!;
      final h2 = IndexWriter.encodeValueHex(2.5)!;
      expect(h1.compareTo(h2), lessThan(0));
    });

    test('bool false sorts before true', () {
      final hF = IndexWriter.encodeValueHex(false)!;
      final hT = IndexWriter.encodeValueHex(true)!;
      expect(hF.compareTo(hT), lessThan(0));
    });

    test('map (non-indexable) returns null', () {
      expect(IndexWriter.encodeValueHex(<String, dynamic>{}), isNull);
    });
  });

  // ── IndexWriter add/remove entries ────────────────────────────────────────

  group('IndexWriter add/remove entries', () {
    test('entry namespace encodes field value', () {
      final batch = WriteBatch();
      IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: _key(),
        document: {'city': 'London'},
      );
      expect(batch.length, equals(1));
      final expectedNs = IndexWriter.indexNamespaceForValue(
        _cityIndex,
        'London',
      )!;
      expect(batch.entries.first.namespace, equals(expectedNs));
    });

    test('entry key is the document key', () {
      final docKey = _key();
      final batch = WriteBatch();
      IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: docKey,
        document: {'city': 'London'},
      );
      expect(batch.entries.first.key, equals(docKey));
    });

    test('fan-out: one entry per array element in separate namespaces', () {
      final batch = WriteBatch();
      final def = IndexDefinition('contacts', 'tags[]');
      IndexWriter.addEntries(
        batch: batch,
        definition: def,
        docKey: _key(),
        document: {
          'tags': ['dart', 'flutter'],
        },
      );
      expect(batch.length, equals(2));
      // Each element has its own namespace.
      final ns0 = batch.entries[0].namespace;
      final ns1 = batch.entries[1].namespace;
      expect(ns0, isNot(equals(ns1)));
    });

    test('skips null field', () {
      final batch = WriteBatch();
      IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: _key(),
        document: {'city': null},
      );
      expect(batch.isEmpty, isTrue);
    });

    test('skips missing field', () {
      final batch = WriteBatch();
      IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: _key(),
        document: {},
      );
      expect(batch.isEmpty, isTrue);
    });

    test('remove entries adds delete with same namespace and key', () {
      final docKey = _key();
      final addBatch = WriteBatch();
      IndexWriter.addEntries(
        batch: addBatch,
        definition: _cityIndex,
        docKey: docKey,
        document: {'city': 'London'},
      );

      final delBatch = WriteBatch();
      IndexWriter.removeEntries(
        batch: delBatch,
        definition: _cityIndex,
        docKey: docKey,
        document: {'city': 'London'},
      );

      expect(delBatch.length, equals(1));
      expect(delBatch.entries.first.isDelete, isTrue);
      expect(
        delBatch.entries.first.namespace,
        equals(addBatch.entries.first.namespace),
      );
      expect(delBatch.entries.first.key, equals(addBatch.entries.first.key));
    });
  });

  // ── IndexManager state transitions ────────────────────────────────────────

  group('IndexManager states', () {
    test('freshly opened database has undefined index state', () async {
      final (db, _) = await _openWithIndexes();
      final state = await db.indexManager.getState('contacts', 'city');
      expect(state.status, equals(IndexStatus.undefined));
      await db.close();
    });

    test('getOrActivate transitions undefined → building', () async {
      final (db, _) = await _openWithIndexes();
      final state = await db.indexManager.getOrActivate('contacts', 'city');
      expect(state.status, equals(IndexStatus.building));
      await db.close();
    });

    test('index transitions to current after build completes', () async {
      final (db, col) = await _openWithIndexes();
      await col.put(_Contact(id: _key(), city: 'London'));

      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final state = await db.indexManager.getState('contacts', 'city');
      expect(state.status, equals(IndexStatus.current));
      await db.close();
    });

    test('concurrent writes may leave index stale', () async {
      final (db, col) = await _openWithIndexes();

      for (var i = 0; i < 5; i++) {
        await col.put(_Contact(id: _key(), city: 'City$i'));
      }

      await db.indexManager.getOrActivate('contacts', 'city');

      for (var i = 0; i < 3; i++) {
        await col.put(_Contact(id: _key(), city: 'New$i'));
      }

      await Future.delayed(const Duration(milliseconds: 100));

      final state = await db.indexManager.getState('contacts', 'city');
      expect(
        state.status,
        anyOf(equals(IndexStatus.current), equals(IndexStatus.stale)),
      );
      await db.close();
    });
  });

  // ── IndexReader ───────────────────────────────────────────────────────────

  group('IndexReader.lookupByValue', () {
    test('returns doc keys for matching value after build', () async {
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      final k2 = _key();
      final k3 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.put(_Contact(id: k2, city: 'Paris'));
      await col.put(_Contact(id: k3, city: 'London'));

      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(docKeys.toSet(), equals({k1, k3}));
      await db.close();
    });

    test('returns empty for value with no matches', () async {
      final (db, col) = await _openWithIndexes();
      await col.put(_Contact(id: _key(), city: 'London'));

      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'Berlin',
      );
      expect(docKeys, isEmpty);
      await db.close();
    });

    test('fan-out: returns correct doc keys for array index', () async {
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      final k2 = _key();
      await col.put(_Contact(id: k1, city: 'x', tags: ['dart', 'flutter']));
      await col.put(_Contact(id: k2, city: 'x', tags: ['flutter', 'web']));

      await db.indexManager.getOrActivate('contacts', 'tags[]');
      await Future.delayed(const Duration(milliseconds: 100));

      final flutterKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _tagsIndex,
        value: 'flutter',
      );
      expect(flutterKeys.toSet(), equals({k1, k2}));

      final dartKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _tagsIndex,
        value: 'dart',
      );
      expect(dartKeys.toSet(), equals({k1}));
      await db.close();
    });
  });

  // ── Write interception consistency ────────────────────────────────────────

  group('write interception', () {
    test('index entries written after activate + put', () async {
      final (db, col) = await _openWithIndexes();
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 50));

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(docKeys, contains(k1));
      await db.close();
    });

    test('old index entry removed when city changes', () async {
      final (db, col) = await _openWithIndexes();
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 50));

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.put(_Contact(id: k1, city: 'Paris'));

      expect(
        (await IndexReader.lookupByValue(
          store: db.store,
          definition: _cityIndex,
          value: 'London',
        )).contains(k1),
        isFalse,
      );
      expect(
        (await IndexReader.lookupByValue(
          store: db.store,
          definition: _cityIndex,
          value: 'Paris',
        )).contains(k1),
        isTrue,
      );
      await db.close();
    });

    test('index entry removed on document delete', () async {
      final (db, col) = await _openWithIndexes();
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 50));

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.delete(k1);

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(docKeys, isNot(contains(k1)));
      await db.close();
    });

    test('undefined index produces no write overhead', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        indexes: [_cityIndex],
        config: KvStoreConfig.forTesting(),
      );
      final col = db.collection(name: 'contacts', codec: _codec);

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));

      // The value-specific index namespace should not exist yet.
      final ns = IndexWriter.indexNamespaceForValue(_cityIndex, 'London')!;
      final indexKeys = await db.store.scan(ns).toList();
      expect(indexKeys, isEmpty);
      await db.close();
    });
  });
}
