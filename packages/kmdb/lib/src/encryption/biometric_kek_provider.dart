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

/// @docImport 'kek_source.dart';
/// @docImport 'package:kmdb/src/query/kmdb_database.dart';

/// Releases a biometric-gated Key Encryption Key (KEK) for the unlock-policy
/// wrapped-DEK model (WI-5, closing SC-1).
///
/// A [BiometricKekProvider] is a thin platform seam: it never sees or
/// produces the DEK itself, only a KEK — the core unlock path
/// (`KmdbDatabase._runEncryptionBootstrap`) calls
/// `KeyDerivation.unwrapDek(wrappedDekBiometric, kek)` with the value
/// [obtainKek] returns, preserving the single authenticated-unwrap
/// chokepoint. Platform code (e.g. `kmdb_flutter`'s implementation backed by
/// `flutter_secure_storage`) never handles the DEK directly.
///
/// ## Idempotent get-or-create contract
///
/// [obtainKek] **must** be idempotent per db-scoped identity: it creates the
/// underlying platform-secured KEK item on first use (during
/// [KmdbDatabase.enableBiometricUnlock] enrolment) and returns the **same**
/// KEK on every subsequent call (during unlock via a [KEKSource.biometric]
/// config). If a call generated a fresh KEK every time, the KEK used to wrap
/// the DEK at enrolment would differ from the KEK obtained at unlock, and
/// `unwrapDek` would fail on every biometric open. Enrolment-invalidation
/// (e.g. adding a new fingerprint under a `biometryCurrentSet`-gated item)
/// destroying the underlying platform item is what gives the "biometric
/// auto-disables and the passphrase is required to reconfigure" semantics —
/// the next [obtainKek] call after invalidation must either recreate the item
/// (a *different* KEK, so unwrap correctly fails) or throw; either way, the
/// caller falls back to the passphrase path.
///
/// Each call to [obtainKek] should trigger a fresh platform biometric
/// authentication prompt (e.g. Face ID / Touch ID / Android biometric
/// prompt) — this is what makes the KEK "biometric-gated" rather than merely
/// device-bound.
abstract interface class BiometricKekProvider {
  /// Returns the 32-byte KEK for this database, prompting for biometric
  /// authentication.
  ///
  /// Creates the underlying platform-secured KEK on first use (get-or-create
  /// — see the class doc comment) and returns the same KEK thereafter, until
  /// the platform invalidates it (e.g. biometric enrolment change).
  ///
  /// Implementations should throw on authentication failure or cancellation
  /// rather than returning a placeholder value.
  Future<Uint8List> obtainKek();
}
