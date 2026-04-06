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

/// A serialisable Bloom filter for SSTable key membership testing.
///
/// Uses double hashing: `h1 = XXH64(key, seed=0)`, `h2 = XXH64(key, seed=h1)`.
/// Each of the [hashCount] probes sets/tests bit `(h1 + i * h2) % numBits`.
///
/// ## Default parameters
///
/// With [bitsPerKey] = 10 and [hashCount] = 7 the expected false-positive rate
/// is ~0.8% for any key set size. These values balance FPR, filter size, and
/// probe count for typical KMDB workloads.
///
/// ## Usage
///
/// ```dart
/// // Build from a set of keys.
/// final filter = BloomFilter.build(keys);
///
/// // Serialise to bytes for embedding in an SSTable.
/// final bytes = filter.toBytes();
///
/// // Reconstruct and test.
/// final f2 = BloomFilter.fromBytes(bytes);
/// print(f2.mayContain(someKey)); // true if key probably present
/// ```
final class BloomFilter {
  BloomFilter._(this._bits, this._hashCount);

  final Uint8List _bits;
  final int _hashCount;

  /// Default bits per key (10 → ~0.8% FPR at k=7).
  static const int defaultBitsPerKey = 10;

  /// Default number of hash probes per key.
  ///
  /// Derived from `bitsPerKey * ln(2) ≈ bitsPerKey * 0.693`. Clamped to `[1, 30]`.
  static const int defaultHashCount = 7;

  // ── Factory constructors ──────────────────────────────────────────────────

  /// Builds a Bloom filter from a collection of [keys].
  ///
  /// [bitsPerKey] controls the filter size and FPR tradeoff.
  /// [hashCount] overrides the default number of hash probes.
  ///
  /// An empty key set produces a zero-size filter that always returns `false`
  /// from [mayContain].
  static BloomFilter build(
    Iterable<Uint8List> keys, {
    int bitsPerKey = defaultBitsPerKey,
    int hashCount = defaultHashCount,
  }) {
    final keyList = keys.toList();
    if (keyList.isEmpty) {
      return BloomFilter._(Uint8List(0), hashCount);
    }

    // Round up to a multiple of 8 so the filter occupies a whole number of bytes.
    final numBits = (keyList.length * bitsPerKey + 7) & ~7;
    final numBytes = numBits >> 3;
    final bits = Uint8List(numBytes);

    for (final key in keyList) {
      _setKey(bits, numBits, key, hashCount);
    }

    return BloomFilter._(bits, hashCount);
  }

  // ── Serialisation ─────────────────────────────────────────────────────────

  /// Serialises the filter to bytes.
  ///
  /// Format: `[hashCount 1B][bits NB]`.
  /// The [hashCount] byte lets the reader reconstruct probes without knowing
  /// the build-time [bitsPerKey].
  Uint8List toBytes() {
    final out = Uint8List(1 + _bits.length);
    out[0] = _hashCount;
    out.setAll(1, _bits);
    return out;
  }

  /// Deserialises a filter previously produced by [toBytes].
  ///
  /// Throws [FormatException] if [bytes] is empty.
  static BloomFilter fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw FormatException('BloomFilter bytes must not be empty');
    }
    final hashCount = bytes[0];
    final bits = Uint8List.sublistView(bytes, 1);
    return BloomFilter._(bits, hashCount);
  }

  // ── Diagnostic accessors ──────────────────────────────────────────────────

  /// Total number of bits in this filter.
  ///
  /// Useful for computing the false-positive rate: a filter with more bits
  /// per key has a lower FPR.
  int get numBits => _bits.length * 8;

  /// Number of hash probes performed per key.
  ///
  /// The default is 7, yielding ~0.8% FPR at 10 bits/key.
  int get numHashFunctions => _hashCount;

  // ── Query ─────────────────────────────────────────────────────────────────

  /// Returns `false` if [key] is definitely not in the set.
  /// Returns `true` if [key] is probably in the set (false positives possible).
  bool mayContain(Uint8List key) {
    if (_bits.isEmpty) return false;
    final numBits = _bits.length * 8;
    final h1 = XxHash64.digest(key);
    final h2 = XxHash64.digest(key, seed: h1);

    for (var i = 0; i < _hashCount; i++) {
      final bitIndex = _bitIndex(h1, h2, i, numBits);
      if ((_bits[bitIndex >> 3] & (1 << (bitIndex & 7))) == 0) {
        return false; // definitely not present
      }
    }
    return true;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static void _setKey(Uint8List bits, int numBits, Uint8List key, int k) {
    final h1 = XxHash64.digest(key);
    final h2 = XxHash64.digest(key, seed: h1);
    for (var i = 0; i < k; i++) {
      final bitIndex = _bitIndex(h1, h2, i, numBits);
      bits[bitIndex >> 3] |= 1 << (bitIndex & 7);
    }
  }

  /// Enhanced double hashing: `(h1 + i * h2) mod numBits`.
  ///
  /// Both h1 and h2 are signed 64-bit values; we use `>>>` (unsigned right
  /// shift) to strip the sign bit before the modulo so the result is always
  /// a valid bit index.
  static int _bitIndex(int h1, int h2, int i, int numBits) {
    // Combine using Kirsch-Mitzenmacher: bit_i = (h1 + i*h2) mod m.
    // Use unsigned arithmetic: take the absolute value via >>> 0 equivalent.
    final combined = (h1 + i * h2).toUnsigned(64) % numBits;
    return combined;
  }
}
