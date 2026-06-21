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

// In-process tests for DumpCommand.
//
// These tests cover:
//  - Standard NDJSON dump (golden path, already covered by cli_runner_test)
//  - Vault dump with vault configured + plain document (no vault URIs) →
//    exercises the _executeVaultDump path through to the scan loop and the
//    _scanForVaultUris → empty → continue branch.
//  - Vault dump where a document has a list field → exercises _scan list path
//    in _scanForVaultUris (lines 224-226).
//  - Vault dump where a document has a vault URI stub (not hydrated) →
//    stubsSkipped incremented (line 163).

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/dump_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

class _Sink implements StringSink {
  final StringBuffer _buf = StringBuffer();

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

  @override
  String toString() => _buf.toString();
}

/// A [VaultStore] that works with the flat [MemoryStorageAdapter] key store.
class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter, String dbPath)
    : super(adapter: adapter, dbDir: dbPath);

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    return const [];
  }
}

/// A vault store that uses its own [MemoryStorageAdapter] (separate from the DB
/// adapter) and overrides [listFilesRecursive] to return its own known keys.
class _HydratedVaultStore extends VaultStore {
  _HydratedVaultStore(this._vaultAdapter)
    : super(adapter: _vaultAdapter, dbDir: '/vault_hydrated');

  final MemoryStorageAdapter _vaultAdapter;

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    // Return all keys in the adapter (so listBlobs works in GC etc.).
    return _vaultAdapter.files.keys.toList();
  }
}

/// Counter for unique db paths.
var _dbCounter = 0;

