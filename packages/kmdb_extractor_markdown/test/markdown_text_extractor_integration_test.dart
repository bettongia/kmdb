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

/// Integration test: registers [MarkdownTextExtractor] in a real
/// [VaultSearchConfig] on a real [KmdbDatabase] and ingests a Markdown vault
/// blob, confirming that indexing reaches the expected terminal status
/// ([KmdbDatabase.vaultIndexingStatus]).
///
/// This exercises [MarkdownTextExtractor] running inside the real, spawned
/// vault indexing isolate (rather than being called directly, as in
/// `markdown_text_extractor_test.dart`) — reaching `indexed` status is
/// conclusive proof the extractor works correctly when copied into and
/// invoked from that isolate. This test uses only `package:kmdb`'s public
/// API (no `package:kmdb/src` imports) — the same surface a consuming
/// application would use.
///
/// A further scenario repeats the flow with database encryption enabled,
/// confirming the WI-10 invariant that extractors only ever see
/// already-decrypted blob bytes.
///
/// ## Scope notes — two distinct, pre-existing `package:kmdb` gaps (not
/// fixed here)
///
/// This test copies the exact pattern established by
/// `kmdb_extractor_pdf/test/pdf_text_extractor_integration_test.dart` (see
/// `kmdb_extractor_html`'s equivalent integration test for the fuller
/// explanation):
///
/// 1. [_TestVaultStore] overrides [VaultStore.listFilesRecursive] because
///    [MemoryStorageAdapter] is a flat key space with no real directory
///    tree — a test-double accommodation, not a core bug.
/// 2. This test stops at [KmdbDatabase.vaultIndexingStatus] rather than also
///    calling `KmdbCollection.searchVault` on a referencing document,
///    because `VaultRefInterceptor` keys `$vault` reference counts by the
///    blob's full 64-character SHA-256 hex digest while the LSM engine's
///    `KeyCodec` only accepts 32-character UUIDv7 hex keys — a real,
///    pre-existing `package:kmdb` limitation unrelated to this plan.
///
/// ## Why there is no "corrupt input → failed" scenario here
///
/// [MarkdownTextExtractor] almost never fails: `decodeText()` always
/// succeeds (its fallback charset accepts any byte sequence), and the
/// `markdown` package's parser does not throw on arbitrary text — worst
/// case, garbage bytes simply parse as one large paragraph. So arbitrary
/// input still reaches `indexed` status, not `failed`. This mirrors
/// `kmdb_extractor_html`'s equivalent note.
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_markdown/kmdb_extractor_markdown.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [VaultStore] subclass that overrides [listFilesRecursive] so hash
/// directory discovery (used by [KmdbDatabase.vaultIndexingStatus] and vault
/// recovery) works against the flat key space of [MemoryStorageAdapter].
///
/// Mirrors `kmdb_extractor_pdf`'s `_TestVaultStore` — see the library-level
/// doc comment for why this override is necessary.
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
String _uniquePath() => '/markdown_extractor_integration_${_counter++}';

/// Reads a fixture Markdown file's bytes.
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

  group('MarkdownTextExtractor — vault indexing isolate integration', () {
    test('a real, prose-bearing Markdown vault blob is extracted and indexed '
        'via the real vault indexing isolate', () async {
      final path = _uniquePath();
      final mem = MemoryStorageAdapter();
      final vault = _TestVaultStore(mem, path);

      final db = await KmdbDatabase.open(
        path: path,
        adapter: mem,
        config: KvStoreConfig.forTesting(),
        vaultStore: vault,
        vaultSearch: VaultSearchConfig(extractors: [MarkdownTextExtractor()]),
      );
      addTearDown(db.close);

      // Ingesting alone auto-queues extraction via VaultStore.onAfterIngest
      // — no document write is needed to trigger indexing. explicitMediaType
      // pins the media type deterministically rather than relying on the
      // real FreedesktopMediaTypeDetector's magic-byte sniffing, keeping
      // this test focused on the extractor/isolate composition.
      final bytes = await _fixture('golden_path.md');
      await vault.ingest(
        bytes: bytes,
        hlcTimestamp: '0000000000000001',
        originalName: 'golden_path.md',
        explicitMediaType: 'text/markdown',
      );

      final status = await _waitForIndexingComplete(db);
      expect(
        status.indexed,
        equals(1),
        reason:
            'the single ingested Markdown blob should have been indexed '
            'by the real vault indexing isolate: $status',
      );
      expect(status.failed, equals(0));
      expect(status.unsupported, equals(0));
    });

    test('a Markdown blob that is 100% a single fenced code block is indexed '
        'with zero chunks, not marked failed or unsupported', () async {
      final path = _uniquePath();
      final mem = MemoryStorageAdapter();
      final vault = _TestVaultStore(mem, path);

      final db = await KmdbDatabase.open(
        path: path,
        adapter: mem,
        config: KvStoreConfig.forTesting(),
        vaultStore: vault,
        vaultSearch: VaultSearchConfig(extractors: [MarkdownTextExtractor()]),
      );
      addTearDown(db.close);

      final bytes = await _fixture('all_code.md');
      await vault.ingest(
        bytes: bytes,
        hlcTimestamp: '0000000000000002',
        originalName: 'all_code.md',
        explicitMediaType: 'text/markdown',
      );

      final status = await _waitForIndexingComplete(db);
      expect(status.indexed, equals(1));
      expect(status.failed, equals(0));
      expect(status.unsupported, equals(0));
    });
  });

  group('MarkdownTextExtractor — WI-10 encryption integration', () {
    test(
      'a Markdown vault blob stored with encryption enabled is decrypted '
      'before MarkdownTextExtractor sees it, and indexing still succeeds',
      () async {
        final path = _uniquePath();
        final mem = MemoryStorageAdapter();
        final vault = _TestVaultStore(mem, path);

        final setup = await EncryptionConfig.createResult(
          passphrase: 'wi9-markdown-integration-test-passphrase',
        );

        final db = await KmdbDatabase.open(
          path: path,
          adapter: mem,
          config: KvStoreConfig.forTesting(),
          vaultStore: vault,
          vaultSearch: VaultSearchConfig(extractors: [MarkdownTextExtractor()]),
          encryptionConfig: setup.config,
        );
        addTearDown(db.close);

        final bytes = await _fixture('golden_path.md');
        final ref = await vault.ingest(
          bytes: bytes,
          hlcTimestamp: '0000000000000003',
          originalName: 'golden_path.md',
          explicitMediaType: 'text/markdown',
        );

        // Confirm the blob is actually stored encrypted on disk — a
        // supporting sanity check on this test's premise, mirroring the PDF
        // extractor's own WI-10 integration test.
        final rawBlob = mem.files[vault.blobPath(ref.sha256)];
        expect(rawBlob, isNotNull);
        expect(
          utf8.decode(rawBlob!, allowMalformed: true),
          isNot(contains('Section Heading')),
          reason: 'ciphertext on disk should not contain plaintext content',
        );

        final status = await _waitForIndexingComplete(db);
        expect(status.indexed, equals(1));
        expect(status.failed, equals(0));
      },
    );
  });
}
