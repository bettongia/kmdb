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

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/collection_schema.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/schema/schema_manager.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<KvStoreImpl> _openStore() async {
  final (store, _) = await KvStoreImpl.open(
    '/db',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return store;
}

Uint8List _encodePayload({
  required int version,
  required Map<String, dynamic> schema,
}) {
  return Uint8List.fromList(
    utf8.encode(jsonEncode({'schemaModelVersion': version, 'schema': schema})),
  );
}

Uint8List _encodeRegistry(List<String> collections) =>
    Uint8List.fromList(utf8.encode(jsonEncode(collections)));

const _contactSchema = CollectionSchema(
  collection: 'contacts',
  jsonSchema: {
    'required': ['name', 'email'],
    'properties': {
      'name': {'type': 'string', 'minLength': 1},
      'email': {'type': 'string'},
    },
  },
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── validate — no registered schema ─────────────────────────────────────────

  group('validate — no schema', () {
    test('no-op for unknown collection', () {
      final manager = SchemaManager();
      expect(
        () => manager.validate('unknown', {'anything': 'goes'}),
        returnsNormally,
      );
    });
  });

  // ── validate — in-memory validation ─────────────────────────────────────────

  group('validate — in-memory', () {
    late SchemaManager manager;

    setUp(() async {
      final store = await _openStore();
      manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
    });

    test('valid doc passes', () {
      expect(
        () =>
            manager.validate('contacts', {'name': 'Alice', 'email': 'a@b.com'}),
        returnsNormally,
      );
    });

    test('missing required field throws SchemaValidationException', () {
      expect(
        () => manager.validate('contacts', {'email': 'a@b.com'}),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('exception reports collection name', () {
      try {
        manager.validate('contacts', {'name': 'Alice'});
        fail('expected exception');
      } on SchemaValidationException catch (e) {
        expect(e.collection, 'contacts');
      }
    });

    test('exception includes all violations', () {
      try {
        manager.validate('contacts', <String, dynamic>{});
        fail('expected exception');
      } on SchemaValidationException catch (e) {
        // both 'name' and 'email' are required
        expect(e.violations.length, 2);
      }
    });

    test('violation paths identify missing fields', () {
      try {
        manager.validate('contacts', <String, dynamic>{});
        fail('expected exception');
      } on SchemaValidationException catch (e) {
        final paths = e.violations.map((v) => v.path).toSet();
        expect(paths, containsAll(['name', 'email']));
      }
    });

    test('minLength violation reported', () {
      expect(
        () => manager.validate('contacts', {'name': '', 'email': 'x@y.com'}),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('additional properties allowed by default', () {
      expect(
        () => manager.validate('contacts', {
          'name': 'Bob',
          'email': 'b@c.com',
          'extra': 42,
        }),
        returnsNormally,
      );
    });

    test('unregistered collection not affected', () {
      expect(
        () => manager.validate('tasks', <String, dynamic>{}),
        returnsNormally,
      );
    });
  });

  // ── register — persistence ───────────────────────────────────────────────────

  group('register — persistence', () {
    test('schema survives round-trip via load()', () async {
      final store = await _openStore();
      final manager1 = SchemaManager();
      await manager1.register(_contactSchema, store.meta);

      // A fresh manager loading from the same store should enforce the schema.
      final manager2 = SchemaManager();
      await manager2.load(store.meta);

      expect(
        () => manager2.validate('contacts', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('load() skips already-registered collection', () async {
      final store = await _openStore();

      // Register a permissive (empty) schema first.
      final loose = const CollectionSchema(
        collection: 'contacts',
        jsonSchema: <String, dynamic>{},
      );
      final manager = SchemaManager();
      await manager.register(loose, store.meta);

      // Overwrite in meta with the stricter schema (simulates a sync).
      final strict = SchemaManager();
      await strict.register(_contactSchema, store.meta);

      // load() must not overwrite the already-registered loose schema.
      await manager.load(store.meta);
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
    });

    test('unknown collection loaded from meta is enforced', () async {
      final store = await _openStore();

      final writer = SchemaManager();
      await writer.register(_contactSchema, store.meta);

      // A second instance that never called register() loads it from storage.
      final reader = SchemaManager();
      await reader.load(store.meta);

      expect(
        () => reader.validate('contacts', {'email': 'only@email.com'}),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('multiple schemas round-trip correctly', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.register(
        const CollectionSchema(
          collection: 'tasks',
          jsonSchema: {
            'required': ['title'],
          },
        ),
        store.meta,
      );

      final reader = SchemaManager();
      await reader.load(store.meta);

      expect(
        () => reader.validate('contacts', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );
      expect(
        () => reader.validate('tasks', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );
    });
  });

  // ── version mismatch ─────────────────────────────────────────────────────────

  group('version mismatch', () {
    test('onSchemaVersionMismatch called for newer schema version', () async {
      final store = await _openStore();

      await store.meta.putRawByName(
        'schema:contacts',
        _encodePayload(
          version: SchemaManager.kSchemaModelVersion + 1,
          schema: {
            'required': ['name'],
          },
        ),
      );
      await store.meta.putRawByName(
        'schema:__registry__',
        _encodeRegistry(['contacts']),
      );

      String? mismatchCollection;
      int? mismatchStored;
      int? mismatchSupported;

      final manager = SchemaManager(
        onSchemaVersionMismatch: (c, stored, supported) {
          mismatchCollection = c;
          mismatchStored = stored;
          mismatchSupported = supported;
        },
      );
      await manager.load(store.meta);

      expect(mismatchCollection, 'contacts');
      expect(mismatchStored, SchemaManager.kSchemaModelVersion + 1);
      expect(mismatchSupported, SchemaManager.kSchemaModelVersion);
    });

    test('schema not enforced after version mismatch', () async {
      final store = await _openStore();

      await store.meta.putRawByName(
        'schema:contacts',
        _encodePayload(
          version: SchemaManager.kSchemaModelVersion + 1,
          schema: {
            'required': ['name'],
          },
        ),
      );
      await store.meta.putRawByName(
        'schema:__registry__',
        _encodeRegistry(['contacts']),
      );

      final manager = SchemaManager(
        onSchemaVersionMismatch: (collection, stored, supported) {},
      );
      await manager.load(store.meta);

      // Must NOT throw even though the schema requires 'name'.
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
    });

    test('corrupt payload silently skipped', () async {
      final store = await _openStore();
      await store.meta.putRawByName(
        'schema:contacts',
        Uint8List.fromList([0x00, 0xff, 0xfe]),
      );
      await store.meta.putRawByName(
        'schema:__registry__',
        _encodeRegistry(['contacts']),
      );

      final manager = SchemaManager();
      // Must not throw.
      await manager.load(store.meta);
      // Enforcement disabled for corrupt schema.
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
    });
  });

  // ── registeredCollections ────────────────────────────────────────────────────

  group('registeredCollections', () {
    test('empty when no schemas registered', () {
      final manager = SchemaManager();
      expect(manager.registeredCollections, isEmpty);
    });

    test('returns collection name after register', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      expect(manager.registeredCollections, contains('contacts'));
    });

    test('returns correct list after registering multiple schemas', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.register(
        const CollectionSchema(
          collection: 'tasks',
          jsonSchema: {
            'required': ['title'],
          },
        ),
        store.meta,
      );
      expect(manager.registeredCollections, containsAll(['contacts', 'tasks']));
      expect(manager.registeredCollections.length, 2);
    });

    test('collection removed from list after deregister', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.deregister('contacts', store.meta);
      expect(manager.registeredCollections, isNot(contains('contacts')));
    });

    test('other collections unaffected by deregister', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.register(
        const CollectionSchema(
          collection: 'tasks',
          jsonSchema: {
            'required': ['title'],
          },
        ),
        store.meta,
      );
      await manager.deregister('contacts', store.meta);
      expect(manager.registeredCollections, contains('tasks'));
      expect(manager.registeredCollections, isNot(contains('contacts')));
    });
  });

  // ── getSchema ────────────────────────────────────────────────────────────────

  group('getSchema', () {
    test('returns null for unknown collection', () {
      final manager = SchemaManager();
      expect(manager.getSchema('unknown'), isNull);
    });

    test('returns schema map for registered collection', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      final schema = manager.getSchema('contacts');
      expect(schema, isNotNull);
      expect(schema!['required'], containsAll(['name', 'email']));
    });

    test('returns raw map that round-trips to the original schema', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      final jsonSchema = <String, dynamic>{
        'required': ['name'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
        },
      };
      await manager.register(
        CollectionSchema(collection: 'items', jsonSchema: jsonSchema),
        store.meta,
      );
      final returned = manager.getSchema('items');
      expect(returned, equals(jsonSchema));
    });

    test('returns null after deregister', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.deregister('contacts', store.meta);
      expect(manager.getSchema('contacts'), isNull);
    });

    test('schema returned after load() matches original', () async {
      final store = await _openStore();
      final manager1 = SchemaManager();
      await manager1.register(_contactSchema, store.meta);

      // A fresh manager must return the same schema after loading from meta.
      final manager2 = SchemaManager();
      await manager2.load(store.meta);
      final schema = manager2.getSchema('contacts');
      expect(schema, isNotNull);
      expect(schema!['required'], containsAll(['name', 'email']));
    });
  });

  // ── deregister ───────────────────────────────────────────────────────────────

  group('deregister', () {
    test('stops enforcement for that collection', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);

      // Confirm schema is enforced before deregister.
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );

      await manager.deregister('contacts', store.meta);

      // After deregister, writes must pass without validation.
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
    });

    test('deregister of unknown collection is a no-op', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      // Must not throw.
      expect(
        () => manager.deregister('never_registered', store.meta),
        returnsNormally,
      );
    });

    test('registry updated correctly — does not appear after load()', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.deregister('contacts', store.meta);

      // A fresh manager loading from the same store must not enforce the schema.
      final fresh = SchemaManager();
      await fresh.load(store.meta);
      expect(
        () => fresh.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
      expect(fresh.registeredCollections, isNot(contains('contacts')));
    });

    test('other registered collections unaffected by deregister', () async {
      final store = await _openStore();
      final manager = SchemaManager();
      await manager.register(_contactSchema, store.meta);
      await manager.register(
        const CollectionSchema(
          collection: 'tasks',
          jsonSchema: {
            'required': ['title'],
          },
        ),
        store.meta,
      );

      await manager.deregister('contacts', store.meta);

      // 'tasks' schema must still be enforced.
      expect(
        () => manager.validate('tasks', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );

      // 'tasks' must survive a fresh load as well.
      final fresh = SchemaManager();
      await fresh.load(store.meta);
      expect(
        () => fresh.validate('tasks', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('deregister after load() removes enforcement', () async {
      final store = await _openStore();

      // Persist the schema via one manager.
      final writer = SchemaManager();
      await writer.register(_contactSchema, store.meta);

      // Load in a fresh manager and then deregister.
      final manager = SchemaManager();
      await manager.load(store.meta);
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );

      await manager.deregister('contacts', store.meta);
      expect(
        () => manager.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
    });
  });
}
