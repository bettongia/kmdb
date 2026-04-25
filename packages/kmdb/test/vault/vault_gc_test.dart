// Copyright 2026 The KMDB Authors
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

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_recovery.dart' show kVaultNamespace;
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

class TestVaultStore extends VaultStore {
  TestVaultStore(MemoryStorageAdapter adapter, {super.dbDir = '/db'})
    : _memAdapter = adapter,
      super(
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _counter,
      );

  final MemoryStorageAdapter _memAdapter;
  static int _seq = 0;
  static String _counter() => 'uuid-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final results = <String>[];
    for (final path in _memAdapter.files.keys) {
      if (path.startsWith(prefix)) {
        results.add(path.substring(prefix.length));
      }
    }
    return results;
  }
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

class _FakeKvStore implements KvStore {
  final Map<String, Map<String, Uint8List>> _data = {};

  void setRefCount(String sha256, int count) {
    _data[kVaultNamespace] ??= {};
    final keyBytes = utf8.encode('refCount');
    final builder = BytesBuilder();
    builder.addByte(0x00); // ValueCodec raw flag
    builder.addByte(0xA1); // CBOR map 1 pair
    builder.addByte(0x60 | keyBytes.length);
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
    _data[kVaultNamespace]![sha256] = builder.toBytes();
  }

  void clearRefCount(String sha256) {
    _data[kVaultNamespace]?.remove(sha256);
  }

  @override
  Future<Uint8List?> get(String ns, String key) async => _data[ns]?[key];

  @override
  Future<void> put(String ns, String key, Uint8List v) async {}

  @override
  Future<void> delete(String ns, String key) async {}

  @override
  Future<void> writeBatch(WriteBatch b) async {}

  @override
  Stream<KvEntry> scan(String ns, {String? startKey, String? endKey}) async* {}

  @override
  Future<void> close({bool flush = true}) async {}

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
  Future<List<String>> listNamespaces() async => [];

  @override
  Future<bool> createNamespace(String ns) async => false;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late MemoryStorageAdapter adapter;
  late TestVaultStore store;
  late _FakeKvStore kvStore;
  late VaultGc gc;

  setUp(() {
    TestVaultStore._seq = 0;
    adapter = MemoryStorageAdapter();
    store = TestVaultStore(adapter);
    kvStore = _FakeKvStore();
    gc = VaultGc(store: store, kvStore: kvStore);
  });

