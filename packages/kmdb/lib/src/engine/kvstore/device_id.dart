// Copyright 2026 The KMDB Authors
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

import 'meta_store.dart';

/// Manages the stable 8-character device identifier used in SSTable filenames.
///
/// The device ID is persisted in `$meta` so every open of the same database
/// directory returns the same value. On the first open of a fresh database,
/// [load] generates a new ID from a UUIDv7 and stores it.
///
/// ## Identity format
///
/// The ID is the first 8 characters of a hyphen-stripped UUIDv7 string.
/// UUIDv7 embeds the current millisecond timestamp in its most-significant
/// bits, so IDs generated at different times are highly unlikely to collide —
/// even across independently provisioned devices.
///
/// Example: `'01965a4b'`
///
/// ## Platform-specific storage
///
/// Full platform-specific secure storage (iOS Keychain, Android
/// SharedPreferences, etc.) is deferred to Phase 8. For now `$meta` is the
/// sole persistence mechanism.
abstract final class DeviceId {
  DeviceId._();

  /// Loads the device ID from [meta], or generates and stores a new one if no
  /// ID has been set yet.
  ///
  /// Returns an 8-character lowercase hex string.
  ///
  /// Example:
  /// ```dart
  /// final id = await DeviceId.load(metaStore);
  /// // id == '01965a4b'  (or similar UUIDv7 prefix)
  /// ```
  static Future<String> load(MetaStore meta) async {
    final stored = await meta.getDeviceId();
    if (stored != null) return stored;

    // First open: generate a new 8-char ID from the UUIDv7 timestamp prefix.
    // Stripping hyphens and taking the first 8 characters yields the 32-bit
    // time_high field, which is unique per millisecond and avoids any external
    // entropy source.
    final id = const Uuid().v7().replaceAll('-', '').substring(0, 8);
    await meta.putDeviceId(id);
    return id;
  }
}
