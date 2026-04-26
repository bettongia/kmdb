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
import 'package:kmdb_cli/src/repl/dot_commands/output_command.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<KmdbDatabase> _openDb() => KmdbDatabase.open(
  path: '/testdb',
  adapter: MemoryStorageAdapter(),
  config: KvStoreConfig.forTesting(),
);

void main() {
  late KmdbDatabase db;
  late SessionState state;
  late StringBuffer out;
  late StringBuffer err;
  late CommandContext ctx;

  setUp(() async {
    db = await _openDb();
    state = SessionState();
    out = StringBuffer();
    err = StringBuffer();
    ctx = CommandContext(db: db, out: out, err: err);
  });

  tearDown(() => db.close());

  group('OutputCommand', () {
    test('no args resets outputSink to null and prints message', () async {
      state.outputSink = StringBuffer(); // pre-set a sink
      final ok = await const OutputCommand().execute(state, ctx, []);
      expect(ok, isTrue);
      expect(state.outputSink, isNull);
      expect(out.toString(), contains('reset'));
    });

    test('valid file path creates an IOSink', () async {
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_out_');
      final path = p.join(tmpDir.path, 'out.txt');
      try {
        final ok = await const OutputCommand().execute(state, ctx, [path]);
        expect(ok, isTrue);
        expect(state.outputSink, isA<io.IOSink>());
        expect(out.toString(), contains(path));
        // Clean up the sink.
        await (state.outputSink as io.IOSink).close();
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('args list is empty after reset confirms outputSink is null', () async {
      // Confirm that calling with no args always resets regardless of prior state.
      state.outputSink = StringBuffer();
      await const OutputCommand().execute(state, ctx, []);
      expect(state.outputSink, isNull);
    });

    test('closing previous IOSink when resetting', () async {
      // Open a temp file sink, then reset via no-arg call.
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_out2_');
      final path = p.join(tmpDir.path, 'prev.txt');
      try {
        await const OutputCommand().execute(state, ctx, [path]);
        expect(state.outputSink, isA<io.IOSink>());
        // Reset to stdout — must not throw even though previous sink is IOSink.
        out.clear();
        final ok = await const OutputCommand().execute(state, ctx, []);
        expect(ok, isTrue);
        expect(state.outputSink, isNull);
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });
  });

  group('OnceCommand', () {
    test('no args resets onceSink to null', () async {
      state.onceSink = StringBuffer();
      final ok = await const OnceCommand().execute(state, ctx, []);
      expect(ok, isTrue);
      expect(state.onceSink, isNull);
    });

    test('valid file path creates an IOSink', () async {
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_once_');
      final path = p.join(tmpDir.path, 'once.txt');
      try {
        final ok = await const OnceCommand().execute(state, ctx, [path]);
        expect(ok, isTrue);
        expect(state.onceSink, isA<io.IOSink>());
        expect(out.toString(), contains(path));
        await (state.onceSink as io.IOSink).close();
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('args list is empty resets a pre-set onceSink', () async {
      state.onceSink = StringBuffer();
      final ok = await const OnceCommand().execute(state, ctx, []);
      expect(ok, isTrue);
      expect(state.onceSink, isNull);
    });
  });
}
