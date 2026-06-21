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

// In-process tests for InsertCommand.
//
// Covers: missing collection arg, reserved key rejection, invalid JSON from
// --value, mutually exclusive --import + --value, and --import without vault.
// Subprocess golden-path and --file tests live in cli_runner_test.dart.

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/insert_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

class _Sink implements StringSink {
  final StringBuffer _buf = StringBuffer();

  @override
  void write(Object? obj) => _buf.write(obj);

  @override
  void writeln([Object? obj = '']) {
    _buf.write(obj);
    _buf.write('\n');
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);

  @override
  String toString() => _buf.toString();
}

/// Opens an in-memory database and returns `(db, ctx)`.
Future<(KmdbDatabase, CommandContext)> _openCtx({
  StringSink? out,
  StringSink? err,
}) async {
  final db = await KmdbDatabase.open(
    path: '/insert_test_db',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  final ctx = CommandContext(
    db: db,
    out: out ?? StringBuffer(),
    err: err ?? StringBuffer(),
  );
  return (db, ctx);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('InsertCommand', () {
    test('missing collection arg returns false with error', () async {
      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      final result = await const InsertCommand().execute(ctx, [], {});
      expect(result, isFalse);
      expect(errSink.toString(), contains('insert requires'));
    });

    test('reserved key in document returns false with error', () async {
      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      // '_ver' is a reserved "_"-prefixed field (other than '_id').
      final result = await const InsertCommand().execute(
        ctx,
        ['docs'],
        {'value': '{"_ver": 1, "name": "bad"}'},
      );
      expect(result, isFalse);
      expect(errSink.toString(), contains('reserved'));
      expect(errSink.toString(), contains('"_ver"'));
    });

    test('invalid JSON from --value returns false with error', () async {
      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      final result = await const InsertCommand().execute(
        ctx,
        ['docs'],
        {'value': '{not valid json}'},
      );
      expect(result, isFalse);
      expect(errSink.toString(), contains('Invalid JSON'));
    });

    test(
      'non-object JSON value from --value returns false with error',
      () async {
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(err: errSink);
        addTearDown(db.close);

        // A bare string is not an object or array.
        final result = await const InsertCommand().execute(
          ctx,
          ['docs'],
          {'value': '"just a string"'},
        );
        expect(result, isFalse);
        expect(errSink.toString(), isNotEmpty);
      },
    );

    test('array with non-object item returns false with error', () async {
      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      // Array where second item is not an object.
      final result = await const InsertCommand().execute(
        ctx,
        ['docs'],
        {'value': '[{"name":"ok"}, 42]'},
      );
      expect(result, isFalse);
      expect(errSink.toString(), contains('not a JSON object'));
    });

    test(
      '--import with --value is mutually exclusive → false + error',
      () async {
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(err: errSink);
        addTearDown(db.close);

        final result = await const InsertCommand().execute(
          ctx,
          ['docs'],
          {'import': 'some.kvlt', 'value': '{"name":"x"}'},
        );
        expect(result, isFalse);
        expect(errSink.toString(), contains('mutually exclusive'));
      },
    );

    test(
      '--import without vault configured returns false with error',
      () async {
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(err: errSink);
        addTearDown(db.close);

        // No vault store configured on this db.
        final result = await const InsertCommand().execute(
          ctx,
          ['docs'],
          {'import': 'some.kvlt'},
        );
        expect(result, isFalse);
        expect(errSink.toString(), contains('vault'));
      },
    );

    test('--file with non-existent path returns false with error', () async {
      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      final result = await const InsertCommand().execute(
        ctx,
        ['docs'],
        {'file': '/nonexistent/path/doc.json'},
      );
      expect(result, isFalse);
      expect(errSink.toString(), contains('Cannot read file'));
    });

    test('--file with NDJSON extension reads NDJSON lines', () async {
      final tmpDir = io.Directory.systemTemp.createTempSync('kmdb_ins_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final ndjsonFile = io.File('${tmpDir.path}/docs.ndjson')
        ..writeAsStringSync('{"name":"Alice"}\n{"name":"Bob"}\n');

      final outSink = _Sink();
      final (db, ctx) = await _openCtx(out: outSink);
      addTearDown(db.close);

      final result = await const InsertCommand().execute(
        ctx,
        ['docs'],
        {'file': ndjsonFile.path},
      );
      expect(result, isTrue);

      // Verify both docs were inserted.
      final count = await db.rawCollection('docs').all().count();
      expect(count, equals(2));
    });

    test('--file with invalid NDJSON line returns false with error', () async {
      final tmpDir = io.Directory.systemTemp.createTempSync('kmdb_ins_bad_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final ndjsonFile = io.File('${tmpDir.path}/bad.ndjson')
        ..writeAsStringSync('{"name":"Alice"}\n{bad json}\n');

      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      final result = await const InsertCommand().execute(
        ctx,
        ['docs'],
        {'file': ndjsonFile.path},
      );
      expect(result, isFalse);
      expect(errSink.toString(), contains('invalid JSON'));
    });

    test(
      '--file with non-existent NDJSON file returns false with error',
      () async {
        // Exercises the IOException path in _readNdjsonFile (lines 363-365).
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(err: errSink);
        addTearDown(db.close);

        final result = await const InsertCommand().execute(
          ctx,
          ['docs'],
          {'file': '/nonexistent/path/missing.ndjson'},
        );
        expect(result, isFalse);
        expect(errSink.toString(), contains('Cannot read file'));
      },
    );

    test(
      '--file NDJSON with a non-object line returns false with error',
      () async {
        // Exercises _parseNdjson when a line is valid JSON but not an object
        // (line 390: ctx.writeError(...) for non-Map decoded value).
        final tmpDir = io.Directory.systemTemp.createTempSync(
          'kmdb_ins_scalar_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));

        // A valid JSON string (not an object) on the second line.
        final ndjsonFile = io.File('${tmpDir.path}/scalar.ndjson')
          ..writeAsStringSync('{"name":"Alice"}\n42\n');

        final errSink = _Sink();
        final (db, ctx) = await _openCtx(err: errSink);
        addTearDown(db.close);

        final result = await const InsertCommand().execute(
          ctx,
          ['docs'],
          {'file': ndjsonFile.path},
        );
        expect(result, isFalse);
        expect(errSink.toString(), contains('expected JSON object'));
      },
    );
  });
}
