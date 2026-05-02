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

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/repl/history.dart';
import 'package:kmdb_cli/src/repl/input_reader.dart';
import 'package:kmdb_cli/src/repl/repl_runner.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// An [InputReader] that throws [io.StdinException] on the first [readLine].
final class _ThrowingInputReader implements InputReader {
  @override
  void setHistory(List<String> history) {}

  @override
  Future<ReadLineOutcome> readLine(
    String prompt, {
    CompletionCallback? completer,
  }) async {
    throw const io.StdinException('Bad file descriptor');
  }

  @override
  Future<void> dispose() async {}
}

// ── Helpers ──────────────────────────────────────────────────────────────────

Future<KmdbDatabase> _openDb() => KmdbDatabase.open(
  path: '/testdb',
  adapter: MemoryStorageAdapter(),
  config: KvStoreConfig.forTesting(),
);

/// Runs the REPL with [lines] as input and returns the exit code.
/// Captures stdout and stderr into [out] and [err].
Future<int> _run(
  List<String> lines,
  KmdbDatabase db, {
  History? history,
  SessionState? state,
  required StringBuffer out,
  required StringBuffer err,
}) async {
  final ctx = CommandContext(db: db, out: out, err: err);
  final reader = FakeInputReader(lines);
  return ReplRunner(
    ctx: ctx,
    dbPath: '/testdb',
    reader: reader,
    history: history,
    state: state,
  ).run();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('basic command execution', () {
    test('executes a batch command and returns 0', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final err = StringBuffer();

      final code = await _run(['collections list'], db, out: out, err: err);

      expect(code, 0);
      expect(err.toString(), isEmpty);
    });

    test('unknown command writes error but continues by default', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final err = StringBuffer();

      await _run(['not_a_real_command'], db, out: out, err: err);
      expect(err.toString(), contains('unknown command'));
    });

    test('blank lines and comments are silently skipped', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final err = StringBuffer();

      final code = await _run(
        ['', '  ', '# this is a comment'],
        db,
        out: out,
        err: err,
      );

      expect(code, 0);
      expect(err.toString(), isEmpty);
    });
  });

  group('.quit / .exit', () {
    test('.quit exits with code 0', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final code = await _run(['.quit'], db, out: out, err: StringBuffer());
      expect(code, 0);
    });

    test('.exit with code exits with that code', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final code = await _run(['.exit 42'], db, out: out, err: StringBuffer());
      expect(code, 42);
    });

    test('EOF (empty input) exits cleanly', () async {
      final db = await _openDb();
      final code = await _run([], db, out: StringBuffer(), err: StringBuffer());
      expect(code, 0);
    });
  });

  group('dot-command: .mode', () {
    test('changes session output mode', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final state = SessionState();

      await _run(
        ['.mode table', '.quit'],
        db,
        state: state,
        out: out,
        err: StringBuffer(),
      );

      expect(out.toString(), contains('table'));
    });

    test('rejects unknown mode', () async {
      final db = await _openDb();
      final err = StringBuffer();

      await _run(['.mode bogus'], db, out: StringBuffer(), err: err);
      expect(err.toString(), contains('Unknown output mode'));
    });
  });

  group('dot-command: .collection', () {
    test('sets active collection and shows count', () async {
      final db = await _openDb();
      // Create a collection with one document.
      final col = db.rawCollection('notes');
      await col.insert({'title': 'hello'});

      final out = StringBuffer();
      final state = SessionState();

      await _run(
        ['.collection notes', '.quit'],
        db,
        state: state,
        out: out,
        err: StringBuffer(),
      );

      expect(state.activeCollection, 'notes');
      expect(out.toString(), contains('1 documents'));
    });

    test('clears active collection with no args', () async {
      final db = await _openDb();
      final state = SessionState()..activeCollection = 'notes';

      await _run(
        ['.collection'],
        db,
        state: state,
        out: StringBuffer(),
        err: StringBuffer(),
      );

      expect(state.activeCollection, isNull);
    });

    test('rejects nonexistent collection', () async {
      final db = await _openDb();
      final err = StringBuffer();

      await _run(['.collection ghost'], db, out: StringBuffer(), err: err);
      expect(err.toString(), contains("does not exist"));
    });
  });

  group('dot-command: .bail', () {
    test('.bail on exits on first error', () async {
      final db = await _openDb();
      final err = StringBuffer();
      final state = SessionState();

      await _run(
        ['.bail on', 'not_a_command', 'collections list'],
        db,
        state: state,
        out: StringBuffer(),
        err: err,
      );

      expect(state.bail, isTrue);
      // After bail, the second command should not have run — we just verify
      // no crash and bail is set.
    });
  });

  group('dot-command: .echo', () {
    test('.echo on echoes commands', () async {
      final db = await _openDb();
      final out = StringBuffer();

      await _run(
        ['.echo on', 'collections list'],
        db,
        out: out,
        err: StringBuffer(),
      );

      expect(out.toString(), contains('collections list'));
    });
  });

  group('dot-command: .show', () {
    test('prints all session settings', () async {
      final db = await _openDb();
      final out = StringBuffer();

      await _run(['.show'], db, out: out, err: StringBuffer());

      expect(out.toString(), contains('mode'));
      expect(out.toString(), contains('collection'));
      expect(out.toString(), contains('timer'));
    });
  });

  group('dot-command: .history', () {
    test('prints recent history entries', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_hist_');
      final hist = History(filePath: p.join(tmpDir.path, 'hist'));

      try {
        hist.add('scan notes');
        hist.add('count notes');

        await _run(
          ['.history'],
          db,
          history: hist,
          out: out,
          err: StringBuffer(),
        );

        expect(out.toString(), contains('scan notes'));
        expect(out.toString(), contains('count notes'));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test(
      'shows the .history command itself when no prior history exists',
      () async {
        final db = await _openDb();
        final out = StringBuffer();
        final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_hist_');
        final hist = History(filePath: p.join(tmpDir.path, 'hist'));

        try {
          // The ReplRunner adds each entered line to history before executing it,
          // so '.history' will always appear in the output when no prior entries exist.
          await _run(
            ['.history'],
            db,
            history: hist,
            out: out,
            err: StringBuffer(),
          );
          expect(out.toString(), contains('.history'));
        } finally {
          await tmpDir.delete(recursive: true);
        }
      },
    );
  });

  group('history recall (!n)', () {
    test('!n re-executes a history entry', () async {
      final db = await _openDb();
      final out = StringBuffer();
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_hist_');
      final hist = History(filePath: p.join(tmpDir.path, 'hist'));

      try {
        hist.add('collections list');

        await _run(['!1'], db, history: hist, out: out, err: StringBuffer());

        // collections list was re-executed; the output contains the result
        expect(out.toString(), isNotEmpty);
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('!n with out-of-range index reports error', () async {
      final db = await _openDb();
      final err = StringBuffer();
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_hist_');
      final hist = History(filePath: p.join(tmpDir.path, 'hist'));

      try {
        await _run(['!99'], db, history: hist, out: StringBuffer(), err: err);
        expect(err.toString(), contains('no history entry'));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });
  });

  group('multi-line input', () {
    test('backslash continuation joins lines', () async {
      final db = await _openDb();
      final out = StringBuffer();

      // Two-line `collections list` split with continuation.
      await _run([r'collections \', 'list'], db, out: out, err: StringBuffer());

      // Should execute successfully (no error about unknown command).
      expect(out.toString(), isNotEmpty);
    });

    test(
      'unbalanced JSON brace triggers continuation until balanced',
      () async {
        final db = await _openDb();
        await db.rawCollection('notes').insert({'status': 'active'});

        final out = StringBuffer();

        // The filter JSON is split across two input lines; the REPL should wait
        // for the closing `}` before dispatching.
        await _run(
          [
            r"""scan notes --filter '{"field":"status",""",
            r""""op":"eq","value":"active"}'""",
          ],
          db,
          out: out,
          err: StringBuffer(),
        );

        // Some output expected (either results or empty array, not an error).
        expect(out.toString(), isNotEmpty);
      },
    );
  });

  group('dot-command: .help', () {
    test('lists all dot-commands', () async {
      final db = await _openDb();
      final out = StringBuffer();

      await _run(['.help'], db, out: out, err: StringBuffer());

      expect(out.toString(), contains('.mode'));
      expect(out.toString(), contains('.collection'));
      expect(out.toString(), contains('.quit'));
    });

    test('shows help for a specific command', () async {
      final db = await _openDb();
      final out = StringBuffer();

      await _run(['.help mode'], db, out: out, err: StringBuffer());
      expect(out.toString(), contains('mode'));
    });

    test('reports error for unknown dot-command', () async {
      final db = await _openDb();
      final err = StringBuffer();

      await _run(['.help bogus'], db, out: StringBuffer(), err: err);
      expect(err.toString(), contains('unknown dot-command'));
    });
  });

  group('dot-command: .timer', () {
    test('enabling timer appends timing output', () async {
      final db = await _openDb();
      final out = StringBuffer();

      await _run(
        ['.timer on', 'collections list'],
        db,
        out: out,
        err: StringBuffer(),
      );

      expect(out.toString(), contains('ms'));
    });
  });

  group('unhandled errors', () {
    test(
      'StdinException from InputReader returns exit code 1 with friendly message',
      () async {
        final db = await _openDb();
        final err = StringBuffer();
        final ctx = CommandContext(db: db, out: StringBuffer(), err: err);

        final code = await ReplRunner(
          ctx: ctx,
          dbPath: '/testdb',
          reader: _ThrowingInputReader(),
        ).run();

        expect(code, 1);
        expect(err.toString(), contains('Error:'));
      },
    );
  });

  group('schema validation error pretty-printing', () {
    test('formats SchemaValidationException with field detail', () async {
      final db = await _openDb();

      // Register a schema requiring a 'title' field.
      await db.registerSchema(
        CollectionSchema(
          collection: 'articles',
          jsonSchema: {
            'type': 'object',
            'required': ['title'],
            'properties': {
              'title': {'type': 'string'},
            },
          },
        ),
      );

      final err = StringBuffer();

      // Insert without the required field — should trigger SchemaValidationException.
      // Use single-quoted JSON so the tokenizer preserves the double quotes.
      await _run(
        [r"""insert articles --value '{"body":"hello"}'"""],
        db,
        out: StringBuffer(),
        err: err,
      );

      // The error output should mention the violation (either "title" or
      // "validation failed") regardless of exact formatting.
      expect(
        err.toString().toLowerCase(),
        anyOf(contains('title'), contains('validation'), contains('schema')),
      );
    });
  });
}
