// Copyright 2026 The KMDB Authors.
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

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/schema_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a fresh memory-backed database for testing.
Future<KmdbDatabase> _openDb() async {
  return KmdbDatabase.open(
    path: '/testdb',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
}

/// Creates a [CommandContext] backed by [db] with captured output sinks.
CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

/// A minimal valid JSON Schema for 'contacts'.
const _contactSchema = {
  'required': ['name', 'email'],
  'properties': {
    'name': {'type': 'string', 'minLength': 1},
    'email': {'type': 'string'},
  },
};

/// A minimal valid JSON Schema for 'tasks'.
const _taskSchema = {
  'required': ['title'],
  'properties': {
    'title': {'type': 'string'},
  },
};

/// Simple temporary file wrapper.
class _TmpFile {
  _TmpFile({String ext = 'json'})
    : path =
          '${io.Directory.systemTemp.path}'
          '/kmdb_schema_test_${DateTime.now().microsecondsSinceEpoch}.$ext';
  final String path;
  void write(String content) => io.File(path).writeAsStringSync(content);
  void delete() {
    try {
      io.File(path).deleteSync();
    } catch (_) {}
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── schema set ───────────────────────────────────────────────────────────────

  group('schema set', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('registers schema from inline --schema json', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'schema': jsonEncode(_contactSchema)},
      );
      expect(ok, isTrue);
      expect(out.toString(), contains("Schema registered for 'contacts'."));
      expect(db.schemaManager.registeredCollections, contains('contacts'));
    });

    test('registers schema from --file path', () async {
      final tmp = _TmpFile();
      addTearDown(tmp.delete);
      tmp.write(jsonEncode(_contactSchema));

      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'file': tmp.path},
      );
      expect(ok, isTrue);
      expect(out.toString(), contains("Schema registered for 'contacts'."));
      expect(db.schemaManager.registeredCollections, contains('contacts'));
    });

    test('schema is enforced after set', () async {
      final ctx = _ctx(db, out: out, err: err);
      await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'schema': jsonEncode(_contactSchema)},
      );
      // Validate an invalid doc — should fail.
      expect(
        () => db.schemaManager.validate('contacts', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('error when collection name missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['set'], {'schema': '{}'});
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name required'));
    });

    test('error when neither --schema nor --file provided', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['set', 'contacts'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('--schema'));
    });

    test('error when both --schema and --file provided', () async {
      final tmp = _TmpFile();
      addTearDown(tmp.delete);
      tmp.write('{}');

      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'schema': '{}', 'file': tmp.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    test('error when --schema is not valid JSON', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'schema': '{bad json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));
    });

    test('error when --schema root is not a JSON object (array)', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'schema': '[1, 2, 3]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('error when --file does not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['set', 'contacts'],
        {'file': '/no/such/file.json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('cannot read file'));
    });
  });

  // ── schema show ──────────────────────────────────────────────────────────────

  group('schema show', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      out = StringBuffer();
      err = StringBuffer();
      // Pre-register a schema for most tests.
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
    });
    tearDown(() => db.close());

    test('prints registered schema as pretty JSON', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['show', 'contacts'], {});
      expect(ok, isTrue);
      // Should be valid JSON containing the schema fields.
      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['required'], containsAll(['name', 'email']));
    });

    test('error when collection has no schema', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['show', 'tasks'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains("No schema registered for 'tasks'."));
    });

    test('error when collection name missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['show'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name required'));
    });
  });

  // ── schema list ──────────────────────────────────────────────────────────────

  group('schema list', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('prints message when no schemas registered', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['list'], {});
      expect(ok, isTrue);
      expect(out.toString(), contains('No schemas registered.'));
    });

    test('prints single collection name', () async {
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['list'], {});
      expect(ok, isTrue);
      expect(out.toString(), contains('contacts'));
    });

    test('prints multiple collection names — one per line', () async {
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
      await db.registerSchema(
        CollectionSchema(collection: 'tasks', jsonSchema: _taskSchema),
      );
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['list'], {});
      expect(ok, isTrue);
      final lines = out
          .toString()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, containsAll(['contacts', 'tasks']));
    });
  });

  // ── schema remove ────────────────────────────────────────────────────────────

  group('schema remove', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('removes registered schema and confirms', () async {
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['remove', 'contacts'], {});
      expect(ok, isTrue);
      expect(out.toString(), contains("Schema removed for 'contacts'."));
      expect(
        db.schemaManager.registeredCollections,
        isNot(contains('contacts')),
      );
    });

    test('removes enforcement — writes no longer validated', () async {
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
      final ctx = _ctx(db, out: out, err: err);
      await SchemaCommand().execute(ctx, ['remove', 'contacts'], {});
      // Must not throw after removal.
      expect(
        () => db.schemaManager.validate('contacts', <String, dynamic>{}),
        returnsNormally,
      );
    });

    test('unknown collection is a no-op — does not error', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, [
        'remove',
        'never_registered',
      ], {});
      expect(ok, isTrue);
      expect(
        out.toString(),
        contains("Schema removed for 'never_registered'."),
      );
    });

    test('error when collection name missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, ['remove'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name required'));
    });
  });

  // ── schema validate ──────────────────────────────────────────────────────────

  group('schema validate', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      out = StringBuffer();
      err = StringBuffer();
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
    });
    tearDown(() => db.close());

    test('prints valid:true for conforming document (--doc)', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'doc': '{"name": "Alice", "email": "a@b.com"}'},
      );
      expect(ok, isTrue);
      expect(out.toString(), contains('"valid": true'));
    });

    test('prints valid:true for conforming document (--file)', () async {
      final tmp = _TmpFile();
      addTearDown(tmp.delete);
      tmp.write('{"name": "Alice", "email": "a@b.com"}');

      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'file': tmp.path},
      );
      expect(ok, isTrue);
      expect(out.toString(), contains('"valid": true'));
    });

    test('reports violations for non-conforming document', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'doc': '{}'},
      );
      expect(ok, isFalse);
      final errStr = err.toString();
      expect(errStr, contains("schema validation failed for 'contacts'"));
      // Violations should list the missing required fields.
      expect(errStr, contains('name'));
      expect(errStr, contains('email'));
    });

    test('violation format: indented path: message per line', () async {
      final ctx = _ctx(db, out: out, err: err);
      await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'doc': '{}'},
      );
      // Each violation line must be indented with two spaces.
      final lines = err.toString().split('\n').where((l) => l.isNotEmpty);
      final violationLines = lines.skip(1).toList(); // skip the header line
      for (final line in violationLines) {
        expect(line, startsWith('  '));
      }
    });

    test(
      'no schema registered — informational message, returns true',
      () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await SchemaCommand().execute(
          ctx,
          ['validate', 'tasks'],
          {'doc': '{}'},
        );
        expect(ok, isTrue);
        expect(out.toString(), contains('Document not validated.'));
      },
    );

    test('error when collection name missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate'],
        {'doc': '{}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name required'));
    });

    test('error when neither --doc nor --file provided', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(ctx, [
        'validate',
        'contacts',
      ], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('--doc'));
    });

    test('error when both --doc and --file provided', () async {
      final tmp = _TmpFile();
      addTearDown(tmp.delete);
      tmp.write('{"name": "Alice", "email": "a@b.com"}');

      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'doc': '{"name":"Alice","email":"a@b.com"}', 'file': tmp.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    test('error when --doc is invalid JSON', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'doc': '{bad json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));
    });

    test('error when --doc is not a JSON object (array)', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'doc': '[1, 2, 3]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('error when --file does not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await SchemaCommand().execute(
        ctx,
        ['validate', 'contacts'],
        {'file': '/no/such/file.json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('cannot read file'));
    });
  });

  // ── Unknown subcommand ───────────────────────────────────────────────────────

  group('schema — routing', () {
    late KmdbDatabase db;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('error on unknown subcommand', () async {
      final ctx = _ctx(db, err: err);
      final ok = await SchemaCommand().execute(ctx, ['unknown'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('unknown subcommand'));
    });

    test('error when no subcommand provided', () async {
      final ctx = _ctx(db, err: err);
      final ok = await SchemaCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('subcommand required'));
    });
  });

  // ── Cross-collection isolation ────────────────────────────────────────────────

  group('cross-collection isolation', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('schema only enforced for its named collection', () async {
      // Register schema only for 'contacts'.
      await SchemaCommand().execute(
        _ctx(db, out: out, err: err),
        ['set', 'contacts'],
        {'schema': jsonEncode(_contactSchema)},
      );

      // 'contacts' must be validated.
      expect(
        () => db.schemaManager.validate('contacts', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );

      // 'tasks' must not be validated (no schema registered).
      expect(
        () => db.schemaManager.validate('tasks', <String, dynamic>{}),
        returnsNormally,
      );
    });

    test('remove does not affect other registered collections', () async {
      await db.registerSchema(
        CollectionSchema(collection: 'contacts', jsonSchema: _contactSchema),
      );
      await db.registerSchema(
        CollectionSchema(collection: 'tasks', jsonSchema: _taskSchema),
      );

      final ctx = _ctx(db, out: out, err: err);
      await SchemaCommand().execute(ctx, ['remove', 'contacts'], {});

      // 'tasks' must still be enforced.
      expect(
        () => db.schemaManager.validate('tasks', <String, dynamic>{}),
        throwsA(isA<SchemaValidationException>()),
      );
    });
  });
}
