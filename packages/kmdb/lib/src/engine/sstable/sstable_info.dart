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

import '../util/hlc.dart';

/// Parsed metadata from an SSTable filename.
///
/// Two filename formats are supported (distinguished by segment count after
/// splitting on `-`):
///
/// **Regular flush (3 segments):**
/// ```
/// {deviceId}-{minHlc16}-{maxHlc16}.sst
/// ```
/// where `{minHlc16}` and `{maxHlc16}` are the full 64-bit HLC encoded as
/// 16 uppercase hex characters (physical + logical). Using the full HLC
/// prevents filename collisions when multiple flushes occur within the same
/// physical millisecond.
///
/// **Consolidation output (4 segments):**
/// ```
/// {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst
/// ```
///
/// See §8 for the full naming convention.
final class SstableInfo {
  const SstableInfo({
    required this.filename,
    required this.deviceId,
    required this.minHlc,
    required this.maxHlc,
    this.epoch,
  });

  /// The bare filename (no directory path), e.g. `a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst`.
  final String filename;

  /// The 8-character device identifier (truncated UUID hex, no hyphens).
  final String deviceId;

  /// The minimum HLC timestamp of any key in this SSTable.
  final Hlc minHlc;

  /// The maximum HLC timestamp of any key in this SSTable.
  final Hlc maxHlc;

  /// Consolidation epoch fencing token, or `null` for regular flush SSTables.
  final int? epoch;

  /// Whether this file was produced by a consolidation coordinator.
  bool get isConsolidation => epoch != null;

  // ── Parsing ──────────────────────────────────────────────────────────────

  /// Parses an SSTable filename into its component metadata.
  ///
  /// Throws [FormatException] if the filename does not match either expected
  /// format.
  static SstableInfo parse(String filename) {
    // Strip the `.sst` extension.
    if (!filename.endsWith('.sst')) {
      throw FormatException('SSTable filename must end with .sst: $filename');
    }
    final base = filename.substring(0, filename.length - 4);
    final parts = base.split('-');

    if (parts.length == 3) {
      // Regular flush: {deviceId}-{minHlc}-{maxHlc}
      return SstableInfo(
        filename: filename,
        deviceId: _validateDeviceId(parts[0], filename),
        minHlc: _parseHlc(parts[1], filename),
        maxHlc: _parseHlc(parts[2], filename),
      );
    }

    if (parts.length == 4) {
      // Consolidation: {deviceId}-{epoch}-{minHlc}-{maxHlc}
      final epochStr = parts[1];
      final epochVal = int.tryParse(epochStr);
      if (epochVal == null) {
        throw FormatException(
          'Invalid epoch "$epochStr" in SSTable filename: $filename',
        );
      }
      return SstableInfo(
        filename: filename,
        deviceId: _validateDeviceId(parts[0], filename),
        epoch: epochVal,
        minHlc: _parseHlc(parts[2], filename),
        maxHlc: _parseHlc(parts[3], filename),
      );
    }

    throw FormatException(
      'SSTable filename must have 3 or 4 dash-separated segments: $filename',
    );
  }

  // ── Generation ────────────────────────────────────────────────────────────

  /// Constructs a regular flush filename.
  ///
  /// Uses the full 16-character HLC hex (physical + logical) so that multiple
  /// flushes within the same physical millisecond produce distinct filenames.
  ///
  /// ```
  /// {deviceId}-{minHlc}-{maxHlc}.sst
  /// ```
  static String flushName(String deviceId, Hlc minHlc, Hlc maxHlc) =>
      '$deviceId-${minHlc.toHex()}-${maxHlc.toHex()}.sst';

  /// Constructs a consolidation output filename.
  ///
  /// ```
  /// {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst
  /// ```
  static String consolidationName(
    String deviceId,
    int epoch,
    Hlc minHlc,
    Hlc maxHlc,
  ) =>
      '$deviceId-$epoch-${minHlc.toPhysicalHex()}-${maxHlc.toPhysicalHex()}.sst';

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _validateDeviceId(String id, String filename) {
    if (id.length != 8) {
      throw FormatException(
        'deviceId must be 8 characters, got "$id" in: $filename',
      );
    }
    return id;
  }

  static Hlc _parseHlc(String hex, String filename) {
    try {
      return Hlc.fromHex(hex);
    } catch (_) {
      throw FormatException(
        'Invalid HLC hex "$hex" in SSTable filename: $filename',
      );
    }
  }

  @override
  String toString() => 'SstableInfo($filename)';
}