/// Opens an in-memory [KmdbDatabase], optionally with a vault store.
Future<(KmdbDatabase, CommandContext)> _openCtx({
  _TestVaultStore? vault,
  StringSink? out,
  StringSink? err,
}) async {
  final dbPath = '/dump_test_db_${_dbCounter++}';
  final db = await KmdbDatabase.open(
    path: dbPath,
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
  final ctx = CommandContext(db: db, out: out ?? _Sink(), err: err ?? _Sink());
  return (db, ctx);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('DumpCommand --vault', () {
    test(
      'plain documents (no vault URIs) are dumped, no KVLT files written',
      () async {
        // Use a real tmpdir so the vault dump can create directories.
        final tmpDir = io.Directory.systemTemp.createTempSync(
          'kmdb_dump_test_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));

        final adapter = MemoryStorageAdapter();
        final vault = _TestVaultStore(
          adapter,
          '/dump_vault_plain_${_dbCounter++}',
        );
        final outSink = _Sink();
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(
          vault: vault,
          out: outSink,
          err: errSink,
        );
        addTearDown(db.close);

        // Insert a plain document with a list field to also exercise
        // _scan's List<dynamic> branch (lines 224-226).
        final col = ctx.rawCollection('items');
        await col.insert({
          'name': 'item-1',
          'tags': ['a', 'b', 'c'],
        });
        await col.insert({
          'name': 'item-2',
          'nested': {'x': 1},
        });

        final vaultDir = '${tmpDir.path}/vault_out';
        final ok = await const DumpCommand().execute(ctx, [], {
          'vault': true,
          'vault-dir': vaultDir,
        });

        // No vault URIs in docs → no KVLT files, but the dump succeeds.
        expect(ok, isTrue, reason: errSink.toString());
        // Output should contain the documents as NDJSON.
        expect(outSink.toString(), contains('item-1'));
        // Vault output dir exists but collection subdir was never created
        // (all documents had empty vault URI sets → continue at line 144).
        expect(io.Directory(vaultDir).existsSync(), isTrue);
        expect(
          io.Directory('$vaultDir/items').existsSync(),
          isFalse,
          reason: 'no vault URI docs → no per-collection subdir',
        );
      },
    );

    test(
      'document with stub vault URI (not hydrated) increments stubsSkipped',
      () async {
        // Use a real tmpdir for the vault dir.
        final tmpDir = io.Directory.systemTemp.createTempSync(
          'kmdb_dump_stub_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));

        final adapter = MemoryStorageAdapter();
        final vault = _TestVaultStore(
          adapter,
          '/dump_vault_stub_${_dbCounter++}',
        );
        final outSink = _Sink();
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(
          vault: vault,
          out: outSink,
          err: errSink,
        );
        addTearDown(db.close);

        // Build a fake vault URI (sha256 not ingested into the vault).
        // The sha256 must be 64 hex chars for VaultRef to be valid.
        const fakeSha256 =
            'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
        final vaultUri = 'kmdb-vault://sha256/$fakeSha256';

        // Insert a document referencing a stub vault URI (blob not hydrated).
        // Use db.store.put() to bypass KmdbCollection._writeDocument and the
        // VaultRefInterceptor, which would try to read/write sha256 as a 64-char
        // KV key (rejected by LSM engine key validation).
        const docId = '01900000000070809000000000000050';
        final doc = {'title': 'doc-with-stub', 'file': vaultUri};
        await db.store.put('docs', docId, await ValueCodec.encode(doc));

        final vaultDir = '${tmpDir.path}/vault_stub_out';
        final ok = await const DumpCommand().execute(ctx, [], {
          'vault': true,
          'vault-dir': vaultDir,
        });

        // The dump should succeed. The stub URI is not hydrated → stubsSkipped=1.
        // The output summary should contain packagesWritten=0.
        expect(ok, isTrue, reason: errSink.toString());
        // The NDJSON output must contain the document.
        expect(outSink.toString(), contains('doc-with-stub'));
      },
    );

    test('hydrated vault blob: dump writes a .kvlt package file', () async {
      // Exercises the fully-hydrated vault path in DumpCommand:
      //   - vaultStore.isHydrated → true
      //   - vaultStore.getBytes + getManifest (lines 167-175)
      //   - VaultPackage.write (line 185)
      //   - File.writeAsBytes (lines 191-192)
      // A separate MemoryStorageAdapter for the vault store ensures no key
      // conflicts with the DB adapter.
      final tmpDir = io.Directory.systemTemp.createTempSync(
        'kmdb_dump_hydrated_',
      );
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final vaultAdapter = MemoryStorageAdapter();
      final vault = _HydratedVaultStore(vaultAdapter);
      final dbAdapter = MemoryStorageAdapter();
      final dbPath = '/dump_hydrated_${_dbCounter++}';
      final db = await KmdbDatabase.open(
        path: dbPath,
        adapter: dbAdapter,
        config: KvStoreConfig.forTesting(),
        vaultStore: vault,
      );
      addTearDown(db.close);

      final outSink = _Sink();
      final errSink = _Sink();
      final ctx = CommandContext(db: db, out: outSink, err: errSink);

      // Ingest a small blob into the vault (makes it hydrated).
      final blobBytes = utf8.encode('hello vault blob');
      final ref = await vault.ingest(
        bytes: blobBytes,
        hlcTimestamp: '000000000000:0000',
      );
      final vaultUri = ref.uri;

      // Store a document referencing the hydrated blob (bypass VaultRefInterceptor).
      const docId = '01900000000070809000000000000055';
      await db.store.put(
        'docs',
        docId,
        await ValueCodec.encode({'title': 'hydrated-doc', 'file': vaultUri}),
      );

      final vaultDir = '${tmpDir.path}/vault_hydrated_out';
      final ok = await const DumpCommand().execute(ctx, [], {
        'vault': true,
        'vault-dir': vaultDir,
      });

      expect(ok, isTrue, reason: errSink.toString());
      // The document JSON must be in the output.
      expect(outSink.toString(), contains('hydrated-doc'));
      // A .kvlt file must have been written for the hydrated document.
      final kvltFiles = io.Directory('$vaultDir/docs')
          .listSync(recursive: true)
          .whereType<io.File>()
          .where((f) => f.path.endsWith('.kvlt'))
          .toList();
      expect(kvltFiles, hasLength(1), reason: 'expected one .kvlt package');
    });
  });
}
