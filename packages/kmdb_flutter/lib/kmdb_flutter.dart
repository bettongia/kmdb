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

/// Flutter add-on package for KMDB.
///
/// Provides Flutter-specific capabilities that cannot live in the pure-Dart
/// `kmdb` package without pulling the Flutter SDK into its dependency graph:
///
/// 1. [KmdbFlutter.initialize()] — registers `cryptography_flutter` to enable
///    hardware-accelerated AES-256-GCM and Argon2id on iOS and Android.
///    Call once in `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
///
/// 2. [FlutterBiometricKekProvider] — a native `BiometricKekProvider`
///    implementation for the unlock-policy wrapped-DEK model (WI-5, closing
///    SC-1) — biometric-gated unlock backed by `flutter_secure_storage`'s
///    `accessControlFlags: [AccessControlFlag.biometryCurrentSet]` (iOS /
///    macOS) or `AndroidOptions.biometric(enforceBiometrics: true)`
///    (Android). There is no persistent DEK session cache in this package
///    (or in `kmdb` core) any more: a warm cache that skipped credential
///    verification was SC-1 itself. Every unlock — passphrase, recovery
///    code, or biometric — is an authenticated unwrap; see
///    [EncryptionConfig.biometric] and `KmdbDatabase.enableBiometricUnlock`
///    in `kmdb`.
///
/// ## Quick start
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:kmdb/kmdb.dart';
/// import 'package:kmdb_flutter/kmdb_flutter.dart';
///
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   KmdbFlutter.initialize();   // enable native crypto acceleration
///
///   final db = await KmdbDatabase.open(
///     path: '/path/to/db',
///     adapter: adapter,
///     encryptionConfig: EncryptionConfig(passphrase: 'my-passphrase'),
///   );
///
///   // Optionally enrol biometric unlock (native platforms only):
///   await db.enableBiometricUnlock(
///     FlutterBiometricKekProvider(dbDir: '/path/to/db'),
///   );
///   // ...
///   runApp(MyApp(db: db));
/// }
/// ```
library;

export 'src/flutter_biometric_kek_provider.dart';
export 'src/kmdb_flutter_init.dart';
