// Copyright 2026 The Authors.
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
import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Test for the CLI entry point.
///
/// These are end-to-end tests that run the actual `bin/kmdb.dart` script
/// using [Process.run].
void main() {
  const binPath = 'bin/kmdb.dart';

  // Resolve the package root so these tests work regardless of which
  // directory `dart test` is invoked from (workspace root or package root).
  // When invoked from the workspace root, `packages/kmdb_cli` is a
  // subdirectory; when invoked from the package root, `pubspec.yaml` is at
  // the current directory.
  final workspacePkg = p.join(p.current, 'packages', 'kmdb_cli');
  final packageRoot = io.File(p.join(workspacePkg, 'pubspec.yaml')).existsSync()
      ? workspacePkg
      : p.current;

  /// Runs the CLI with [args] and returns the result.
  Future<io.ProcessResult> run(List<String> args) async {
    // Run from the package root where pubspec.yaml is located.
    // Clear DART_VM_OPTIONS so coverage tool flags (--pause-isolates-on-exit,
    // --enable-vm-service) are not inherited by the subprocess.  Without this,
    // each CLI subprocess pauses before exiting waiting for a VM-service
    // connection that never comes, causing 30-second test timeouts.
    final result = await io.Process.run(
      'dart',
      [binPath, ...args],
      workingDirectory: packageRoot,
      environment: {...io.Platform.environment, 'DART_VM_OPTIONS': ''},
    );
    // Give the OS/FS a tiny bit of time to settle after command exit.
    await Future.delayed(const Duration(milliseconds: 50));
    return result;
  }

  late _TmpDir tmp;

  setUp(() => tmp = _TmpDir());
  tearDown(() => tmp.clean());

  group('KmdbCli — init directory guard', () {
    test('init succeeds in a non-existent directory', () async {
      final dbPath = tmp.file('fresh_db');
      final result = await run([dbPath, 'init']);
      expect(result.exitCode, equals(0), reason: result.stderr);
    });

    test('init succeeds in an empty directory', () async {
      final dbPath = tmp.file('empty_dir');
      io.Directory(dbPath).createSync();
      final result = await run([dbPath, 'init']);
      expect(result.exitCode, equals(0), reason: result.stderr);
    });

    test('init succeeds when reopening an existing KMDB database', () async {
      final dbPath = tmp.file('existing_db');
      // First init creates the database.
      final first = await run([dbPath, 'init']);
      expect(first.exitCode, equals(0), reason: first.stderr);
      // Second init on the same path should succeed.
      final second = await run([dbPath, 'init']);
      expect(second.exitCode, equals(0), reason: second.stderr);
    });

    test(
      'init fails on a non-empty directory without a KMDB database',
      () async {
        final dbPath = tmp.file('foreign_dir');
        io.Directory(dbPath).createSync();
        // Plant a foreign file in the directory.
        io.File(
          p.join(dbPath, 'existing_file.txt'),
        ).writeAsStringSync('some existing content');
        final result = await run([dbPath, 'init']);
        expect(result.exitCode, equals(1));
        expect(result.stderr, contains('is not empty'));
      },
    );

    test('init fails on a directory that contains sub-directories', () async {
      final dbPath = tmp.file('dir_with_subdir');
      io.Directory(dbPath).createSync();
      io.Directory(p.join(dbPath, 'subdir')).createSync();
      final result = await run([dbPath, 'init']);
      expect(result.exitCode, equals(1));
      expect(result.stderr, contains('is not empty'));
    });
  });

  group('KmdbCli — unknown flag guard', () {
    test('rejects short unknown flag in db-path position', () async {
      final result = await run(['-v']);
      expect(result.exitCode, equals(1));
      expect(result.stderr, contains("unknown flag '-v'"));
    });

    test('rejects long unknown flag in db-path position', () async {
      final result = await run(['--unknown-flag']);
      expect(result.exitCode, equals(1));
      expect(result.stderr, contains("unknown flag '--unknown-flag'"));
    });

    test('does not create a directory for the rejected flag', () async {
      final cwd = io.Directory.current.path;
      await run(['-v']);
      expect(io.Directory(p.join(cwd, '-v')).existsSync(), isFalse);
    });
  });

  group('KmdbCli — integration', () {
    test('shows help when no args provided', () async {
      final result = await run([]);
      // CLI returns 1 when no args provided.
      expect(result.exitCode, equals(1));
      expect(result.stdout, contains('Usage: kmdb'));
    });

    test('put then get document', () async {
      final dbPath = tmp.file('db');

      // Put document (assigned a random UUIDv7 ID)
      final putResult = await run([
        dbPath,
        'insert',
        'tasks',
        '--value',
        '{"title":"Buy bread"}',
      ]);
      expect(
        putResult.exitCode,
        equals(0),
        reason: 'Put failed: ${putResult.stderr}',
      );

      final putDocs = json.decode(putResult.stdout) as List;
      final id = putDocs[0]['_id'] as String;
      expect(id, hasLength(32));

      // Get document
      final getResult = await run([dbPath, 'get', 'tasks', id]);
      expect(
        getResult.exitCode,
        equals(0),
        reason: 'Get failed: ${getResult.stderr}',
      );
      final docs = json.decode(getResult.stdout) as List;
      expect(docs, hasLength(1));
      expect(docs[0]['title'], equals('Buy bread'));
      expect(docs[0]['_id'], equals(id));
    });

    test('delete document', () async {
      final dbPath = tmp.file('db');

      // Put
      final putResult = await run([
        dbPath,
        'insert',
        'tasks',
        '--value',
        '{"title":"x"}',
      ]);
      final id = (json.decode(putResult.stdout) as List)[0]['_id'] as String;

      // Delete
      final delResult = await run([dbPath, 'delete', 'tasks', id]);
      expect(delResult.exitCode, equals(0), reason: delResult.stderr);

      // Get (should be empty)
      final getResult = await run([dbPath, 'get', 'tasks', id]);
      // get returns 1 and error message if not found
      expect(getResult.exitCode, equals(1));
      expect(getResult.stderr, contains('not found'));
    });

    test('scan documents', () async {
      final dbPath = tmp.file('db');

      await run([dbPath, 'insert', 'tasks', '--value', '{"title":"A"}']);
      await run([dbPath, 'insert', 'tasks', '--value', '{"title":"B"}']);

      final scanResult = await run([dbPath, 'scan', 'tasks']);
      expect(scanResult.exitCode, equals(0), reason: scanResult.stderr);
      final docs = json.decode(scanResult.stdout) as List;
      expect(docs, hasLength(2));
    });

    test('import and export', () async {
      final dbPath = tmp.file('db');
      final exportPath = tmp.file('export.ndjson');

      // 1. Create some data
      final p1 = await run([dbPath, 'insert', 'tasks', '--value', '{"v":1}']);
      final p2 = await run([dbPath, 'insert', 'tasks', '--value', '{"v":2}']);
      expect(p1.exitCode, 0);
      expect(p2.exitCode, 0);

      // 2. Export using --mode ndjson to stdout, and capture it.
      final exportResult = await run([
        dbPath,
        '--format',
        'ndjson',
        'export',
        'tasks',
      ]);
      expect(
        exportResult.exitCode,
        equals(0),
        reason: 'Export failed: ${exportResult.stderr}',
      );

      final exportContent = exportResult.stdout as String;
      final exportLines = exportContent.trim().split('\n');
      expect(
        exportLines,
        hasLength(2),
        reason: 'Export should have 2 lines. Output: "$exportContent"',
      );

      // Write to file for import command.
      io.File(exportPath).writeAsStringSync(exportContent);

      // 3. Create a fresh DB and import
      final db2Path = tmp.file('db2');
      final importResult = await run([
        db2Path,
        'import',
        'tasks',
        '--input',
        exportPath,
      ]);
      expect(importResult.exitCode, equals(0), reason: importResult.stderr);

      // 4. Verify count in new DB
      final countResult = await run([db2Path, 'count', 'tasks']);
      expect(countResult.exitCode, equals(0), reason: countResult.stderr);
      final result = json.decode(countResult.stdout) as Map;
      expect(result['count'], equals(2));
    });
  });

  group('KmdbCli — --key=value flag syntax', () {
    test('insert accepts --value=<json> (equals form)', () async {
      final dbPath = tmp.file('db');
      // The shell passes --value={"title":"hi"} as a single token when the
      // user writes --value='{"title":"hi"}'. The CLI must split on the first
      // '=' to parse the flag value correctly; previously this caused the
      // process to hang waiting on stdin.
      final result = await run([
        dbPath,
        'insert',
        'notes',
        '--value={"title":"hi"}',
      ]);
      expect(result.exitCode, equals(0), reason: result.stderr);
      final docs = json.decode(result.stdout) as List;
      expect(docs[0]['title'], equals('hi'));
    });

    test('insert accepts --file=<path> (equals form)', () async {
      final dbPath = tmp.file('db');
      final jsonPath = tmp.file('doc.json');
      io.File(jsonPath).writeAsStringSync('{"title":"from file"}');
      final result = await run([dbPath, 'insert', 'notes', '--file=$jsonPath']);
      expect(result.exitCode, equals(0), reason: result.stderr);
      final docs = json.decode(result.stdout) as List;
      expect(docs[0]['title'], equals('from file'));
    });

    test('scan accepts --limit=<n> (equals form)', () async {
      final dbPath = tmp.file('db');
      await run([dbPath, 'insert', 'notes', '--value', '{"v":1}']);
      await run([dbPath, 'insert', 'notes', '--value', '{"v":2}']);
      await run([dbPath, 'insert', 'notes', '--value', '{"v":3}']);
      final result = await run([dbPath, 'scan', 'notes', '--limit=2']);
      expect(result.exitCode, equals(0), reason: result.stderr);
      final docs = json.decode(result.stdout) as List;
      expect(docs, hasLength(2));
    });
  });

  group('KmdbCli — --no-flush and flush command', () {
    test('persists WAL and skips SST creation with --no-flush', () async {
      final dbPath = tmp.file('db');

      // Run insert with --no-flush.
      final putResult = await run([
        dbPath,
        '--no-flush',
        'insert',
        'notes',
        '--value',
        '{"title":"WAL test"}',
      ]);
      expect(putResult.exitCode, equals(0), reason: putResult.stderr);

      final id = (json.decode(putResult.stdout) as List)[0]['_id'] as String;

      // Verify WAL exists, but no SST files.
      final walFile = io.File(p.join(dbPath, 'wal-00001.log'));
      expect(walFile.existsSync(), isTrue, reason: 'WAL should exist');

      final sstDir = io.Directory(p.join(dbPath, 'sst'));
      if (sstDir.existsSync()) {
        final sstFiles = sstDir
            .listSync()
            .where((f) => f.path.endsWith('.sst'))
            .toList();
        expect(sstFiles, isEmpty, reason: 'SST should NOT exist');
      }

      // Next command should still read the data (via WAL recovery).
      final getResult = await run([dbPath, 'get', 'notes', id]);
      expect(getResult.exitCode, equals(0), reason: getResult.stderr);
      final docs = json.decode(getResult.stdout) as List;
      expect(docs[0]['_id'], equals(id));

      // Running flush command should move data to SST and delete WAL.
      final flushResult = await run([dbPath, 'flush']);
      expect(flushResult.exitCode, equals(0), reason: flushResult.stderr);

      // Verify WAL is gone (it's rotated/deleted on flush).
      expect(walFile.existsSync(), isFalse, reason: 'WAL should be deleted');

      // Verify SST exists now.
      final sstFilesAfter = sstDir
          .listSync()
          .where((f) => f.path.endsWith('.sst'))
          .toList();
      expect(sstFilesAfter, isNotEmpty, reason: 'SST SHOULD exist after flush');
    });

    test('flushes by default without --no-flush', () async {
      final dbPath = tmp.file('db');

      // Run insert without flags (defaulting to --flush).
      final putResult = await run([
        dbPath,
        'insert',
        'notes',
        '--value',
        '{"title":"Direct flush"}',
      ]);
      expect(putResult.exitCode, equals(0), reason: putResult.stderr);

      // Verify WAL is gone and SST exists.
      final walFile = io.File(p.join(dbPath, 'wal-00001.log'));
      // print(walFile.parent.listSync());
      expect(
        walFile.existsSync(),
        isFalse,
        reason: 'WAL should NOT exist (flushed): $walFile',
      );

      final sstDir = io.Directory(p.join(dbPath, 'sst'));
      final sstFiles = sstDir
          .listSync()
          .where((f) => f.path.endsWith('.sst'))
          .toList();
      expect(sstFiles, isNotEmpty, reason: 'SST SHOULD exist (flushed)');
    });
  });
}

class _TmpDir {
  _TmpDir() : _dir = io.Directory.systemTemp.createTempSync('kmdb_cli_test_');
  final io.Directory _dir;

  String file(String name) => p.join(_dir.path, name);

  void clean() {
    if (_dir.existsSync()) {
      _dir.deleteSync(recursive: true);
    }
  }
}
