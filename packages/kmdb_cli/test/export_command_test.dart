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
import 'package:kmdb_cli/src/commands/export_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

var _dbCounter = 0;

Future<KmdbDatabase> _openStore() async {
  return KmdbDatabase.open(
    path: '/testdb_export_${_dbCounter++}',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
}

CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('ExportCommand — argument validation', () {
    test('returns false when collection arg is missing', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final err = StringBuffer();

      final ok = await ExportCommand().execute(_ctx(db, err: err), [], {});

      expect(ok, isFalse);
      expect(err.toString(), contains('export requires <collection>'));
    });
  });

  group('ExportCommand --vault without vault configured', () {
    test('returns false and writes error', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final err = StringBuffer();

      final ok = await ExportCommand().execute(
        _ctx(db, err: err),
        ['notes'],
        {'vault': true},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('--vault requires vault'));
    });
  });
}
