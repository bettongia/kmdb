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

/// Caches an unwrapped DEK in platform-appropriate secure storage so the user
/// is not re-prompted for a passphrase on every app launch.
///
/// This is a pure-Dart seam. Concrete platform-backed implementations live
/// outside the `kmdb` package:
///
/// - **`kmdb_flutter`** provides `FlutterSecureDekCache`, backed by
///   `flutter_secure_storage` (Keychain on iOS/macOS, Keystore on Android).
/// - **`InMemoryDekCache`** (this file) is the default: it holds the DEK in
///   memory for the current process only. Suitable for CLI, tests, and web
///   (where the proposal mandates re-deriving the DEK per session).
///
/// ## Key format
///
/// The [dbId] is a stable identifier for the database (typically the device ID
/// or a hash of the database path). It is used to namespace keys in the
/// underlying secure storage so multiple databases can coexist.
///
/// ## Web behaviour
///
/// On the web platform, the DEK is **not** persisted between sessions. The
/// default [InMemoryDekCache] implements this: `store` writes to memory and
/// `read` returns the cached value only for the current process lifetime.
/// Flutter web apps that want longer-lived sessions should implement their own
/// `DekCache` over a suitable web secret-storage API.
///
/// ## Security note
///
/// The DEK is sensitive. Implementations must:
/// - Use platform secure storage (Keychain, Keystore) — not SharedPreferences
///   or local files.
/// - Clear the cached DEK when the user changes their passphrase
///   ([clear] is called automatically by `kmdb encryption change-passphrase`).
abstract interface class DekCache {
  /// Stores [dek] keyed by [dbId] in platform-appropriate secure storage.
  ///
  /// An existing entry for [dbId] is overwritten (used when the passphrase
  /// is changed and the DEK is re-wrapped).
  Future<void> store(String dbId, Uint8List dek);

  /// Returns the cached DEK for [dbId], or `null` if none is stored.
  ///
  /// A `null` result means the user must be prompted for their passphrase
  /// so that the DEK can be re-derived.
  Future<Uint8List?> read(String dbId);

  /// Removes the cached DEK for [dbId].
  ///
  /// Called automatically on `kmdb encryption change-passphrase` to invalidate
  /// the previously cached DEK. Also useful on sign-out or revoke-access flows.
  Future<void> clear(String dbId);
}

/// Default [DekCache] that holds the DEK in memory for the current process.
///
/// This implementation never writes to disk or any external store. The cached
/// DEK is lost when the process exits (or the [InMemoryDekCache] instance is
/// garbage-collected).
///
/// This is appropriate for:
/// - **CLI tools** — short-lived; the passphrase is supplied once per
///   invocation.
/// - **Tests** — no persistent side effects between test runs.
/// - **Web** — the proposal requires re-deriving the DEK per session on web
///   (platform secure storage is not available in browsers).
///
/// Flutter mobile/desktop apps should inject a `FlutterSecureDekCache` from
/// the `kmdb_flutter` add-on package so the DEK survives app restarts without
/// re-prompting the user.
final class InMemoryDekCache implements DekCache {
  final Map<String, Uint8List> _cache = {};

  @override
  Future<void> store(String dbId, Uint8List dek) async {
    _cache[dbId] = Uint8List.fromList(dek);
  }

  @override
  Future<Uint8List?> read(String dbId) async {
    final cached = _cache[dbId];
    // Return a defensive copy so the caller cannot mutate the cached value.
    return cached != null ? Uint8List.fromList(cached) : null;
  }

  @override
  Future<void> clear(String dbId) async {
    _cache.remove(dbId);
  }
}
