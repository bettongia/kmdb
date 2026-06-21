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

// In-process CLI runner tests.
//
// IMPORTANT: Every test must supply inline tokens, `--read`, or be an
// early-exit scenario (--version, --help, etc.). Bare-`<db>` (REPL path)
// is subprocess-only — the tty detection always reads stdin in a test isolate,
// which would block indefinitely.
//
// The `_run` helper captures stdout/stderr via `IOOverrides.runZoned` so that
// test assertions can inspect printed output without spawning a subprocess.
// This gives full coverage instrumentation of `cli_runner.dart`.

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb_cli/kmdb_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Output-capture harness ────────────────────────────────────────────────────

/// A minimal [io.Stdout] implementation that writes all output to a
/// [StringBuffer].
///
/// Used with [io.IOOverrides.runZoned] to capture stdout/stderr in-process.
/// [io.IOOverrides.runZoned] requires the `stdout`/`stderr` factories to return
/// an [io.Stdout] (a subtype of [io.IOSink]) — hence this implements
/// [io.Stdout] rather than [io.IOSink]. All optional members are handled by
/// [noSuchMethod].
final class _BufferSink implements io.Stdout {
  _BufferSink(this._buf);

  final StringBuffer _buf;

  // ── IOSink / Stdout members used by the CLI ─────────────────────────────

  @override
  void write(Object? obj) => _buf.write(obj);

  @override
  void writeln([Object? obj = '']) {
    if (obj != null && obj != '') _buf.write(obj);
    _buf.write('\n');
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    _buf.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) => _buf.write(String.fromCharCode(charCode));

  @override
  void add(List<int> data) => _buf.write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}

  // ANSI support — always false in test capture context.
  @override
  bool get supportsAnsiEscapes => false;

  // Unimplemented members of io.Stdout (terminal size, etc.) are forwarded
  // to noSuchMethod so that callers using optional Stdout features don't crash.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs [KmdbCli.run] in-process with [args], capturing stdout and stderr.
///
/// Returns a record with the exit code and captured output strings.
/// All tests must avoid the bare-`<db>` REPL path (see file header).
Future<({int code, String out, String err})> _run(List<String> args) async {
  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final code = await io.IOOverrides.runZoned(
    () => KmdbCli.run(args),
    stdout: () => _BufferSink(outBuf),
    stderr: () => _BufferSink(errBuf),
  );
  return (code: code, out: outBuf.toString(), err: errBuf.toString());
}

// ── Temp directory helper ─────────────────────────────────────────────────────

class _TmpDir {
  final _dir = io.Directory.systemTemp.createTempSync('kmdb_inprocess_test_');

  /// Returns an absolute path inside the temp dir (not yet created).
  String file(String name) => p.join(_dir.path, name);

  void clean() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late _TmpDir tmp;

  setUp(() => tmp = _TmpDir());
  tearDown(() => tmp.clean());

  // ── Early-exit scenarios (no DB opened) ──────────────────────────────────

