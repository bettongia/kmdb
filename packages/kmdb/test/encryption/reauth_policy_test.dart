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

/// Tests for [ReauthPolicy] (WI-5 Phase 2 — default-on periodic re-auth).
///
/// Split into two layers:
///
/// 1. Pure unit tests of each [ReauthPolicy] variant's `permitsBiometric` —
///    fast, no database involved.
/// 2. Integration tests wired through [KmdbDatabase.open] with an injected
///    clock (`now:`), proving the policy is actually enforced at the
///    bootstrap chokepoint rather than merely implemented in isolation. These
///    drive the clock forward instead of sleeping for a real 14 days (Q4).
///
/// The deeper SC-1-adjacent edge cases (biometric enrolment-invalidation,
/// `disableBiometricUnlock`, the `$meta`-LWW-hazard regression for the
/// re-auth timestamp) live in `unlock_policy_test.dart` (Phase 5) — this file
/// is scoped to the re-authentication *policy* itself.
library;

import 'dart:typed_data';

import 'package:kmdb/src/encryption/biometric_kek_provider.dart';
import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/reauth_policy.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/secret/secret_store.dart';
import 'package:test/test.dart';

/// A [BiometricKekProvider] test double — see the doc comment in
/// `kmdb_database_encryption_test.dart`'s copy for the idempotency rationale.
final class _FakeBiometricKekProvider implements BiometricKekProvider {
  _FakeBiometricKekProvider([Uint8List? kek])
    : _kek = kek ?? Uint8List.fromList(List.generate(32, (i) => i));

  final Uint8List _kek;

  @override
  Future<Uint8List> obtainKek() async => Uint8List.fromList(_kek);
}

const _kPassphrase = 'reauth-test-passphrase';

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── Pure unit tests ──────────────────────────────────────────────────────

  group('ReauthPolicy.interval', () {
    const policy = ReauthPolicy.interval(Duration(days: 14));
    final now = DateTime(2026, 8, 11);

    test(
      'permits biometric when the passphrase was used within the interval',
      () {
        final lastUsed = now.subtract(const Duration(days: 13));
        expect(policy.permitsBiometric(lastUsed, now), isTrue);
      },
    );

    test('permits biometric exactly at the interval boundary', () {
      final lastUsed = now.subtract(const Duration(days: 14));
      expect(policy.permitsBiometric(lastUsed, now), isTrue);
    });

    test('refuses biometric once the interval has lapsed', () {
      final lastUsed = now.subtract(const Duration(days: 15));
      expect(policy.permitsBiometric(lastUsed, now), isFalse);
    });

    test('fails closed when no timestamp has ever been recorded', () {
      expect(policy.permitsBiometric(null, now), isFalse);
    });
  });

  group('ReauthPolicy.alwaysRequirePassphrase', () {
    const policy = ReauthPolicy.alwaysRequirePassphrase();
    final now = DateTime(2026, 8, 11);

    test('refuses biometric even immediately after passphrase use', () {
      expect(policy.permitsBiometric(now, now), isFalse);
    });

    test('refuses biometric when no timestamp has been recorded', () {
      expect(policy.permitsBiometric(null, now), isFalse);
    });
  });

  group('ReauthPolicy.headlessSession', () {
    const policy = ReauthPolicy.headlessSession();
    final now = DateTime(2026, 8, 11);

    test(
      'permits biometric with no recorded timestamp (no periodic prompt)',
      () {
        expect(policy.permitsBiometric(null, now), isTrue);
      },
    );

    test(
      'permits biometric no matter how long ago the passphrase was used',
      () {
        final longAgo = now.subtract(const Duration(days: 3650));
        expect(policy.permitsBiometric(longAgo, now), isTrue);
      },
    );
  });

  // ── Integration tests (KmdbDatabase.open, injected clock) ───────────────

  group(
    'ReauthPolicy enforcement at KmdbDatabase.open (interval, default)',
    () {
      test(
        'biometric unlock succeeds while within the default 14-day interval',
        () async {
          final secretStore = InMemorySecretStore();
          final provider = _FakeBiometricKekProvider();
          var clock = DateTime(2026, 1, 1);

          final result = await EncryptionConfig.createResult(
            passphrase: _kPassphrase,
          );
          final adapter = MemoryStorageAdapter();
          final db1 = await KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: result.config,
            secretStore: secretStore,
            now: () => clock,
          );
          await db1.enableBiometricUnlock(provider);
          await db1.close();

          // Advance the clock by 10 days — still within the 14-day interval.
          clock = clock.add(const Duration(days: 10));

          final db2 = await KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig.biometric(provider),
            secretStore: secretStore,
            now: () => clock,
          );
          await db2.close();
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );

      test(
        'biometric unlock is refused once the default 14-day interval lapses',
        () async {
          final secretStore = InMemorySecretStore();
          final provider = _FakeBiometricKekProvider();
          var clock = DateTime(2026, 1, 1);

          final result = await EncryptionConfig.createResult(
            passphrase: _kPassphrase,
          );
          final adapter = MemoryStorageAdapter();
          final db1 = await KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: result.config,
            secretStore: secretStore,
            now: () => clock,
          );
          await db1.enableBiometricUnlock(provider);
          await db1.close();

          // Advance the clock by 15 days — past the 14-day interval.
          clock = clock.add(const Duration(days: 15));

          await expectLater(
            () => KmdbDatabase.open(
              path: '/db',
              adapter: adapter,
              config: KvStoreConfig.forTesting(),
              encryptionConfig: EncryptionConfig.biometric(provider),
              secretStore: secretStore,
              now: () => clock,
            ),
            throwsA(
              isA<EncryptionError>().having(
                (e) => e.code,
                'code',
                EncryptionErrorCode.biometricUnavailable,
              ),
            ),
          );

          // The passphrase path must still work — the database is not bricked.
          final db2 = await KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
            secretStore: secretStore,
            now: () => clock,
          );
          await db2.close();
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    },
  );

  group('ReauthPolicy.alwaysRequirePassphrase enforcement at open', () {
    test(
      'biometric unlock is refused immediately, even right after enrolment',
      () async {
        final secretStore = InMemorySecretStore();
        final provider = _FakeBiometricKekProvider();
        final clock = DateTime(2026, 1, 1);

        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();
        final db1 = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
          secretStore: secretStore,
          now: () => clock,
        );
        await db1.enableBiometricUnlock(provider);
        await db1.close();

        await expectLater(
          () => KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig.biometric(
              provider,
              reauthPolicy: const ReauthPolicy.alwaysRequirePassphrase(),
            ),
            secretStore: secretStore,
            now: () => clock,
          ),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.biometricUnavailable,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('ReauthPolicy.headlessSession suppresses the interval check', () {
    test(
      'biometric unlock succeeds with no recorded passphrase-use timestamp',
      () async {
        final secretStore = InMemorySecretStore();
        final provider = _FakeBiometricKekProvider();
        final clock = DateTime(2026, 1, 1);

        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();
        final db1 = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
          secretStore: secretStore,
          now: () => clock,
        );
        await db1.enableBiometricUnlock(provider);
        await db1.close();

        // Advance the clock far beyond any interval — headlessSession has no
        // timer, so this must still succeed.
        final laterClock = clock.add(const Duration(days: 3650));

        final db2 = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig.biometric(
            provider,
            reauthPolicy: const ReauthPolicy.headlessSession(),
          ),
          secretStore: secretStore,
          now: () => laterClock,
        );
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
