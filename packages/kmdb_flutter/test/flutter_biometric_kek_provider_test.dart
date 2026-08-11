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

/// Tests for [FlutterBiometricKekProvider].
///
/// `FlutterSecureStorage.setMockInitialValues` installs the package's own
/// in-memory test platform implementation, which stores/reads plain values
/// regardless of `accessControlFlags`/`enforceBiometrics` — real biometric
/// prompting cannot be exercised in a unit test (no hardware, no OS
/// authentication UI). What *is* verified here is the contract this class
/// promises core: idempotent get-or-create (the same KEK on repeated calls,
/// which is what makes wrap-at-enrolment and unwrap-at-unlock use the same
/// key), per-database key scoping, and KEK randomness/length. The real
/// biometric-gating behaviour (enrolment invalidation, actual prompt) is a
/// release-checklist item — see docs/spec/28_release_checklist.md RC-28+.
library;

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb_flutter/kmdb_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('FlutterBiometricKekProvider.obtainKek — idempotent get-or-create', () {
    test(
      'the first call creates a KEK; subsequent calls return the same one',
      () async {
        final provider = FlutterBiometricKekProvider(dbDir: '/path/to/db');

        final first = await provider.obtainKek();
        final second = await provider.obtainKek();
        final third = await provider.obtainKek();

        expect(second, equals(first));
        expect(third, equals(first));
      },
    );

    test(
      'a fresh provider instance for the same dbDir reuses the same KEK',
      () async {
        // Idempotency must survive process restarts (a new provider object),
        // not just repeated calls on the same instance — the wrap created at
        // enrolment must still unwrap after the app is killed and relaunched.
        final provider1 = FlutterBiometricKekProvider(dbDir: '/path/to/db');
        final kek1 = await provider1.obtainKek();

        final provider2 = FlutterBiometricKekProvider(dbDir: '/path/to/db');
        final kek2 = await provider2.obtainKek();

        expect(kek2, equals(kek1));
      },
    );

    test('the generated KEK is 32 bytes (256 bits)', () async {
      final provider = FlutterBiometricKekProvider(dbDir: '/path/to/db');
      final kek = await provider.obtainKek();
      expect(kek.length, equals(32));
    });

    test('two providers for distinct databases get distinct KEKs', () async {
      final providerA = FlutterBiometricKekProvider(dbDir: '/path/to/db-a');
      final providerB = FlutterBiometricKekProvider(dbDir: '/path/to/db-b');

      final kekA = await providerA.obtainKek();
      final kekB = await providerB.obtainKek();

      expect(kekA, isNot(equals(kekB)));
    });

    test(
      'successive fresh KEKs (distinct databases) are not trivially related',
      () async {
        // Not a rigorous randomness test — just a smoke check that
        // Random.secure() is actually being used (not e.g. an all-zero stub).
        final keks = <Uint8List>[];
        for (var i = 0; i < 5; i++) {
          final provider = FlutterBiometricKekProvider(dbDir: '/db-$i');
          keks.add(await provider.obtainKek());
        }
        final distinct = keks.map((k) => String.fromCharCodes(k)).toSet();
        expect(distinct.length, equals(keks.length));
      },
    );
  });
}
