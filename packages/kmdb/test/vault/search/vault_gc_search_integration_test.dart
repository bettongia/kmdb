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

/// Integration tests for [VaultGc] vault search index cleanup (WI-3 Step 11).
///
/// Verifies that when a vault blob is GC'd, all derived vault search KV entries
/// (`$$vault:fts:corpus:`, `$$vault:vec:idx:`, `$$vault:extract:`,
/// `$vault:docref:`) and the `extract/` filesystem subdirectory are removed.
///
/// ## Architecture note
///
/// `$vault` ref-count entries use SHA-256 hex strings (64 chars) as keys, which
/// are incompatible with the LSM engine's UUIDv7 key codec. In production the
/// ref-count writes go through the same `writeBatchInternal` path as vault
/// search entries, but the ref-count write is inside the same `WriteBatch` as
/// the document write — a known design constraint (see vault_integration_test.dart
/// "vault URI wiring" comment). Tests that need only ref-count reads (GC sweep)
/// can use a [_RefCountKvStore] test double that stores ref counts in-memory,
/// while a real [KvStoreImpl] is passed separately via [VaultGc.searchStore] to
/// exercise the vault search cleanup path.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/compaction/reclamation_policy.dart'
    show ReclamationPolicyRegistry;
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/search/vault_bm25_writer.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_recovery.dart'
    show kVaultNamespace, kVaultRefCountSentinelKey;
import 'package:kmdb/src/vault/vault_store.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// Always reports [Iterable.empty] media types — vault blob media type is not
/// relevant to GC integration tests.
final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => const [];
}

/// A [VaultStore] subclass that overrides [listFilesRecursive] to enumerate
/// files in the in-memory adapter's flat file map.
final class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(
        dbDir: _dbDir,
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _seqUuid,
      );

  final MemoryStorageAdapter _mem;

  static int _seq = 0;
  static String _seqUuid() => 'staging-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return [
      for (final path in _mem.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

/// An in-memory [KvStore] that stores `$vault:{sha256}` ref-count entries
/// under [kVaultRefCountSentinelKey] — the namespace-per-blob scheme
/// (matching production; see [kVaultRefCountSentinelKey]'s doc comment for
/// why the sha256 lives in the namespace, not the key).
///
/// Used as the [VaultGc.kvStore] so that ref-count reads work correctly in
/// tests. A separate real [KvStoreImpl] is passed as [VaultGc.searchStore] to
/// exercise vault search index cleanup.
///
/// All methods beyond [get] are no-ops — this store is read-only from GC's
/// perspective (GC only calls [get] for ref-count reads).
final class _RefCountKvStore implements KvStore {
  final Map<String, Map<String, Uint8List>> _data = {};

  static String _refNamespace(String sha256) => '$kVaultNamespace:$sha256';

  /// Seeds a `$vault:{sha256}` ref-count entry encoding `{refCount: count}`.
  void setRefCount(String sha256, int count) {
    final ns = _refNamespace(sha256);
    _data[ns] ??= {};
    // Match the ValueCodec.encode format used by VaultRefInterceptor:
    // [0x00 encryption flag][0x00 compression flag][CBOR map {refCount: N}].
    final keyBytes = utf8.encode('refCount');
    final builder = BytesBuilder();
    builder.addByte(0x00); // EncryptionFlag.none
    builder.addByte(0x00); // CompressionFlag.none
    builder.addByte(0xA1); // CBOR map, 1 pair
    builder.addByte(0x60 | keyBytes.length); // text(N)
    builder.add(keyBytes);
    if (count <= 23) {
      builder.addByte(count);
    } else if (count <= 255) {
      builder.addByte(0x18);
      builder.addByte(count);
    } else {
      builder.addByte(0x19);
      builder.addByte((count >> 8) & 0xFF);
      builder.addByte(count & 0xFF);
    }
    _data[ns]![kVaultRefCountSentinelKey] = builder.toBytes();
  }

  /// Removes the ref-count entry for [sha256] (simulates decrement to zero).
  void clearRefCount(String sha256) {
    _data[_refNamespace(sha256)]?.remove(kVaultRefCountSentinelKey);
  }

  @override
  Future<Uint8List?> get(String namespace, String key) async =>
      _data[namespace]?[key];

  @override
  Future<void> put(String namespace, String key, Uint8List value) async {}

  @override
  Future<void> delete(String namespace, String key) async {}

  @override
  Future<void> writeBatch(WriteBatch batch) async {}

  @override
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
  }) async* {}

  @override
  Future<void> close({bool flush = true}) async {}

  @override
  void setTombstoneHorizonProvider(Future<Hlc> Function()? provider) {}

  @override
  void setVersionDropCallback(
    Future<void> Function(List<Uint8List>)? callback,
  ) {}

  @override
  void setVersionRegistryProvider(
    Future<ReclamationPolicyRegistry> Function()? provider,
  ) {}

  @override
  Stream<VersionHistoryEntry> scanVersionHistory(
    String namespace,
    String docKey,
  ) async* {}

  @override
  Future<void> compactAll() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<StoreStats> stats() async => const StoreStats(
    dbDir: '/test',
    l0Count: 0,
    l1Count: 0,
    l2Count: 0,
    totalSstBytes: 0,
    totalDbBytes: 0,
  );

  @override
  Future<StoreInfo> storeInfo() async =>
      const StoreInfo(dbDir: '/test', deviceId: '00000000', currentHlc: '0');

  @override
  Future<void> reassignDeviceId(String newDeviceId) async {}

  @override
  Stream<String> get writeEvents => const Stream.empty();

  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) async {}

  @override
  Future<void> dropAllSstables() async {}

  @override
  Future<void> resetTombstoneFloor() async {}

  @override
  Future<List<String>> listNamespaces() async => [];

  @override
  Future<bool> createNamespace(String namespace) async => false;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const _dbDir = '/gc-search-test';
