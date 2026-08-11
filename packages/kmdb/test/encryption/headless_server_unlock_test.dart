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

/// Integration tests for the headless/server unlock pattern (WI-5 Phase 4).
///
/// `kmdb_server` itself is a separate proposal — this is a library-side hook
/// only. What is tested here is that the two documented patterns (see
/// [ReauthPolicy.headlessSession]'s doc comment) actually work end-to-end:
///
/// 1. Plain passphrase read non-interactively (e.g. from a mounted secret
///    file such as systemd's `$CREDENTIALS_DIRECTORY` or Docker's
///    `/run/secrets`) — this is just [EncryptionConfig] with no biometric
///    involvement, so it is exercised via the existing State-5 unlock tests
///    in `kmdb_database_encryption_test.dart`; not duplicated here.
/// 2. A machine-bound [BiometricKekProvider] (standing in for a KMS/HSM- or
///    mounted-secret-backed key, not real biometric hardware) paired with
///    [ReauthPolicy.headlessSession] — "unlock once at worker start,
///    re-authenticate on restart; no timer, no periodic prompt". This file
///    proves that pattern: a single "worker start" unlock survives many
///    simulated process restarts with the clock advanced arbitrarily far,
///    with no passphrase ever re-entered.
library;

import 'dart:typed_data';

import 'package:kmdb/src/encryption/biometric_kek_provider.dart';
import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/reauth_policy.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/secret/secret_store.dart';
import 'package:test/test.dart';

/// A [BiometricKekProvider] standing in for a machine-bound key source (a
/// KMS, an HSM, or a key read from a mounted secret directory) — the
/// "headless" analogue of a real platform biometric prompt. Satisfies the
/// same idempotent get-or-create contract: the key is fixed for the lifetime
/// of this instance, simulating a stable machine identity.
final class _MachineKeyProvider implements BiometricKekProvider {
  _MachineKeyProvider(this._kek);

  final Uint8List _kek;

  @override
  Future<Uint8List> obtainKek() async => Uint8List.fromList(_kek);
}

const _kPassphrase = 'headless-server-provisioning-passphrase';

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('Headless/server unlock (machine-bound key + headlessSession)', () {
    test(
      'a single worker-start unlock survives many simulated restarts, '
      'with the clock advanced arbitrarily far and no passphrase re-entry',
      () async {
        // A durable SecretStore standing in for a directory-backed store
        // rooted at a persistent volume — the wrap must survive "container
        // restarts" (simulated here as repeated KmdbDatabase.open calls).
        final secretStore = InMemorySecretStore();
        final machineKey = Uint8List.fromList(List.generate(32, (i) => i * 7));
        final provider = _MachineKeyProvider(machineKey);
        var clock = DateTime(2026, 1, 1);

        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();

        // "Provisioning" step — a human runs this once, out of band, then the
        // passphrase is never needed again for this deployment.
        final provisionDb = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
          secretStore: secretStore,
          now: () => clock,
        );
        await provisionDb.enableBiometricUnlock(provider);
        await provisionDb.close();

        // Simulate many "worker start" events (process restarts) spread over
        // years — headlessSession has no timer, so every one must succeed
        // without ever supplying the passphrase again.
        for (final daysElapsed in [0, 1, 30, 400, 3650]) {
          clock = DateTime(2026, 1, 1).add(Duration(days: daysElapsed));
          final workerDb = await KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig.biometric(
              provider,
              reauthPolicy: const ReauthPolicy.headlessSession(),
            ),
            secretStore: secretStore,
            now: () => clock,
          );
          await workerDb.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'the same machine-bound unlock, WITHOUT headlessSession, is refused '
      'once the default interval lapses — proving the opt-out is load-bearing',
      () async {
        // Same setup as above, but using the default ReauthPolicy.interval
        // instead of headlessSession — demonstrates that headlessSession is
        // not a no-op: without it, a long-lived headless deployment would
        // eventually be refused, which is exactly the wrong behaviour for a
        // server with no user to re-prompt.
        final secretStore = InMemorySecretStore();
        final machineKey = Uint8List.fromList(List.generate(32, (i) => i * 3));
        final provider = _MachineKeyProvider(machineKey);
        var clock = DateTime(2026, 1, 1);

        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final adapter = MemoryStorageAdapter();

        final provisionDb = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
          secretStore: secretStore,
          now: () => clock,
        );
        await provisionDb.enableBiometricUnlock(provider);
        await provisionDb.close();

        // 400 days later, without headlessSession, the default 14-day
        // interval has long since lapsed.
        clock = DateTime(2026, 1, 1).add(const Duration(days: 400));

        await expectLater(
          () => KmdbDatabase.open(
            path: '/db',
            adapter: adapter,
            config: KvStoreConfig.forTesting(),
            encryptionConfig: EncryptionConfig.biometric(provider),
            secretStore: secretStore,
            now: () => clock,
          ),
          throwsA(isA<Exception>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
