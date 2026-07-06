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

/// Tests for the `$vault:docref:` index maintained by [VaultRefInterceptor].
///
/// These tests focus on the docref extension (RQ-4) rather than ref-count
/// mechanics (which are covered in `vault_write_interception_test.dart`).
library;

import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/compaction/reclamation_policy.dart'
    show ReclamationPolicyRegistry;
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_recovery.dart'
    show kVaultNamespace, kVaultRefCountSentinelKey;
import 'package:kmdb/src/vault/vault_ref_interceptor.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : super(
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _counter,
        dbDir: '/db',
      );

  static int _seq = 0;
  static String _counter() => 'uuid-${_seq++}';
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

/// A minimal in-memory KvStore that applies WriteBatch writes and supports
/// reading individual entries.
final class _MemKvStore implements KvStore {
  final Map<String, Map<String, Uint8List>> _data = {};

  @override
  Future<Uint8List?> get(String ns, String key) async => _data[ns]?[key];

  @override
  Future<void> put(String ns, String key, Uint8List v) async {
    _data[ns] ??= {};
    _data[ns]![key] = v;
  }

  @override
  Future<void> delete(String ns, String key) async {
    _data[ns]?.remove(key);
  }

  @override
  Future<void> writeBatch(WriteBatch batch) async {
    for (final e in batch.entries) {
      final v = e.value;
      if (v != null) {
        _data[e.namespace] ??= {};
        _data[e.namespace]![e.key] = v;
      } else {
        _data[e.namespace]?.remove(e.key);
      }
    }
  }

  @override
  Stream<KvEntry> scan(String ns, {String? startKey, String? endKey}) async* {}

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
  Future<void> reassignDeviceId(String id) async {}

  @override
  Stream<String> get writeEvents => const Stream.empty();

  @override
  Future<void> ingestSstable(String f, Uint8List b) async {}

  @override
  Future<void> dropAllSstables() async {}

  @override
  Future<void> resetTombstoneFloor() async {}

  @override
  Future<List<String>> listNamespaces() async => [];

  @override
  Future<bool> createNamespace(String ns) async => false;

  // ── Docref helpers ──────────────────────────────────────────────────────────

  /// Reads the field-path value from `$vault:docref:{sha256}` / `{docId}`.
  ///
  /// The field path is stored as `{"p": fieldPath}` via [ValueCodec].
  Future<String?> readDocRef(String sha256, String docId) async {
    final bytes = _data['$kVaultDocRefPrefix$sha256']?[docId];
    if (bytes == null) return null;
    final decoded = await ValueCodec.decode(bytes);
    return decoded['p'] as String?;
  }

  /// Returns `true` if no docref entry exists for [sha256] / [docId].
  Future<bool> hasNoDocRef(String sha256, String docId) async =>
      await readDocRef(sha256, docId) == null;

