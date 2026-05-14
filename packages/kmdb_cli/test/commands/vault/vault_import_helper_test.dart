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
import 'package:kmdb_cli/src/commands/vault/vault_import_helper.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

var _dbCounter = 0;

/// A [VaultStore] backed by [MemoryStorageAdapter] for tests.
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

/// Opens an in-memory [KmdbDatabase] with vault wired.
Future<(KmdbDatabase, _TestVaultStore)> _openWithVault() async {
  final dbPath = '/testdb_vault_helper_${_dbCounter++}';
  final adapter = MemoryStorageAdapter();
  final vault = _TestVaultStore(adapter, dbPath);
  final db = await KmdbDatabase.open(
    path: dbPath,
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
  return (db, vault);
}

/// Small bytes for vault ingestion tests.
final _kBytes = Uint8List.fromList(utf8.encode('hello vault'));

/// A valid KVLT package containing one attachment, built in-memory.
Uint8List _makePackage({Uint8List? bytes}) {
  final b = bytes ?? _kBytes;
  return VaultPackage.write(
    documentJson: {'_id': '01900000000070809000000000000001', 'x': 1},
    attachments: [
      VaultAttachment(subdirName: '0', bytes: b, uploadManifest: null),
    ],
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── readVaultPackage ───────────────────────────────────────────────────────

  group('readVaultPackage', () {
    test('parses a valid package from bytes', () {
      final packageBytes = _makePackage();
      final err = StringBuffer();
      final contents = readVaultPackage(
        packagePath: null,
        packageBytes: packageBytes,
        errSink: err,
      );

      expect(contents, isNotNull);
      expect(contents!.attachments, hasLength(1));
      expect(err.toString(), isEmpty);
    });

    test('returns null and writes error for invalid bytes', () {
      final err = StringBuffer();
      final contents = readVaultPackage(
        packagePath: null,
        packageBytes: Uint8List.fromList([0, 1, 2, 3]),
        errSink: err,
      );

      expect(contents, isNull);
      expect(err.toString(), contains('Invalid vault package'));
    });

    test('reads a package from a file path', () async {
      final tmpDir = io.Directory.systemTemp.createTempSync('kvlt_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final file = io.File('${tmpDir.path}/test.kvlt');
      await file.writeAsBytes(_makePackage());

      final err = StringBuffer();
      final contents = readVaultPackage(
        packagePath: file.path,
        packageBytes: null,
        errSink: err,
      );

      expect(contents, isNotNull);
      expect(err.toString(), isEmpty);
    });

    test('returns null and writes error for non-existent file path', () {
      final err = StringBuffer();
      final contents = readVaultPackage(
        packagePath: '/nonexistent/path/test.kvlt',
        packageBytes: null,
        errSink: err,
      );

      expect(contents, isNull);
      expect(err.toString(), contains('Cannot read package file'));
    });
  });

  // ── ingestVaultAttachments ─────────────────────────────────────────────────

  group('ingestVaultAttachments', () {
    test('ingests attachments and returns their sha256 hashes', () async {
      final (db, vault) = await _openWithVault();
      addTearDown(() => db.close());

      final attachment = VaultAttachment(
        subdirName: '0',
        bytes: _kBytes,
        uploadManifest: null,
      );
      final err = StringBuffer();
      final hashes = await ingestVaultAttachments(
        vaultStore: vault,
        attachments: [attachment],
        hlcTimestamp: '0000000000000001',
        errSink: err,
      );

      expect(hashes, isNotNull);
      expect(hashes!.length, equals(1));
      expect(hashes.first, isNotEmpty);
      expect(err.toString(), isEmpty);
    });

    test('returns null and writes error on CRC mismatch', () async {
      // Build a package with valid bytes, then tamper the attachment bytes
      // to cause a CRC mismatch on ingest.
      // We construct a VaultAttachment whose bytes differ from what was
      // "declared" by computing a CRC on one value but passing different bytes.
      // The simplest way is to use a _FakeCrcVaultStore that throws on ingest.
      // Since we can't easily subvert the CRC check from outside, we verify the
      // catch branch by directly using a store that throws VaultCrcMismatchException.
      //
      // VaultStore.ingest validates CRC internally, so we need to craft bytes
      // that will fail the CRC check — that means tampered bytes that don't
      // match the manifest CRC.
      //
      // Strategy: ingest a file to get a valid manifest, then pass different bytes
      // with the same manifest. We do this by calling ingestVaultAttachments with
      // an attachment where bytes differ from what the manifest declares.
      //
      // However, VaultAttachment with uploadManifest=null always creates a fresh
      // manifest from the provided bytes (no CRC mismatch possible that way).
      // A CRC mismatch requires providing a manifest whose CRC doesn't match the bytes.
      //
      // Use a _VaultStoreThrowsCrc that always throws VaultCrcMismatchException
      // on the first ingest call to test the catch branch directly.
      final (db, _) = await _openWithVault();
      addTearDown(() => db.close());
      final fakeVault = _ThrowingVaultStore();

      final attachment = VaultAttachment(
        subdirName: '0',
        bytes: _kBytes,
        uploadManifest: null,
      );
      final err = StringBuffer();
      final hashes = await ingestVaultAttachments(
        vaultStore: fakeVault,
        attachments: [attachment],
        hlcTimestamp: '0000000000000001',
        errSink: err,
      );

      expect(hashes, isNull);
      expect(err.toString(), isNotEmpty);
    });
  });

  // ── extractVaultUrisFromDoc ────────────────────────────────────────────────

  group('extractVaultUrisFromDoc', () {
    // Build a fake vault URI using a known SHA-256 so we can identify it.
    final sha256 = 'a' * 64;
    final vaultUri = 'kmdb-vault://sha256/$sha256';

    test('returns empty set for a plain document', () {
      final result = extractVaultUrisFromDoc({'title': 'hello', 'x': 1});
      expect(result, isEmpty);
    });

    test('finds a vault URI at the top level', () {
      final result = extractVaultUrisFromDoc({'file': vaultUri});
      expect(result, contains(sha256));
    });

    test('finds a vault URI nested in a map', () {
      final result = extractVaultUrisFromDoc({
        'attachment': {'url': vaultUri},
      });
      expect(result, contains(sha256));
    });

    test('finds vault URIs nested in a list', () {
      final result = extractVaultUrisFromDoc({
        'files': [vaultUri],
      });
      expect(result, contains(sha256));
    });

    test('deduplicates the same URI appearing multiple times', () {
      final result = extractVaultUrisFromDoc({'a': vaultUri, 'b': vaultUri});
      expect(result, hasLength(1));
      expect(result, contains(sha256));
    });

    test('finds multiple distinct vault URIs', () {
      final sha256b = 'b' * 64;
      final vaultUriB = 'kmdb-vault://sha256/$sha256b';
      final result = extractVaultUrisFromDoc({
        'file1': vaultUri,
        'file2': vaultUriB,
      });
      expect(result, containsAll([sha256, sha256b]));
    });
  });
}

// ── Fake VaultStore that always throws VaultCrcMismatchException ──────────────

class _ThrowingVaultStore extends VaultStore {
  _ThrowingVaultStore()
    : super(adapter: MemoryStorageAdapter(), dbDir: '/fake');

  @override
  Future<VaultRef> ingest({
    required Uint8List bytes,
    required String hlcTimestamp,
    String originalName = 'blob',
    String? explicitMediaType,
  }) {
    throw const VaultCrcMismatchException(
      sha256:
          'aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd',
      existingCrc32c: 'aaaaaaaa',
      incomingCrc32c: 'bbbbbbbb',
    );
  }

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async => [];
}
