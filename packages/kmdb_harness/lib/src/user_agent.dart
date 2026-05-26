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

import 'dart:math';

import 'actions.dart';
import 'config.dart';
import 'device.dart';

// ── Document size tier constants ──────────────────────────────────────────────

/// Approximate body length for the small document tier (~100 B encoded).
const int _smallBodyLength = 60;

/// Approximate body length for the medium document tier (~10 KB encoded).
const int _mediumBodyLength = 6000;

/// Approximate body length for the large document tier (~500 KB encoded).
const int _largeBodyLength = 300000;

// ── Key pool ─────────────────────────────────────────────────────────────────

/// The pool a key belongs to.
enum _KeyPool { shared, deviceLocal, hot }

/// A key together with its assigned pool type.
final class _PooledKey {
  const _PooledKey(this.key, this.pool);

  /// The document key string.
  final String key;

  /// The pool this key belongs to.
  final _KeyPool pool;
}

// ── Tag word pool ─────────────────────────────────────────────────────────────

const List<String> _tagWords = [
  'alpha',
  'beta',
  'gamma',
  'delta',
  'epsilon',
  'zeta',
  'eta',
  'theta',
  'iota',
  'kappa',
  'lambda',
  'mu',
  'nu',
  'xi',
  'omicron',
];

// ── UserAgent ─────────────────────────────────────────────────────────────────

/// Generates deterministic action sequences for the harness.
///
/// The [UserAgent] uses a seeded [Random] instance so that any failing run can
/// be replayed exactly by supplying the same [seed]. In fuzz mode ([seed] is
/// `null`), the seed is derived from the system clock at construction time and
/// stored in [effectiveSeed] for recording in the [HarnessReport].
///
/// The agent generates actions for a set of [Device] instances, choosing
/// action types weighted by the device's current FSM state. All document data
/// is produced using the fixed schema:
///
/// | Field    | Type             |
/// | -------- | ---------------- |
/// | `title`  | `String`         |
/// | `body`   | `String`         |
/// | `count`  | `int`            |
/// | `active` | `bool`           |
/// | `tags`   | `List<String>`   |
///
/// The `body` field length determines the document size tier (small/medium/large).
final class UserAgent {
  /// Creates a [UserAgent].
  ///
  /// [_config] supplies the key pool ratios, doc size distribution, device count,
  /// and collection count. [seed] is `null` for fuzz mode (clock-derived seed).
  UserAgent({required this._config, int? seed}) {
    effectiveSeed = seed ?? DateTime.now().millisecondsSinceEpoch;
    _rng = Random(effectiveSeed);
    _buildKeyPools();
  }

  final HarnessConfig _config;

  /// The PRNG seed actually used for this agent.
  ///
  /// In seeded mode this equals the supplied [seed]. In fuzz mode this is
  /// derived from the system clock at construction time and recorded in the
  /// [HarnessReport] for exact replay.
  late final int effectiveSeed;

  late final Random _rng;
  int _nextActionId = 1;

  /// All keys partitioned into their pools.
  final List<_PooledKey> _keys = [];

  /// Keys that are in the shared pool (all devices may write these).
  final List<String> _sharedKeys = [];

  /// Per-device-local keys, keyed by device index.
  final Map<int, List<String>> _deviceLocalKeys = {};

  /// Hot keys (small shared subset written at high frequency).
  final List<String> _hotKeys = [];

  // ── Key pool construction ─────────────────────────────────────────────────

  void _buildKeyPools() {
    // Total key budget: 10 keys per device per collection.
    final totalKeys = _config.deviceCount * _config.collectionCount * 10;
    final sharedCount = (totalKeys * _config.keyPoolRatios.shared / 100).ceil();
    final hotCount = (totalKeys * _config.keyPoolRatios.hot / 100).ceil();
    final deviceLocalCount =
        (totalKeys * _config.keyPoolRatios.deviceLocal / 100).ceil();

    // Shared keys (available to all devices).
    for (var i = 0; i < sharedCount; i++) {
      final key = _makeKey('shared', i);
      _sharedKeys.add(key);
      _keys.add(_PooledKey(key, _KeyPool.shared));
    }

    // Hot keys (small shared subset — derived from the shared pool).
    // Keys are also added to _keys with their pool tag for reporting purposes.
    for (var i = 0; i < hotCount && i < _sharedKeys.length; i++) {
      final key = _sharedKeys[i];
      _hotKeys.add(key);
      _keys.add(_PooledKey(key, _KeyPool.hot));
    }

    // Device-local keys.
    for (var d = 0; d < _config.deviceCount; d++) {
      final local = <String>[];
      for (var i = 0; i < deviceLocalCount; i++) {
        final key = _makeKey('dev${d}_local', i);
        local.add(key);
        _keys.add(_PooledKey(key, _KeyPool.deviceLocal));
      }
      _deviceLocalKeys[d] = local;
    }
  }

