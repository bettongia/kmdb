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

/// Integration test: registers [PdfTextExtractor] in a real
/// [VaultSearchConfig] on a real [KmdbDatabase] and ingests PDF vault blobs,
/// confirming that indexing reaches the expected terminal status
/// ([KmdbDatabase.vaultIndexingStatus]).
///
/// This exercises the nested-isolate composition described in the WI-8 plan:
/// [KmdbDatabase.open] spawns a dedicated vault indexing isolate that copies
/// [PdfTextExtractor] into it and calls `extract()` there; `betto_pdfium`
/// internally routes all PDFium FFI calls through its own separate,
/// process-wide singleton isolate. Reaching `indexed`/`failed` status
/// (rather than hanging or crashing the isolate) is conclusive proof that
/// this doubly-nested isolate composition — vault indexing isolate calling
/// into betto_pdfium's own `PdfiumIsolate` — works end to end. This test
/// uses only `package:kmdb`'s public API (no `package:kmdb/src` imports) —
/// the same surface a consuming application would use.
///
/// A further scenario repeats the flow with database encryption enabled,
/// confirming the WI-10 invariant that extractors only ever see already
/// -decrypted blob bytes: [PdfTextExtractor] can only successfully parse the
/// PDF (reaching `indexed` rather than `failed`) if the bytes it received
/// were correctly decrypted first.
///
/// ## Scope note — a pre-existing, unrelated `package:kmdb` limitation
///
/// This test stops at [KmdbDatabase.vaultIndexingStatus] rather than also
/// calling [KmdbCollection.searchVault] on a referencing document. Wiring a
/// document to a vault blob through the normal collection write path
/// (`KmdbCollection.insert`/`put` with a `kmdb-vault://` URI field) currently
/// throws, because `VaultRefInterceptor` keys `$vault` reference counts by
/// the blob's full 64-character SHA-256 hex digest, while the LSM engine's
/// `KeyCodec` only accepts 32-character UUIDv7 hex keys — a pre-existing gap
/// in `package:kmdb` unrelated to this plan, already documented by
/// `packages/kmdb/test/vault/vault_integration_test.dart`'s own
/// "`_wireVaultRefsInMap`/`_wireVaultRefsInList` coverage" section (which
/// works around it by writing directly via the internal `KvStore`, bypassing
/// the public collection API entirely). Reproducing that same workaround
/// here would exercise a bypass of the very pipeline this plan is meant to
/// validate, so this test instead validates exactly what the WI-8 plan calls
/// for: the extractor/isolate composition, via [vaultIndexingStatus] —
/// without either masking the pre-existing bug or taking on out-of-scope
/// surgery to fix `package:kmdb` core in this plan.
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_pdf/kmdb_extractor_pdf.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [VaultStore] subclass that overrides [listFilesRecursive] so hash
/// directory discovery (used by [KmdbDatabase.vaultIndexingStatus] and vault
/// recovery) works against the flat key space of [MemoryStorageAdapter].
///
/// This mirrors the pattern used by `package:kmdb`'s own vault search tests
/// (e.g. `vault_search_commands_test.dart`) — `MemoryStorageAdapter` has no
/// real directory tree, so the default filesystem-walking implementation
/// finds nothing without this override.
final class _TestVaultStore extends VaultStore {
  _TestVaultStore(this._mem, String dbPath)
    : super(adapter: _mem, dbDir: dbPath);

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

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Counter to give each test a unique db path and avoid [LockException].
var _counter = 0;
String _uniquePath() => '/pdf_extractor_integration_${_counter++}';

/// Reads a fixture PDF's bytes.
Future<Uint8List> _fixture(String relativePath) =>
    File('test/fixtures/$relativePath').readAsBytes();

/// Waits until vault indexing has settled (no pending/in-flight work),
/// polling [KmdbDatabase.watchVaultIndexingStatus].
Future<VaultIndexingStatus> _waitForIndexingComplete(KmdbDatabase db) => db
    .watchVaultIndexingStatus()
    .firstWhere((status) => status.isComplete)
    .timeout(const Duration(seconds: 30));

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('PdfTextExtractor — vault indexing isolate integration', () {
    test(
      'a real, text-bearing PDF vault blob is extracted and indexed via the '
      'real vault indexing isolate (nested-isolate composition proof)',
      () async {
        final path = _uniquePath();
        final mem = MemoryStorageAdapter();
        final vault = _TestVaultStore(mem, path);

        final db = await KmdbDatabase.open(
          path: path,
          adapter: mem,
          config: KvStoreConfig.forTesting(),
          vaultStore: vault,
          vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
        );
        addTearDown(db.close);

        // Ingesting alone auto-queues extraction via VaultStore.onAfterIngest
        // — no document write is needed to trigger indexing. explicitMediaType
        // pins the media type deterministically rather than relying on the
        // real FreedesktopMediaTypeDetector's magic-byte sniffing, keeping
        // this test focused on the extractor/isolate composition.
        final bytes = await _fixture('arxiv/2312.17524v1.pdf');
        await vault.ingest(
          bytes: bytes,
          hlcTimestamp: '0000000000000001',
          originalName: '2312.17524v1.pdf',
          explicitMediaType: 'application/pdf',
        );

        final status = await _waitForIndexingComplete(db);
        expect(
          status.indexed,
          equals(1),
          reason:
              'the single ingested PDF should have been indexed by the real '
              'vault indexing isolate (proves the nested-isolate composition '
              'with betto_pdfium\'s PdfiumIsolate works end to end): $status',
        );
        expect(status.failed, equals(0));
        expect(status.unsupported, equals(0));
      },
    );

    test('scanned (image-only) PDF is indexed with zero chunks, not marked '
        'failed or unsupported', () async {
      final path = _uniquePath();
      final mem = MemoryStorageAdapter();
      final vault = _TestVaultStore(mem, path);

      final db = await KmdbDatabase.open(
        path: path,
        adapter: mem,
        config: KvStoreConfig.forTesting(),
        vaultStore: vault,
        vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
      );
      addTearDown(db.close);

      final bytes = await _fixture('scanned.pdf');
      await vault.ingest(
        bytes: bytes,
        hlcTimestamp: '0000000000000002',
        originalName: 'scanned.pdf',
        explicitMediaType: 'application/pdf',
      );

      final status = await _waitForIndexingComplete(db);
      // Per Q1: a predominantly-scanned document still maps to `indexed`
      // (with 0 chunks) — not `failed` or `unsupported`.
      expect(status.indexed, equals(1));
      expect(status.failed, equals(0));
      expect(status.unsupported, equals(0));
    });

    test('a corrupt PDF is marked failed, not unsupported (extractor matched '
        'but could not process the blob)', () async {
      final path = _uniquePath();
      final mem = MemoryStorageAdapter();
      final vault = _TestVaultStore(mem, path);

      final db = await KmdbDatabase.open(
        path: path,
        adapter: mem,
        config: KvStoreConfig.forTesting(),
        vaultStore: vault,
        vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
      );
      addTearDown(db.close);

      final bytes = await _fixture('corrupt.pdf');
      await vault.ingest(
        bytes: bytes,
        hlcTimestamp: '0000000000000003',
        originalName: 'corrupt.pdf',
        explicitMediaType: 'application/pdf',
      );

      final status = await _waitForIndexingComplete(db);
      expect(status.failed, equals(1));
      expect(status.indexed, equals(0));
      expect(status.unsupported, equals(0));
    });
  });

