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
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/collection_schema.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/query/schema/schema_manager.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Contact {
  const _Contact({
    required this.id,
    required this.name,
    this.email,
    this.age,
    this.extra,
  });

  final String id;
  final String name;
  final String? email;
  final int? age;
  final String? extra;
}

final class _ContactCodec implements KmdbCodec<_Contact> {
  const _ContactCodec();

  @override
  String keyOf(_Contact v) => v.id;

  @override
  _Contact withKey(_Contact v, String key) => _Contact(
    id: key,
    name: v.name,
    email: v.email,
    age: v.age,
    extra: v.extra,
  );

  @override
  Map<String, dynamic> encode(_Contact v) {
    final m = <String, dynamic>{'name': v.name};
    if (v.email != null) m['email'] = v.email;
    if (v.age != null) m['age'] = v.age;
    if (v.extra != null) m['extra'] = v.extra;
    return m;
  }

  @override
  _Contact decode(Map<String, dynamic> json) => _Contact(
    id: json['_id'] as String,
    name: json['name'] as String? ?? '',
    email: json['email'] as String?,
    age: json['age'] as int?,
    extra: json['extra'] as String?,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _codec = _ContactCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

const _strictSchema = CollectionSchema(
  collection: 'contacts',
  jsonSchema: {
    'required': ['name', 'email'],
    'properties': {
      'name': {'type': 'string', 'minLength': 1},
      'email': {'type': 'string'},
      'age': {'type': 'integer', 'minimum': 0},
    },
    'additionalProperties': false,
  },
);

Future<(KmdbDatabase, KmdbCollection<_Contact>)> _openWithSchema({
  CollectionSchema schema = _strictSchema,
}) async {
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: MemoryStorageAdapter(),
    schemas: [schema],
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(name: 'contacts', codec: _codec));
}

Future<(KmdbDatabase, KmdbCollection<_Contact>)> _openWithoutSchema() async {
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(name: 'contacts', codec: _codec));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── put ──────────────────────────────────────────────────────────────────────

  group('put', () {
    test('valid document succeeds', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      await expectLater(
        col.put(_Contact(id: _key(), name: 'Alice', email: 'a@b.com')),
        completes,
      );
    });

    test('missing required field throws SchemaValidationException', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      await expectLater(
        col.put(_Contact(id: _key(), name: 'Alice')), // no email
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test(
      'additional property rejected when additionalProperties: false',
      () async {
        final (db, col) = await _openWithSchema();
        addTearDown(db.close);
        await expectLater(
          col.put(
            _Contact(
              id: _key(),
              name: 'Alice',
              email: 'a@b.com',
              extra: 'oops',
            ),
          ),
          throwsA(isA<SchemaValidationException>()),
        );
      },
    );

    test('no partial write on schema violation', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      final id = _key();
      await expectLater(
        col.put(_Contact(id: id, name: 'Alice')), // missing email
        throwsA(isA<SchemaValidationException>()),
      );
      expect(await col.get(id), isNull);
    });

    test('no schema — any document accepted', () async {
      final (db, col) = await _openWithoutSchema();
      addTearDown(db.close);
      await expectLater(col.put(_Contact(id: _key(), name: 'Bob')), completes);
    });
  });

  // ── insert ───────────────────────────────────────────────────────────────────