  /// Generates a stable, valid UUIDv7 hex key for the given pool and index.
  ///
  /// The key is 32 hex characters with version nibble = 7 (position 12) and
  /// variant nibble = 8 (position 16), satisfying [KeyCodec.keyToBytes]
  /// validation. The label hash and index are encoded in the random fields so
  /// keys are deterministic and unique per `(label, index)` pair.
  static String _makeKey(String label, int index) {
    // Fixed 48-bit millisecond timestamp prefix (epoch 0 in test space).
    const ts = '019000000000'; // 12 hex chars
    // Encode the 12-bit label hash into the 3 random bits after the version.
    final lh = (label.hashCode.abs() & 0xFFF).toRadixString(16).padLeft(3, '0');
    // Encode the index into the 15-char random tail.
    final ix = (index & 0x7FFFFFFFFFFFC).toRadixString(16).padLeft(15, '0');
    // Layout: ts(12) + '7'(1) + lh(3) + '8'(1) + ix(15) = 32 chars.
    // Pos 12 = '7' (UUIDv7 version), pos 16 = '8' (variant 10xxxxxx).
    return '${ts}7${lh}8$ix';
  }

  // ── Action generation ─────────────────────────────────────────────────────

  /// Returns the next sequential action ID.
  int _nextId() => _nextActionId++;

  /// Generates a [CreateDb] action for [deviceIndex].
  Action createDb(int deviceIndex) =>
      Action(id: _nextId(), deviceId: deviceIndex, type: ActionType.createDb);

  /// Generates a [CreateCollection] action for [deviceIndex].
  ///
  /// The collection name is derived deterministically from the device index
  /// and a counter so that all devices use the same set of collection names
  /// (enabling cross-device sync verification).
  Action createCollection(int deviceIndex, int collectionIndex) => Action(
    id: _nextId(),
    deviceId: deviceIndex,
    type: ActionType.createCollection,
    collectionName: 'col_$collectionIndex',
  );

  /// Generates the pre-seeding action sequence for [device].
  ///
  /// Pre-seeding writes one document per collection to the device before the
  /// run loop starts. The device must already be in [DeviceState.ready] state.
  List<Action> preSeedActions(int deviceIndex, int documentCount) {
    final actions = <Action>[];
    for (var i = 0; i < documentCount; i++) {
      final colIndex = i % _config.collectionCount;
      final key = _sharedKeys.isNotEmpty
          ? _sharedKeys[i % _sharedKeys.length]
          : _makeKey('preseed', i);
      actions.add(
        Action(
          id: _nextId(),
          deviceId: deviceIndex,
          type: ActionType.put,
          collectionName: 'col_$colIndex',
          key: key,
          document: _generateDocument(key),
        ),
      );
    }
    return actions;
  }

  /// Generates a single random action for [device] based on its FSM state.
  ///
  /// The action type is chosen to reflect what is valid for the device's
  /// current [DeviceState]. Actions that would be no-ops (e.g. put on an
  /// uninitialised device) are not generated — the FSM guard inside [Device]
  /// handles inapplicable actions, but generating them deliberately wastes
  /// cycles.
  Action generateAction(Device device) {
    final deviceIdx = device.deviceIndex;

    switch (device.state) {
      case DeviceState.uninitialised:
        return createDb(deviceIdx);

      case DeviceState.initialised:
        // Only createCollection is valid until at least one exists.
        return createCollection(deviceIdx, 0);

      case DeviceState.ready:
        return _generateReadyAction(device);
    }
  }