const _deviceId = 'gcsrch01';

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

Future<KvStoreImpl> _openStore(MemoryStorageAdapter adapter) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: _deviceId,
  );
  return store;
}

/// Seeds vault search KV entries for [sha256] as if a blob had been indexed:
///
/// - `$$vault:fts:corpus:{sha256}` — BM25 corpus sentinel (via VaultBm25Writer)
/// - `$$vault:fts:{sha256}:{hexTerm}` — per-chunk BM25 term entries
/// - `$$vault:extract:{sha256}` — extraction status sentinel
/// - `$vault:docref:{sha256}` / [docKey] — document-reference entry
///
/// All writes go through [store.writeBatchInternal] to bypass the public-API
/// system-namespace guard. These namespaces use proper UUIDv7-format keys
/// ([kVaultCorpusSentinelKey], [kVaultChunkKey]) so the LSM key codec accepts
/// them without error.
Future<void> _seedVaultSearchEntries(
  KvStoreImpl store, {
  required String sha256,
  required String docKey,
}) async {
  // ── BM25 index ($$vault:fts:corpus: and $$vault:fts:{sha256}: namespaces) ──
  final bm25Batch = WriteBatch();
  await const VaultBm25Writer().write(
    sha256: sha256,
    termFrequencies: [
      {'machin': 3, 'learn': 2},
    ],
    totalTokens: 5,
    batch: bm25Batch,
  );
  await store.writeBatchInternal(bm25Batch);

  // ── Extraction status sentinel ($$vault:extract:{sha256}) ─────────────────
  final extractBatch = WriteBatch()
    ..put(
      '$kVaultExtractPrefix$sha256',
      kVaultCorpusSentinelKey,
      _bytes('{"status":"indexed","chunkCount":1}'),
    );
  await store.writeBatchInternal(extractBatch);

  // ── Document reference ($vault:docref:{sha256} / docKey) ──────────────────
  // ValueCodec.encode mirrors what VaultRefInterceptor writes.
  // docKey is a 32-char UUIDv7 hex string — compatible with the LSM key codec.
  final fieldBytes = await ValueCodec.encode({'p': 'attachment'});
  final docRefBatch = WriteBatch()
    ..put('$kVaultDocRefPrefix$sha256', docKey, fieldBytes);
  await store.writeBatchInternal(docRefBatch);
}

/// Seeds the `extract/` filesystem directory with dummy artefacts to verify
/// that [VaultGc.sweep] deletes them.
///
/// Only the three artefacts that [VaultSearchManager] actually writes are
/// seeded (`text.txt`, `chunks_v1.json`) — there is no fourth
/// `extract_status.json` file; extraction status lives solely in the
/// `$$vault:extract:{sha256}` KV entry (see §32). [VaultGc.sweep] deletes the
/// whole `extract/` directory regardless of its contents, so the dummy
/// content here need not match the real flag-byte-prefixed wire format.
Future<void> _seedExtractDir(
  MemoryStorageAdapter adapter,
  VaultStore vaultStore, {
  required String sha256,
}) async {
  final extractDir = '${vaultStore.hashDir(sha256)}/extract';
  await adapter.writeFile(
    '$extractDir/text.txt',
    _bytes('machine learning is a field of AI'),
  );
  await adapter.writeFile(
    '$extractDir/chunks_v1.json',
    _bytes('[{"start":0,"end":33,"wordCount":7}]'),
  );
}