  group('insert', () {
    test('valid document succeeds', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      await expectLater(
        col.insert(_Contact(id: _key(), name: 'Bob', email: 'b@c.com')),
        completes,
      );
    });

    test('invalid document throws SchemaValidationException', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      // Empty name violates minLength: 1.
      await expectLater(
        col.insert(_Contact(id: _key(), name: '', email: 'b@c.com')),
        throwsA(isA<SchemaValidationException>()),
      );
    });
  });

  // ── replace ──────────────────────────────────────────────────────────────────

  group('replace', () {
    test('valid replacement succeeds', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      final id = _key();
      await col.put(_Contact(id: id, name: 'Alice', email: 'a@b.com'));
      await expectLater(
        col.replace(_Contact(id: id, name: 'Alicia', email: 'new@b.com')),
        completes,
      );
    });

    test('invalid replacement throws SchemaValidationException', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      final id = _key();
      await col.put(_Contact(id: id, name: 'Alice', email: 'a@b.com'));
      await expectLater(
        col.replace(_Contact(id: id, name: 'Alice')), // missing email
        throwsA(isA<SchemaValidationException>()),
      );
    });
  });

  // ── update ───────────────────────────────────────────────────────────────────

  group('update', () {
    test('valid update succeeds', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      final id = _key();
      await col.put(_Contact(id: id, name: 'Alice', email: 'a@b.com'));
      await expectLater(
        col.update(
          id,
          (c) => _Contact(id: id, name: 'Alicia', email: 'a@b.com'),
        ),
        completes,
      );
    });

    test('update that produces invalid doc throws', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      final id = _key();
      await col.put(_Contact(id: id, name: 'Alice', email: 'a@b.com'));
      // Updater removes the required email field.
      await expectLater(
        col.update(id, (c) => _Contact(id: id, name: 'Alice')),
        throwsA(isA<SchemaValidationException>()),
      );
    });
  });

  // ── delete — schema NOT enforced ─────────────────────────────────────────────

  group('delete', () {
    test('delete is never blocked by schema', () async {
      final (db, col) = await _openWithSchema();
      addTearDown(db.close);
      final id = _key();
      await col.put(_Contact(id: id, name: 'Alice', email: 'a@b.com'));
      await expectLater(col.delete(id), completes);
      expect(await col.get(id), isNull);
    });
  });

  // ── additionalProperties defaults to true ────────────────────────────────────

  group('additionalProperties defaults', () {
    test(
      'extra fields accepted when additionalProperties not specified',
      () async {
        final (db, col) = await _openWithSchema(
          schema: const CollectionSchema(
            collection: 'contacts',
            jsonSchema: {
              'required': ['name', 'email'],
              'properties': {
                'name': {'type': 'string'},
                'email': {'type': 'string'},
              },
              // no additionalProperties key — defaults to true
            },
          ),
        );
        addTearDown(db.close);
        await expectLater(
          col.put(
            _Contact(id: _key(), name: 'Bob', email: 'b@c.com', extra: 'ok'),
          ),
          completes,
        );
      },
    );
  });

  // ── schema persisted across open ─────────────────────────────────────────────

  group('schema persisted across open', () {
    test('schema loaded from meta on second open', () async {
      final adapter = MemoryStorageAdapter();

      // First open — register schema and close.
      final db1 = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        schemas: [_strictSchema],
        config: KvStoreConfig.forTesting(),
      );
      await db1.close();

      // Second open — no schemas param; schema should be loaded from meta.
      final db2 = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
      );
      addTearDown(db2.close);
      final col2 = db2.collection(name: 'contacts', codec: _codec);

      await expectLater(
        col2.put(_Contact(id: _key(), name: 'Alice')), // missing email
        throwsA(isA<SchemaValidationException>()),
      );
    });
  });

  // ── onSchemaVersionMismatch callback ─────────────────────────────────────────

  group('onSchemaVersionMismatch', () {
    test(
      'callback fired and enforcement disabled for unknown version',
      () async {
        final adapter = MemoryStorageAdapter();

        // Open a store directly to write a future-version schema payload.
        final (rawStore, _) = await KvStoreImpl.open(
          '/db',
          adapter,
          config: KvStoreConfig.forTesting(),
        );
        final futurePayload = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'schemaModelVersion': SchemaManager.kSchemaModelVersion + 1,
              'schema': {
                'required': ['name', 'email'],
              },
            }),
          ),
        );
        await rawStore.meta.putRawByName('schema:contacts', futurePayload);
        await rawStore.meta.putRawByName(
          'schema:__registry__',
          Uint8List.fromList(utf8.encode(jsonEncode(['contacts']))),
        );
        await rawStore.close();

        String? callbackCollection;
        final db = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          onSchemaVersionMismatch: (collection, stored, supported) {
            callbackCollection = collection;
          },
        );
        addTearDown(db.close);
        final col = db.collection(name: 'contacts', codec: _codec);

        expect(callbackCollection, 'contacts');
        // Enforcement disabled — missing email must not throw.
        await expectLater(
          col.put(_Contact(id: _key(), name: 'Alice')),
          completes,
        );
      },
    );
  });
}