  /// Reads the ref count from `$vault:{sha256}`.
  Future<int> readRefCount(String sha256) async {
    final bytes = _data['$kVaultNamespace:$sha256']?[kVaultRefCountSentinelKey];
    if (bytes == null) return 0;
    final decoded = await ValueCodec.decode(bytes);
    final v = decoded['refCount'];
    return v is int ? v : 0;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

const _docId = 'aaaa0000000000000000000000000000'; // 32-char hex docKey

void main() {
  late MemoryStorageAdapter adapter;
  late _TestVaultStore vaultStore;
  late _MemKvStore kvStore;
  late VaultGc gc;
  late VaultRefInterceptor interceptor;

  setUp(() {
    _TestVaultStore._seq = 0;
    adapter = MemoryStorageAdapter();
    vaultStore = _TestVaultStore(adapter);
    kvStore = _MemKvStore();
    gc = VaultGc(store: vaultStore, kvStore: kvStore);
    interceptor = VaultRefInterceptor(kvStore: kvStore, gc: gc);
  });

  group('VaultRefInterceptor — docref index (RQ-4)', () {
    // ── Insert: new doc with VaultRef ───────────────────────────────────────

    test('insert doc with VaultRef → docref entry written', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('hello'),
        hlcTimestamp: 't1',
      );
      final batch = WriteBatch();
      await interceptor.interceptWrite(
        batch: batch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {'attachment': ref.uri},
      );
      await kvStore.writeBatch(batch);

      final fieldPath = await kvStore.readDocRef(ref.sha256, _docId);
      expect(fieldPath, equals('attachment'));
    });

    test(
      'insert doc with nested VaultRef → correct dot-path recorded',
      () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('nested'),
          hlcTimestamp: 't1',
        );
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: 'test',
          docKey: _docId,
          oldDoc: null,
          newDoc: {
            'doc': {'file': ref.uri},
          },
        );
        await kvStore.writeBatch(batch);

        final fieldPath = await kvStore.readDocRef(ref.sha256, _docId);
        expect(fieldPath, equals('doc.file'));
      },
    );

    test('insert doc with VaultRef in list → array path recorded', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('list item'),
        hlcTimestamp: 't1',
      );
      final batch = WriteBatch();
      await interceptor.interceptWrite(
        batch: batch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {
          'attachments': [ref.uri],
        },
      );
      await kvStore.writeBatch(batch);

      final fieldPath = await kvStore.readDocRef(ref.sha256, _docId);
      expect(fieldPath, equals('attachments[0]'));
    });

    // ── Insert: no VaultRef ─────────────────────────────────────────────────

    test('insert doc without VaultRef → no docref entry written', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('hello'),
        hlcTimestamp: 't1',
      );
      final batch = WriteBatch();
      await interceptor.interceptWrite(
        batch: batch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {'title': 'plain text, no ref'},
      );
      await kvStore.writeBatch(batch);

      expect(await kvStore.hasNoDocRef(ref.sha256, _docId), isTrue);
    });

    // ── Update: old ref removed, new ref added ──────────────────────────────

    test(
      'update: old ref removed, new added → old docref deleted, new written',
      () async {
        final refA = await vaultStore.ingest(
          bytes: _bytes('blob a'),
          hlcTimestamp: 't1',
        );
        final refB = await vaultStore.ingest(
          bytes: _bytes('blob b'),
          hlcTimestamp: 't2',
        );

        // Initial insert with refA.
        final insertBatch = WriteBatch();
        await interceptor.interceptWrite(
          batch: insertBatch,
          namespace: 'test',
          docKey: _docId,
          oldDoc: null,
          newDoc: {'file': refA.uri},
        );
        await kvStore.writeBatch(insertBatch);

        // Update: swap refA → refB.
        final updateBatch = WriteBatch();
        await interceptor.interceptWrite(
          batch: updateBatch,
          namespace: 'test',
          docKey: _docId,
          oldDoc: {'file': refA.uri},
          newDoc: {'file': refB.uri},
        );
        await kvStore.writeBatch(updateBatch);

        // refA docref should be gone; refB docref should be present.
        expect(await kvStore.hasNoDocRef(refA.sha256, _docId), isTrue);
        final newPath = await kvStore.readDocRef(refB.sha256, _docId);
        expect(newPath, equals('file'));
      },
    );

    // ── Delete: doc deleted → docref removed ───────────────────────────────

    test('delete doc → docref entry deleted', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('blob'),
        hlcTimestamp: 't1',
      );

      // Insert.
      final insertBatch = WriteBatch();
      await interceptor.interceptWrite(
        batch: insertBatch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {'attachment': ref.uri},
      );
      await kvStore.writeBatch(insertBatch);

      // Delete.
      final deleteBatch = WriteBatch();
      await interceptor.interceptWrite(
        batch: deleteBatch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: {'attachment': ref.uri},
        newDoc: null,
      );
      await kvStore.writeBatch(deleteBatch);

      expect(await kvStore.hasNoDocRef(ref.sha256, _docId), isTrue);
    });

    // ── Two different VaultRef fields in same doc ───────────────────────────

    test(
      'doc with two different VaultRef fields → both sha256 entries written',
      () async {
        final refA = await vaultStore.ingest(
          bytes: _bytes('blob a'),
          hlcTimestamp: 't1',
        );
        final refB = await vaultStore.ingest(
          bytes: _bytes('blob b'),
          hlcTimestamp: 't2',
        );

        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: 'test',
          docKey: _docId,
          oldDoc: null,
          newDoc: {'photo': refA.uri, 'document': refB.uri},
        );
        await kvStore.writeBatch(batch);

        final pathA = await kvStore.readDocRef(refA.sha256, _docId);
        final pathB = await kvStore.readDocRef(refB.sha256, _docId);
        expect(pathA, equals('photo'));
        expect(pathB, equals('document'));
      },
    );

    // ── Same sha256 in two fields: first-field-path-wins ───────────────────

    test('same sha256 in two fields → first field path wins', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('shared blob'),
        hlcTimestamp: 't1',
      );

      final batch = WriteBatch();
      await interceptor.interceptWrite(
        batch: batch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {'first': ref.uri, 'second': ref.uri},
      );
      await kvStore.writeBatch(batch);

      // Both URIs have the same sha256, so only one docref entry is written.
      // The path should be 'first' (first encountered in DFS order).
      final path = await kvStore.readDocRef(ref.sha256, _docId);
      expect(path, equals('first'));
    });

    // ── Unchanged sha256 in update → not touched ───────────────────────────

    test('unchanged sha256 during update → docref not modified', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('stable blob'),
        hlcTimestamp: 't1',
      );

      // Insert.
      final insertBatch = WriteBatch();
      await interceptor.interceptWrite(
        batch: insertBatch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {'file': ref.uri},
      );
      await kvStore.writeBatch(insertBatch);

      // Update that changes other fields but not the vault ref.
      final updateBatch = WriteBatch();
      await interceptor.interceptWrite(
        batch: updateBatch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: {'file': ref.uri, 'title': 'old'},
        newDoc: {'file': ref.uri, 'title': 'new'},
      );
      await kvStore.writeBatch(updateBatch);

      // Docref should still be present and unchanged.
      final path = await kvStore.readDocRef(ref.sha256, _docId);
      expect(path, equals('file'));
    });

    // ── Ref count and docref are written in the same batch ─────────────────

    test('ref count and docref are in same WriteBatch (atomic)', () async {
      final ref = await vaultStore.ingest(
        bytes: _bytes('blob'),
        hlcTimestamp: 't1',
      );

      final batch = WriteBatch();
      await interceptor.interceptWrite(
        batch: batch,
        namespace: 'test',
        docKey: _docId,
        oldDoc: null,
        newDoc: {'file': ref.uri},
      );

      // Before committing the batch, both ref count and docref entries should
      // be present in the batch (not yet in the store).
      final docrefNs = '$kVaultDocRefPrefix${ref.sha256}';
      final refCountEntry = batch.entries.any(
        (e) =>
            e.namespace == '$kVaultNamespace:${ref.sha256}' &&
            e.key == kVaultRefCountSentinelKey,
      );
      final docrefEntry = batch.entries.any(
        (e) => e.namespace == docrefNs && e.key == _docId,
      );
      expect(refCountEntry, isTrue, reason: 'ref count entry in batch');
      expect(docrefEntry, isTrue, reason: 'docref entry in batch');
    });
  });
}
