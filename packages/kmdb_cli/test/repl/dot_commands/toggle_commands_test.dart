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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/toggle_commands.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
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

  group('CompactCommand', () {
    test('on enables compact', () async {
      await const CompactCommand().execute(state, ctx, ['on']);
      expect(state.compact, isTrue);
      expect(out.toString(), contains('on'));
    });

    test('off disables compact', () async {
      state.compact = true;
      await const CompactCommand().execute(state, ctx, ['off']);
      expect(state.compact, isFalse);
    });

    test('no args shows current value', () async {
      await const CompactCommand().execute(state, ctx, []);
      expect(out.toString(), contains('off'));
    });

    test('invalid arg returns false', () async {
      final ok = await const CompactCommand().execute(state, ctx, ['maybe']);
      expect(ok, isFalse);
      expect(err.toString(), contains('on or off'));
    });
  });

  group('HeadersCommand', () {
    test('off disables headers', () async {
      await const HeadersCommand().execute(state, ctx, ['off']);
      expect(state.headers, isFalse);
    });

    test('on enables headers', () async {
      state.headers = false;
      await const HeadersCommand().execute(state, ctx, ['on']);
      expect(state.headers, isTrue);
    });

    test('invalid arg returns false', () async {
      final ok = await const HeadersCommand().execute(state, ctx, ['yes']);
      expect(ok, isFalse);
    });
  });

  group('EchoCommand', () {
    test('on enables echo', () async {
      await const EchoCommand().execute(state, ctx, ['on']);
      expect(state.echo, isTrue);
    });

    test('off disables echo', () async {
      state.echo = true;
      await const EchoCommand().execute(state, ctx, ['off']);
      expect(state.echo, isFalse);
    });
  });

  group('BailCommand', () {
    test('on enables bail', () async {
      await const BailCommand().execute(state, ctx, ['on']);
      expect(state.bail, isTrue);
    });

    test('off disables bail', () async {
      state.bail = true;
      await const BailCommand().execute(state, ctx, ['off']);
      expect(state.bail, isFalse);
    });
  });

  group('TimerCommand', () {
    test('on enables timer', () async {
      await const TimerCommand().execute(state, ctx, ['on']);
      expect(state.timer, isTrue);
    });

    test('off disables timer', () async {
      state.timer = true;
      await const TimerCommand().execute(state, ctx, ['off']);
      expect(state.timer, isFalse);
    });
  });
}
