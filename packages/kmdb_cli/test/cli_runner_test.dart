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

/// Integration tests for [KmdbCli.run].
///
/// Tests launch the CLI as a subprocess (`dart run bin/kmdb.dart`) so that
/// real stdin, stdout, file paths, and exit codes are exercised end-to-end.
/// Each test gets an isolated temp directory for database and script files.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Subprocess helper ─────────────────────────────────────────────────────────

const _entrypoint = 'bin/kmdb.dart';

/// Runs `dart run bin/kmdb.dart [args]` and captures the result.
///
/// If [stdin] is provided it is written to the process and stdin is then
/// closed. If [stdin] is null stdin is closed immediately so the subprocess
/// does not block trying to read it.
Future<_RunResult> _run(
  List<String> args, {
  String? stdin,
}) async {
  final proc = await io.Process.start(
    'dart',
    ['run', _entrypoint, ...args],
    workingDirectory: io.Directory.current.path,
  );

  // Always close stdin after optionally writing, so the subprocess can detect
  // EOF rather than blocking on an open pipe.
  if (stdin != null) {
    proc.stdin.write(stdin);
    await proc.stdin.flush();
  }
  await proc.stdin.close();

  final results = await Future.wait([
    proc.stdout.transform(utf8.decoder).join(),
    proc.stderr.transform(utf8.decoder).join(),
  ]);
  final exitCode = await proc.exitCode;

  return _RunResult(
    exitCode: exitCode,
    stdout: results[0],
    stderr: results[1],
  );
}

class _RunResult {
  const _RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// Parses the last non-empty line of [stdout] as JSON.
  ///
  /// When multiple commands are run the output contains one JSON value per
  /// command. Callers that only care about the final command's output (e.g.
  /// a trailing `count`) should use this instead of decoding [stdout] directly.
  dynamic get lastJson {
    final lines = stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) throw StateError('No output from CLI');
    return json.decode(lines.last);
  }
}

// ── Temp directory helper ─────────────────────────────────────────────────────

class _TmpDir {
  _TmpDir() {
    path = io.Directory.systemTemp.createTempSync('kmdb_cli_test_').path;
  }

  late final String path;

  String file(String name) => p.join(path, name);

  void writeFile(String name, String content) =>
      io.File(file(name)).writeAsStringSync(content);

