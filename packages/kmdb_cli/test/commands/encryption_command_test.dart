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

// In-process tests for EncryptionCommand.
//
// These tests cover scenarios that return before any call to _readPassword()
// (stdin interaction). They test the dispatch/guard logic only. Interactive
// passphrase-prompt scenarios are covered by subprocess tests in cli_runner_test.dart.

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/encryption_command.dart';
import 'package:test/test.dart';

/// Creates a [CommandContext] backed by a real tmpdir database for testing.
Future<(KmdbDatabase, CommandContext)> _openCtx(
  String path, {
  StringBuffer? out,
  StringBuffer? err,
}) async {
  final db = await KmdbDatabase.open(
    path: path,
    adapter: StorageAdapterNative(),
  );
  final outSink = out != null ? _StringBufferSink(out) : null;
  final errSink = err != null ? _StringBufferSink(err) : null;
  final ctx = CommandContext(
    db: db,
    out: outSink ?? StringBuffer(),
    err: errSink ?? StringBuffer(),
  );
  return (db, ctx);
}

/// Opens a plaintext (non-encrypted) database.
Future<(KmdbDatabase, CommandContext)> _openPlainCtx(
  String path, {
  StringBuffer? out,
  StringBuffer? err,
}) => _openCtx(path, out: out, err: err);

class _StringBufferSink implements StringSink {
  _StringBufferSink(this._buf);
  final StringBuffer _buf;

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
}

class _TmpDir {
  final io.Directory _dir = io.Directory.systemTemp.createTempSync(
    'kmdb_enc_cmd_',
  );

  String file(String name) => '${_dir.path}/$name';

  void clean() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}

void main() {
  late _TmpDir tmp;

  setUp(() => tmp = _TmpDir());
  tearDown(() => tmp.clean());

  // ── EncryptionCommand dispatch errors ─────────────────────────────────────────

  group('EncryptionCommand — dispatch errors', () {
    test('encryption with no sub-command returns false', () async {
      final errBuf = StringBuffer();
      final (db, ctx) = await _openPlainCtx(tmp.file('db'), err: errBuf);
      addTearDown(() => db.close());

      final cmd = EncryptionCommand();
      final result = await cmd.execute(ctx, [], {});
      expect(result, isFalse);
      expect(errBuf.toString(), contains('requires a sub-command'));
    });

    test('encryption unknown-sub returns false with useful error', () async {
      final errBuf = StringBuffer();
      final (db, ctx) = await _openPlainCtx(tmp.file('db'), err: errBuf);
      addTearDown(() => db.close());

      final cmd = EncryptionCommand();
      final result = await cmd.execute(ctx, ['notreal'], {});
      expect(result, isFalse);
      expect(errBuf.toString(), contains('Unknown encryption sub-command'));
    });

    test(
      'encryption change-passphrase on non-encrypted DB returns false',
      () async {
        final errBuf = StringBuffer();
        final (db, ctx) = await _openPlainCtx(tmp.file('db'), err: errBuf);
        addTearDown(() => db.close());

        // Pass 'change-passphrase' with a non-encrypted DB — should fail before
        // calling _readPassword().
        final cmd = EncryptionCommand();
        final result = await cmd.execute(ctx, ['change-passphrase'], {});
        expect(result, isFalse);
        expect(errBuf.toString(), contains('requires an encrypted database'));
      },
    );
  });

  // ── EncryptionCommand metadata ────────────────────────────────────────────────

  group('EncryptionCommand — metadata', () {
    test('name is "encryption"', () {
      expect(EncryptionCommand().name, equals('encryption'));
    });

    test('replVisible is false', () {
      expect(EncryptionCommand().replVisible, isFalse);
    });
  });
}
