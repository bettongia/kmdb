import '../util/hlc.dart';

/// Parsed metadata from an SSTable filename.
///
/// Two filename formats are supported (distinguished by segment count after
/// splitting on `-`):
///
/// **Regular flush (3 segments):**
/// ```
/// {deviceId}-{minHlc}-{maxHlc}.sst
/// ```
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

  /// The bare filename (no directory path), e.g. `a1b2c3d4-017F8A0A0000-017F8A0AFFFF.sst`.
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
            'Invalid epoch "$epochStr" in SSTable filename: $filename');
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
        'SSTable filename must have 3 or 4 dash-separated segments: $filename');
  }

  // ── Generation ────────────────────────────────────────────────────────────

  /// Constructs a regular flush filename.
  ///
  /// ```
  /// {deviceId}-{minHlc}-{maxHlc}.sst
  /// ```
  static String flushName(String deviceId, Hlc minHlc, Hlc maxHlc) =>
      '$deviceId-${minHlc.toPhysicalHex()}-${maxHlc.toPhysicalHex()}.sst';

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
          'deviceId must be 8 characters, got "$id" in: $filename');
    }
    return id;
  }

  static Hlc _parseHlc(String hex, String filename) {
    try {
      return Hlc.fromHex(hex);
    } catch (_) {
      throw FormatException(
          'Invalid HLC hex "$hex" in SSTable filename: $filename');
    }
  }

  @override
  String toString() => 'SstableInfo($filename)';
}
