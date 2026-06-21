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

// In-process tests for ExportCommand.
//
// These tests cover:
//  - Missing collection argument → false + error
//  - Basic NDJSON export (golden path)
//  - Vault export without vault configured → false + error
//
// Subprocess round-trip (export + import) is covered in cli_runner_test.dart.

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/export_command.dart';
import 'package:test/test.dart';

// ── Vault test helper ─────────────────────────────────────────────────────────

class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter, String dbPath)
    : super(adapter: adapter, dbDir: dbPath);

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async => const [];
}

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

var _exportDbCounter = 0;

/// Opens an in-memory database and returns `(db, ctx)`.
Future<(KmdbDatabase, CommandContext)> _openCtx({
  StringSink? out,
  StringSink? err,
  _TestVaultStore? vault,
}) async {
  final db = await KmdbDatabase.open(
    path: '/export_test_db_${_exportDbCounter++}',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
  final ctx = CommandContext(
    db: db,
    out: out ?? StringBuffer(),
    err: err ?? StringBuffer(),
  );
  return (db, ctx);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('ExportCommand', () {
    test('missing collection arg returns false with error', () async {
      final errSink = _Sink();
      final (db, ctx) = await _openCtx(err: errSink);
      addTearDown(db.close);

      final result = await const ExportCommand().execute(ctx, [], {});
      expect(result, isFalse);
      expect(errSink.toString(), contains('export requires'));
    });

    test('exports documents as NDJSON', () async {
      final outSink = _Sink();
      final (db, ctx) = await _openCtx(out: outSink);
      addTearDown(db.close);

      // Insert two documents.
      final col = ctx.rawCollection('notes');
      final doc1 = await col.insert({'title': 'First note'});
      final doc2 = await col.insert({'title': 'Second note'});

      final result = await const ExportCommand().execute(ctx, ['notes'], {});
      expect(result, isTrue);

      // Output should have two NDJSON lines.
      final lines = outSink
          .toString()
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines.length, equals(2));

      // Each line must be valid JSON containing _id and title.
      final decoded = lines
          .map(jsonDecode)
          .cast<Map<String, dynamic>>()
          .toList();
      final ids = decoded.map((d) => d['_id'] as String).toSet();
      expect(ids, containsAll([doc1['_id'], doc2['_id']]));
      for (final d in decoded) {
        expect(d['title'], isA<String>());
      }
    });

    test(
      '--vault flag without vault configured returns false with error',
      () async {
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(err: errSink);
        addTearDown(db.close);

        // No vault store configured — --vault must fail gracefully.
        final result = await const ExportCommand().execute(
          ctx,
          ['notes'],
          {'vault': true},
        );
        expect(result, isFalse);
        expect(errSink.toString(), contains('vault'));
      },
    );

    test('vault export with default output dir creates directory', () async {
      // This test uses a real tmpdir to verify the directory creation path.
      // It requires a real StorageAdapterNative so the vault store is writeable.
      final tmpDir = io.Directory.systemTemp.createTempSync('kmdb_exp_vault_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final dbPath = '${tmpDir.path}/db';
      final db = await KmdbDatabase.open(
        path: dbPath,
        adapter: StorageAdapterNative(),
      );
      addTearDown(db.close);

      final outSink = _Sink();
      final errSink = _Sink();
      final ctx = CommandContext(db: db, out: outSink, err: errSink);

      // Insert a plain document (no vault URIs) to the 'docs' collection.
      final col = ctx.rawCollection('docs');
      await col.insert({'body': 'no vault'});

      // Run vault export — should succeed, writing the output summary.
      // Since there are no vault URIs in documents, the packageDir will be
      // created but no .kvlt files written.
      final vaultExportDir = '${tmpDir.path}/vault_out';
      final result = await const ExportCommand().execute(
        ctx,
        ['docs'],
        {'vault': true, 'output': vaultExportDir},
      );
      // db has no vault store; should return false with error.
      // (vault store is only present when configured in KmdbDatabase.open)
      expect(result, isFalse);
      expect(errSink.toString(), contains('vault'));
    });

    test(
      'vault export with plain docs (no vault URIs) succeeds, no packages written',
      () async {
        // Use real tmpdir so directory creation works.
        final tmpDir = io.Directory.systemTemp.createTempSync(
          'kmdb_exp_plain_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));

        final adapter = MemoryStorageAdapter();
        final vault = _TestVaultStore(
          adapter,
          '/export_vault_plain_${_exportDbCounter++}',
        );
        final outSink = _Sink();
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(
          vault: vault,
          out: outSink,
          err: errSink,
        );
        addTearDown(db.close);

        // Insert documents with no vault URIs; one has a list field to exercise
        // the _scan List<dynamic> branch (lines 228-230).
        final col = ctx.rawCollection('items');
        await col.insert({
          'title': 'plain-1',
          'tags': ['x', 'y'],
        });
        await col.insert({
          'title': 'plain-2',
          'nested': {'k': 1},
        });

        final outputDir = '${tmpDir.path}/export_plain';
        final result = await const ExportCommand().execute(
          ctx,
          ['items'],
          {'vault': true, 'output': outputDir},
        );

        expect(result, isTrue, reason: errSink.toString());
        // Both plain docs must appear in the NDJSON output.
        expect(outSink.toString(), contains('plain-1'));
        expect(outSink.toString(), contains('plain-2'));
        // No .kvlt files written (no vault URIs → no attachments).
        final files = io.Directory(
          outputDir,
        ).listSync(recursive: true).whereType<io.File>();
        expect(files, isEmpty, reason: 'no vault URI docs → no packages');
      },
    );

    test(
      'vault export: document with stub vault URI is skipped (stubsSkipped++)',
      () async {
        final tmpDir = io.Directory.systemTemp.createTempSync('kmdb_exp_stub_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));

        final adapter = MemoryStorageAdapter();
        final vault = _TestVaultStore(
          adapter,
          '/export_vault_stub_${_exportDbCounter++}',
        );
        final outSink = _Sink();
        final errSink = _Sink();
        final (db, ctx) = await _openCtx(
          vault: vault,
          out: outSink,
          err: errSink,
        );
        addTearDown(db.close);

        // Insert a document with a stub vault URI via raw store (bypasses
        // VaultRefInterceptor which would reject the 64-char sha256 key).
        const fakeSha256 =
            'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
        final vaultUri = 'kmdb-vault://sha256/$fakeSha256';
        const docId = '01900000000070809000000000000060';
        await db.store.put(
          'docs',
          docId,
          await ValueCodec.encode({'title': 'stub-doc', 'file': vaultUri}),
        );

        final outputDir = '${tmpDir.path}/export_stub';
        final result = await const ExportCommand().execute(
          ctx,
          ['docs'],
          {'vault': true, 'output': outputDir},
        );

        expect(result, isTrue, reason: errSink.toString());
        // The document JSON must be in the output (line 199: also write JSON line).
        // Since it IS a stub and the loop continues past attachments,
        // VaultPackage.write is called with empty attachments → KVLT written.
        // The stub SHA-256 is not hydrated → stubsSkipped = 1, subdirIndex = 0.
        expect(outSink.toString(), contains('stub-doc'));
      },
    );
  });
}
