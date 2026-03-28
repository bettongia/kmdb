/// Hybrid Logical Clock timestamp.
///
/// An [Hlc] encodes a 64-bit value split into two fields:
/// - **Upper 48 bits**: physical wall-clock time in milliseconds since Unix epoch.
/// - **Lower 16 bits**: logical counter, incremented when multiple events share
///   the same physical millisecond.
///
/// HLC timestamps are used on WAL records, SSTable entries, and `.hwm` files.
/// They provide a causally-consistent ordering across devices without requiring
/// a central time server: a message recipient advances their clock to be at
/// least as recent as the sender's timestamp.
///
/// Reference: Kulkarni et al., "Logical Physical Clocks and Consistent
/// Snapshots in Globally Distributed Databases", HotDep 2014.
final class Hlc implements Comparable<Hlc> {
  /// Creates an [Hlc] from its component parts.
  ///
  /// [physicalMs] must fit in 48 bits (≤ 281474976710655).
  /// [logical] must fit in 16 bits (≤ 65535).
  const Hlc(this.physicalMs, this.logical)
      : assert(physicalMs >= 0 && physicalMs <= 0xFFFFFFFFFFFF,
            'physicalMs must fit in 48 bits'),
        assert(logical >= 0 && logical <= 0xFFFF,
            'logical counter must fit in 16 bits');

  /// Physical wall-clock component, milliseconds since Unix epoch (48-bit).
  final int physicalMs;

  /// Logical counter component (16-bit). Breaks ties within the same
  /// physical millisecond.
  final int logical;

  // ── Encoding ──────────────────────────────────────────────────────────────

  /// Packs the HLC into a single 64-bit integer: `(physicalMs << 16) | logical`.
  ///
  /// Used as the WAL record sequence field (8 bytes, big-endian).
  int get encoded => (physicalMs << 16) | logical;

  /// Decodes a packed 64-bit [encoded] value back into an [Hlc].
  static Hlc fromEncoded(int encoded) => Hlc(
        (encoded >>> 16) & 0xFFFFFFFFFFFF, // upper 48 bits
        encoded & 0xFFFF, // lower 16 bits
      );

  /// Parses a 16-character uppercase hex string (the full 64-bit encoding).
  ///
  /// Also accepts 12-character strings (physical-only, logical defaults to 0),
  /// which is the format used in SSTable filenames.
  static Hlc fromHex(String hex) {
    if (hex.length == 12) {
      return Hlc(int.parse(hex, radix: 16), 0);
    }
    if (hex.length == 16) {
      final encoded = int.parse(hex, radix: 16);
      return fromEncoded(encoded);
    }
    throw FormatException('HLC hex must be 12 or 16 characters, got ${hex.length}');
  }

  /// Formats the full 64-bit HLC as a 16-character uppercase hex string.
  ///
  /// Used in WAL records and for diagnostic output.
  String toHex() =>
      encoded.toUnsigned(64).toRadixString(16).toUpperCase().padLeft(16, '0');

  /// Formats only the 48-bit physical component as a 12-character uppercase
  /// hex string.
  ///
  /// Used in SSTable filenames (`{deviceId}-{minHlc}-{maxHlc}.sst`), where
  /// the logical counter is not needed for sync ordering.
  String toPhysicalHex() =>
      physicalMs.toRadixString(16).toUpperCase().padLeft(12, '0');

  // ── Ordering ──────────────────────────────────────────────────────────────

  @override
  int compareTo(Hlc other) {
    final cmp = physicalMs.compareTo(other.physicalMs);
    if (cmp != 0) return cmp;
    return logical.compareTo(other.logical);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Hlc &&
          physicalMs == other.physicalMs &&
          logical == other.logical;

  @override
  int get hashCode => Object.hash(physicalMs, logical);

  @override
  String toString() => 'Hlc(${toHex()})';
}
