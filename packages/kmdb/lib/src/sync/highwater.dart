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

import 'dart:convert';
import 'dart:typed_data';

import '../engine/util/hlc.dart';
import 'cloud/cloud_adapter.dart';

/// Per-device high-water mark (HWM) persisted in the sync folder.
///
/// Each device writes one `.hwm` file to `{syncRoot}/highwater/{deviceId}.hwm`.
/// The file tracks:
///
/// - The device's own current HLC ([currentHlc]), updated after each push.
/// - The highest HLC the device has processed for each peer ([peers]), updated
///   after each successful pull of a peer's SSTables.
///
/// These values allow pull to skip SSTables the local device has already
/// ingested (i.e., those whose HLC ≤ the recorded peer HWM).
///
/// ## File format
///
/// The `.hwm` file is a JSON document:
/// ```json
/// {
///   "deviceId": "a1b2c3d4",
///   "currentHlc": "017F8A0B3000",
///   "lastUpdated": "2026-03-27T10:30:00.000Z",
///   "peers": {
///     "f9e8d7c6": "017F8A0B2FFF",
///     "1a2b3c4d": "017F8A0A0000"
///   }
/// }
/// ```
///
/// HLC strings are the 12-character physical-only hex format (via
/// [Hlc.toPhysicalHex]), read back with [Hlc.fromHex].
///
/// ## Immutability
///
/// [HighwaterMark] is immutable. Methods that produce a modified HWM return a
/// new instance ([withPeer], [withCurrentHlc]).
final class HighwaterMark {
  /// Creates a [HighwaterMark].
  const HighwaterMark({
    required this.deviceId,
    required this.currentHlc,
    required this.lastUpdated,
    required this.peers,
  });

  /// The 8-character device identifier owning this HWM file.
  final String deviceId;

  /// The device's own current HLC at the time this HWM was last saved.
  final Hlc currentHlc;

  /// Wall-clock UTC timestamp of the last save (used for staleness detection).
  final DateTime lastUpdated;

  /// Mapping from peer device ID to the highest HLC the local device has
  /// processed from that peer's SSTables.
  final Map<String, Hlc> peers;

  // ── Factory: load from sync folder ───────────────────────────────────────

  /// Loads the HWM for the device at [path] from the [adapter].
  ///
  /// Returns `null` if no HWM file exists for this device yet (i.e. first
  /// push from this device). Throws [FormatException] if the file exists but
  /// cannot be parsed.
  static Future<HighwaterMark?> load(String path, CloudAdapter adapter) async {
    final bytes = await adapter.download(path);
    if (bytes == null) return null;
    return _parse(bytes, path);
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Serialises this HWM to JSON and uploads it to [path] via [adapter].
  Future<void> save(String path, CloudAdapter adapter) async {
    final map = {
      'deviceId': deviceId,
      'currentHlc': currentHlc.toPhysicalHex(),
      'lastUpdated': lastUpdated.toUtc().toIso8601String(),
      'peers': {
        for (final entry in peers.entries)
          entry.key: entry.value.toPhysicalHex(),
      },
    };
    final json = jsonEncode(map);
    await adapter.upload(path, Uint8List.fromList(utf8.encode(json)));
  }

  // ── Derived instances ─────────────────────────────────────────────────────

  /// Returns a new [HighwaterMark] with the peer entry for [peerId] set to
  /// [hlc], or updated if it is higher than the existing value.
  ///
  /// The [lastUpdated] timestamp is preserved — call [withCurrentHlc] when
  /// saving to update the timestamp.
  HighwaterMark withPeer(String peerId, Hlc hlc) {
    final updated = Map<String, Hlc>.from(peers);
    final existing = updated[peerId];
    if (existing == null || hlc > existing) {
      updated[peerId] = hlc;
    }
    return HighwaterMark(
      deviceId: deviceId,
      currentHlc: currentHlc,
      lastUpdated: lastUpdated,
      peers: Map.unmodifiable(updated),
    );
  }

  /// Returns a new [HighwaterMark] with [currentHlc] updated to [hlc] and
  /// [lastUpdated] advanced to [now] (default: [DateTime.now]).
  ///
  /// Call this before [save] to stamp the update time.
  HighwaterMark withCurrentHlc(Hlc hlc, {DateTime? now}) {
    return HighwaterMark(
      deviceId: deviceId,
      currentHlc: hlc,
      lastUpdated: (now ?? DateTime.now()).toUtc(),
      peers: peers,
    );
  }

  // ── Staleness check ───────────────────────────────────────────────────────

  /// Returns `true` if [peerId] is considered stale.
  ///
  /// For Phase 5 this is a simplified check:
  /// - If [peerId] is not in [peers], returns `true` (never seen this peer).
  /// - Otherwise, returns `false` (full stale detection via peer HWM file
  ///   timestamps is implemented in Phase 8).
  ///
  /// The [staleness] duration parameter is reserved for future use.
  bool isPeerStale(
    String peerId, {
    Duration staleness = const Duration(days: 90),
  }) {
    // Phase 5: consider a peer stale only if we have never recorded its HWM.
    // Full staleness detection (comparing lastUpdated across HWM files) is
    // deferred to Phase 8 when the full sync manager is implemented.
    return !peers.containsKey(peerId);
  }

  // ── Serialisation helpers ─────────────────────────────────────────────────

  /// Parses a [HighwaterMark] from [bytes] at [path] (for error messages).
  static HighwaterMark _parse(Uint8List bytes, String path) {
    final String jsonStr;
    try {
      jsonStr = utf8.decode(bytes);
    } catch (e) {
      throw FormatException('HWM file is not valid UTF-8 at $path: $e');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (e) {
      throw FormatException('HWM file is not valid JSON at $path: $e');
    }

    if (decoded is! Map<String, dynamic>) {
      throw FormatException('HWM file must be a JSON object at $path');
    }

    final deviceId = decoded['deviceId'] as String?;
    final currentHlcStr = decoded['currentHlc'] as String?;
    final lastUpdatedStr = decoded['lastUpdated'] as String?;
    final peersRaw = decoded['peers'] as Map<String, dynamic>?;

    if (deviceId == null || currentHlcStr == null || lastUpdatedStr == null) {
      throw FormatException(
        'HWM file missing required fields (deviceId, currentHlc, lastUpdated) at $path',
      );
    }

    final Hlc currentHlc;
    try {
      currentHlc = Hlc.fromHex(currentHlcStr);
    } catch (e) {
      throw FormatException('HWM currentHlc is invalid at $path: $e');
    }

    final DateTime lastUpdated;
    try {
      lastUpdated = DateTime.parse(lastUpdatedStr).toUtc();
    } catch (e) {
      throw FormatException('HWM lastUpdated is invalid at $path: $e');
    }

    final peers = <String, Hlc>{};
    if (peersRaw != null) {
      for (final entry in peersRaw.entries) {
        try {
          peers[entry.key] = Hlc.fromHex(entry.value as String);
        } catch (e) {
          throw FormatException(
            'HWM peer HLC invalid for "${entry.key}" at $path: $e',
          );
        }
      }
    }

    return HighwaterMark(
      deviceId: deviceId,
      currentHlc: currentHlc,
      lastUpdated: lastUpdated,
      peers: Map.unmodifiable(peers),
    );
  }

  @override
  String toString() =>
      'HighwaterMark(deviceId: $deviceId, currentHlc: ${currentHlc.toPhysicalHex()}, '
      'peers: ${peers.keys.join(", ")})';
}
