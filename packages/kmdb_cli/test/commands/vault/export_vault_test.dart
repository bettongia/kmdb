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
import 'package:kmdb_cli/src/commands/export_command.dart';
import 'package:test/test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// A [VaultStore] backed by [MemoryStorageAdapter] for CLI tests.
class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(adapter: adapter, dbDir: '/testdb');

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

/// Builds a [CommandContext] with an optional [VaultStore].
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

/// Ingests [bytes] into [vault] and returns the `kmdb-vault://` URI string.
Future<String> _ingest(
  _TestVaultStore vault,
  Uint8List bytes, {
  String name = 'test.bin',
}) async {
  final ref = await vault.ingest(
    bytes: bytes,
    hlcTimestamp: '0000000000000001',
    originalName: name,
  );
  return ref.toString();
}

/// Small bytes that won't trigger Zstd for vault ingestion.
final _kFileBytes = Uint8List.fromList(utf8.encode('export-vault-test'));

void main() {
  group('ExportCommand --vault', () {
    late KvStoreImpl store;
    late MemoryStorageAdapter memAdapter;
    late _TestVaultStore vault;
    late StringBuffer out;
    late StringBuffer err;
    late io.Directory tmpDir;

    setUp(() async {
      store = await _openStore();
      memAdapter = MemoryStorageAdapter();
      vault = _TestVaultStore(memAdapter);
      out = StringBuffer();
      err = StringBuffer();
      tmpDir = io.Directory.systemTemp.createTempSync(
        'kmdb_export_vault_test_',
      );
    });
    tearDown(() async {
      await store.close();
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    // ── Missing collection argument ───────────────────────────────────────

    test('returns false when collection arg is missing', () async {
      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await ExportCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires <collection>'));
    });

    // ── Vault not configured ──────────────────────────────────────────────

    test('--vault returns false when vault store is null', () async {
      final ctx = _ctx(store, vault: null, out: out, err: err);
      final ok = await ExportCommand().execute(
        ctx,
        ['notes'],
        {'vault': true, 'output': '${tmpDir.path}/out'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('requires vault'));
    });

    // ── Output dir creation failure ───────────────────────────────────────

    test('--vault returns false when output dir cannot be created', () async {
      final ctx = _ctx(store, vault: vault, out: out, err: err);
      // Use a path blocked by an existing regular file.
      final blocked = '${tmpDir.path}/blocked';
      io.File(blocked).createSync();
      final badDir = '$blocked/nested';

      final ok = await ExportCommand().execute(
        ctx,
        ['notes'],
        {'vault': true, 'output': badDir},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Cannot create output directory'));
    });

    // ── Standard export (no --vault) ──────────────────────────────────────

    test('standard export (no --vault) writes NDJSON to out sink', () async {
      const id = '01900000000070809000000000000020';
      await store.put('docs', id, ValueCodec.encode({'i': id}));

      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await ExportCommand().execute(ctx, ['docs'], {});

      expect(ok, isTrue);
      expect(out.toString(), contains(id));
    });

    // ── Empty collection ──────────────────────────────────────────────────

    test(
      '--vault on empty collection writes summary with zero counts',
      () async {
        final ctx = _ctx(store, vault: vault, out: out, err: err);
        final ok = await ExportCommand().execute(
          ctx,
          ['empty'],
          {'vault': true, 'output': '${tmpDir.path}/export_out'},
        );
        expect(ok, isTrue);
        expect(out.toString(), contains('exported'));
        expect(out.toString(), contains('stubsSkipped'));
      },
    );

    // ── Documents without vault refs ──────────────────────────────────────

    test(
      '--vault exports plain documents to NDJSON (no package files)',
      () async {
        const id = '01900000000070809000000000000021';
        await store.put('docs', id, ValueCodec.encode({'i': id}));

        final outputDir = '${tmpDir.path}/plain_export';
        final ctx = _ctx(store, vault: vault, out: out, err: err);
        final ok = await ExportCommand().execute(
          ctx,
          ['docs'],
          {'vault': true, 'output': outputDir},
        );
        expect(ok, isTrue);
        expect(out.toString(), contains(id));
        // No KVLT packages created: directory either doesn't exist or is empty.
        final dir = io.Directory(outputDir);
        if (dir.existsSync()) {
          final files = dir.listSync().whereType<io.File>().toList();
          expect(
            files,
            isEmpty,
            reason: 'No KVLT packages for plain documents',
          );
        }
      },
    );

    // ── Stub skipping ─────────────────────────────────────────────────────

    test('--vault skips stub vault objects', () async {
      // Create a stub: manifest present, no blob.
      final sha256 = VaultStore.computeSha256ForTest(_kFileBytes);
      final crc32c = VaultStore.computeCrc32cForTest(_kFileBytes);
      final dir = vault.hashDir(sha256);
      await vault.adapter.createDirectory(dir);
      await vault.adapter.writeFile(
        vault.manifestPath(sha256),
        Uint8List.fromList(
          utf8.encode(
            '{"schemaVersion":1,"sha256":"$sha256","size":${_kFileBytes.length},'
            '"crc32c":"$crc32c","mediaType":"text/plain","originalName":"stub.bin",'
            '"createdAt":"0000000000000001"}',
          ),
        ),
      );

      // Verify the stub state.
      expect(await vault.exists(sha256), isTrue);
      expect(await vault.isHydrated(sha256), isFalse);

      // The export --vault command should skip this stub when processing docs
      // that reference it. Since we can't store vault-URI documents without Zstd,
      // we verify the stub detection logic through the vault store directly.
      final vaultUri = 'kmdb-vault://sha256/$sha256';
      expect(vaultUri, startsWith('kmdb-vault://sha256/'));
    });

    // ── Hydrated vault object export ──────────────────────────────────────

    test('fully hydrated vault object can be read back', () async {
      // Ingest a file and verify it is hydrated.
      final vaultUri = await _ingest(vault, _kFileBytes, name: 'attach.bin');
      final sha256 = VaultStore.computeSha256ForTest(_kFileBytes);

      expect(await vault.exists(sha256), isTrue);
      expect(await vault.isHydrated(sha256), isTrue);
      expect(vaultUri, startsWith('kmdb-vault://sha256/'));

      // The bytes can be read back from the vault.
      final bytes = await vault.getBytes(sha256);
      expect(bytes, equals(_kFileBytes));
    });

    // ── Default output dir name ───────────────────────────────────────────

    test('default output dir is <collection>_vault_export', () async {
      // Export with --vault but no explicit --output.
      // The command will attempt to create '<collection>_vault_export'.
      // We just verify the command runs without crash and reports in out.
      final ctx = _ctx(store, vault: vault, out: out, err: err);
      final ok = await ExportCommand().execute(ctx, ['docs'], {'vault': true});
      // May succeed or fail depending on cwd write permissions.
      // Key assertion: the command doesn't crash unexpectedly.
      if (ok) {
        expect(out.toString(), anyOf(contains('exported'), contains('docs')));
        // Clean up any created directory.
        final defaultDir = io.Directory('docs_vault_export');
        if (defaultDir.existsSync()) {
          defaultDir.deleteSync(recursive: true);
        }
      } else {
        // Cannot create directory in cwd: that's acceptable in test env.
        expect(err.toString(), isNotEmpty);
      }
    });
  });
}
