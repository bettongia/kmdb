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

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/update_command.dart';
import 'package:test/test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Counter to generate unique in-memory database paths per test, preventing
/// LockException when multiple [KmdbDatabase] instances are opened concurrently.
var _dbCounter = 0;

/// A [VaultStore] that works with the flat [MemoryStorageAdapter] key store.
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

/// Opens an in-memory [KmdbDatabase] for tests, optionally wired with [vault].
///
/// Each call uses a unique path to prevent [LockException] when tests open
/// multiple databases concurrently (e.g. a vault-wired db and a no-vault db).
Future<KmdbDatabase> _openStore({String? path, _TestVaultStore? vault}) async {
  final dbPath = path ?? '/testdb_update_import_${_dbCounter++}';
  return KmdbDatabase.open(
    path: dbPath,
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
}

/// Builds a [CommandContext] backed by [db].
CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

/// Writes a small document into [db] directly using the raw KV store.
///
/// The document must be small enough to stay below the Zstd compression
/// threshold (64 raw CBOR bytes). Uses raw ValueCodec encoding. If the doc
/// exceeds the threshold, the Zstd library is required.
Future<void> _putSmallDoc(KmdbDatabase db, String collection, String id) async {
  // {'i': id} where id is short → stays under 64 bytes in CBOR
  final doc = {'i': id}; // use short key to stay under threshold
  await db.store.put(collection, id, ValueCodec.encode(doc));
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('UpdateCommand --import', () {
    late KmdbDatabase db;
    late MemoryStorageAdapter memAdapter;
    late _TestVaultStore vault;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      final dbPath = '/testdb_update_import_${_dbCounter++}';
      memAdapter = MemoryStorageAdapter();
      vault = _TestVaultStore(memAdapter, dbPath);
      db = await _openStore(path: dbPath, vault: vault);
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    // ── Mutual exclusion ──────────────────────────────────────────────────

    test('--import is mutually exclusive with --set', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', 'someid'],
        {'import': '/some/path.kvlt', 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    // ── Vault not configured ──────────────────────────────────────────────

    test('--import returns false when vault store is null', () async {
      final dbNoVault = await _openStore();
      addTearDown(() => dbNoVault.close());
      final ctx = _ctx(dbNoVault, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'import': '/some/path.kvlt'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('requires vault'));
    });

    // ── No target ID ──────────────────────────────────────────────────────

    test('--import requires a positional ID or --id flag', () async {
      // Create a valid (if empty) package so we get past the file-reading step.
      final plainDoc = {'t': 'x'};
      final packageBytes = VaultPackage.write(documentJson: plainDoc);
      final tmpPath =
          '${io.Directory.systemTemp.path}/kmdb_upd_test_${DateTime.now().microsecondsSinceEpoch}.kvlt';
      io.File(tmpPath).writeAsBytesSync(packageBytes);
      addTearDown(() {
        try {
          io.File(tmpPath).deleteSync();
        } catch (_) {}
      });

      final ctx = _ctx(db, out: out, err: err);
      // No positional id, no --id flag — only collection name.
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'import': tmpPath},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('target document ID'));
    });

    // ── Positional id AND --id flag conflict ──────────────────────────────

    test('returns false when both positional id and --id are given', () async {
      final plainDoc = {'t': 'x'};
      final packageBytes = VaultPackage.write(documentJson: plainDoc);
      final tmpPath =
          '${io.Directory.systemTemp.path}/kmdb_upd_test2_${DateTime.now().microsecondsSinceEpoch}.kvlt';
      io.File(tmpPath).writeAsBytesSync(packageBytes);
      addTearDown(() {
        try {
          io.File(tmpPath).deleteSync();
        } catch (_) {}
      });

      final ctx = _ctx(db, out: out, err: err);
      // Both positional id (args[1]) and --id flag provided.
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', 'positional-id'],
        {'import': tmpPath, 'id': 'flag-id'},
      );
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });

    // ── Non-existent package file ──────────────────────────────────────────

    test('returns false when package file does not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', 'some-id'],
        {'import': '/nonexistent/path.kvlt'},
      );
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });

    // ── Corrupt package ───────────────────────────────────────────────────

    test('returns false for corrupt package file', () async {
      final tmpPath =
          '${io.Directory.systemTemp.path}/kmdb_upd_corrupt_${DateTime.now().microsecondsSinceEpoch}.kvlt';
      io.File(tmpPath).writeAsBytesSync(Uint8List.fromList([9, 9, 9]));
      addTearDown(() {
        try {
          io.File(tmpPath).deleteSync();
        } catch (_) {}
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', 'some-id'],
        {'import': tmpPath},
      );
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });

    // ── Document not found ────────────────────────────────────────────────

    test('returns false when target document does not exist', () async {
      // Build a valid package with a plain document (no vault refs).
      final plainDoc = {'t': 'y'};
      final packageBytes = VaultPackage.write(documentJson: plainDoc);
      final tmpPath =
          '${io.Directory.systemTemp.path}/kmdb_upd_notfound_${DateTime.now().microsecondsSinceEpoch}.kvlt';
      io.File(tmpPath).writeAsBytesSync(packageBytes);
      addTearDown(() {
        try {
          io.File(tmpPath).deleteSync();
        } catch (_) {}
      });

      // Valid UUIDv7-format key that has not been inserted.
      const absentId = '01900000000070809000000000000001';

      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', absentId],
        {'import': tmpPath},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    // ── Package with unreferenced attachment ──────────────────────────────

    test('returns false when attachment is not referenced in document', () async {
      final attachBytes = Uint8List.fromList(utf8.encode('unref-file'));
      final sha256 = VaultStore.computeSha256ForTest(attachBytes);
      final docWithNoRef = {'t': 'z'};
      final packageBytes = VaultPackage.write(
        documentJson: docWithNoRef,
        attachments: [VaultAttachment(subdirName: '0', bytes: attachBytes)],
      );
      final tmpPath =
          '${io.Directory.systemTemp.path}/kmdb_upd_unref_${DateTime.now().microsecondsSinceEpoch}.kvlt';
      io.File(tmpPath).writeAsBytesSync(packageBytes);
      addTearDown(() {
        try {
          io.File(tmpPath).deleteSync();
        } catch (_) {}
      });

      // Seed a small target document that stays under the Zstd threshold.
      // Must be a valid UUIDv7 hex string (version nibble = 7, variant = 8-b).
      const targetId = '01900000000070809000000000000002';
      await _putSmallDoc(db, 'col', targetId);

      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', targetId],
        {'import': tmpPath},
      );
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
      expect(sha256.length, equals(64)); // suppress unused variable warning
    });
  });
}
