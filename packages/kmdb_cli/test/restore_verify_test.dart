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

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/count_command.dart';
import 'package:kmdb_cli/src/commands/restore_command.dart';
import 'package:kmdb_cli/src/commands/verify_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

var _dbCounter = 0;

Future<KmdbDatabase> _openStore() async {
  return KmdbDatabase.open(
    path: '/testdb_rv_${_dbCounter++}',
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

String _key(String seed) {
  final hex = seed.codeUnits
      .map((c) => c.toRadixString(16))
      .join()
      .padRight(32, '0')
      .substring(0, 32);
  final chars = hex.split('');
  chars[12] = '7';
  chars[16] = '8';
  return chars.join();
}

// ── RestoreCommand ────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('RestoreCommand', () {
    test('restores documents from a dump file', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final id1 = _key('r1');
      final id2 = _key('r2');

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync(
        '# collection: notes\n'
        '{"_id":"$id1","title":"Hello"}\n'
        '{"_id":"$id2","title":"World"}\n',
      );

      final out = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, out: out), [], {
        'input': tmp.path,
      });

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['restored'], equals(2));

      final raw1 = await db.store.get('notes', id1);
      expect(raw1, isNotNull);
      expect((await ValueCodec.decode(raw1!))['title'], 'Hello');
    });

    test('restores multiple collections', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final id1 = _key('r3');
      final id2 = _key('r4');

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test2_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync(
        '# collection: notes\n'
        '{"_id":"$id1","x":1}\n'
        '# collection: tasks\n'
        '{"_id":"$id2","x":2}\n',
      );

      final out = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, out: out), [], {
        'input': tmp.path,
      });

      expect(ok, isTrue);
      expect(await db.store.get('notes', id1), isNotNull);
      expect(await db.store.get('tasks', id2), isNotNull);
    });

    test('skips blank and comment lines', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final id1 = _key('r5');

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test3_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync(
        '\n'
        '# collection: notes\n'
        '# another comment\n'
        '\n'
        '{"_id":"$id1","x":1}\n',
      );

      final out = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, out: out), [], {
        'input': tmp.path,
      });

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['restored'], equals(1));
    });

    test(
      'returns false when document appears before collection header',
      () async {
        final db = await _openStore();
        addTearDown(() => db.close());
        final id1 = _key('r6');

        final tmp = io.File(
          '${io.Directory.systemTemp.path}/restore_test4_${_dbCounter++}.ndjson',
        );
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync();
        });
        tmp.writeAsStringSync('{"_id":"$id1","x":1}\n');

        final err = StringBuffer();
        final ok = await RestoreCommand().execute(_ctx(db, err: err), [], {
          'input': tmp.path,
        });

        expect(ok, isFalse);
        expect(err.toString(), contains('before any collection header'));
      },
    );

    test('returns false for invalid JSON', () async {
      final db = await _openStore();
      addTearDown(() => db.close());

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test5_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync('# collection: notes\n{bad json}\n');

      final err = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, err: err), [], {
        'input': tmp.path,
      });

      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));
    });

    test('returns false when document is not a JSON object', () async {
      final db = await _openStore();
      addTearDown(() => db.close());

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test6_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync('# collection: notes\n[1,2,3]\n');

      final err = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, err: err), [], {
        'input': tmp.path,
      });

      expect(ok, isFalse);
      expect(err.toString(), contains('expected JSON object'));
    });

    test('returns false when document is missing _id field', () async {
      final db = await _openStore();
      addTearDown(() => db.close());

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test7_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync('# collection: notes\n{"title":"no id"}\n');

      final err = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, err: err), [], {
        'input': tmp.path,
      });

      expect(ok, isFalse);
      expect(err.toString(), contains('"_id"'));
    });

    test('empty dump file restores zero documents', () async {
      final db = await _openStore();
      addTearDown(() => db.close());

      final tmp = io.File(
        '${io.Directory.systemTemp.path}/restore_test8_${_dbCounter++}.ndjson',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      tmp.writeAsStringSync('');

      final out = StringBuffer();
      final ok = await RestoreCommand().execute(_ctx(db, out: out), [], {
        'input': tmp.path,
      });

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['restored'], equals(0));
    });
  });

  // ── VerifyCommand ───────────────────────────────────────────────────────────

  group('VerifyCommand', () {
    test('returns true and reports 0 errors for a valid database', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final id1 = _key('v1');
      await db.store.put('notes', id1, await ValueCodec.encode({'x': 1}));

      final out = StringBuffer();
      final ok = await VerifyCommand().execute(_ctx(db, out: out), [], {});

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['checked'], equals(1));
      expect(result['errors'], equals(0));
    });

    test('returns true and checked=0 for an empty database', () async {
      final db = await _openStore();
      addTearDown(() => db.close());

      final out = StringBuffer();
      final ok = await VerifyCommand().execute(_ctx(db, out: out), [], {});

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['checked'], equals(0));
      expect(result['errors'], equals(0));
    });

    test('verifies documents in multiple collections', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      await db.store.put(
        'notes',
        _key('v2'),
        await ValueCodec.encode({'a': 1}),
      );
      await db.store.put(
        'tasks',
        _key('v3'),
        await ValueCodec.encode({'b': 2}),
      );

      final out = StringBuffer();
      final ok = await VerifyCommand().execute(_ctx(db, out: out), [], {});

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['checked'], equals(2));
    });

    test('returns false and reports error for undecodable document', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final id1 = _key('v4');
      await db.store.put('notes', id1, Uint8List.fromList([0xFF, 0xFE, 0xFD]));

      final out = StringBuffer();
      final ok = await VerifyCommand().execute(_ctx(db, out: out), [], {});

      expect(ok, isFalse);
      final result = json.decode(out.toString()) as Map;
      expect(result['errors'], greaterThan(0));
    });
  });

  // ── CountCommand ─────────────────────────────────────────────────────────────

  group('CountCommand', () {
    test('returns false for a filter that is not a JSON object', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      await db.store.put(
        'notes',
        _key('c1'),
        await ValueCodec.encode({'x': 1}),
      );

      final err = StringBuffer();
      final ok = await CountCommand().execute(
        _ctx(db, err: err),
        ['notes'],
        {'filter': '[1,2,3]'},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid filter'));
    });
  });

  // ── VaultCommand ────────────────────────────────────────────────────────────

  group('VaultCommand', () {
    test('returns false when vault is not configured', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final err = StringBuffer();

      final ok = await VaultCommand().execute(_ctx(db, err: err), [
        'get',
        'kmdb-vault://sha256/${'a' * 64}',
      ], {});

      expect(ok, isFalse);
      expect(err.toString(), contains('Vault is not available'));
    });

    test(
      'returns false when no sub-command is given (with vault configured)',
      () async {
        final dbPath = '/testdb_vault_cmd_${_dbCounter++}';
        final adapter = MemoryStorageAdapter();
        final vault = _TestVaultStore(adapter, dbPath);
        final db = await KmdbDatabase.open(
          path: dbPath,
          adapter: MemoryStorageAdapter(),
          config: KvStoreConfig.forTesting(),
          vaultStore: vault,
        );
        addTearDown(() => db.close());
        final err = StringBuffer();

        final ok = await VaultCommand().execute(_ctx(db, err: err), [], {});

        expect(ok, isFalse);
        expect(err.toString(), contains('requires a sub-command'));
      },
    );

    test(
      'returns false for unknown sub-command (with vault configured)',
      () async {
        final dbPath = '/testdb_vault_cmd2_${_dbCounter++}';
        final adapter = MemoryStorageAdapter();
        final vault = _TestVaultStore(adapter, dbPath);
        final db = await KmdbDatabase.open(
          path: dbPath,
          adapter: MemoryStorageAdapter(),
          config: KvStoreConfig.forTesting(),
          vaultStore: vault,
        );
        addTearDown(() => db.close());
        final err = StringBuffer();

        final ok = await VaultCommand().execute(_ctx(db, err: err), [
          'delete',
        ], {});

        expect(ok, isFalse);
        expect(err.toString(), contains("Unknown vault sub-command 'delete'"));
      },
    );
  });
}

// ── Minimal VaultStore for tests that need a vault-configured DB ──────────────

class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter, String dbPath)
    : _mem = adapter,
      super(adapter: adapter, dbDir: dbPath);

  final MemoryStorageAdapter _mem;

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return [
      for (final path in _mem.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}
