// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:uuid/uuid.dart';

/// Generates the stable 8-character device identifier used in SSTable
/// filenames.
///
/// The device ID is persisted solely in the local `DEVICE_ID` file (see
/// `KvStoreImpl.ensureDeviceId`) — never in `$meta`, because `$meta`
/// replicates via synced SSTables and a Last-Write-Wins read of a
/// replicated key could resolve to a peer's identity rather than this
/// device's own (the SC-5 defect; see the attribute registry's `device_id`
/// entry). [generate] is a pure generator with no persistence side effect;
/// callers are responsible for storing the result.
///
/// ## Identity format
///
/// The ID is the first 8 characters of a hyphen-stripped UUID v4 string
/// (purely random). Using the random portion of a UUID rather than a
/// timestamp prefix ensures uniqueness even when multiple databases are
/// opened for the first time within the same millisecond — a common
/// scenario in tests and CLI demos.
///
/// Example: `'a3f2b1c9'`
///
/// ## Platform-specific storage
///
/// Full platform-specific secure storage (iOS Keychain, Android
/// SharedPreferences, etc.) is deferred to Phase 8. For now the `DEVICE_ID`
/// file is the sole persistence mechanism.
abstract final class DeviceId {
  DeviceId._();

  /// Generates a fresh 8-character lowercase hex device ID.
  ///
  /// Returns a new value on every call — it does not check or persist
  /// anything. Callers that need a stable per-database identity (e.g.
  /// `KvStoreImpl.ensureDeviceId`) must first check for an existing stored
  /// value and only call this when none is found, then persist the result
  /// themselves.
  ///
  /// Example:
  /// ```dart
  /// final id = DeviceId.generate();
  /// // id == 'a3f2b1c9'  (or similar UUIDv4 prefix)
  /// ```
  static String generate() {
    // Generate a new 8-char ID from the random portion of a UUID. UUIDv4 is
    // used rather than the timestamp prefix of a UUIDv7 because multiple
    // databases opened within the same millisecond (common in tests and CLI
    // demos) would otherwise receive identical IDs — the top 32 bits of a
    // UUIDv7 timestamp change only every ~65 seconds. A random UUID gives
    // ~4 billion values in 4 bytes, making same-millisecond collisions
    // negligibly unlikely.
    return const Uuid().v4().replaceAll('-', '').substring(0, 8);
  }
}
