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

import 'package:cryptography_flutter/cryptography_flutter.dart';

/// Entry point for the `kmdb_flutter` add-on package.
///
/// Call [KmdbFlutter.initialize()] in `main()` after
/// `WidgetsFlutterBinding.ensureInitialized()` and before `runApp()`:
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   KmdbFlutter.initialize();
///   runApp(MyApp());
/// }
/// ```
///
/// This registers `cryptography_flutter` as the active [Cryptography]
/// implementation, enabling hardware-accelerated AES-256-GCM and Argon2id on
/// supported devices:
///
/// - **iOS:** Secure Enclave-backed AES-GCM.
/// - **Android:** Android Keystore / BoringSSL AES-GCM.
/// - **macOS / Linux / Windows:** background-isolate offload for Argon2id.
///
/// Without this call, `kmdb`'s encryption path uses the pure-Dart
/// `cryptography` implementation, which is correct but significantly slower
/// — Argon2id passphrase unlock can take several seconds on mobile.
///
/// ## Idempotency
///
/// [initialize] is safe to call more than once. A static guard ensures
/// `FlutterCryptography.enable()` is called at most once per process lifetime.
/// Repeat calls return immediately.
///
/// ## Note on Flutter auto-registration
///
/// As of `cryptography_flutter` 2.3.4, the plugin is auto-registered by
/// Flutter's generated plugin registrant, which means [FlutterCryptography]
/// becomes active even without an explicit `initialize()` call. Calling
/// [initialize] remains the recommended pattern because:
///
/// 1. It is explicit and documents the intent in `main()`.
/// 2. It ensures the plugin is active before any code that runs between
///    `WidgetsFlutterBinding.ensureInitialized()` and `runApp()`.
/// 3. It provides a stable call site for future additions (e.g. registering
///    `FlutterSecureDekCache` defaults, pre-warming the Argon2id isolate).
abstract final class KmdbFlutter {
  /// Whether [initialize] has been called for this process.
  static bool _initialized = false;

  /// Initializes the `kmdb_flutter` add-on.
  ///
  /// Registers [FlutterCryptography] as the active [Cryptography]
  /// implementation, enabling hardware-accelerated AES-256-GCM and Argon2id.
  ///
  /// Must be called after `WidgetsFlutterBinding.ensureInitialized()` and
  /// before `runApp()` for the acceleration to cover all operations including
  /// those triggered during app startup (e.g. encrypted database open).
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  // ignore: deprecated_member_use
  static void initialize() {
    if (_initialized) return;
    _initialized = true;
    // FlutterCryptography.enable() is marked @Deprecated in 2.3.4 because
    // Flutter auto-registers the plugin via the generated plugin registrant.
    // We still call it explicitly to:
    //   (a) ensure the plugin is active before any code between
    //       ensureInitialized() and runApp();
    //   (b) provide forward compatibility if auto-registration behaviour
    //       changes in future versions.
    // The method itself is safe and idempotent.
    // ignore: deprecated_member_use
    FlutterCryptography.enable();
  }

  /// Resets the initialization guard.
  ///
  /// This method exists for testing purposes only — it allows tests that
  /// call [initialize] to reset state between test runs.
  ///
  /// Do not call this in production code.
  // ignore: unused_element — used in tests via @visibleForTesting workaround
  static void resetForTesting() {
    _initialized = false;
  }
}
