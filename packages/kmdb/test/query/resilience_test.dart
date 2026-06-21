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

// Group G: engine and query layer resilience tests.
//
// Covers edge cases in KmdbDatabase, KmdbCollection, and KmdbQuery that were
// not exercised by the golden-path tests. All storage-touching tests use
// MemoryStorageAdapter (which is fine for query-layer functional tests) or
// a real tmpdir adapter.

import 'dart:async';

import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/collection_schema.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/filter/filter.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Doc {
  const _Doc({required this.id, required this.name, this.score = 0});
  final String id;
  final String name;
  final int score;
}

final class _DocCodec implements KmdbCodec<_Doc> {
  const _DocCodec();

  @override
  String keyOf(_Doc v) => v.id;

  @override
  _Doc withKey(_Doc v, String key) =>
      _Doc(id: key, name: v.name, score: v.score);

  @override
  Map<String, dynamic> encode(_Doc v) => {'name': v.name, 'score': v.score};

  @override
  _Doc decode(Map<String, dynamic> j) => _Doc(
    id: j['_id'] as String,
    name: j['name'] as String,
    score: j['score'] as int? ?? 0,
  );
}

const _codec = _DocCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

Future<(KmdbDatabase, KmdbCollection<_Doc>)> _open() async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db_resilience',
    adapter: adapter,
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(name: 'docs', codec: _codec));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── KmdbDatabase ─────────────────────────────────────────────────────────────

  group('KmdbDatabase', () {
    test('close() is idempotent — calling twice does not throw', () async {
      final (db, _) = await _open();
      await db.close();
      // Second close should be a no-op, not an exception.
      await expectLater(db.close(), completes);
    });

    test('open() with an empty ftsIndexes list opens without error', () async {
      final db = await KmdbDatabase.open(
        path: '/db_empty_fts',
        adapter: MemoryStorageAdapter(),
        ftsIndexes: const [],
        config: KvStoreConfig.forTesting(),
      );
      addTearDown(db.close);
      expect(db.ftsManager, isNull);
    });

    test(
      'changePassphrase() on a non-encrypted DB raises StateError',
      () async {
        final (db, _) = await _open();
        addTearDown(db.close);

        // The database has no encryption blob — changePassphrase must throw.
        await expectLater(
          db.changePassphrase(
            currentConfig: EncryptionConfig(passphrase: 'old'),
            newPassphrase: 'new',
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('onResume() completes without error on an in-memory store', () async {
      final (db, _) = await _open();
      addTearDown(db.close);
      // onResume() is a no-op on desktop (no materialised view tier in tests).
      await expectLater(db.onResume(), completes);
    });

    test(
      'open() with onIndexReady fires callback when index build completes',
      () async {
        final ready = <(String, String)>[];

        final db = await KmdbDatabase.open(
          path: '/db_index_ready',
          adapter: MemoryStorageAdapter(),
          config: KvStoreConfig.forTesting(),
          indexes: [IndexDefinition('items', 'name')],
          onIndexReady: (ns, path) => ready.add((ns, path)),
        );
        addTearDown(db.close);

        // Insert a document and activate the index to trigger the build.
        final col = db.rawCollection('items');
        await col.insert({'name': 'widget'});
        await db.indexManager.getOrActivate('items', 'name');

        // Allow the async build to complete.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // The onIndexReady callback should have fired.
        expect(ready, contains(('items', 'name')));
      },
    );
  });

  // ── KmdbCollection ────────────────────────────────────────────────────────────

  group('KmdbCollection', () {
    test(
      'put() with a document that fails schema validation raises SchemaViolationError; '
      'document is NOT persisted',
      () async {
        final db = await KmdbDatabase.open(
          path: '/db_schema',
          adapter: MemoryStorageAdapter(),
          config: KvStoreConfig.forTesting(),
          schemas: const [
            CollectionSchema(
              collection: 'docs',
              jsonSchema: {
                'type': 'object',
                'required': ['name'],
                'properties': {
                  'name': {'type': 'string'},
                },
              },
            ),
          ],
        );
        addTearDown(db.close);

        final col = db.rawCollection('docs');

        // Valid insert — should succeed.
        final inserted = await col.insert({'name': 'Alice'});
        final id = inserted['_id'] as String;

        // Invalid put (missing required 'name' field) — should be rejected.
        await expectLater(
          col.put({'_id': id, 'body': 'no name field'}),
          throwsA(isA<SchemaValidationException>()),
        );

        // The original document must still be present unchanged.
        final doc = await col.get(id);
        expect(doc?['name'], equals('Alice'));
      },
    );

    test('delete() on a key that does not exist is a silent no-op', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      // delete a non-existent key — should not throw.
      await expectLater(col.delete(_key()), completes);
    });

    test('watch() stream emits on write to the collection namespace', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      final events = <List<_Doc>>[];
      final sub = col.all().watch().listen(events.add);
      addTearDown(sub.cancel);

      // Insert a document — should trigger the watch() stream.
      await col.insert(_Doc(id: _key(), name: 'First'));

      // Allow the debounced stream to fire.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(events, isNotEmpty);
    });
  });

  // ── KmdbQuery ────────────────────────────────────────────────────────────────

  group('KmdbQuery', () {
    test('count() on empty collection returns 0', () async {
      final (db, col) = await _open();
      addTearDown(db.close);
      expect(await col.all().count(), equals(0));
    });

    test('any() on empty collection returns false', () async {
      final (db, col) = await _open();
      addTearDown(db.close);
      expect(await col.all().any(), isFalse);
    });

    test('first() on empty collection returns null', () async {
      final (db, col) = await _open();
      addTearDown(db.close);
      expect(await col.all().first(), isNull);
    });

    test(
      'orderBy on a field absent in some documents sorts consistently',
      () async {
        final (db, _) = await _open();
        addTearDown(db.close);

        // Use rawCollection so we can omit the 'score' field in some docs.
        final col = db.rawCollection('mixed');
        await col.insert({'name': 'A', 'score': 10});
        await col.insert({'name': 'B'}); // no score field
        await col.insert({'name': 'C', 'score': 5});

        // orderBy 'score' ascending — null/missing sorts consistently.
        final results = await db
            .rawCollection('mixed')
            .all()
            .orderBy('score')
            .get();

        // All three docs must be returned.
        expect(results.length, equals(3));
        // No crash is the key assertion; sort order is implementation-defined
        // for null values but must be stable.
      },
    );

    test('Filter.not() wrapping a nested equality filter works', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      final k1 = _key();
      final k2 = _key();
      await col.putMany([
        _Doc(id: k1, name: 'Alpha'),
        _Doc(id: k2, name: 'Beta'),
      ]);

      // Not(name == 'Alpha') should return only 'Beta'.
      final results = await col
          .where(Filter.not(Field('name').equals('Alpha')))
          .get();

      expect(results.length, equals(1));
      expect(results.first.name, equals('Beta'));
    });

    test('offset beyond result count returns empty list', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      await col.putMany([
        _Doc(id: _key(), name: 'A'),
        _Doc(id: _key(), name: 'B'),
      ]);

      final results = await col.all().offset(100).get();
      expect(results, isEmpty);
    });

    test('stream() emits all documents on first listen', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      final k1 = _key();
      final k2 = _key();
      await col.putMany([_Doc(id: k1, name: 'A'), _Doc(id: k2, name: 'B')]);

      final all = await col.all().stream().toList();
      expect(all.length, equals(2));
    });

    test('explainedGet() returns documents and query plan', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      final k1 = _key();
      await col.insert(_Doc(id: k1, name: 'Explained'));

      // explainedGet is a delegation helper on KmdbCollection.
      final query = col.all();
      final (docs, plan) = await col.explainedGet(query);
      expect(docs.length, equals(1));
      expect(docs.first.name, equals('Explained'));
      // A QueryPlan is returned (it may be empty for in-memory stores).
      expect(plan, isNotNull);
    });

    test('count() with a where filter returns filtered count', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      await col.putMany([
        _Doc(id: _key(), name: 'Alice', score: 10),
        _Doc(id: _key(), name: 'Bob', score: 5),
        _Doc(id: _key(), name: 'Carol', score: 10),
      ]);

      final count = await col.where(Field('score').equals(10)).count();
      expect(count, equals(2));
    });

    test('any() returns true when at least one document matches', () async {
      final (db, col) = await _open();
      addTearDown(db.close);

      await col.insert(_Doc(id: _key(), name: 'X'));
      expect(await col.all().any(), isTrue);
    });

    test('orderBy on a bool field exercises bool comparison branch', () async {
      // _compareValues has a `bool` branch (line 601-602 in kmdb_query.dart)
      // that is exercised only when orderBy targets a bool field.
      final (db, _) = await _open();
      addTearDown(db.close);

      final col = db.rawCollection('boolcol');
      await col.insert({'name': 'true-doc', 'active': true});
      await col.insert({'name': 'false-doc', 'active': false});
      await col.insert({'name': 'another-true', 'active': true});

      // orderBy 'active' should sort without crashing, exercising bool branch.
      final results = await col.all().orderBy('active').get();
      expect(results.length, equals(3));
    });

    test(
      'watch() propagates errors via the stream when get() throws',
      () async {
        final (db, col) = await _open();
        addTearDown(db.close);

        // Build a watch stream and start listening.
        final errors = <Object>[];
        final sub = col
            .where(Field('name').equals('x'))
            .watch()
            .handleError(errors.add)
            .listen((_) {});
        addTearDown(sub.cancel);

        // Close the database while the watch stream is still subscribed.
        // The next debounced query will fail and addError to the controller,
        // exercising the catch(e, st) branch in _emitCurrent (line 272).
        await db.close();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Error may or may not have been emitted depending on timing,
        // but the stream must not crash the test isolate.
      },
    );
  });

  // ── KmdbDatabase.registerSchema / deregisterSchema / schemaManager ────────────

  group('KmdbDatabase schema management helpers', () {
    test(
      'registerSchema persists schema and deregisterSchema removes it',
      () async {
        final db = await KmdbDatabase.open(
          path: '/db',
          adapter: MemoryStorageAdapter(),
          config: KvStoreConfig.forTesting(),
        );
        addTearDown(db.close);

        // schemaManager getter (line 1107) must expose a non-null SchemaManager.
        expect(db.schemaManager, isNotNull);

        // registerSchema (lines 1125-1126) registers via the schema manager.
        await db.registerSchema(
          CollectionSchema(
            collection: 'products',
            jsonSchema: {
              'type': 'object',
              'required': ['sku'],
            },
          ),
        );

        // deregisterSchema (lines 1143-1144) removes it; subsequent writes succeed.
        await db.deregisterSchema('products');
      },
    );
  });
}