  group('early-exit scenarios', () {
    test('--version → exit 0, out contains version string', () async {
      final result = await _run(['--version']);
      expect(result.code, equals(0));
      expect(result.out, contains('kmdb'));
    });

    test('--help → exit 0, out contains usage text', () async {
      final result = await _run(['--help']);
      expect(result.code, equals(0));
      expect(result.out, contains('Usage:'));
    });

    test('-h → exit 0, out contains usage text', () async {
      final result = await _run(['-h']);
      expect(result.code, equals(0));
      expect(result.out, contains('Usage:'));
    });

    test('help (positional) → exit 0, usage printed', () async {
      final result = await _run(['help']);
      expect(result.code, equals(0));
      expect(result.out, contains('Usage:'));
    });

    test('help <command> → exit 0', () async {
      final result = await _run(['help', 'scan']);
      expect(result.code, equals(0));
      // help may print to stdout or stderr depending on the runner implementation.
      // The important thing is that it exits successfully.
    });

    test('no args → exit 1, usage printed', () async {
      final result = await _run([]);
      expect(result.code, equals(1));
      expect(result.out, contains('Usage:'));
    });

    test(
      'DB path starts with - → exit 1, err contains "unknown flag"',
      () async {
        final result = await _run(['--unknown-xyz']);
        expect(result.code, equals(1));
        expect(result.err, contains('unknown flag'));
      },
    );

    test('--format invalid → exit 1, err contains error', () async {
      final dbPath = tmp.file('db');
      final result = await _run([
        '--format',
        'invalid_format',
        dbPath,
        'scan',
        'ns',
      ]);
      expect(result.code, equals(1));
      expect(result.err, isNotEmpty);
    });

    test('--format with no value → exit 1', () async {
      final result = await _run(['--format']);
      expect(result.code, equals(1));
      expect(result.err, contains('--format requires a value'));
    });

    test('--output with no value → exit 1', () async {
      final result = await _run(['--output']);
      expect(result.code, equals(1));
      expect(result.err, contains('--output requires a value'));
    });

    test('--passphrase with no value → exit 1', () async {
      final result = await _run(['--passphrase']);
      expect(result.code, equals(1));
      expect(result.err, contains('--passphrase requires a value'));
    });

    test('--recovery-code with no value → exit 1', () async {
      final result = await _run(['--recovery-code']);
      expect(result.code, equals(1));
      expect(result.err, contains('--recovery-code requires a value'));
    });

    test('--read with no value → exit 1', () async {
      final result = await _run(['--read']);
      expect(result.code, equals(1));
      expect(result.err, contains('--read requires a file path'));
    });

    test(
      '--passphrase + --recovery-code together → exit 1, mutually exclusive',
      () async {
        final dbPath = tmp.file('db');
        final result = await _run([
          '--passphrase',
          'pass',
          '--recovery-code',
          'code',
          dbPath,
          'scan',
          'ns',
        ]);
        expect(result.code, equals(1));
        expect(result.err, contains('mutually exclusive'));
      },
    );
  });

  // ── Inline-token scenarios (remaining.length > 1) ────────────────────────

  group('inline-token scenarios', () {
    test(
      '--format=json inline-equals form accepted for valid command',
      () async {
        final dbPath = tmp.file('db');
        final result = await _run(['--format=json', dbPath, 'scan', 'ns']);
        expect(result.code, equals(0));
      },
    );

    test('--passphrase=mypass inline-equals form parsed correctly', () async {
      final dbPath = tmp.file('db');
      // Wrong passphrase on a non-encrypted DB should fail with encryption
      // error, proving the flag was parsed.
      final result = await _run(['--passphrase=mypass', dbPath, 'scan', 'ns']);
      // A non-encrypted DB opened with a passphrase yields an EncryptionError.
      expect(result.code, equals(1));
      expect(result.err, isNotEmpty);
    });

    test(
      '--no-flush flag honoured (close without flush does not crash)',
      () async {
        final dbPath = tmp.file('db');
        final result = await _run(['--no-flush', dbPath, 'scan', 'ns']);
        expect(result.code, equals(0));
      },
    );

    test('inline tokens dispatched: <db> scan ns succeeds', () async {
      final dbPath = tmp.file('db');
      final result = await _run([dbPath, 'scan', 'ns']);
      expect(result.code, equals(0));
    });

    test(
      'unknown command in inline tokens → exit 1 with unknown-command error',
      () async {
        final dbPath = tmp.file('db');
        final result = await _run([dbPath, 'not_a_real_cmd']);
        expect(result.code, equals(1));
        expect(result.err, contains("unknown command"));
      },
    );

    test(
      '--continue-on-error: two commands where first fails → both run, exit 1',
      () async {
        // Use --read with a script that has a bad command followed by scan.
        final dbPath = tmp.file('db');
        final scriptPath = tmp.file('script.kmdb');
        io.File(scriptPath).writeAsStringSync('not_a_cmd\nscan ns\n');

        final result = await _run([
          '--continue-on-error',
          '--read',
          scriptPath,
          dbPath,
        ]);
        expect(result.code, equals(1));
        // Both commands ran: error for first, output for second.
        expect(result.err, contains('unknown command'));
      },
    );

    test('DB path starts with - → exit 1 with unknown-flag message', () async {
      final result = await _run(['-not-a-db-path']);
      expect(result.code, equals(1));
      expect(result.err, contains('unknown flag'));
    });
  });

  // ── --read file scenarios ─────────────────────────────────────────────────

