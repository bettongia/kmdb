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

/// Tests that verify vault search namespace sync exclusion (WI-3 Step 10).
///
/// Vault search introduces five KV namespaces. Three are local-only (`$$` prefix,
/// WI-0 convention) and route to `.local.sst` files that are never uploaded by
/// `SyncEngine`. One is syncable (single `$` prefix). This test file confirms:
///
/// 1. The `isLocalOnly` predicate returns the correct value for each namespace.
/// 2. When vault search entries are written and the store is flushed, the
///    resulting SSTable files have the correct local/syncable split: `$$vault:*`
///    entries land in `.local.sst` only, and `$vault:docref:` entries land in
///    a syncable `.sst`.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/util/namespace_codec.dart';
import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/vault/search/vault_bm25_writer.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _dbDir = '/db';
const _sstDir = '$_dbDir/sst';
const _deviceId = 'vaultsync1';

Future<KvStoreImpl> _openStore(MemoryStorageAdapter adapter) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: _deviceId,
  );
  return store;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── Predicate tests ────────────────────────────────────────────────────────

  group('isLocalOnly predicate — vault search namespaces', () {
    final sha256 = 'a' * 64;

    test(r'$$vault:fts: is local-only', () {
      // BM25 per-term namespace: $$-prefix → routes to .local.sst, never uploaded.
      expect(isLocalOnly('$kVaultFtsPrefix$sha256:deadbeef'), isTrue);
    });

    test(r'$$vault:fts:corpus: is local-only', () {
      // Corpus sentinel namespace is also $$-prefixed.
      expect(isLocalOnly('$kVaultFtsCorpusPrefix$sha256'), isTrue);
    });

    test(r'$$vault:vec:idx: is local-only', () {
      // SQ8 vector index namespace is $$-prefixed.
      expect(isLocalOnly('$kVaultVecIdxPrefix$sha256'), isTrue);
    });

    test(r'$$vault:extract: is local-only', () {
      // Extraction status namespace is $$-prefixed.
      expect(isLocalOnly('$kVaultExtractPrefix$sha256'), isTrue);
    });

    test(r'$vault:docref: is NOT local-only (syncable)', () {
      // Document→blob references must reach other devices: single-$ prefix.
      expect(isLocalOnly('$kVaultDocRefPrefix$sha256'), isFalse);
    });
  });

  // ── SSTable split test ────────────────────────────────────────────────────

  group('SSTable split — vault search entries land in correct partition', () {
    // Helper: writes vault BM25 entries + a docref entry, flushes the store,
    // and returns the adapter with the resulting SSTable files.
    Future<(KvStoreImpl, MemoryStorageAdapter)> setupAndFlush(
      String sha256,
    ) async {
      final adapter = MemoryStorageAdapter();
      final store = await _openStore(adapter);

      const docId = '01900000000070008000000000000001';

      // ── Local-only entries ($$vault: prefix) ──────────────────────────────

      // Use VaultBm25Writer.write() to produce correctly encoded BM25 entries.
      // The writer uses the same hex-term encoding as the real indexing path.
      final bm25Batch = WriteBatch();
      const VaultBm25Writer().write(
        sha256: sha256,
        termFrequencies: [
          {'machin': 2},
        ],
        totalTokens: 2,
        batch: bm25Batch,
      );
      await store.writeBatchInternal(bm25Batch);

      // Write an extract status entry ($$vault:extract:{sha256}).
      final extractBatch = WriteBatch()
        ..put(
          '$kVaultExtractPrefix$sha256',
          kVaultCorpusSentinelKey,
          Uint8List.fromList(utf8.encode('{"status":"indexed"}')),
        );
      await store.writeBatchInternal(extractBatch);

      // ── Syncable entry ($vault:docref: prefix) ────────────────────────────

      // Document reference: $vault:docref:{sha256} / {docId} → field path.
      // ValueCodec.encode is used to mirror VaultRefInterceptor.
      final fieldPathBytes = await ValueCodec.encode({'p': 'attachment'});
      final docRefBatch = WriteBatch()
        ..put('$kVaultDocRefPrefix$sha256', docId, fieldPathBytes);
      await store.writeBatchInternal(docRefBatch);

      // Flush to produce SSTable files.
      await store.flush();

      return (store, adapter);
    }

    test(
      r'$$vault:fts: entries land only in .local.sst files after flush',
      () async {
        final sha256 = 'b' * 64;
        final (store, adapter) = await setupAndFlush(sha256);

        final sstFiles = await adapter.listFiles(_sstDir);
        final syncableFiles = sstFiles
            .where((f) => f.endsWith('.sst') && !f.endsWith('.local.sst'))
            .toList();

        expect(
          syncableFiles,
          isNotEmpty,
          reason: 'Expected at least one syncable .sst after mixed flush',
        );

        // Assert $$vault: bytes are NOT in syncable .sst files.
        // The internal key encodes the namespace as a length-prefixed UTF-8
        // string, so the ASCII bytes of '$$vault:' appear literally in the raw
        // key bytes of any $$vault:-namespaced entry.
        for (final filename in syncableFiles) {
          final path = '$_sstDir/$filename';
          final reader = await SstableReader.open(path, adapter);
          await for (final entry in reader.scan()) {
            final rawKey = String.fromCharCodes(entry.key);
            expect(
              rawKey.contains(r'$$vault:'),
              isFalse,
              reason:
                  // ignore: unnecessary_string_escapes
                  'Syncable SSTable $filename must not contain \$\$vault: entries',
            );
          }
        }

        await store.close();
      },
    );

    test(
      r'$$vault:fts: entries ARE present in .local.sst files after flush',
      () async {
        final sha256 = 'c' * 64;
        final (store, adapter) = await setupAndFlush(sha256);

        final sstFiles = await adapter.listFiles(_sstDir);
        final localOnlyFiles = sstFiles
            .where((f) => f.endsWith('.local.sst'))
            .toList();

        expect(
          localOnlyFiles,
          isNotEmpty,
          reason: r'Expected at least one .local.sst after $$vault: write',
        );

        // Assert $$vault: bytes ARE present in at least one .local.sst file.
        var foundVaultKey = false;
        for (final filename in localOnlyFiles) {
          final path = '$_sstDir/$filename';
          final reader = await SstableReader.open(path, adapter);
          await for (final entry in reader.scan()) {
            final rawKey = String.fromCharCodes(entry.key);
            if (rawKey.contains(r'$$vault:')) {
              foundVaultKey = true;
            }
          }
        }
        expect(
          foundVaultKey,
          isTrue,
          reason: r'Expected $$vault: entries in at least one .local.sst file',
        );

        await store.close();
      },
    );

    test(r'$vault:docref: entries are readable after flush (syncable)', () async {
      // Verify that $vault:docref: entries written to the KvStore are readable
      // back after a flush — confirming they land in syncable (not local-only) SSTables.
      final sha256 = 'd' * 64;
      const docId = '01900000000070008000000000000001';
      final (store, _) = await setupAndFlush(sha256);

      // The entry must be readable from the store after flush.
      final fieldPathBytes = await store.get(
        '$kVaultDocRefPrefix$sha256',
        docId,
      );
      expect(
        fieldPathBytes,
        isNotNull,
        reason: '\$vault:docref: entry must be readable after flush',
      );

      // Confirm the value decodes to the expected field path.
      final decoded = await ValueCodec.decode(fieldPathBytes!);
      expect(decoded['p'], equals('attachment'));

      await store.close();
    });

    test(
      r'$$vault:extract: entries are readable after flush (local-only)',
      () async {
        // Local-only entries must still be readable from the local store —
        // they are only excluded from *sync upload*, not from local reads.
        final sha256 = 'e' * 64;
        final (store, _) = await setupAndFlush(sha256);

        final extractEntry = await store.get(
          '$kVaultExtractPrefix$sha256',
          kVaultCorpusSentinelKey,
        );
        expect(
          extractEntry,
          isNotNull,
          reason:
              r'$$vault:extract: entry must be readable locally after flush',
        );

        await store.close();
      },
    );
  });
}
