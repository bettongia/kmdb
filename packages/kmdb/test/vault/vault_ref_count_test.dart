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

import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/vault/vault_recovery.dart' show kVaultNamespace;
import 'package:kmdb/src/vault/vault_ref_count.dart';
import 'package:test/test.dart';

// ── Test double ─────────────────────────────────────────────────────────────

/// A minimal in-memory [KvStore] that returns whatever raw bytes are stashed
/// under `$vault:{sha256}`. Only [get] is functional; everything else is a
/// no-op, so malformed values can be injected directly.
class _FakeKvStore implements KvStore {
  final Map<String, Uint8List> _vault = {};

  /// Stores the exact [bytes] for [sha256] under the `$vault` namespace.
  void setRaw(String sha256, Uint8List bytes) => _vault[sha256] = bytes;

  @override
  Future<Uint8List?> get(String namespace, String key) async =>
      namespace == kVaultNamespace ? _vault[key] : null;

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
  Future<List<String>> listNamespaces() async => [];

  @override
  Future<bool> createNamespace(String namespace) async => false;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

final _sha = 'aa' * 32;

void main() {
  late _FakeKvStore kvStore;

  setUp(() => kvStore = _FakeKvStore());

  group('VaultRefCount.read', () {
    test('absent entry → RefCountAbsent', () async {
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountAbsent>());
    });

    group('well-formed counts round-trip (as written by the interceptor)', () {
      // These are exactly the encodings VaultRefInterceptor produces:
      // ValueCodec.encode({'refCount': n}). Covers CBOR inline (0–23), uint8,
      // and uint16 integer widths.
      for (final n in [0, 1, 5, 23, 24, 100, 255, 256, 1000, 65535]) {
        test('refCount == $n decodes to RefCountValue($n)', () async {
          kvStore.setRaw(_sha, ValueCodec.encode({'refCount': n}));
          final result = await VaultRefCount.read(kvStore, _sha);
          expect(result, isA<RefCountValue>());
          expect((result as RefCountValue).count, equals(n));
        });
      }
    });

    test('negative stored count is clamped to RefCountValue(0)', () async {
      kvStore.setRaw(_sha, ValueCodec.encode({'refCount': -3}));
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountValue>());
      expect((result as RefCountValue).count, equals(0));
    });

    test('empty bytes → RefCountUndecodable', () async {
      kvStore.setRaw(_sha, Uint8List(0));
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountUndecodable>());
    });

    test('truncated value bytes → RefCountUndecodable', () async {
      final full = ValueCodec.encode({'refCount': 65535});
      // Drop the trailing bytes so the CBOR payload is incomplete.
      kvStore.setRaw(_sha, Uint8List.sublistView(full, 0, full.length - 1));
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountUndecodable>());
    });

    test(
      'wrong major type (CBOR int, not a map) → RefCountUndecodable',
      () async {
        // Flag byte 0x00 (no compression) + CBOR positive int 1 (0x01).
        kvStore.setRaw(_sha, Uint8List.fromList([0x00, 0x01]));
        final result = await VaultRefCount.read(kvStore, _sha);
        expect(result, isA<RefCountUndecodable>());
      },
    );

    test('unknown compression flag → RefCountUndecodable', () async {
      // 0xEE is not a valid CompressionFlag; ValueCodec.decode throws.
      kvStore.setRaw(_sha, Uint8List.fromList([0xEE, 0xA0]));
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountUndecodable>());
    });

    test('valid map missing the refCount key → RefCountUndecodable', () async {
      kvStore.setRaw(_sha, ValueCodec.encode({'other': 5}));
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountUndecodable>());
    });

    test('refCount present but non-integer → RefCountUndecodable', () async {
      kvStore.setRaw(_sha, ValueCodec.encode({'refCount': 'not-a-number'}));
      final result = await VaultRefCount.read(kvStore, _sha);
      expect(result, isA<RefCountUndecodable>());
    });
  });
}