  Action _generateReadyAction(Device device) {
    final deviceIdx = device.deviceIndex;

    // Weight the action type selection.
    // Distribution: 40% put, 20% get, 10% delete, 20% sync, 10% partition.
    final roll = _rng.nextInt(100);
    final ActionType type;
    if (roll < 40) {
      type = ActionType.put;
    } else if (roll < 60) {
      type = ActionType.get;
    } else if (roll < 70) {
      type = ActionType.delete;
    } else if (roll < 90) {
      type = ActionType.sync;
    } else {
      type = ActionType.networkPartition;
    }

    // Pick a collection name.
    final colIndex = _rng.nextInt(_config.collectionCount);
    final collectionName = 'col_$colIndex';

    switch (type) {
      case ActionType.put:
        final key = _pickKey(deviceIdx);
        return Action(
          id: _nextId(),
          deviceId: deviceIdx,
          type: ActionType.put,
          collectionName: collectionName,
          key: key,
          document: _generateDocument(key),
        );

      case ActionType.get:
        final key = _pickKey(deviceIdx);
        return Action(
          id: _nextId(),
          deviceId: deviceIdx,
          type: ActionType.get,
          collectionName: collectionName,
          key: key,
        );

      case ActionType.delete:
        final key = _pickKey(deviceIdx);
        return Action(
          id: _nextId(),
          deviceId: deviceIdx,
          type: ActionType.delete,
          collectionName: collectionName,
          key: key,
        );

      case ActionType.sync:
        return Action(
          id: _nextId(),
          deviceId: deviceIdx,
          type: ActionType.sync,
        );

      case ActionType.networkPartition:
        // Toggle partition state.
        final activate = !device.isPartitioned;
        return Action(
          id: _nextId(),
          deviceId: deviceIdx,
          type: ActionType.networkPartition,
          partitioned: activate,
        );

      default:
        return Action(
          id: _nextId(),
          deviceId: deviceIdx,
          type: ActionType.sync,
        );
    }
  }

  /// Picks a document key for [deviceIndex], respecting pool membership.
  ///
  /// Hot keys are selected 30% of the time to exercise rapid-succession
  /// scenarios. Shared keys 40% of the time. Device-local keys otherwise.
  String _pickKey(int deviceIndex) {
    final roll = _rng.nextInt(100);
    if (roll < 30 && _hotKeys.isNotEmpty) {
      return _hotKeys[_rng.nextInt(_hotKeys.length)];
    } else if (roll < 70 && _sharedKeys.isNotEmpty) {
      return _sharedKeys[_rng.nextInt(_sharedKeys.length)];
    } else {
      final local = _deviceLocalKeys[deviceIndex];
      if (local != null && local.isNotEmpty) {
        return local[_rng.nextInt(local.length)];
      }
      // Fallback to shared if no local keys are available.
      if (_sharedKeys.isNotEmpty) {
        return _sharedKeys[_rng.nextInt(_sharedKeys.length)];
      }
      return _makeKey('fallback', deviceIndex);
    }
  }

  // ── Document generation ───────────────────────────────────────────────────

  /// Generates a document using the fixed harness schema.
  ///
  /// The document size tier is sampled from [DocSizeDistribution] probabilities.
  /// The Large tier uses an extended `body` string to reach ~500 KB without
  /// any Vault or blob interaction.
  Map<String, dynamic> _generateDocument(String key) {
    final tier = _sampleTier();
    final bodyLength = switch (tier) {
      _SizeTier.small => _smallBodyLength,
      _SizeTier.medium => _mediumBodyLength,
      _SizeTier.large => _largeBodyLength,
    };

    final tagCount = _rng.nextInt(6); // 0–5 tags
    final tags = List.generate(tagCount, (_) {
      return _tagWords[_rng.nextInt(_tagWords.length)];
    });

    return {
      'title': _randomWord(8),
      'body': _randomString(bodyLength),
      'count': _rng.nextInt(100000),
      'active': _rng.nextBool(),
      'tags': tags,
    };
  }

  _SizeTier _sampleTier() {
    final roll = _rng.nextInt(100);
    final d = _config.docSizeDistribution;
    if (roll < d.small) return _SizeTier.small;
    if (roll < d.small + d.medium) return _SizeTier.medium;
    return _SizeTier.large;
  }

  /// Generates a random ASCII word of approximately [length] characters.
  String _randomWord(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz';
    return String.fromCharCodes(
      List.generate(
        length,
        (_) => chars.codeUnitAt(_rng.nextInt(chars.length)),
      ),
    );
  }

  /// Generates a random ASCII string of [length] characters.
  ///
  /// Uses a repeating random-word pattern for compressibility, keeping
  /// encoded sizes predictable across compression-enabled platforms.
  String _randomString(int length) {
    if (length <= 0) return '';
    final buf = StringBuffer();
    while (buf.length < length) {
      buf.write(_randomWord(16));
      buf.write(' ');
    }
    return buf.toString().substring(0, length);
  }
}

/// Document size tier.
enum _SizeTier { small, medium, large }
