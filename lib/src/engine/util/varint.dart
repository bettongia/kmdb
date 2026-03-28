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

/// Unsigned variable-length integer (varint) encoding.
///
/// Uses the standard LEB128 encoding: each byte contributes 7 low-order bits
/// of the value; the high bit is a continuation flag (1 = more bytes follow,
/// 0 = last byte). Values 0–127 encode to a single byte; larger values use
/// 2–10 bytes for the full uint64 range.
///
/// This encoding is used in SSTable data blocks to encode key/value lengths,
/// keeping block headers compact when most keys and values are short.
///
/// ## Example
/// ```dart
/// final buf = Uint8List(10);
/// final written = Varint.encode(300, buf, 0); // 2 bytes
/// final (value, consumed) = Varint.decode(buf, 0);
/// assert(value == 300 && consumed == 2);
/// ```
final class Varint {
  Varint._();

  /// Maximum bytes a varint encoding can occupy (ceil(64/7) = 10).
  static const int maxBytes = 10;

  // ── Encode ─────────────────────────────────────────────────────────────────

  /// Returns the number of bytes needed to encode [value].
  static int encodedLength(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value', 'must be non-negative');
    if (value == 0) return 1;
    var n = 0;
    var v = value;
    while (v > 0) {
      n++;
      v >>>= 7;
    }
    return n;
  }

  /// Encodes [value] as a varint into [buf] starting at [offset].
  ///
  /// Returns the number of bytes written.
  ///
  /// Throws [ArgumentError] if [value] is negative.
  /// Throws [RangeError] if [buf] does not have enough space.
  static int encode(int value, Uint8List buf, int offset) {
    if (value < 0) throw ArgumentError.value(value, 'value', 'must be non-negative');
    var v = value;
    var pos = offset;
    do {
      var byte = v & 0x7F;
      v >>>= 7;
      if (v != 0) byte |= 0x80;
      buf[pos++] = byte;
    } while (v != 0);
    return pos - offset;
  }

  /// Encodes [value] and returns it as a new [Uint8List].
  static Uint8List encodeToBytes(int value) {
    final buf = Uint8List(encodedLength(value));
    encode(value, buf, 0);
    return buf;
  }

  // ── Decode ─────────────────────────────────────────────────────────────────

  /// Decodes a varint from [buf] at [offset].
  ///
  /// Returns a record `(value, bytesConsumed)`.
  ///
  /// Throws [FormatException] if the varint spans more than [maxBytes] or if
  /// [buf] ends prematurely.
  static (int value, int bytesConsumed) decode(Uint8List buf, int offset) {
    var result = 0;
    var shift = 0;
    var pos = offset;

    while (true) {
      if (pos >= buf.length) {
        throw FormatException(
          'Varint truncated at offset $pos (buffer length ${buf.length})',
        );
      }
      if (shift >= 64) {
        throw FormatException(
          'Varint too long: exceeds $maxBytes bytes at offset $offset',
        );
      }
      final byte = buf[pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }

    return (result, pos - offset);
  }

  /// Reads a sequence of [count] varints from [buf] at [offset].
  ///
  /// Returns a list of decoded values and the total bytes consumed.
  static (List<int> values, int bytesConsumed) decodeMany(
    Uint8List buf,
    int offset,
    int count,
  ) {
    final values = <int>[];
    var pos = offset;
    for (var i = 0; i < count; i++) {
      final (v, n) = decode(buf, pos);
      values.add(v);
      pos += n;
    }
    return (values, pos - offset);
  }
}
