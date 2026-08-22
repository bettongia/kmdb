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

/// WI-5 Phase 5 test matrix — edge/fault cases for the unlock policy that
/// closes SC-1, not covered by the golden-path tests already spread across
/// `kmdb_database_encryption_test.dart` (State 1-5, biometric enrolment
/// smoke test), `reauth_policy_test.dart` (Phase 2, re-auth interval/
/// alwaysRequirePassphrase/headlessSession — pure + integration), and
/// `headless_server_unlock_test.dart` (Phase 4).
///
/// This file covers what those do not:
///
/// - The SC-1 regression headline itself.
/// - Biometric enrolment-invalidation (simulated: the platform destroying the
///   underlying wrap) forces the passphrase path, and a fresh enrolment
///   re-establishes biometric unlock.
/// - `disableBiometricUnlock()` → subsequent biometric open refused.
/// - Fail-closed when biometric was *never* enrolled at all (distinct from
///   "was enrolled, then invalidated").
/// - `lock()` discards the DEK; the next `open()` re-authenticates.
/// - The "passphrase last used" timestamp is local-only: (a) structurally,
///   `EncryptionBlob` (the `$meta`-synced, cross-device structure) never
///   carries it or the biometric wrap; (b) behaviourally, one device's own
///   (absent/stale) timestamp governs its own re-auth decision regardless of
///   what a "peer" device's SecretStore might contain — nothing crosses.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:kmdb/src/encryption/biometric_kek_provider.dart';
import 'package:kmdb/src/encryption/encryption_blob.dart';
import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/secret/secret_key.dart';
import 'package:kmdb/src/secret/secret_store.dart';
import 'package:test/test.dart';

/// A [BiometricKekProvider] test double satisfying the idempotent
/// get-or-create contract via a fixed KEK.
final class _FakeBiometricKekProvider implements BiometricKekProvider {
  _FakeBiometricKekProvider([Uint8List? kek])
    : _kek = kek ?? Uint8List.fromList(List.generate(32, (i) => i));

  final Uint8List _kek;

  @override
  Future<Uint8List> obtainKek() async => Uint8List.fromList(_kek);
}

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
const _kPassphrase = 'unlock-policy-test-passphrase';
const _kDbPath = '/db';