  group('VaultGc', () {
    group('onZeroRefs', () {
      test('creates tombstone.json for the hash', () async {
        final ref = await store.ingest(
          bytes: _bytes('test'),
          hlcTimestamp: 't1',
        );
        await gc.onZeroRefs(ref.sha256);
        expect(await store.isTombstoned(ref.sha256), isTrue);
      });

      test('does not affect the blob or manifest', () async {
        final ref = await store.ingest(
          bytes: _bytes('intact'),
          hlcTimestamp: 't1',
        );
        await gc.onZeroRefs(ref.sha256);
        expect(await store.exists(ref.sha256), isTrue);
        expect(await store.isHydrated(ref.sha256), isTrue);
      });
    });

    group('onRefRestored', () {
      test('removes tombstone.json', () async {
        final ref = await store.ingest(
          bytes: _bytes('restore'),
          hlcTimestamp: 't1',
        );
        await gc.onZeroRefs(ref.sha256);
        expect(await store.isTombstoned(ref.sha256), isTrue);

        await gc.onRefRestored(ref.sha256);
        expect(await store.isTombstoned(ref.sha256), isFalse);
      });

      test('blob and manifest remain after un-tombstoning', () async {
        final ref = await store.ingest(
          bytes: _bytes('un-tomb'),
          hlcTimestamp: 't1',
        );
        await gc.onZeroRefs(ref.sha256);
        await gc.onRefRestored(ref.sha256);

        expect(await store.exists(ref.sha256), isTrue);
        expect(await store.isHydrated(ref.sha256), isTrue);
      });
    });

    group('sweep', () {
      test('deletes tombstoned object with zero ref count', () async {
        final ref = await store.ingest(
          bytes: _bytes('sweep me'),
          hlcTimestamp: 't1',
        );
        kvStore.clearRefCount(ref.sha256); // no ref count = 0
        await gc.onZeroRefs(ref.sha256);

        final result = await gc.sweep();
        expect(result.deleted, equals(1));
        expect(await store.exists(ref.sha256), isFalse);
        expect(await store.isHydrated(ref.sha256), isFalse);
      });

      test('sweep returns correct counts', () async {
        final ref1 = await store.ingest(
          bytes: _bytes('del 1'),
          hlcTimestamp: 't1',
        );
        final ref2 = await store.ingest(
          bytes: _bytes('del 2'),
          hlcTimestamp: 't2',
        );

        kvStore.clearRefCount(ref1.sha256);
        kvStore.clearRefCount(ref2.sha256);
        await gc.onZeroRefs(ref1.sha256);
        await gc.onZeroRefs(ref2.sha256);

        final result = await gc.sweep();
        expect(result.examined, equals(2));
        expect(result.deleted, equals(2));
        expect(result.skipped, equals(0));
      });

      test('skips non-tombstoned objects', () async {
        final ref = await store.ingest(
          bytes: _bytes('keep'),
          hlcTimestamp: 't1',
        );
        kvStore.setRefCount(ref.sha256, 1);
        // No tombstone.

        final result = await gc.sweep();
        expect(result.examined, equals(0)); // not examined (not tombstoned)
        expect(result.deleted, equals(0));
        expect(await store.exists(ref.sha256), isTrue);
      });

      test(
        'guard: tombstone present but ref count restored before sweep',
        () async {
          // This tests the TOCTOU guard: a tombstone was created when ref=0,
          // but before the sweep ran, the object was re-referenced.
          final ref = await store.ingest(
            bytes: _bytes('guard test'),
            hlcTimestamp: 't1',
          );
          await gc.onZeroRefs(ref.sha256); // tombstone created when ref=0

          // Before sweep, ref count is restored (new document references this object).
          kvStore.setRefCount(ref.sha256, 1);

          final result = await gc.sweep();
          expect(result.examined, equals(1)); // tombstoned so examined
          expect(result.deleted, equals(0)); // but NOT deleted
          expect(result.skipped, equals(1)); // re-referenced, tombstone removed
          expect(await store.exists(ref.sha256), isTrue); // object preserved
          expect(
            await store.isTombstoned(ref.sha256),
            isFalse,
          ); // tombstone cleaned up
        },
      );

      test('sweep is idempotent — second sweep finds nothing to do', () async {
        final ref = await store.ingest(
          bytes: _bytes('idempotent'),
          hlcTimestamp: 't1',
        );
        kvStore.clearRefCount(ref.sha256);
        await gc.onZeroRefs(ref.sha256);

        final first = await gc.sweep();
        expect(first.deleted, equals(1));

        // Second sweep — hash dir already deleted, nothing to examine.
        final second = await gc.sweep();
        expect(second.examined, equals(0));
        expect(second.deleted, equals(0));
      });

      test('empty vault returns empty result', () async {
        final result = await gc.sweep();
        expect(result.examined, equals(0));
        expect(result.deleted, equals(0));
        expect(result.skipped, equals(0));
        expect(result.hadWork, isFalse);
      });

      test('stub (manifest-only) is swept when tombstoned and ref=0', () async {
        final sha256 = 'aa' * 32;
        final manifest = VaultManifest(
          sha256: sha256,
          size: 10,
          crc32c: 'abcd1234',
          mediaType: 'application/octet-stream',
          originalName: 'stub.bin',
          createdAt: 't1',
        );
        await store.createStub(manifest);
        kvStore.clearRefCount(sha256);
        await gc.onZeroRefs(sha256);

        final result = await gc.sweep();
        expect(result.deleted, equals(1));
        expect(await store.exists(sha256), isFalse);
      });
    });

    group('VaultGcResult', () {
      test('hadWork is false when nothing deleted', () {
        const r = VaultGcResult(examined: 3, deleted: 0, skipped: 3);
        expect(r.hadWork, isFalse);
      });

      test('hadWork is true when objects deleted', () {
        const r = VaultGcResult(examined: 2, deleted: 2, skipped: 0);
        expect(r.hadWork, isTrue);
      });

      test('toString contains field values', () {
        const r = VaultGcResult(examined: 5, deleted: 3, skipped: 2);
        final s = r.toString();
        expect(s, contains('5'));
        expect(s, contains('3'));
        expect(s, contains('2'));
      });
    });
  });
}
