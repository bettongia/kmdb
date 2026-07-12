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

/// Tests for Gap 3 of the Encryption confidentiality reconciliation plan:
/// `MetaStore`'s late-bound [EncryptionProvider], the `enc:blob` exemption
/// (Q2), and the `$meta` format-version gate (B8/B9) that discriminates a
/// brand-new database from a legacy (pre-plan) one.
library;

import 'dart:typed_data';

import 'package:kmdb/src/encryption/encryption_blob.dart';
import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/encryption_flag.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/engine/kvstore/crash_recovery.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _dbDir = '/db';
const _deviceId = 'testdev1';
const _kPassphrase = 'meta-gate-test-passphrase';

Future<(KvStoreImpl, OpenResult)> _open(
  MemoryStorageAdapter adapter, {
  String deviceId = _deviceId,
}) => KvStoreImpl.open(
  _dbDir,
  adapter,
  config: KvStoreConfig.forTesting(),
  deviceId: deviceId,
);

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

String _key(int n) => SequentialKeyGenerator(start: n).next();

// ── Test model (for KmdbDatabase-level bootstrap-ordering tests) ─────────────

final class _Note {
  const _Note({required this.id, required this.text});
  final String id;
  final String text;
}

final class _NoteCodec implements KmdbCodec<_Note> {
  const _NoteCodec();

  @override
  String keyOf(_Note value) => value.id;

  @override
  _Note withKey(_Note value, String key) => _Note(id: key, text: value.text);

  @override
  Map<String, dynamic> encode(_Note value) => {'text': value.text};

  @override
  _Note decode(Map<String, dynamic> json) =>
      _Note(id: json['_id'] as String, text: json['text'] as String);
}

const _codec = _NoteCodec();