final _keyGen = SequentialKeyGenerator();
String _key() => _keyGen.next();

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── The SC-1 regression (headline) ──────────────────────────────────────

  group('SC-1 regression: a wrong passphrase is always rejected', () {
    test(
      'a deliberately wrong passphrase is rejected even with a prior '
      'successful unlock AND a warm, enrolled biometric wrap present',
      () async {
        // This is the exact scenario SC-1 broke: a warm session state (here,
        // an enrolled biometric wrap — the closest equivalent to the old
        // DekCache's "warm cache") must never let a wrong passphrase through.
        // Before the fix, kmdb_database.dart:751-753 returned a DEK from a
        // warm DekCache without ever checking the supplied passphrase at
        // all — this test would have passed spuriously on old `main` only
        // because it never reached the passphrase-check code path in the
        // first place. Now, only KEKSource.passphrase is ever consulted for
        // a passphrase config, so a wrong passphrase always fails Argon2id
        // + AES-GCM tag verification, independent of any other unlock state.
        final secretStore = InMemorySecretStore();
        final provider = _FakeBiometricKekProvider();

        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();
        final db1 = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
          secretStore: secretStore,
        );
        final col1 = db1.collection(name: 'notes', codec: _codec);
        await col1.put(_Note(id: _key(), text: 'secret'));
        // Let CacheLayer's fire-and-forget generation-counter read
        // (triggered by the write event above) settle before this instance
        // is closed and a new one opened on the same adapter — otherwise the
        // orphaned read can race a subsequent open's compaction and observe
        // a torn (mid-rewrite) file in the in-memory adapter's file map,
        // surfacing as a spurious, unrelated AES-GCM failure in this test.
        await Future<void>.delayed(Duration.zero);
        // Establish "warm" biometric state — the SC-1-adjacent stand-in for
        // the old DekCache's warm-process-lifetime cache.
        await db1.enableBiometricUnlock(provider);
        await db1.close();

        // A biometric open first, to prove biometric unlock itself is
        // genuinely warm/working (sanity check the setup is meaningful).
        final dbBiometric = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(provider),
          secretStore: secretStore,
        );
        await dbBiometric.close();

        // Now the headline assertion: a WRONG passphrase must still be
        // rejected, even though the database has a warm, working biometric
        // wrap and was just successfully opened moments ago.
        await expectLater(
          () => KmdbDatabase.open(
            path: _kDbPath,
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig(
              passphrase: 'deliberately-wrong',
            ),
            secretStore: secretStore,
          ),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.badCredentials,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ── Biometric enrolment-invalidation ────────────────────────────────────

  group('Biometric enrolment-invalidation forces the passphrase path', () {
    test(
      'a destroyed wrap (simulating platform enrolment invalidation) is '
      'refused, the passphrase still works, and re-enrolment restores it',
      () async {
        final secretStore = InMemorySecretStore();
        final provider = _FakeBiometricKekProvider();

        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();
        final db1 = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
          secretStore: secretStore,
        );
        await db1.enableBiometricUnlock(provider);
        await db1.close();

        // Simulate the platform invalidating the biometric-gated item (e.g.
        // a new fingerprint was enrolled) by removing it directly from the
        // SecretStore — the same externally-observable effect as the
        // platform refusing to release it: the wrap is simply gone.
        await secretStore.delete(
          dbScopedSecretKey(_kDbPath, 'dek.wrap.biometric'),
        );

        // Biometric unlock now fails closed.
        await expectLater(
          () => KmdbDatabase.open(
            path: _kDbPath,
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig.biometric(provider),
            secretStore: secretStore,
          ),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.biometricUnavailable,
            ),
          ),
        );

        // The passphrase path is unaffected — "reconfigure after
        // invalidation" starts by unlocking with the passphrase.
        final db2 = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
          secretStore: secretStore,
        );

        // Re-enrolment from that unlocked session restores biometric unlock.
        await db2.enableBiometricUnlock(provider);
        await db2.close();

        final db3 = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(provider),
          secretStore: secretStore,
        );
        await db3.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ── disableBiometricUnlock ───────────────────────────────────────────────

  group('disableBiometricUnlock', () {
    test('disables biometric unlock; a subsequent biometric open is refused '
        'and the passphrase is required', () async {
      final secretStore = InMemorySecretStore();
      final provider = _FakeBiometricKekProvider();

      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );
      final adapter = MemoryStorageAdapter();
      final db1 = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
        secretStore: secretStore,
      );
      await db1.enableBiometricUnlock(provider);
      await db1.close();

      // Sanity: biometric unlock works before disabling.
      final dbCheck = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: EncryptionConfig.biometric(provider),
        secretStore: secretStore,
      );
      await dbCheck.disableBiometricUnlock();
      await dbCheck.close();

      await expectLater(
        () => KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(provider),
          secretStore: secretStore,
        ),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.biometricUnavailable,
          ),
        ),
      );

      final db2 = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
        secretStore: secretStore,
      );
      await db2.close();
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('disableBiometricUnlock is a no-op when never enrolled', () async {
      final secretStore = InMemorySecretStore();
      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
        secretStore: secretStore,
      );
      // Must not throw.
      await db.disableBiometricUnlock();
      await db.close();
    });
  });

  // ── Fail-closed: never enrolled ─────────────────────────────────────────

  group('Fail-closed when biometric was never enrolled', () {
    test('a biometric KEKSource with no wrap ever present in SecretStore falls '
        'back to requiring the passphrase — never silently opens', () async {
      final secretStore = InMemorySecretStore();
      final provider = _FakeBiometricKekProvider();

      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );
      final adapter = MemoryStorageAdapter();
      final db1 = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
        secretStore: secretStore,
      );
      // No enableBiometricUnlock call at all.
      await db1.close();

      await expectLater(
        () => KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(provider),
          secretStore: secretStore,
        ),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.biometricUnavailable,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a fresh, never-opened database with a biometric config throws '
        'biometricUnavailable, not badCredentials (there is nothing to '
        'authenticate against yet on this device)', () async {
      // A biometric EncryptionConfig on a database with NO enc:blob at all
      // is state 3 (unlock config on plaintext DB) if the DB is plaintext,
      // but if the DB IS encrypted and simply has never had biometric
      // enrolled on this device, the fail-closed gate must fire before any
      // KEK is even requested from the provider.
      final secretStore = InMemorySecretStore();
      final provider = _FakeBiometricKekProvider();

      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );
      final adapter = MemoryStorageAdapter();
      final provisionDb = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
        secretStore: secretStore,
      );
      await provisionDb.close();

      // A DIFFERENT SecretStore — simulating a second device that has
      // never enrolled biometric unlock, even though the database itself
      // (enc:blob) is shared/synced.
      final otherDeviceSecretStore = InMemorySecretStore();

      await expectLater(
        () => KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(provider),
          secretStore: otherDeviceSecretStore,
        ),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.biometricUnavailable,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ── lock() ────────────────────────────────────────────────────────────────

  group('lock() discards the DEK; the next open() re-authenticates', () {
    test(
      'after lock(), further encrypted access on the same instance throws '
      'databaseLocked, and a fresh open() with the passphrase works',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();
        final db = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
        );
        final col = db.collection(name: 'notes', codec: _codec);
        final id = _key();
        await col.put(_Note(id: id, text: 'before-lock'));
        // Let CacheLayer's fire-and-forget generation-counter read settle
        // before locking — see the identical note in the SC-1 regression
        // test above for why this avoids spurious cross-open races.
        await Future<void>.delayed(Duration.zero);

        db.lock();

        // Any further encrypted operation on this now-locked instance fails.
        await expectLater(
          () => col.get(id),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.databaseLocked,
            ),
          ),
        );
        await expectLater(
          () => col.put(_Note(id: _key(), text: 'after-lock')),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.databaseLocked,
            ),
          ),
        );

        // Discard the locked instance — lock() only invalidates the DEK, it
        // does not release the storage lock; a real caller would drop this
        // instance the same way. flush: false per lock()'s doc comment: a
        // flush-triggered compaction would need to decrypt the $meta
        // namespace listing, which fails on a locked provider — no data is
        // lost, since anything written before lock() is already durable in
        // the WAL and will be replayed on the next open().
        await db.close(flush: false);

        // A fresh open() (a new instance, on the same underlying storage)
        // re-authenticates from scratch and reads the data written earlier.
        final db2 = await KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
        );
        final col2 = db2.collection(name: 'notes', codec: _codec);
        final note = await col2.get(id);
        expect(note?.text, equals('before-lock'));
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('lock() on a plaintext database is a harmless no-op', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
      );
      // Must not throw.
      db.lock();
      final col = db.collection(name: 'notes', codec: _codec);
      // Plaintext access still works — lock() only affects EncryptionProvider.
      await col.put(_Note(id: _key(), text: 'still readable'));
      await db.close();
    });

    test('lock() is idempotent — calling it twice does not throw', () async {
      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
      );
      db.lock();
      db.lock(); // must not throw
    });
  });

  // ── "Last used" timestamp is local-only ─────────────────────────────────

  group('The re-auth timestamp and biometric wrap are local-only', () {
    test(
      r'EncryptionBlob (the $meta-synced structure) never carries the '
      'biometric wrap or the re-auth timestamp — structural regression guard',
      () {
        // If either field were ever added to EncryptionBlob's CBOR map, it
        // would ride the sync channel ($meta is not local-only — see
        // isLocalOnly's doc comment) and reopen exactly the LWW-resurrection
        // hazard this design decision exists to avoid. Assert the encoded
        // map's key set is EXACTLY the seven documented fields — no more.
        final blob = EncryptionBlob(
          argon2Salt: Uint8List.fromList(List.generate(32, (i) => i)),
          wrappedDekPassphrase: Uint8List.fromList(List.generate(60, (i) => i)),
          wrappedDekRecovery: Uint8List.fromList(List.generate(60, (i) => i)),
        );
        final decoded = cbor.decode(blob.encode()) as CborMap;
        final keys = decoded.keys
            .map((k) => (k as CborString).toString())
            .toSet();
        expect(
          keys,
          equals({'v', 'salt', 'wdekP', 'wdekR', 'm', 't', 'p'}),
          reason:
              'enc:blob must never carry the biometric wrap or the '
              're-auth timestamp — both are per-device local state stored '
              r'exclusively in SecretStore, never $meta.',
        );
      },
    );

    test('a device with no recorded passphrase use is refused biometric unlock '
        "even though a separate (peer-simulating) SecretStore has a recent "
        'timestamp — nothing crosses between stores', () async {
      // Two independent SecretStore instances stand in for two devices.
      // Device A "recently" used its passphrase (fresh timestamp in A's
      // store). Device B has never recorded passphrase use at all. If the
      // timestamp were (incorrectly) synced/shared, device B's biometric
      // attempt might spuriously succeed by riding device A's fresh
      // timestamp. It must not: each device's own SecretStore is the only
      // input to its own re-auth decision.
      final deviceAStore = InMemorySecretStore();
      final deviceBStore = InMemorySecretStore();
      final provider = _FakeBiometricKekProvider();

      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );
      final adapter = MemoryStorageAdapter();

      // Device A: provision + enrol biometric — this writes a fresh
      // "passphrase last used" timestamp into deviceAStore only.
      final dbA = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: result.config,
        secretStore: deviceAStore,
      );
      await dbA.enableBiometricUnlock(provider);
      await dbA.close();

      // Sanity: device A's own biometric unlock succeeds (its own fresh
      // timestamp permits it).
      final dbACheck = await KmdbDatabase.open(
        path: _kDbPath,
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        encryptionConfig: EncryptionConfig.biometric(provider),
        secretStore: deviceAStore,
      );
      await dbACheck.close();

      // Device B: never enrolled, never used the passphrase — its store
      // is empty. Even with the exact same provider (so unwrap would
      // succeed cryptographically if a wrap were readable), there is no
      // wrap in deviceBStore at all, and no timestamp — fail-closed on
      // both counts, and neither is satisfied by device A's activity.
      await expectLater(
        () => KmdbDatabase.open(
          path: _kDbPath,
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(provider),
          secretStore: deviceBStore,
        ),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.biometricUnavailable,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
