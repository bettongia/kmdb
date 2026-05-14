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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:kmdb_cli/src/repl/dot_commands/color_command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/limit_command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/mode_command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/nullvalue_command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/show_command.dart';
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

  group('ModeCommand', () {
    test('sets output mode', () async {
      await const ModeCommand().execute(state, ctx, ['table']);
      expect(state.outputMode, OutputMode.table);
    });

    test('no args returns error', () async {
      final ok = await const ModeCommand().execute(state, ctx, []);
      expect(ok, isFalse);
    });

    test('unknown mode returns error', () async {
      final ok = await const ModeCommand().execute(state, ctx, ['bogus']);
      expect(ok, isFalse);
      expect(err.toString(), contains('Unknown output mode'));
    });

    test('all valid modes are accepted', () async {
      for (final m in ['json', 'compact', 'ndjson', 'table', 'csv', 'line']) {
        state = SessionState();
        out = StringBuffer();
        err = StringBuffer();
        ctx = CommandContext(db: db, out: out, err: err);
        final ok = await const ModeCommand().execute(state, ctx, [m]);
        expect(ok, isTrue, reason: 'mode $m should be accepted');
      }
    });
  });

  group('ColorCommand', () {
    test('on sets ColorMode.on', () async {
      await const ColorCommand().execute(state, ctx, ['on']);
      expect(state.colorMode, ColorMode.on);
    });

    test('off sets ColorMode.off', () async {
      await const ColorCommand().execute(state, ctx, ['off']);
      expect(state.colorMode, ColorMode.off);
    });

    test('auto sets ColorMode.auto', () async {
      state.colorMode = ColorMode.on;
      await const ColorCommand().execute(state, ctx, ['auto']);
      expect(state.colorMode, ColorMode.auto);
    });

    test('invalid arg returns false', () async {
      final ok = await const ColorCommand().execute(state, ctx, ['yes']);
      expect(ok, isFalse);
    });
  });

  group('NullValueCommand', () {
    test('sets nullValue string', () async {
      await const NullValueCommand().execute(state, ctx, ['NULL']);
      expect(state.nullValue, 'NULL');
    });

    test('no args shows current value', () async {
      state.nullValue = 'N/A';
      await const NullValueCommand().execute(state, ctx, []);
      expect(out.toString(), contains('N/A'));
    });
  });

  group('LimitCommand', () {
    test('sets a positive limit', () async {
      await const LimitCommand().execute(state, ctx, ['50']);
      expect(state.defaultLimit, 50);
    });

    test('0 means no limit', () async {
      state.defaultLimit = 10;
      await const LimitCommand().execute(state, ctx, ['0']);
      expect(state.defaultLimit, 0);
      expect(out.toString(), contains('none'));
    });

    test('negative value returns error', () async {
      final ok = await const LimitCommand().execute(state, ctx, ['-1']);
      expect(ok, isFalse);
    });

    test('non-integer returns error', () async {
      final ok = await const LimitCommand().execute(state, ctx, ['abc']);
      expect(ok, isFalse);
    });
  });

  group('ShowCommand', () {
    test('outputs all settings', () async {
      state
        ..outputMode = OutputMode.csv
        ..activeCollection = 'posts'
        ..defaultLimit = 25;

      await const ShowCommand().execute(state, ctx, []);
      final output = out.toString();
      expect(output, contains('csv'));
      expect(output, contains('posts'));
      expect(output, contains('25'));
    });
  });
}
