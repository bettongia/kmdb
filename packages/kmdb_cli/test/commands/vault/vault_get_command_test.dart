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
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_get_command.dart';
import 'package:test/test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// A [VaultStore] subclass that overrides [listFilesRecursive] so it works
/// with the flat [MemoryStorageAdapter] key store used in tests.
class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter memAdapter)
    : _mem = memAdapter,
      super(adapter: memAdapter, dbDir: '/testdb');

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

/// Opens an in-memory [KvStoreImpl] for tests.
Future<KvStoreImpl> _openStore() async {
  final (store, _) = await KvStoreImpl.open(
    '/testdb',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return store;
}

/// Builds a [CommandContext] for tests.
CommandContext _ctx(
  KvStoreImpl store, {
  required _TestVaultStore? vault,
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  store: store,
  vaultStore: vault,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

/// Content bytes short enough that VaultStore never invokes Zstd compression.
final _kBytes = Uint8List.fromList(utf8.encode('vault-get-test'));

/// Ingests [bytes] into [vault] and returns the `kmdb-vault://` URI string.
Future<String> _ingest(
  _TestVaultStore vault,
  Uint8List bytes, {
  String name = 'test.txt',
}) async {
  final ref = await vault.ingest(
    bytes: bytes,
    hlcTimestamp: '0000000000000001',
    originalName: name,
  );
  return ref.toString();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('VaultGetCommand', () {
    late KvStoreImpl store;
    late MemoryStorageAdapter memAdapter;
    late _TestVaultStore vault;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      memAdapter = MemoryStorageAdapter();
      vault = _TestVaultStore(memAdapter);
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    // ── Vault store not configured ────────────────────────────────────────

    test('returns false when vault store is null', () async {
      final ctx = _ctx(store, vault: null, out: out, err: err);
      final ok = await VaultGetCommand().execute(ctx, [
        'kmdb-vault://sha256/${'a' * 64}',
      ], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('not configured'));
    });

    // ── URI argument validation ────────────────────────────────────────────

    test('returns false when no URI argument is given', () async {
      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await VaultGetCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires a URI argument'));
    });

    test('returns false for a non-vault URI scheme', () async {
      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await VaultGetCommand().execute(ctx, [
        'https://example.com/file',
      ], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid vault URI'));
    });

    test(
      'returns false for a malformed vault URI (too short sha256)',
      () async {
        final ctx = _ctx(store, vault: vault, out: out, err: err);
        final ok = await VaultGetCommand().execute(ctx, [
          'kmdb-vault://sha256/short',
        ], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('Invalid vault URI'));
      },
    );

    // ── Object not found ──────────────────────────────────────────────────

    test('returns false when the vault object does not exist', () async {
      final ctx = _ctx(store, vault: vault, out: out, err: err);
      // A valid-format SHA-256 that has not been ingested.
      final ok = await VaultGetCommand().execute(ctx, [
        'kmdb-vault://sha256/${'b' * 64}',
      ], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    // ── Stub (manifest present, blob absent) ──────────────────────────────

    test('returns false for a stub object', () async {
      // Create a stub: manifest present but no blob file.
      final sha256 = VaultStore.computeSha256ForTest(_kBytes);
      final crc32c = VaultStore.computeCrc32cForTest(_kBytes);
      final dir = vault.hashDir(sha256);
      await vault.adapter.createDirectory(dir);
      await vault.adapter.writeFile(
        vault.manifestPath(sha256),
        Uint8List.fromList(
          utf8.encode(
            '{"schemaVersion":1,"sha256":"$sha256","size":${_kBytes.length},'
            '"crc32c":"$crc32c","mediaType":"text/plain","originalName":"f.txt",'
            '"createdAt":"0000000000000001"}',
          ),
        ),
      );
      // Blob is deliberately absent to simulate a stub.

      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await VaultGetCommand().execute(ctx, [
        'kmdb-vault://sha256/$sha256',
      ], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('stub'));
    });

    // ── Successful retrieval with --output ────────────────────────────────

    test('writes blob to --output file and returns JSON summary', () async {
      final uri = await _ingest(vault, _kBytes);
      final sha256 = VaultStore.computeSha256ForTest(_kBytes);

      final tmpPath =
          '${io.Directory.systemTemp.path}/kmdb_vault_get_${DateTime.now().microsecondsSinceEpoch}.bin';
      addTearDown(() {
        try {
          io.File(tmpPath).deleteSync();
        } catch (_) {}
      });

      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await VaultGetCommand().execute(
        ctx,
        [uri],
        {'output': tmpPath},
      );

      expect(ok, isTrue);
      // Output file must exist and contain the original bytes.
      final written = io.File(tmpPath).readAsBytesSync();
      expect(written, equals(_kBytes));
      // ctx.out must contain a JSON summary with uri and sha256.
      final summary = out.toString();
      expect(summary, contains(sha256));
      expect(summary, contains(uri));
    });

    // ── Write to --output fails ───────────────────────────────────────────

    test('returns false when --output path is not writable', () async {
      final uri = await _ingest(vault, _kBytes);
      // Use a path in a non-existent directory to force an I/O failure.
      const badPath = '/nonexistent/dir/file.bin';

      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await VaultGetCommand().execute(
        ctx,
        [uri],
        {'output': badPath},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('Cannot write'));
    });
  });
}