/// Builds a "legacy" (pre-plan) database directly on the storage layer,
/// bypassing [KvStoreImpl.open] entirely (and therefore its format-version
/// gate) so [seedValues] can write genuinely bare, un-framed bytes — exactly
/// what pre-Phase-2 code would have produced. Uses [CrashRecovery] +
/// [KvStoreImpl.forTesting] directly, mirroring the pattern in
/// `lsm_engine_test.dart`'s `openWithClock`.
Future<void> _seedLegacyDatabase(
  MemoryStorageAdapter adapter,
  Map<String, Uint8List> seedValues,
) async {
  final recovery = CrashRecovery(
    adapter: adapter,
    config: KvStoreConfig.forTesting(),
  );
  final (engine, _) = await recovery.open(_dbDir, deviceId: _deviceId);
  final meta = MetaStore(engine);
  engine.setMetaStore(meta);
  for (final entry in seedValues.entries) {
    await engine.put(MetaStore.kNamespace, entry.key, entry.value);
  }
  final store = KvStoreImpl.forTesting(
    engine,
    meta,
    KvStoreConfig.forTesting(),
    dirtyFlagPresent: false,
  );
  await store.close();
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── MetaStore encryption round-trip ────────────────────────────────────────

  group('MetaStore — encryption round-trip (Gap 3)', () {
    late AesGcmEncryptionProvider provider;

    setUp(() async {
      final dek = await KeyDerivation.generateDek();
      provider = AesGcmEncryptionProvider(dek);
    });

    test('generation counter round-trips with encryption active', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      store.meta.encryption = provider;

      await store.meta.incrementGenerationCounter('tasks');
      await store.meta.incrementGenerationCounter('tasks');
      expect(await store.meta.getGenerationCounter('tasks'), equals(2));

      // Confirm the raw bytes are genuinely AES-GCM framed, not plaintext.
      final raw = await store.get(
        MetaStore.kNamespace,
        MetaStore.genKey('tasks'),
      );
      expect(raw![0], equals(EncryptionFlag.aesGcm.byte));

      await store.close();
    });

    test('device ID round-trips with encryption active', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      store.meta.encryption = provider;

      await store.meta.putDeviceId('a1b2c3d4');
      expect(await store.meta.getDeviceId(), equals('a1b2c3d4'));

      final raw = await store.get(MetaStore.kNamespace, MetaStore.deviceIdKey);
      expect(raw![0], equals(EncryptionFlag.aesGcm.byte));
      // Ciphertext must not contain the plaintext device ID.
      expect(raw, isNot(contains(_bytes('a1b2c3d4').first)));

      await store.close();
    });

    test('namespace registry round-trips with encryption active', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      store.meta.encryption = provider;

      await store.meta.registerNamespace('secret-collection');
      expect(await store.meta.getNamespaces(), contains('secret-collection'));

      await store.close();
    });

    test('tombstone floor round-trips with encryption active', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      store.meta.encryption = provider;

      const floor = Hlc(12345, 3);
      await store.meta.setTombstoneFloor(floor);
      expect(await store.meta.getTombstoneFloor(), equals(floor));

      await store.close();
    });

    test('getRawByName/putRawByName (index/FTS/Vec/schema/version state) '
        'round-trip with encryption active', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      store.meta.encryption = provider;

      final blob = _bytes('opaque-index-state-blob');
      await store.meta.putRawByName('index:tasks:status', blob);
      expect(await store.meta.getRawByName('index:tasks:status'), equals(blob));

      final raw = await store.get(
        MetaStore.kNamespace,
        MetaStore.indexKey('tasks', 'status'),
      );
      expect(raw![0], equals(EncryptionFlag.aesGcm.byte));

      await store.close();
    });

    test(
      'dirty flag round-trip with encryption active (presence-only read)',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        store.meta.encryption = provider;

        await store.meta.setDirty();
        expect(await store.meta.getDirtyFlag(), isTrue);
        await store.meta.clearDirty();
        expect(await store.meta.getDirtyFlag(), isFalse);

        await store.close(flush: false);
      },
    );

    test(
      'values encrypted under one DEK are unreadable under another (wrong key)',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        store.meta.encryption = provider;
        await store.meta.putDeviceId('deadbeef');
        await store.close();

        final otherDek = await KeyDerivation.generateDek();
        final wrongProvider = AesGcmEncryptionProvider(otherDek);
        final (store2, _) = await _open(adapter);
        store2.meta.encryption = wrongProvider;

        await expectLater(
          store2.meta.getDeviceId(),
          throwsA(isA<EncryptionError>()),
        );
        await store2.close();
      },
    );
  });

  // ── enc:blob exemption (Q2) ────────────────────────────────────────────────

  group('MetaStore — enc:blob exemption (Q2)', () {
    test('getEncryptionBlob/putEncryptionBlob never encrypt, even when '
        'MetaStore.encryption is set', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final dek = await KeyDerivation.generateDek();
      store.meta.encryption = AesGcmEncryptionProvider(dek);

      final salt = Uint8List.fromList(List.generate(32, (i) => i));
      final wrapped = Uint8List.fromList(List.generate(60, (i) => i + 1));
      final blob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrapped,
        wrappedDekRecovery: wrapped,
      );
      await store.meta.putEncryptionBlob(blob);

      // Read back via the exempt path — must succeed even though a
      // provider is configured (proving putEncryptionBlob did not wrap it
      // with EncryptionEnvelope, which would require decryption to read).
      final read = await store.meta.getEncryptionBlob();
      expect(read, isNotNull);
      expect(read!.argon2Salt, equals(salt));

      // Confirm at the byte level: the raw bytes decode directly as the
      // enc:blob CBOR map format (EncryptionBlob.decode), not as an
      // EncryptionEnvelope frame — i.e. putRawByName/getRawByName (the
      // now-encrypting generic accessors) were never used for this key.
      // A genuinely EncryptionEnvelope-wrapped blob would begin with
      // EncryptionFlag.aesGcm (0x01); enc:blob's CBOR map starts with a
      // CBOR major-type-5 (map) byte instead — never 0x01.
      final raw = await store.get(
        MetaStore.kNamespace,
        MetaStore.encryptionBlobKey,
      );
      expect(raw, isNotNull);
      expect(raw![0], isNot(equals(EncryptionFlag.aesGcm.byte)));

      await store.close();
    });
  });

  // ── Format-version marker (Phase 2/B8-B9) ─────────────────────────────────

  group('Format-version marker (Phase 2/B8-B9)', () {
    test('a brand-new (empty) database opens successfully and writes '
        'the marker', () async {
      final adapter = MemoryStorageAdapter();
      final (store, result) = await _open(adapter);
      expect(result.isNewDatabase, isTrue);
      expect(
        await store.meta.getFormatVersionMarker(),
        equals(MetaStore.kCurrentFormatVersion),
      );
      await store.close();
    });

    test('reopening an already-current-format database does not error and '
        'is not misclassified as new', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.close();

      final (store2, result2) = await _open(adapter);
      expect(result2.isNewDatabase, isFalse);
      expect(
        await store2.meta.getFormatVersionMarker(),
        equals(MetaStore.kCurrentFormatVersion),
      );
      await store2.close();
    });

    test('a legacy database with real content and no marker fails cleanly '
        'at open()', () async {
      final adapter = MemoryStorageAdapter();
      // Seed a populated gen counter, bare (un-framed) CBOR — no
      // format-version marker key at all. This mirrors what a pre-Phase-2
      // build would have persisted for a namespace with real write
      // history.
      await _seedLegacyDatabase(adapter, {
        MetaStore.genKey('tasks'): _bareUint64(5),
      });

      await expectLater(
        _open(adapter),
        throwsA(isA<LegacyDatabaseFormatException>()),
      );
    });

    test('a legacy database whose generation counter is 0 fails cleanly — '
        'the exact byte-collision case B9 exists to prevent (0x00 == '
        'EncryptionFlag.none)', () async {
      final adapter = MemoryStorageAdapter();
      await _seedLegacyDatabase(adapter, {
        // A legacy generation counter of exactly 0: 8 zero bytes. This is
        // the value every freshly-registered namespace would have held
        // under pre-Phase-2 code. This single entry is sufficient on its
        // own to make $meta non-empty, so the format-version gate's
        // "looks fresh" fallback (KvStoreImpl.open()'s
        // `engine.scan(MetaStore.kNamespace).isEmpty` check) correctly does
        // *not* misclassify this database as still-effectively-fresh — no
        // separate namespaces-registry entry needs to be seeded too.
        MetaStore.genKey('tasks'): _bareUint64(0),
      });

      await expectLater(
        _open(adapter),
        throwsA(isA<LegacyDatabaseFormatException>()),
      );
    });

    test('a legacy database whose generation counter is 1 fails cleanly — '
        'the exact byte-collision case B9 exists to prevent (0x01 == '
        'EncryptionFlag.aesGcm)', () async {
      final adapter = MemoryStorageAdapter();
      await _seedLegacyDatabase(adapter, {
        MetaStore.genKey('tasks'): _bareUint64(1),
      });

      await expectLater(
        _open(adapter),
        throwsA(isA<LegacyDatabaseFormatException>()),
      );
    });

    test('a legacy database whose only content is a bare device_id fails '
        'cleanly too (not just the counter=0/1 collision case)', () async {
      final adapter = MemoryStorageAdapter();
      await _seedLegacyDatabase(adapter, {
        MetaStore.deviceIdKey: _bytes('a1b2c3d4'),
      });

      await expectLater(
        _open(adapter),
        throwsA(isA<LegacyDatabaseFormatException>()),
      );
    });
  });

  // ── Bootstrap ordering (Q1) ────────────────────────────────────────────────

  group('Bootstrap ordering (Q1) — KmdbDatabase.open()', () {
    test('every \$meta entry written during provisioning (incl. the first '
        'device_id write) is encrypted from the very first write', () async {
      final adapter = MemoryStorageAdapter();
      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );

      final db = await KmdbDatabase.open(
        path: _dbDir,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
      );

      // Trigger the namespace registry + gen counter + dirty flag writes,
      // and the device_id write, all after open() — all must be encrypted.
      final col = db.collection(name: 'notes', codec: _codec);
      await col.insert(const _Note(id: '', text: 'hello'));
      final deviceId = await db.ensureDeviceId();
      expect(deviceId, isNotEmpty);

      // Read every relevant $meta entry's RAW bytes directly and confirm
      // each carries the EncryptionFlag.aesGcm prefix.
      final store = db.store;
      final rawGen = await store.get(
        MetaStore.kNamespace,
        MetaStore.genKey('notes'),
      );
      expect(rawGen![0], equals(EncryptionFlag.aesGcm.byte));

      final rawDeviceId = await store.get(
        MetaStore.kNamespace,
        MetaStore.deviceIdKey,
      );
      expect(
        rawDeviceId![0],
        equals(EncryptionFlag.aesGcm.byte),
        reason:
            'the very first device_id write must be encrypted, not just '
            'subsequent ones',
      );

      // Functional round-trip for the namespace registry (no public raw
      // key helper is exposed for it, unlike genKey/deviceIdKey — its
      // decode path already exercises EncryptionEnvelope.unwrap, so a
      // successful, correct result here is proof it round-trips through
      // encryption rather than reading stale/garbage bytes).
      expect(await store.listNamespaces(), contains('notes'));

      await db.close();
    });
  });

  // ── Crash recovery with encrypted $meta (FaultyStorageAdapter) ────────────

  group('Crash recovery with encrypted \$meta (FaultyStorageAdapter)', () {
    test('WAL replay of encrypted \$meta entries recovers correctly after a '
        'crash before flush', () async {
      final adapter = FaultyStorageAdapter();
      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );

      final db = await KmdbDatabase.open(
        path: _dbDir,
        adapter: adapter,
        config: const KvStoreConfig(
          memtableSizeBytes: 4096,
          fsyncOnWrite: true,
        ),
        encryptionConfig: result.config,
      );
      final col = db.collection(name: 'notes', codec: _codec);
      await col.put(_Note(id: _key(1), text: 'before crash'));

      // Simulate a crash: discard anything not fsync'd, without a clean
      // close (so the WAL — not an SSTable — is what recovery must
      // replay).
      await db.close(flush: false);
      adapter.crash();

      final db2 = await KmdbDatabase.open(
        path: _dbDir,
        adapter: adapter,
        config: const KvStoreConfig(
          memtableSizeBytes: 4096,
          fsyncOnWrite: true,
        ),
        encryptionConfig: result.config,
      );
      final col2 = db2.collection(name: 'notes', codec: _codec);
      final recovered = await col2.get(_key(1));
      expect(recovered?.text, equals('before crash'));

      // $meta itself must also have survived and remain decryptable —
      // e.g. the namespace registry.
      expect(await db2.store.listNamespaces(), contains('notes'));

      await db2.close();
    });
  });
}

/// Encodes [value] as a big-endian 8-byte unsigned integer — the exact
/// bare (pre-Phase-2) generation-counter wire format, with no
/// EncryptionEnvelope/EncryptionFlag framing at all.
Uint8List _bareUint64(int value) {
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setUint64(0, value, Endian.big);
  return bytes;
}