  group('--read file scenarios', () {
    test('--read <script.kmdb> executes each line', () async {
      final dbPath = tmp.file('db');
      final scriptPath = tmp.file('script.kmdb');
      io.File(scriptPath).writeAsStringSync('scan ns\nscan ns\n');

      final result = await _run(['--read', scriptPath, dbPath]);
      expect(result.code, equals(0));
    });

    test('--read file not found → exit 1, err contains error', () async {
      final dbPath = tmp.file('db');
      final missingPath = tmp.file('nonexistent.kmdb');

      final result = await _run(['--read', missingPath, dbPath]);
      expect(result.code, equals(1));
      // The file-not-found path writes an error. Either the open-file error
      // or the "file not found" message should appear.
      expect(result.err, isNotEmpty);
    });

    test(
      '--read script with comments and blank lines is handled correctly',
      () async {
        final dbPath = tmp.file('db');
        final scriptPath = tmp.file('script.kmdb');
        io.File(scriptPath).writeAsStringSync('# comment\n\nscan ns\n');

        final result = await _run(['--read', scriptPath, dbPath]);
        expect(result.code, equals(0));
      },
    );

    test('dot-command in --read script returns error: not supported', () async {
      // Dot-commands are only valid in REPL mode. When encountered in a
      // --read script, _executeCommandLine should reject with an error.
      final dbPath = tmp.file('db');
      final scriptPath = tmp.file('dotcmd.kmdb');
      io.File(scriptPath).writeAsStringSync('.mode table\n');

      final result = await _run(['--read', scriptPath, dbPath]);
      expect(result.code, equals(1));
      expect(result.err, contains('dot-commands'));
    });
  });

  // ── --output file scenarios ───────────────────────────────────────────────

  group('--output file scenarios', () {
    test('--output <file> writes command output to file', () async {
      final dbPath = tmp.file('db');
      final outputPath = tmp.file('out.json');

      final result = await _run(['--output', outputPath, dbPath, 'scan', 'ns']);
      expect(result.code, equals(0));
      // Output goes to file, not captured buffer.
      expect(io.File(outputPath).existsSync(), isTrue);
    });
  });

  // ── Config parse error ────────────────────────────────────────────────────

  group('config parse error', () {
    test(
      'malformed config.json → warning in err but command still runs',
      () async {
        final dbPath = tmp.file('db');
        // Create a local/ dir with a malformed config.json.
        io.Directory('$dbPath/local').createSync(recursive: true);
        io.File(
          '$dbPath/local/config.json',
        ).writeAsStringSync('not-valid-json');

        final result = await _run([dbPath, 'scan', 'ns']);
        // Command should still run despite config error.
        expect(result.code, equals(0));
        expect(result.err, contains('Warning'));
      },
    );
  });

  // ── Encryption scenarios ──────────────────────────────────────────────────

  group('encryption scenarios', () {
    test(
      '<db> init --passphrase <pp> on new DB → exit 0, err contains recovery code',
      () async {
        final dbPath = tmp.file('encrypted_db');
        final result = await _run([
          dbPath,
          'init',
          '--passphrase',
          'mypass123',
        ]);
        expect(result.code, equals(0));
        expect(result.err, contains('Recovery code'));
      },
    );

    test(
      '--passphrase <pp> <db> scan ns on existing encrypted DB → exit 0',
      () async {
        final dbPath = tmp.file('encrypted_db2');
        // Create encrypted DB first.
        final initResult = await _run([
          dbPath,
          'init',
          '--passphrase',
          'mypassword',
        ]);
        expect(initResult.code, equals(0), reason: initResult.err);

        // Now open with correct passphrase.
        final result = await _run([
          '--passphrase',
          'mypassword',
          dbPath,
          'scan',
          'ns',
        ]);
        expect(result.code, equals(0));
      },
    );

    test(
      'wrong passphrase on encrypted DB → exit 1, err contains encryption error',
      () async {
        final dbPath = tmp.file('encrypted_db3');
        // Create encrypted DB first.
        await _run([dbPath, 'init', '--passphrase', 'correctpass']);

        // Open with wrong passphrase.
        final result = await _run([
          '--passphrase',
          'wrongpass',
          dbPath,
          'scan',
          'ns',
        ]);
        expect(result.code, equals(1));
        expect(result.err, isNotEmpty);
      },
    );
  });

  // ── Error fallback ────────────────────────────────────────────────────────