  void delete() {
    try {
      io.Directory(path).deleteSync(recursive: true);
    } catch (_) {}
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── --read script file ────────────────────────────────────────────────────

  group('KmdbCli — --read script file', () {
    late _TmpDir tmp;

    setUp(() => tmp = _TmpDir());
    tearDown(() => tmp.delete());

    test('executes commands from a script file', () async {
      // JSON values must be single-quoted so the CLI tokeniser preserves the
      // inner double-quotes intact.
      final id1 = 'a' * 32;
      final id2 = 'b' * 32;
      final dbPath = tmp.file('db');
      tmp.writeFile('seed.kmdb', """
# seed script
put notes --value '{"id":"$id1","title":"First"}'
put notes --value '{"id":"$id2","title":"Second"}'
""");

      // Run the seed script.
      final seed = await _run([dbPath, '--read', tmp.file('seed.kmdb')]);
      expect(seed.exitCode, equals(0), reason: seed.stderr);

      // Verify document count in a separate invocation (single JSON output).
      final count = await _run([dbPath], stdin: 'count notes\n');
      expect(count.exitCode, equals(0), reason: count.stderr);
      expect((json.decode(count.stdout) as Map)['count'], equals(2));
    });

    test('skips comment lines and blank lines in script', () async {
      final id1 = 'c' * 32;
      final dbPath = tmp.file('db');
      tmp.writeFile('commented.kmdb', """
# This is a comment

put items --value '{"id":"$id1","v":1}'

# Another comment
""");

      final seed = await _run([dbPath, '--read', tmp.file('commented.kmdb')]);
      expect(seed.exitCode, equals(0), reason: seed.stderr);

      final count = await _run([dbPath], stdin: 'count items\n');
      expect(count.exitCode, equals(0), reason: count.stderr);
      expect((json.decode(count.stdout) as Map)['count'], equals(1));
    });

    test('returns exit code 1 for a missing script file', () async {
      final result = await _run(
          [tmp.file('db'), '--read', tmp.file('nonexistent.kmdb')]);

      expect(result.exitCode, equals(1));
    });

    test('stops on first error by default', () async {
      final id1 = 'd' * 32;
      // 'delete things' is missing the key arg — causes an error.
      tmp.writeFile('errors.kmdb', """
put things --value '{"id":"$id1","v":1}'
delete things
count things
""");

      final result =
          await _run([tmp.file('db'), '--read', tmp.file('errors.kmdb')]);

      expect(result.exitCode, equals(1));
      // count should NOT appear because execution stopped after the error.
      expect(result.stdout, isNot(contains('"count"')));
    });

    test('--continue-on-error keeps running after errors', () async {
      final id1 = 'e' * 32;
      tmp.writeFile('continue.kmdb', """
put things --value '{"id":"$id1","v":1}'
delete things
count things
""");

      final result = await _run([
        '--continue-on-error',
        tmp.file('db'),
        '--read',
        tmp.file('continue.kmdb'),
      ]);

      // Exit code is still 1 because an error occurred.
      expect(result.exitCode, equals(1));
      // But count output IS present because execution continued.
      expect(result.stdout, contains('"count"'));
    });

    test('--output writes results to a file instead of stdout', () async {
      final id1 = 'f' * 32;
      final outFile = tmp.file('out.json');
      tmp.writeFile('script.kmdb',
          "put ns --value '{\"id\":\"$id1\",\"v\":99}'\n");

      final result = await _run([
        '--output', outFile,
        tmp.file('db'),
        '--read', tmp.file('script.kmdb'),
      ]);

      expect(result.exitCode, equals(0), reason: result.stderr);
      // stdout is empty; output was redirected to file.
      expect(result.stdout.trim(), isEmpty);
      final fileContent = io.File(outFile).readAsStringSync();
      expect(fileContent, contains('"v"'));
    });
  });

  // ── stdin pipe ────────────────────────────────────────────────────────────

  group('KmdbCli — stdin pipe', () {
    late _TmpDir tmp;

    setUp(() => tmp = _TmpDir());
    tearDown(() => tmp.delete());

    test('reads a single command from stdin', () async {
      final id1 = '1' * 32;
      final dbPath = tmp.file('db');

      // Seed a document via stdin pipe.
      await _run([dbPath],
          stdin: "put notes --value '{\"id\":\"$id1\",\"n\":1}'\n");

      // Count via a second stdin pipe invocation.
      final result = await _run([dbPath], stdin: 'count notes\n');

      expect(result.exitCode, equals(0), reason: result.stderr);
      final decoded = json.decode(result.stdout) as Map;
      expect(decoded['count'], equals(1));
    });

    test('reads multiple commands from stdin', () async {
      final id1 = '2' * 32;
      final id2 = '3' * 32;
      final dbPath = tmp.file('db');

      // Seed two documents via stdin.
      final seed = await _run(
        [dbPath],
        stdin: "put ns --value '{\"id\":\"$id1\",\"v\":1}'\n"
            "put ns --value '{\"id\":\"$id2\",\"v\":2}'\n",
      );
      expect(seed.exitCode, equals(0), reason: seed.stderr);

      // Count in a separate invocation for a clean single-output assertion.
      final count = await _run([dbPath], stdin: 'count ns\n');
      expect(count.exitCode, equals(0), reason: count.stderr);
      expect((json.decode(count.stdout) as Map)['count'], equals(2));
    });

    test('ignores comment lines piped via stdin', () async {
      final id1 = '4' * 32;
      final dbPath = tmp.file('db');

      // Seed with inline comments; only the put line should execute.
      final seed = await _run(
        [dbPath],
        stdin: '# a comment\n'
            "put ns --value '{\"id\":\"$id1\",\"v\":1}'\n"
            '# another comment\n',
      );
      expect(seed.exitCode, equals(0), reason: seed.stderr);

      final count = await _run([dbPath], stdin: 'count ns\n');
      expect(count.exitCode, equals(0), reason: count.stderr);
      expect((json.decode(count.stdout) as Map)['count'], equals(1));
    });
  });

  // ── Inline command ────────────────────────────────────────────────────────

  group('KmdbCli — inline command', () {
    late _TmpDir tmp;

    setUp(() => tmp = _TmpDir());
    tearDown(() => tmp.delete());

    test('executes a single inline command', () async {
      // Each extra arg after db path is a full command string.
      final result = await _run([tmp.file('db'), 'collections']);

      expect(result.exitCode, equals(0), reason: result.stderr);
      expect(json.decode(result.stdout), isA<List>());
    });

    test('returns exit code 1 when no arguments are given', () async {
      final result = await _run([]);
      expect(result.exitCode, equals(1));
    });

    test('--version prints version string', () async {
      final result = await _run(['--version']);
      expect(result.exitCode, equals(0));
      expect(result.stdout.trim(), matches(RegExp(r'kmdb \d+\.\d+\.\d+')));
    });

    test('returns exit code 1 for an unknown command', () async {
      final result = await _run([tmp.file('db'), 'frobnicate']);
      expect(result.exitCode, equals(1));
      expect(result.stderr, contains('unknown command'));
    });
  });

  // ── --no-flush and flush command ──────────────────────────────────────────

  group('KmdbCli — --no-flush and flush command', () {
    late _TmpDir tmp;

    setUp(() => tmp = _TmpDir());
    tearDown(() => tmp.delete());

    test('persists WAL and skips SST creation with --no-flush', () async {
      final dbPath = tmp.file('db');
      final id = 'a' * 32;

      // Run put with --no-flush.
      final putResult = await _run(
          [dbPath, '--no-flush', 'put', 'notes', '--value', '{"id":"$id"}']);
      expect(putResult.exitCode, equals(0), reason: putResult.stderr);

      // Verify WAL exists, but no SST files.
      final walFile = io.File(p.join(dbPath, 'wal-00001.log'));
      expect(walFile.existsSync(), isTrue, reason: 'WAL should exist');

      final sstDir = io.Directory(p.join(dbPath, 'sst'));
      final sstFiles = sstDir
          .listSync()
          .where((f) => f.path.endsWith('.sst'))
          .toList();
      expect(sstFiles, isEmpty, reason: 'SST should NOT exist');

      // Next command should still read the data (via WAL recovery).
      final getResult = await _run([dbPath, 'get', 'notes', id]);
      expect(getResult.exitCode, equals(0), reason: getResult.stderr);
      final docs = json.decode(getResult.stdout) as List;
      expect(docs[0]['id'], equals(id));

      // Running flush command should move data to SST and delete WAL.
      final flushResult = await _run([dbPath, 'flush']);
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
      final id = 'b' * 32;

      // Run put without flags (defaulting to --flush).
      final putResult =
          await _run([dbPath, 'put', 'notes', '--value', '{"id":"$id"}']);
      expect(putResult.exitCode, equals(0), reason: putResult.stderr);

      // Verify WAL is gone and SST exists.
      final walFile = io.File(p.join(dbPath, 'wal-00001.log'));
      expect(walFile.existsSync(), isFalse, reason: 'WAL should NOT exist (flushed)');

      final sstDir = io.Directory(p.join(dbPath, 'sst'));
      final sstFiles = sstDir
          .listSync()
          .where((f) => f.path.endsWith('.sst'))
          .toList();
      expect(sstFiles, isNotEmpty, reason: 'SST SHOULD exist (flushed)');
    });
  });
}