/// Returns true iff any key exists in [namespace] on [store].
Future<bool> _namespaceHasEntries(KvStoreImpl store, String namespace) async {
  await for (final _ in store.scan(namespace)) {
    return true;
  }
  return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // The doc key is a valid UUIDv7 hex string for the $vault:docref: namespace.
  const docKey = '01900000000070008000000000000001';

  group('VaultGc — vault search index cleanup (Step 11)', () {
    late MemoryStorageAdapter adapter;
    late _TestVaultStore vaultStore;
    late KvStoreImpl searchStore;
    late _RefCountKvStore refCountStore;
    late VaultGc gc;

    setUp(() async {
      _TestVaultStore._seq = 0;
      adapter = MemoryStorageAdapter();
      searchStore = await _openStore(adapter);
      vaultStore = _TestVaultStore(adapter);
      refCountStore = _RefCountKvStore();
      // Use the in-memory ref-count store for ref-count reads (sha256 keys).
      // Use the real KvStoreImpl (searchStore) for vault search entry cleanup.
      gc = VaultGc(
        store: vaultStore,
        kvStore: refCountStore,
        searchStore: searchStore,
      );
    });

    tearDown(() async => searchStore.close());

    test(
      'sweep deletes BM25 corpus + extract status + docref entries for GC\'d blob',
      () async {
        // Arrange: ingest a blob, seed vault search entries and ref count.
        final ref = await vaultStore.ingest(
          bytes: _bytes('machine learning document'),
          hlcTimestamp: 't1',
        );
        final sha256 = ref.sha256;

        refCountStore.setRefCount(sha256, 1);
        await _seedVaultSearchEntries(
          searchStore,
          sha256: sha256,
          docKey: docKey,
        );
        await _seedExtractDir(adapter, vaultStore, sha256: sha256);

        // Verify entries are present before GC.
        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultFtsCorpusPrefix$sha256',
          ),
          isTrue,
          reason: 'BM25 corpus sentinel must exist before GC',
        );
        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultExtractPrefix$sha256',
          ),
          isTrue,
          reason: 'Extract status sentinel must exist before GC',
        );
        expect(
          await _namespaceHasEntries(searchStore, '$kVaultDocRefPrefix$sha256'),
          isTrue,
          reason: 'Document reference entry must exist before GC',
        );
        expect(
          adapter.files.keys.where((p) => p.contains('/extract/')),
          isNotEmpty,
          reason: 'Extract directory files must exist before GC',
        );

        // Act: drop the ref count (simulate VaultRefInterceptor decrement)
        // and tombstone the blob, then run sweep().
        refCountStore.clearRefCount(sha256);
        await gc.onZeroRefs(sha256);
        final result = await gc.sweep();

        // Assert: GC deleted the blob.
        expect(result.deleted, equals(1));
        expect(result.examined, equals(1));
        expect(await vaultStore.exists(sha256), isFalse);

        // Assert: vault search KV entries are all gone.
        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultFtsCorpusPrefix$sha256',
          ),
          isFalse,
          reason: 'BM25 corpus sentinel must be deleted by GC',
        );

        // Assert: ALL per-term BM25 entries are also deleted (not just the
        // corpus sentinel). _seedVaultSearchEntries writes terms "machin" and
        // "learn"; each gets its own $$vault:fts:{sha256}:{hexTerm} namespace.
        final machinHex = VaultBm25Writer.termToHex('machin');
        final learnHex = VaultBm25Writer.termToHex('learn');
        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultFtsPrefix$sha256:$machinHex',
          ),
          isFalse,
          reason: 'Per-term "machin" BM25 entries must be deleted by GC',
        );
        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultFtsPrefix$sha256:$learnHex',
          ),
          isFalse,
          reason: 'Per-term "learn" BM25 entries must be deleted by GC',
        );

        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultExtractPrefix$sha256',
          ),
          isFalse,
          reason: 'Extract status sentinel must be deleted by GC',
        );
        expect(
          await _namespaceHasEntries(searchStore, '$kVaultDocRefPrefix$sha256'),
          isFalse,
          reason: 'Document reference entry must be deleted by GC',
        );

        // Assert: extract directory filesystem files are gone.
        expect(
          adapter.files.keys.where(
            (p) =>
                p.contains('/extract/') && p.contains(sha256.substring(0, 8)),
          ),
          isEmpty,
          reason:
              'extract/ directory files must be deleted by GC sweep for $sha256',
        );
      },
    );

    test(
      'sweep with no vault search entries is a no-op — blob dir deleted normally',
      () async {
        // A blob that was never indexed (no $$vault: or $vault:docref: entries).
        // GC must still delete the blob directory without errors.
        final ref = await vaultStore.ingest(
          bytes: _bytes('unindexed blob'),
          hlcTimestamp: 't2',
        );
        final sha256 = ref.sha256;

        refCountStore.clearRefCount(sha256);
        await gc.onZeroRefs(sha256);
        final result = await gc.sweep();

        expect(result.deleted, equals(1));
        expect(await vaultStore.exists(sha256), isFalse);
      },
    );

    test('sweep deletes vec index entries when present', () async {
      // Arrange: seed a per-chunk vector index entry ($$vault:vec:idx:{sha256}).
      final ref = await vaultStore.ingest(
        bytes: _bytes('vector document'),
        hlcTimestamp: 't3',
      );
      final sha256 = ref.sha256;

      refCountStore.setRefCount(sha256, 1);

      // Write a dummy vector index entry directly.
      final vecNs = '$kVaultVecIdxPrefix$sha256';
      final vecBatch = WriteBatch()
        ..put(
          vecNs,
          kVaultChunkKey(0),
          Uint8List.fromList([0x01, 0x02, 0x03]), // dummy SQ8 vector bytes
        );
      await searchStore.writeBatchInternal(vecBatch);

      expect(
        await _namespaceHasEntries(searchStore, vecNs),
        isTrue,
        reason: 'Vector index entry must exist before GC',
      );

      // Act: GC the blob.
      refCountStore.clearRefCount(sha256);
      await gc.onZeroRefs(sha256);
      final result = await gc.sweep();

      // Assert: vector index entry is gone.
      expect(result.deleted, equals(1));
      expect(
        await _namespaceHasEntries(searchStore, vecNs),
        isFalse,
        reason: 'Vector index entry must be deleted by GC sweep',
      );
    });

    test('sweep deletes extract/ directory alongside blob', () async {
      // Arrange: blob with a populated extract directory but no KV entries.
      final ref = await vaultStore.ingest(
        bytes: _bytes('extracted text blob'),
        hlcTimestamp: 't4',
      );
      final sha256 = ref.sha256;

      await _seedExtractDir(adapter, vaultStore, sha256: sha256);
      final extractPathPrefix = '${vaultStore.hashDir(sha256)}/extract/';
      expect(
        adapter.files.keys.where((p) => p.startsWith(extractPathPrefix)),
        isNotEmpty,
        reason: 'extract/ must have files before GC',
      );

      refCountStore.clearRefCount(sha256);
      await gc.onZeroRefs(sha256);
      await gc.sweep();

      // Assert: extract directory files are gone.
      expect(
        adapter.files.keys.where((p) => p.startsWith(extractPathPrefix)),
        isEmpty,
        reason: 'extract/ directory must be deleted by GC sweep',
      );
    });

    test(
      'sweep does not delete vault search entries for a re-referenced blob (TOCTOU guard)',
      () async {
        // A tombstone was created when ref=0, but before the sweep ran the blob
        // was re-referenced. The TOCTOU guard must skip deletion. The vault search
        // entries for this blob must remain intact.
        final ref = await vaultStore.ingest(
          bytes: _bytes('re-referenced blob'),
          hlcTimestamp: 't5',
        );
        final sha256 = ref.sha256;

        refCountStore.setRefCount(sha256, 1);
        await _seedVaultSearchEntries(
          searchStore,
          sha256: sha256,
          docKey: docKey,
        );

        // Tombstone when ref=0, then restore ref before sweep.
        refCountStore.clearRefCount(sha256);
        await gc.onZeroRefs(sha256);
        // Re-reference before sweep (new document pinned the blob).
        refCountStore.setRefCount(sha256, 1);

        final result = await gc.sweep();

        expect(result.deleted, equals(0));
        expect(result.skipped, equals(1));
        expect(await vaultStore.exists(sha256), isTrue);

        // Vault search KV entries must still be present.
        expect(
          await _namespaceHasEntries(
            searchStore,
            '$kVaultFtsCorpusPrefix$sha256',
          ),
          isTrue,
          reason:
              'BM25 corpus sentinel must NOT be deleted for re-referenced blob',
        );
      },
    );
  });
}
