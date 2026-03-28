import 'dart:typed_data';

/// Pure-Dart implementation of the XXH64 hashing algorithm (seed = 0 default).
///
/// XXH64 is used throughout the storage engine for checksums:
/// - WAL record headers (verified on every read during replay)
/// - SSTable data blocks (verified on block read)
/// - SSTable footer (verified on file open and sync ingestion)
/// - Bloom filter double-hashing (`h1 = digest(key)`, `h2 = digest(key, seed: h1)`)
///
/// ## Why XXH64
/// 64-bit output provides ~10¹⁹ collision resistance vs CRC32's ~10⁹. It is
/// also faster than CRC32 on ARM processors without hardware CRC acceleration,
/// which covers the majority of mobile devices KMDB targets.
///
/// ## Platform note
/// Arithmetic uses Dart's arbitrary-precision [int] with [int.toSigned] to
/// truncate products to 64 bits after multiplication. This is correct on
/// native (VM) and dart2wasm. dart2js is not supported by KMDB.
///
/// Reference: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
final class XxHash64 {
  XxHash64._();

  // ── Prime constants (signed 64-bit representations) ─────────────────────
  // Values > 2^63 − 1 are expressed as their two's-complement negative form
  // so they fit in Dart's int on 64-bit platforms without bignum promotion.
  static const int _p1 = -7046029288634856825; // 0x9E3779B185EBCA87
  static const int _p2 = -4417276706812531889; // 0xC2B2AE3D27D4EB4F
  static const int _p3 = 1609587929392839161; //  0x165667B19E3779F9
  static const int _p4 = -8796714831421723037; // 0x85EBCA77C2B2AE63
  static const int _p5 = 2870177450012600261; //  0x27D4EB2F165667C5

  /// Computes the XXH64 digest of [data] with an optional [seed].
  ///
  /// Returns a signed 64-bit integer whose bit pattern is the XXH64 hash.
  /// Use [toHex] to format as a zero-padded 16-character hex string.
  ///
  /// Example:
  /// ```dart
  /// final hash = XxHash64.digest(Uint8List.fromList(utf8.encode('test')));
  /// ```
  static int digest(Uint8List data, {int seed = 0}) {
    final bd = ByteData.sublistView(data);
    final len = data.length;
    int pos = 0;
    int h64;

    if (len >= 32) {
      // Consume 32-byte stripes using four independent accumulators.
      // Each accumulator is initialised to a distinct value to break
      // symmetry and maximise avalanche across the four lanes.
      var v1 = _add(_add(seed, _p1), _p2);
      var v2 = _add(seed, _p2);
      var v3 = seed;
      var v4 = _sub(seed, _p1);

      while (pos <= len - 32) {
        v1 = _round(v1, bd.getInt64(pos, Endian.little));
        pos += 8;
        v2 = _round(v2, bd.getInt64(pos, Endian.little));
        pos += 8;
        v3 = _round(v3, bd.getInt64(pos, Endian.little));
        pos += 8;
        v4 = _round(v4, bd.getInt64(pos, Endian.little));
        pos += 8;
      }

      // Merge the four accumulators into a single 64-bit value.
      h64 = _add(
        _add(_add(_rotl(v1, 1), _rotl(v2, 7)), _rotl(v3, 12)),
        _rotl(v4, 18),
      );
      h64 = _mergeRound(h64, v1);
      h64 = _mergeRound(h64, v2);
      h64 = _mergeRound(h64, v3);
      h64 = _mergeRound(h64, v4);
    } else {
      // Short-input path: initialise directly from the seed.
      h64 = _add(seed, _p5);
    }

    h64 = _add(h64, len);

    // ── Process remaining 8-byte chunks ────────────────────────────────────
    while (pos <= len - 8) {
      final k1 = _round(0, bd.getInt64(pos, Endian.little));
      h64 ^= k1;
      h64 = _add(_mul(_rotl(h64, 27), _p1), _p4);
      pos += 8;
    }

    // ── Process remaining 4-byte chunk ─────────────────────────────────────
    if (pos <= len - 4) {
      // Read as unsigned 32-bit then widen to 64-bit before multiply.
      final u32 = bd.getUint32(pos, Endian.little);
      h64 ^= _mul(u32, _p1);
      h64 = _add(_mul(_rotl(h64, 23), _p2), _p3);
      pos += 4;
    }

    // ── Process remaining bytes (0–3) ───────────────────────────────────────
    while (pos < len) {
      h64 ^= _mul(data[pos], _p5);
      h64 = _mul(_rotl(h64, 11), _p1);
      pos++;
    }

    // ── Final avalanche mixing ──────────────────────────────────────────────
    h64 ^= h64 >>> 33;
    h64 = _mul(h64, _p2);
    h64 ^= h64 >>> 29;
    h64 = _mul(h64, _p3);
    h64 ^= h64 >>> 32;

    return h64;
  }

  /// Formats [hash] (as returned by [digest]) as a zero-padded 16-character
  /// uppercase hex string, e.g. `'EF46DB3751D8E999'`.
  static String toHex(int hash) {
    // Split into two unsigned 32-bit halves. toUnsigned(64) is a no-op on the
    // Dart VM (native ints are already 64-bit signed), so we use >>> (unsigned
    // right shift) to extract the high half with zero fill, and & 0xFFFFFFFF
    // to isolate the low half.
    final hi = (hash >>> 32) & 0xFFFFFFFF;
    final lo = hash & 0xFFFFFFFF;
    return '${hi.toRadixString(16).padLeft(8, '0')}${lo.toRadixString(16).padLeft(8, '0')}'.toUpperCase();
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  // All arithmetic helpers truncate results to signed 64-bit using toSigned(64)
  // so that subsequent operations (especially >>>) receive a proper signed int
  // rather than a positive bignum that could exceed int.maxValue.

  static int _add(int a, int b) => (a + b).toSigned(64);
  static int _sub(int a, int b) => (a - b).toSigned(64);
  static int _mul(int a, int b) => (a * b).toSigned(64);

  /// Rotate-left 64-bit: shifts [v] left by [r] bits, wrapping the overflow
  /// into the low bits. The left shift result is truncated to 64 bits before
  /// OR-ing with the unsigned right shift.
  static int _rotl(int v, int r) =>
      (v << r).toSigned(64) | (v >>> (64 - r));

  /// XXH64 mixing round applied to each 8-byte lane.
  static int _round(int acc, int input) {
    acc = _add(acc, _mul(input, _p2));
    acc = _rotl(acc, 31);
    return _mul(acc, _p1);
  }

  /// Merge-round used to collapse the four accumulators after the main loop.
  static int _mergeRound(int acc, int val) {
    val = _round(0, val);
    acc ^= val;
    return _add(_mul(acc, _p1), _p4);
  }
}
