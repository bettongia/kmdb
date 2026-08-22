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

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kmdb/kmdb.dart';

/// Length in bytes of the KEK this provider creates — matches
/// `KeyDerivation.kKekLength` (32 bytes / 256 bits) in `kmdb` core, kept as a
/// local constant rather than importing an internal core symbol.
const int _kKekLength = 32;

/// Native [BiometricKekProvider] implementation for the unlock-policy
/// wrapped-DEK model (WI-5, closing SC-1), backed by [FlutterSecureStorage].
///
/// ## Idempotent get-or-create ([obtainKek])
///
/// The first call for a given [dbDir] generates a fresh random 32-byte KEK
/// and stores it in platform-secured storage; every subsequent call reads
/// and returns the **same** KEK (see [BiometricKekProvider]'s doc comment for
/// why this matters — enrol and unlock must derive the same key or
/// `unwrapDek` fails). Reading a biometric-gated item is what triggers the
/// platform authentication prompt; writing (creation) does not necessarily
/// prompt, since the OS evaluates the access-control policy on *read*, not on
/// *write*.
///
/// ## Platform support
///
/// - **iOS / macOS:** the KEK item is stored in the Keychain with
///   `accessControlFlags: [AccessControlFlag.biometryCurrentSet]` —
///   reading it requires currently-enrolled biometrics (Face ID / Touch ID),
///   restricted with [KeychainAccessibility.first_unlock_this_device] so the
///   item is available after the first unlock following a reboot but never
///   synced via iCloud Keychain.
/// - **Android:** `AndroidOptions.biometric(enforceBiometrics: true,
///   biometricType: AndroidBiometricType.strongBiometricOnly)` — the
///   KeyStore-backed AES-GCM key requires `setUserAuthenticationRequired`,
///   so reading it prompts for a Class 3 (strong) biometric.
/// - **Windows / Linux:** `flutter_secure_storage` has **no biometric-gating
///   option** on these platforms (`WindowsOptions`/`LinuxOptions` carry no
///   equivalent of `accessControlFlags`/`enforceBiometrics`). The KEK is
///   still stored securely (DPAPI on Windows, the platform keyring/fallback
///   on Linux) but reading it does **not** prompt for biometric
///   authentication — it is gated only by OS login. `EncryptionConfig`
///   callers on these platforms should prefer the passphrase path; this
///   provider still functions (get-or-create, `unwrapDek` succeeds) but does
///   not deliver the coercion-resistance property the biometric path exists
///   for. This is an explicit, documented limitation — see §31.
///
/// ## Enrolment-invalidation
///
/// Adding or removing a fingerprint/face invalidates the OS-level access
/// control policy on iOS/macOS/Android — the next [obtainKek] read then
/// fails (the platform refuses to release the item), which surfaces to core
/// as [EncryptionErrorCode.biometricUnavailable] (the wrap can no longer be
/// unwrapped, so `_unwrapBiometric` in `kmdb`'s bootstrap treats it as
/// unavailable and the caller falls back to the passphrase — see
/// `KmdbDatabase.enableBiometricUnlock`'s doc comment for the "reconfigure
/// after invalidation" flow). This is automatic auto-disable semantics — no
/// explicit invalidation handling is needed in this class.
final class FlutterBiometricKekProvider implements BiometricKekProvider {
  /// Creates a [FlutterBiometricKekProvider] scoped to the database at
  /// [dbDir] — the same path passed to `KmdbDatabase.open(path:)`.
  ///
  /// Supply [iosOptions]/[macosOptions]/[androidOptions] to override the
  /// secure-by-default biometric-gating options (e.g. to customize the
  /// Android biometric prompt title). [windowsOptions]/[linuxOptions] have no
  /// biometric-gating equivalent (see the class doc comment) and default to
  /// the plain platform defaults.
  FlutterBiometricKekProvider({
    required String dbDir,
    FlutterSecureStorage? storage,
    IOSOptions? iosOptions,
    MacOsOptions? macosOptions,
    AndroidOptions? androidOptions,
    WindowsOptions? windowsOptions,
    LinuxOptions? linuxOptions,
  }) : _storageKey = dbScopedSecretKey(dbDir, 'kek.biometric'),
       _storage = storage ?? const FlutterSecureStorage(),
       _iosOptions =
           iosOptions ??
           const IOSOptions(
             accessibility: KeychainAccessibility.first_unlock_this_device,
             accessControlFlags: [AccessControlFlag.biometryCurrentSet],
           ),
       _macosOptions =
           macosOptions ??
           const MacOsOptions(
             accessibility: KeychainAccessibility.first_unlock_this_device,
             accessControlFlags: [AccessControlFlag.biometryCurrentSet],
           ),
       _androidOptions =
           androidOptions ??
           const AndroidOptions.biometric(
             enforceBiometrics: true,
             biometricType: AndroidBiometricType.strongBiometricOnly,
           ),
       _windowsOptions = windowsOptions ?? const WindowsOptions(),
       _linuxOptions = linuxOptions ?? const LinuxOptions();

  /// The `flutter_secure_storage` key for this database's biometric KEK.
  /// Derived via [dbScopedSecretKey] so distinct databases on the same device
  /// never collide (mirrors the per-device `SecretStore` scoping core uses
  /// for the biometric-wrapped DEK itself).
  final String _storageKey;

  final FlutterSecureStorage _storage;
  final IOSOptions _iosOptions;
  final MacOsOptions _macosOptions;
  final AndroidOptions _androidOptions;
  final WindowsOptions _windowsOptions;
  final LinuxOptions _linuxOptions;

  @override
  Future<Uint8List> obtainKek() async {
    final existing = await _storage.read(
      key: _storageKey,
      iOptions: _iosOptions,
      mOptions: _macosOptions,
      aOptions: _androidOptions,
      wOptions: _windowsOptions,
      lOptions: _linuxOptions,
    );
    if (existing != null) {
      return _decode(existing);
    }

    // Get-or-create: no item yet for this database — generate a fresh random
    // KEK and persist it under the biometric-gated item. This is the
    // "enrol" half of the idempotent contract; the caller (core's
    // KmdbDatabase.enableBiometricUnlock) then wraps the DEK under the KEK
    // this call returns.
    final kek = _generateRandomKek();
    await _storage.write(
      key: _storageKey,
      value: _encode(kek),
      iOptions: _iosOptions,
      mOptions: _macosOptions,
      aOptions: _androidOptions,
      wOptions: _windowsOptions,
      lOptions: _linuxOptions,
    );
    return kek;
  }

  /// Generates a cryptographically-random 32-byte KEK using [Random.secure].
  static Uint8List _generateRandomKek() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_kKekLength, (_) => random.nextInt(256)),
    );
  }

  /// Encodes [kek] as base64url (no padding) for storage as a
  /// `flutter_secure_storage` string value.
  static String _encode(Uint8List kek) =>
      base64Url.encode(kek).replaceAll('=', '');

  /// Decodes a KEK previously encoded by [_encode], restoring `=` padding as
  /// needed for [base64Url] to accept it.
  static Uint8List _decode(String value) {
    final remainder = value.length % 4;
    final padded = remainder == 0
        ? value
        : value.padRight(value.length + (4 - remainder), '=');
    return Uint8List.fromList(base64Url.decode(padded));
  }
}
