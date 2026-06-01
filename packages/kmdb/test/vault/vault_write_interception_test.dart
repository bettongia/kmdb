// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/compaction/reclamation_policy.dart'
    show ReclamationPolicyRegistry;
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_recovery.dart' show kVaultNamespace;
import 'package:kmdb/src/vault/vault_ref_interceptor.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _counter,
        dbDir: '/db',
      );

  final MemoryStorageAdapter _mem;
  static int _seq = 0;
  static String _counter() => 'uuid-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return _mem.files.keys
        .where((p) => p.startsWith(prefix))
        .map((p) => p.substring(prefix.length))
        .toList();
  }
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

/// A simple in-memory [KvStore] for interceptor tests.
///
/// Stores ref count entries using [ValueCodec] so [VaultRefInterceptor] can
/// read them back correctly.
class _TrackingKvStore implements KvStore {
  final Map<String, Map<String, Uint8List>> _data = {};
  final List<(String, String, Uint8List?)> writes = [];

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

  /// Reads the ref count for [sha256] from the `$vault` namespace.
  int readRefCount(String sha256) {
    final bytes = _data[kVaultNamespace]?[sha256];
    if (bytes == null) return 0;
    final decoded = ValueCodec.decode(bytes);
    final v = decoded['refCount'];
    return v is int ? v : 0;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late MemoryStorageAdapter adapter;
  late _TestVaultStore vaultStore;
  late _TrackingKvStore kvStore;
  late VaultGc gc;
  late VaultRefInterceptor interceptor;

  setUp(() {
    _TestVaultStore._seq = 0;
    adapter = MemoryStorageAdapter();
    vaultStore = _TestVaultStore(adapter);
    kvStore = _TrackingKvStore();
    gc = VaultGc(store: vaultStore, kvStore: kvStore);
    interceptor = VaultRefInterceptor(kvStore: kvStore, gc: gc);
  });

  group('VaultRefInterceptor', () {
    group('insert (oldDoc=null → newDoc with vault uri)', () {
      test('increments ref count from 0 to 1', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('hello'),
          hlcTimestamp: 't1',
        );
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {'file': ref.uri},
        );
        await kvStore.writeBatch(batch);
        expect(kvStore.readRefCount(ref.sha256), equals(1));
      });

      test('does not create tombstone when ref goes 0→1', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('hello'),
          hlcTimestamp: 't1',
        );
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {'file': ref.uri},
        );
        await kvStore.writeBatch(batch);
        // No tombstone should exist.
        expect(await vaultStore.isTombstoned(ref.sha256), isFalse);
      });

      test('handles nested vault uri in document', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('nested'),
          hlcTimestamp: 't1',
        );
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {
            'meta': {'attachment': ref.uri},
          },
        );
        await kvStore.writeBatch(batch);
        expect(kvStore.readRefCount(ref.sha256), equals(1));
      });

      test('handles vault uri in list', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('list-item'),
          hlcTimestamp: 't1',
        );
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {
            'attachments': [ref.uri],
          },
        );
        await kvStore.writeBatch(batch);
        expect(kvStore.readRefCount(ref.sha256), equals(1));
      });

      test('increments multiple different vault uris', () async {
        final ref1 = await vaultStore.ingest(
          bytes: _bytes('file1'),
          hlcTimestamp: 't1',
        );
        final ref2 = await vaultStore.ingest(
          bytes: _bytes('file2'),
          hlcTimestamp: 't2',
        );
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {'a': ref1.uri, 'b': ref2.uri},
        );
        await kvStore.writeBatch(batch);
        expect(kvStore.readRefCount(ref1.sha256), equals(1));
        expect(kvStore.readRefCount(ref2.sha256), equals(1));
      });
    });

    group('update (oldDoc and newDoc)', () {
      test('no-op when vault uri unchanged', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('unchanged'),
          hlcTimestamp: 't1',
        );
        // Set initial ref count.
        final initBatch = WriteBatch();
        await interceptor.interceptWrite(
          batch: initBatch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {'file': ref.uri},
        );
        await kvStore.writeBatch(initBatch);
        expect(kvStore.readRefCount(ref.sha256), equals(1));

        // Update with same vault uri — count should stay at 1.
        final updateBatch = WriteBatch();
        await interceptor.interceptWrite(
          batch: updateBatch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: {'file': ref.uri},
          newDoc: {'file': ref.uri, 'extra': 'value'},
        );
        await kvStore.writeBatch(updateBatch);
        expect(kvStore.readRefCount(ref.sha256), equals(1));
      });

      test('decrements old uri and increments new uri on swap', () async {
        final ref1 = await vaultStore.ingest(
          bytes: _bytes('old-file'),
          hlcTimestamp: 't1',
        );
        final ref2 = await vaultStore.ingest(
          bytes: _bytes('new-file'),
          hlcTimestamp: 't2',
        );
        // Insert with ref1.
        final batch1 = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch1,
          namespace: 'test',
          docKey: 'testkey',
          oldDoc: null,
          newDoc: {'file': ref1.uri},
        );
        await kvStore.writeBatch(batch1);

        // Update to ref2.
        final batch2 = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch2,
          namespace: 'test',
          docKey: 'testkey',
          oldDoc: {'file': ref1.uri},
          newDoc: {'file': ref2.uri},
        );
        await kvStore.writeBatch(batch2);

        // ref1 should be tombstoned (went to 0), ref2 at 1.
        expect(kvStore.readRefCount(ref1.sha256), equals(0));
        expect(kvStore.readRefCount(ref2.sha256), equals(1));
        expect(await vaultStore.isTombstoned(ref1.sha256), isTrue);
        expect(await vaultStore.isTombstoned(ref2.sha256), isFalse);
      });

      test('adding a new vault uri increments that uri only', () async {
        final ref1 = await vaultStore.ingest(
          bytes: _bytes('existing'),
          hlcTimestamp: 't1',
        );
        final ref2 = await vaultStore.ingest(
          bytes: _bytes('added'),
          hlcTimestamp: 't2',
        );
        // Start with ref1.
        final batch1 = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch1,
          namespace: 'test',
          docKey: 'testkey',
          oldDoc: null,
          newDoc: {'a': ref1.uri},
        );
        await kvStore.writeBatch(batch1);

        // Add ref2.
        final batch2 = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch2,
          namespace: 'test',
          docKey: 'testkey',
          oldDoc: {'a': ref1.uri},
          newDoc: {'a': ref1.uri, 'b': ref2.uri},
        );
        await kvStore.writeBatch(batch2);

        expect(kvStore.readRefCount(ref1.sha256), equals(1));
        expect(kvStore.readRefCount(ref2.sha256), equals(1));
      });
    });

    group('delete (oldDoc with vault uri → newDoc=null)', () {
      test('decrements ref count to 0 and creates tombstone', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('to-delete'),
          hlcTimestamp: 't1',
        );
        // Insert.
        final batch1 = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch1,
          namespace: 'test',
          docKey: 'testkey',
          oldDoc: null,
          newDoc: {'file': ref.uri},
        );
        await kvStore.writeBatch(batch1);

        // Delete.
        final batch2 = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch2,
          namespace: 'test',
          docKey: 'testkey',
          oldDoc: {'file': ref.uri},
          newDoc: null,
        );
        await kvStore.writeBatch(batch2);

        expect(kvStore.readRefCount(ref.sha256), equals(0));
        expect(await vaultStore.isTombstoned(ref.sha256), isTrue);
      });

      test(
        'object not deleted by interceptor — GC handles actual deletion',
        () async {
          final ref = await vaultStore.ingest(
            bytes: _bytes('keep-until-gc'),
            hlcTimestamp: 't1',
          );
          final batch1 = WriteBatch();
          await interceptor.interceptWrite(
            batch: batch1,
            namespace: 'test',
            docKey: 'testkey',
            oldDoc: null,
            newDoc: {'file': ref.uri},
          );
          await kvStore.writeBatch(batch1);
          final batch2 = WriteBatch();
          await interceptor.interceptWrite(
            batch: batch2,
            namespace: 'test',
            docKey: 'testkey',
            oldDoc: {'file': ref.uri},
            newDoc: null,
          );
          await kvStore.writeBatch(batch2);

          // Object should still exist (blob + manifest) — only tombstoned.
          expect(await vaultStore.exists(ref.sha256), isTrue);
          expect(await vaultStore.isHydrated(ref.sha256), isTrue);
        },
      );
    });

    group('no vault uris', () {
      test('no-op for documents without vault uris', () async {
        final batch = WriteBatch();
        await interceptor.interceptWrite(
          batch: batch,
          namespace: "test",
          docKey: "testkey",
          oldDoc: {'name': 'Alice', 'age': 30},
          newDoc: {'name': 'Bob', 'age': 31},
        );
        await kvStore.writeBatch(batch);
        expect(kvStore._data[kVaultNamespace] ?? {}, isEmpty);
      });
    });

    group('ref-count restored before GC sweep (un-tombstone)', () {
      test('tombstone removed when same object re-referenced', () async {
        final ref = await vaultStore.ingest(
          bytes: _bytes('revived'),
          hlcTimestamp: 't1',
        );

        // Insert then delete — tombstone created.
        final b1 = WriteBatch();
        await interceptor.interceptWrite(
          batch: b1,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {'f': ref.uri},
        );
        await kvStore.writeBatch(b1);
        final b2 = WriteBatch();
        await interceptor.interceptWrite(
          batch: b2,
          namespace: "test",
          docKey: "testkey",
          oldDoc: {'f': ref.uri},
          newDoc: null,
        );
        await kvStore.writeBatch(b2);
        expect(await vaultStore.isTombstoned(ref.sha256), isTrue);

        // Re-insert the same object — tombstone should be removed.
        final b3 = WriteBatch();
        await interceptor.interceptWrite(
          batch: b3,
          namespace: "test",
          docKey: "testkey",
          oldDoc: null,
          newDoc: {'f': ref.uri},
        );
        await kvStore.writeBatch(b3);
        expect(kvStore.readRefCount(ref.sha256), equals(1));
        expect(await vaultStore.isTombstoned(ref.sha256), isFalse);
      });
    });
  });
}
