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

/// Tests for [KmdbDatabase.rawCollection] and [RawDocumentCodec].
///
/// These tests verify that untyped collections returned from [rawCollection]
/// participate fully in the write pipeline: reserved-key validation, schema
/// enforcement, and secondary index maintenance all fire automatically.
library;

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/collection_schema.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/index/index_reader.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/query/raw_document_codec.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a [KmdbDatabase] with a memory adapter, optional indexes, and optional
/// schemas. Returns the database so callers can close it in tearDown.
Future<KmdbDatabase> _open({
  List<IndexDefinition> indexes = const [],
  List<CollectionSchema> schemas = const [],
}) async {
  final adapter = MemoryStorageAdapter();
  return KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    indexes: indexes,
    schemas: schemas,
    config: KvStoreConfig.forTesting(),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── RawDocumentCodec unit tests ───────────────────────────────────────────

  group('RawDocumentCodec', () {
    const codec = RawDocumentCodec();

    test('keyOf returns _id field', () {
      final doc = {'_id': 'abc123', 'name': 'Alice'};
      expect(codec.keyOf(doc), equals('abc123'));
    });

    test('keyOf throws StateError when _id is absent', () {
      final doc = {'name': 'Alice'};
      expect(() => codec.keyOf(doc), throwsA(isA<StateError>()));
    });

    test('keyOf throws StateError when _id is not a String', () {
      final doc = {'_id': 42, 'name': 'Alice'};
      expect(() => codec.keyOf(doc), throwsA(isA<StateError>()));
    });

    test('withKey returns copy with _id set', () {
      final doc = {'name': 'Alice'};
      final result = codec.withKey(doc, 'new-key');
      expect(result['_id'], equals('new-key'));
      expect(result['name'], equals('Alice'));
      // Original must not be mutated.
      expect(doc.containsKey('_id'), isFalse);
    });

    test('encode removes _id field', () {
      final doc = {'_id': 'abc', 'name': 'Alice', 'age': 30};
      final encoded = codec.encode(doc);
      expect(encoded.containsKey('_id'), isFalse);
      expect(encoded['name'], equals('Alice'));
      expect(encoded['age'], equals(30));
      // Original must not be mutated.
      expect(doc.containsKey('_id'), isTrue);
    });

    test('encode returns copy — original is not mutated', () {
      final doc = {'_id': 'abc', 'x': 1};
      codec.encode(doc);
      expect(doc['_id'], equals('abc'));
    });

    test('decode returns json unchanged', () {
      final json = {'name': 'Alice', 'age': 30};
      expect(codec.decode(json), same(json));
    });
  });

  // ── rawCollection round-trip ──────────────────────────────────────────────

  group('rawCollection round-trip', () {
    test('insert assigns a new key and get retrieves the document', () async {
      final db = await _open();
      final col = db.rawCollection('items');

      final inserted = await col.insert({'name': 'Widget', 'qty': 5});
      expect(inserted['_id'], isA<String>());
      expect(inserted['name'], equals('Widget'));
      expect(inserted['qty'], equals(5));

      final retrieved = await col.get(inserted['_id'] as String);
      expect(retrieved, isNotNull);
      expect(retrieved!['name'], equals('Widget'));
      expect(retrieved['_id'], equals(inserted['_id']));

      await db.close();
    });

    test('put upserts a document and get retrieves it', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'name': 'Gadget'});
      final doc = await col.get(key);
      expect(doc, isNotNull);
      expect(doc!['name'], equals('Gadget'));
      expect(doc['_id'], equals(key));

      await db.close();
    });

    test('put overwrites an existing document', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'name': 'First'});
      await col.put({'_id': key, 'name': 'Second'});

      final doc = await col.get(key);
      expect(doc!['name'], equals('Second'));

      await db.close();
    });

    test('get returns null for absent key', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();

      expect(await col.get(gen.next()), isNull);

      await db.close();
    });

    test('update merges fields', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'name': 'Widget', 'qty': 5});

      final result = await col.update(key, (old) {
        return Map<String, dynamic>.of(old)..['qty'] = 10;
      });
      expect(result, isNotNull);
      expect(result!['qty'], equals(10));
      expect(result['name'], equals('Widget'));

      // Verify the update is persisted.
      final persisted = await col.get(key);
      expect(persisted!['qty'], equals(10));

      await db.close();
    });

    test('update returns null when document does not exist', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();

      final result = await col.update(gen.next(), (old) => old);
      expect(result, isNull);

      await db.close();
    });

    test('delete removes a document', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'name': 'Widget'});
      await col.delete(key);

      expect(await col.get(key), isNull);

      await db.close();
    });

    test('delete is a no-op for absent key', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();

      // Should not throw.
      await col.delete(gen.next());

      await db.close();
    });
  });

  // ── rawCollection + ReservedKeyValidator (Layer 1) ────────────────────────

  group('rawCollection reserved key validation', () {
    test('insert rejects document with _-prefixed top-level field', () async {
      final db = await _open();
      final col = db.rawCollection('items');

      expect(
        () => col.insert({'_secret': 'value', 'name': 'Widget'}),
        throwsA(isA<ReservedFieldException>()),
      );

      await db.close();
    });

    test('put rejects document with _-prefixed top-level field', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      expect(
        () => col.put({'_id': key, '_secret': 'x', 'name': 'Widget'}),
        throwsA(isA<ReservedFieldException>()),
      );

      await db.close();
    });

    test('nested _ field is allowed — only top-level is reserved', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      // Must not throw — '_' prefix is only reserved at the top level.
      await col.put({
        '_id': key,
        'meta': {'_internal': 'ok'},
      });

      final doc = await col.get(key);
      expect(doc!['meta'], isA<Map>());

      await db.close();
    });

    test('update rejects merged doc with _-prefixed field', () async {
      final db = await _open();
      final col = db.rawCollection('items');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'name': 'Widget'});

      // The updater injects a reserved-prefix field; validation should fire.
      expect(
        () => col.update(key, (old) => {...old, '_evil': true}),
        throwsA(isA<ReservedFieldException>()),
      );

      await db.close();
    });
  });

  // ── rawCollection + schema (Layer 1 — SchemaManager) ─────────────────────

  group('rawCollection + schema enforcement', () {
    const contactSchema = CollectionSchema(
      collection: 'contacts',
      jsonSchema: {
        'type': 'object',
        'required': ['name', 'email'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'email': {'type': 'string'},
        },
      },
    );

    test('valid document is accepted', () async {
      final db = await _open(schemas: [contactSchema]);
      final col = db.rawCollection('contacts');

      // Should not throw.
      await col.insert({'name': 'Alice', 'email': 'alice@example.com'});

      await db.close();
    });

    test('document missing required field is rejected', () async {
      final db = await _open(schemas: [contactSchema]);
      final col = db.rawCollection('contacts');

      expect(
        () => col.insert({'name': 'Bob'}), // missing 'email'
        throwsA(isA<SchemaValidationException>()),
      );

      await db.close();
    });

    test('schema not applied to a different collection', () async {
      final db = await _open(schemas: [contactSchema]);
      // 'items' has no schema — anything goes.
      final col = db.rawCollection('items');

      // Should not throw even though 'name' and 'email' are missing.
      await col.insert({'foo': 'bar'});

      await db.close();
    });

    test('put validates schema', () async {
      final db = await _open(schemas: [contactSchema]);
      final col = db.rawCollection('contacts');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      expect(
        () => col.put({'_id': key, 'name': 'Carol'}), // missing 'email'
        throwsA(isA<SchemaValidationException>()),
      );

      await db.close();
    });

    test('update validates the merged result', () async {
      final db = await _open(schemas: [contactSchema]);
      final col = db.rawCollection('contacts');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'name': 'Dave', 'email': 'dave@example.com'});

      // Remove a required field in the updater — should be rejected.
      expect(
        () => col.update(key, (old) {
          final updated = Map<String, dynamic>.of(old)..remove('email');
          return updated;
        }),
        throwsA(isA<SchemaValidationException>()),
      );

      await db.close();
    });
  });

  // ── rawCollection + secondary index (Layer 2 — IndexManager) ─────────────

  group('rawCollection + secondary index', () {
    test('index entry is written when document is inserted', () async {
      final db = await _open(
        indexes: [IndexDefinition('products', 'category')],
      );
      final col = db.rawCollection('products');

      final doc = await col.insert({'category': 'electronics', 'name': 'TV'});
      final key = doc['_id'] as String;

      // Query via the index to confirm it was built.
      final results = await col
          .where(Field('category').equals('electronics'))
          .get();
      expect(results.length, equals(1));
      expect(results.first['_id'], equals(key));

      await db.close();
    });

    test('index entry is removed when document is deleted', () async {
      final db = await _open(
        indexes: [IndexDefinition('products', 'category')],
      );
      final col = db.rawCollection('products');

      final doc = await col.insert({'category': 'electronics', 'name': 'TV'});
      final key = doc['_id'] as String;

      await col.delete(key);

      final results = await col
          .where(Field('category').equals('electronics'))
          .get();
      expect(results, isEmpty);

      await db.close();
    });

    test('index entry is updated when document is replaced', () async {
      final db = await _open(
        indexes: [IndexDefinition('products', 'category')],
      );
      final col = db.rawCollection('products');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'category': 'electronics', 'name': 'TV'});
      await col.put({'_id': key, 'category': 'appliances', 'name': 'TV'});

      final electronics = await col
          .where(Field('category').equals('electronics'))
          .get();
      expect(electronics, isEmpty);

      final appliances = await col
          .where(Field('category').equals('appliances'))
          .get();
      expect(appliances.length, equals(1));

      await db.close();
    });

    test('array fan-out index works via rawCollection', () async {
      final db = await _open(indexes: [IndexDefinition('products', 'tags[]')]);
      final col = db.rawCollection('products');

      await col.insert({
        'tags': ['dart', 'flutter'],
        'name': 'SDK',
      });

      final results = await col.where(Field('tags').contains('flutter')).get();
      expect(results.length, equals(1));

      await db.close();
    });

    // ── Low-level index entry verification via IndexManager activation ────────
    // These tests use IndexManager.getOrActivate() to fully build the index
    // and then verify entries in the store via IndexReader.lookupByValue.
    // After the initial build, subsequent puts go through the augmentor which
    // keeps the index in sync incrementally.

    test('index entries present in store after build + put', () async {
      final db = await _open(
        indexes: [IndexDefinition('products', 'category')],
      );
      final col = db.rawCollection('products');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'category': 'electronics', 'name': 'TV'});

      // Activate the index (triggers a full build scan) then wait briefly for
      // the async write to complete before checking the store.
      await db.indexManager.getOrActivate('products', 'category');
      await Future.delayed(const Duration(milliseconds: 100));

      final definition = IndexDefinition('products', 'category');
      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: definition,
        value: 'electronics',
      );
      expect(docKeys, contains(key));

      await db.close();
    });

    test('index entries absent from store after delete', () async {
      final db = await _open(
        indexes: [IndexDefinition('products', 'category')],
      );
      final col = db.rawCollection('products');
      final gen = SequentialKeyGenerator();
      final key = gen.next();

      await col.put({'_id': key, 'category': 'electronics', 'name': 'TV'});

      // Build the index.
      await db.indexManager.getOrActivate('products', 'category');
      await Future.delayed(const Duration(milliseconds: 100));

      // The augmentor removes the entry atomically with the delete.
      await col.delete(key);

      final definition = IndexDefinition('products', 'category');
      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: definition,
        value: 'electronics',
      );
      expect(docKeys, isNot(contains(key)));

      await db.close();
    });
  });

  // ── rawCollection via KmdbDatabase.collection() equivalence ──────────────

  group(
    'rawCollection equivalence to collection(name:, codec:RawDocumentCodec())',
    () {
      test(
        'rawCollection and manual RawDocumentCodec collection behave identically',
        () async {
          final db = await _open();

          final raw = db.rawCollection('things');
          final manual = db.collection(
            name: 'things',
            codec: const RawDocumentCodec(),
          );

          // Write via rawCollection and read back via manual collection.
          final inserted = await raw.insert({'x': 1});
          final key = inserted['_id'] as String;

          final retrieved = await manual.get(key);
          expect(retrieved!['x'], equals(1));

          await db.close();
        },
      );
    },
  );
}