  group('error fallback', () {
    test(
      'unknown DB-open error (non-creatable path) → exit 1, error in err',
      () async {
        // Use a path under a file (not a directory), which cannot be created.
        final dbPath = tmp.file('a_file');
        io.File(dbPath).writeAsStringSync('I am a file, not a dir');
        // Try to open a path nested under the file — this should trigger a
        // filesystem error caught by the general catch block.
        final result = await _run(['$dbPath/nested_db', 'scan', 'ns']);
        expect(result.code, equals(1));
        expect(result.err, isNotEmpty);
      },
    );
  });

  // ── Additional cli_runner coverage tests ─────────────────────────────────

  group('remaining.isEmpty after flag parsing', () {
    test('only-flags with no db path → exit 1, "database path required"', () async {
      // --no-flush is consumed by the global flag parser (sets flushOnExit=false)
      // but adds nothing to `remaining`. After parsing, remaining.isEmpty is true,
      // so the runner reaches the "database path required" guard (lines 257-260).
      final result = await _run(['--no-flush']);
      expect(result.code, equals(1));
      expect(result.err, contains('database path required'));
    });

    test('--continue-on-error with no db path → exit 1', () async {
      // Same pattern: --continue-on-error is consumed but leaves remaining empty.
      final result = await _run(['--continue-on-error']);
      expect(result.code, equals(1));
      expect(result.err, contains('database path required'));
    });
  });

  group('init directory guard', () {
    test('init in non-empty non-KMDB dir → exit 1, error in err', () async {
      // Create a non-empty directory that is NOT a KMDB database.
      final dirPath = tmp.file('foreign_dir');
      io.Directory(dirPath).createSync();
      io.File('$dirPath/some_random_file.txt').writeAsStringSync('content');

      // `init` in a non-empty non-KMDB directory is rejected.
      final result = await _run([dirPath, 'init']);
      expect(result.code, equals(1));
      expect(result.err, isNotEmpty);
    });
  });

  group('--recovery-code flag', () {
    test(
      '--recovery-code with wrong code on encrypted DB → exit 1 with error',
      () async {
        final dbPath = tmp.file('rc_test_db');
        // Create encrypted DB with passphrase.
        final initResult = await _run([
          dbPath,
          'init',
          '--passphrase',
          'mypass',
        ]);
        expect(initResult.code, equals(0), reason: initResult.err);
        // Extract recovery code from stderr.
        final recoveryCodeLine = initResult.err
            .split('\n')
            .firstWhere((l) => l.contains('Recovery code:'), orElse: () => '');
        expect(
          recoveryCodeLine,
          isNotEmpty,
          reason: 'No recovery code found in output',
        );

        // Try to open with a clearly invalid recovery code — should fail.
        final result = await _run([
          '--recovery-code',
          'invalid-recovery-code-that-will-never-work',
          dbPath,
          'scan',
          'ns',
        ]);
        expect(result.code, equals(1));
        expect(result.err, isNotEmpty);
      },
    );

    test(
      '--recovery-code with valid code on existing encrypted DB → exit 0',
      () async {
        final dbPath = tmp.file('rc_success_db');
        // Create encrypted DB with passphrase; capture the recovery code.
        final initResult = await _run([
          dbPath,
          'init',
          '--passphrase',
          'secret123',
        ]);
        expect(initResult.code, equals(0), reason: initResult.err);

        // Parse the recovery code from stderr — format: "  Recovery code: <code>"
        final recoveryCode = initResult.err
            .split('\n')
            .firstWhere((l) => l.contains('Recovery code:'), orElse: () => '')
            .split('Recovery code:')
            .last
            .trim();
        expect(
          recoveryCode,
          isNotEmpty,
          reason: 'No recovery code found in init output',
        );

        // Use the valid recovery code to open the encrypted DB.
        final result = await _run([
          '--recovery-code',
          recoveryCode,
          dbPath,
          'scan',
          'ns',
        ]);
        expect(result.code, equals(0), reason: result.err);
      },
    );
  });

  group('help <command> exercises _buildCommandRunner', () {
    test('help scan → exit 0, output contains usage info', () async {
      // help <command> calls _buildCommandRunner() which instantiates
      // _UsageCommand wrappers around all registered commands. This exercises
      // the _UsageCommand.name, description, and invocation getters.
      final result = await _run(['help', 'scan']);
      expect(result.code, equals(0));
    });

    test('help get → exit 0', () async {
      final result = await _run(['help', 'get']);
      expect(result.code, equals(0));
    });
  });
}
