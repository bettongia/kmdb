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

import 'dart:typed_data';

import '../util/xxhash.dart';
import 'lsm_engine.dart';

/// Access to the `$meta` system namespace.
///
/// Provides named helpers for the pieces of engine state stored in `$meta`:
///
/// - **Generation counters** (`gen:{namespace}`) — incremented on every write
///   to a user namespace. The Cache Layer reads these to detect stale cached
///   query results.
/// - **Dirty-open flag** (`dirty`) — written on the first user write after
///   open; cleared on clean close. If set on next open, it means the previous
///   session ended abruptly (crash or process kill), and secondary indexes may
///   need to be rebuilt.
/// - **Device identity** (`device_id`) — the stable 8-character lowercase hex
///   identifier used in SSTable filenames.
///
/// All writes go directly to [LsmEngine], bypassing the `$` namespace guard in
/// [KvStoreImpl] (which is intentional — these are internal writes). All
/// writes therefore go through the WAL as required by the spec.
///
/// ## Key encoding
///
/// Meta keys are symbolic names (e.g. `gen:tasks`, `dirty`). They are encoded
/// as deterministic 32-character hex strings via a two-seed XXH64 hash, which
/// matches the 16-byte key format the LSM engine requires. Collision probability
/// across the ~100 distinct names `$meta` will ever hold is negligible.
final class MetaStore {
  /// Creates a [MetaStore] that reads and writes through [engine].
  const MetaStore(this._engine);

  final LsmEngine _engine;

  /// The system namespace for all meta values.
  static const String kNamespace = r'$meta';

  // ── Generation counters ──────────────────────────────────────────────────

  /// Returns the current generation counter for [userNamespace], or 0 if not
  /// yet set.
  ///
  /// The Cache Layer compares this value against a cached snapshot to decide
  /// whether to evict stale entries.
  Future<int> getGenerationCounter(String userNamespace) async {
    final bytes = await _engine.get(kNamespace, _genKey(userNamespace));
    if (bytes == null || bytes.length < 8) return 0;
    return ByteData.sublistView(bytes).getUint64(0, Endian.big);
  }

  /// Increments and persists the generation counter for [userNamespace].
  ///
  /// Called by [KvStoreImpl] after each successful user write. Returns the
  /// new counter value.
  Future<int> incrementGenerationCounter(String userNamespace) async {
    final current = await getGenerationCounter(userNamespace);
    final next = current + 1;
    await _engine.put(kNamespace, _genKey(userNamespace), _encodeUint64(next));
    return next;
  }

  /// Returns the `$meta` key for the generation counter of [userNamespace].
  ///
  /// Exposed for tests that need to verify the key exists directly.
  static String genKey(String userNamespace) => _genKey(userNamespace);

  static String _genKey(String userNamespace) => _nameToKey('gen:$userNamespace');

  // ── Dirty-open flag ────────────────────────────────────────────────────────

  /// Returns `true` if the dirty-open flag is set in `$meta`.
  ///
  /// A set flag means the previous session did not call [close] cleanly —
  /// either the process was killed or the machine lost power after at least one
  /// write. Secondary indexes for any namespace written in that session may be
  /// stale.
  Future<bool> getDirtyFlag() async {
    final bytes = await _engine.get(kNamespace, _nameToKey('dirty'));
    return bytes != null && bytes.isNotEmpty && bytes[0] != 0;
  }

  /// Writes the dirty-open flag to `$meta`.
  ///
  /// Called by [KvStoreImpl] on the first user write after open (§17, step 8).
  /// The flag is written lazily so read-only sessions never mark the database
  /// dirty.
  Future<void> setDirty() =>
      _engine.put(kNamespace, _nameToKey('dirty'), Uint8List.fromList([1]));

  /// Deletes the dirty-open flag. Called by [KvStoreImpl.close].
  Future<void> clearDirty() => _engine.delete(kNamespace, _nameToKey('dirty'));

  // ── Device ID ──────────────────────────────────────────────────────────────

  /// Returns the stored 8-character device ID, or `null` if not yet set.
  Future<String?> getDeviceId() async {
    final bytes = await _engine.get(kNamespace, _nameToKey('device_id'));
    if (bytes == null) return null;
    return String.fromCharCodes(bytes);
  }

  /// Stores [deviceId] persistently in `$meta`.
  ///
  /// [deviceId] must be an 8-character lowercase hex string.
  Future<void> putDeviceId(String deviceId) => _engine.put(
        kNamespace,
        _nameToKey('device_id'),
        Uint8List.fromList(deviceId.codeUnits),
      );

  // ── Index state ────────────────────────────────────────────────────────────

  /// Returns the `$meta` key for the index state entry of [namespace]/[path].
  ///
  /// Exposed so the Query Layer can locate the raw bytes without going through
  /// the full index-state helpers when that is sufficient.
  static String indexKey(String namespace, String path) =>
      _nameToKey('index:$namespace:$path');

  /// Reads the raw bytes stored under the symbolic [name] in `$meta`.
  ///
  /// Used by the Query Layer to persist and retrieve index state without
  /// accessing the engine's private fields directly.
  Future<Uint8List?> getRawByName(String name) =>
      _engine.get(kNamespace, _nameToKey(name));

  /// Writes [bytes] under the symbolic [name] in `$meta`.
  ///
  /// Used by the Query Layer to persist index state atomically.
  Future<void> putRawByName(String name, Uint8List bytes) =>
      _engine.put(kNamespace, _nameToKey(name), bytes);

  // ── Key encoding ───────────────────────────────────────────────────────────

  /// Encodes a symbolic [name] as a deterministic 32-character hex key.
  ///
  /// Two independent XXH64 digests (seeds 0 and 1) are concatenated to produce
  /// 16 bytes (32 hex chars). This matches the LSM engine's fixed-width key
  /// format and provides ample collision resistance for the small number of
  /// distinct meta keys in use.
  static String _nameToKey(String name) {
    final data = Uint8List.fromList(name.codeUnits);
    final h1 = XxHash64.digest(data, seed: 0);
    final h2 = XxHash64.digest(data, seed: 1);
    final bytes = Uint8List(16);
    final bd = ByteData.sublistView(bytes);
    bd.setInt64(0, h1, Endian.big);
    bd.setInt64(8, h2, Endian.big);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── Value encoding ─────────────────────────────────────────────────────────

  /// Encodes [value] as a big-endian 8-byte unsigned integer.
  static Uint8List _encodeUint64(int value) {
    final bytes = Uint8List(8);
    // setUint64 writes 8 bytes treating value as unsigned; safe for generation
    // counters which are small positive integers.
    ByteData.sublistView(bytes).setUint64(0, value, Endian.big);
    return bytes;
  }
}