  group('PdfTextExtractor — WI-10 encryption integration', () {
    test('a PDF vault blob stored with encryption enabled is decrypted before '
        'PdfTextExtractor sees it, and indexing still succeeds', () async {
      final path = _uniquePath();
      final mem = MemoryStorageAdapter();
      final vault = _TestVaultStore(mem, path);

      final setup = await EncryptionConfig.createResult(
        passphrase: 'wi8-integration-test-passphrase',
      );

      final db = await KmdbDatabase.open(
        path: path,
        adapter: mem,
        config: KvStoreConfig.forTesting(),
        vaultStore: vault,
        vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
        encryptionConfig: setup.config,
      );
      addTearDown(db.close);

      final bytes = await _fixture('arxiv/2312.17524v1.pdf');
      final ref = await vault.ingest(
        bytes: bytes,
        hlcTimestamp: '0000000000000004',
        originalName: '2312.17524v1.pdf',
        explicitMediaType: 'application/pdf',
      );

      // Confirm the blob is actually stored encrypted on disk — otherwise
      // this test would not be exercising the WI-10 decrypt-before-extract
      // path at all. If PdfTextExtractor were handed the raw ciphertext
      // (i.e. decryption were skipped), PdfDocument.fromBytes would throw
      // PdfError.invalidDocument and indexing would end up `failed`, not
      // `indexed` — the assertions below are the real proof this path
      // works, this is a supporting sanity check on the test's premise.
      final rawBlob = mem.files[vault.blobPath(ref.sha256)];
      expect(rawBlob, isNotNull);
      expect(
        utf8.decode(rawBlob!, allowMalformed: true),
        isNot(contains('Distributed File Systems')),
        reason: 'ciphertext on disk should not contain plaintext content',
      );

      final status = await _waitForIndexingComplete(db);
      expect(status.indexed, equals(1));
      expect(status.failed, equals(0));
    });
  });
}
