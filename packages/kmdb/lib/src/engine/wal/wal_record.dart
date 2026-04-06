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

import '../util/hlc.dart';
import '../util/xxhash.dart';

// ── Record type ──────────────────────────────────────────────────────────────

/// WAL record type byte.
enum WalRecordType {
  /// A live key-value write.
  put(0x01),

  /// A delete tombstone. Value field is absent (zero length).
  delete(0x02),

  /// Marks the boundary between two memtable generations.
  ///
  /// Written immediately before a new WAL file is opened during memtable
  /// rotation. Recovery uses this marker to skip records already flushed to an
  /// SSTable.
  flushMarker(0x03);

  const WalRecordType(this.byte);

  /// Single-byte wire encoding.
  final int byte;

  /// Parses a record type from its byte encoding.
  ///
  /// Throws [FormatException] for unrecognised bytes.
  static WalRecordType fromByte(int byte) => switch (byte) {
    0x01 => put,
    0x02 => delete,
    0x03 => flushMarker,
    _ => throw FormatException(
      'Unknown WAL record type: 0x${byte.toRadixString(16)}',
    ),
  };

  /// Returns a JSON-compatible representation of this record type.
  ///
  /// Returns the enum name as a string (e.g. `"put"`, `"delete"`,
  /// `"flushMarker"`).
  Map<String, dynamic> toMap() => {'name': name, 'byte': byte};
}

// ── WAL record ──────────────────────────────────────────────────────────────

/// A single decoded WAL record.
///
/// ## Wire format
///
/// ```
/// [checksum 8B][type 1B][seq 8B][nsLen 1B][ns NB][keyLen 2B][key KB][valLen 4B][val VB]
/// ```
///
/// The checksum covers all bytes after the 8-byte checksum field.
/// [WalRecordType.flushMarker] records omit the namespace, key, and value fields.
final class WalRecord {
  const WalRecord({
    required this.type,
    required this.sequence,
    this.namespace = '',
    this.key = const [],
    this.value = const [],
  });

  /// Record type.
  final WalRecordType type;

  /// HLC timestamp of this write.
  final Hlc sequence;

  /// Namespace (empty for [WalRecordType.flushMarker]).
  final String namespace;

  /// Raw key bytes (16-byte UUIDv7 binary; empty for flush marker).
  final List<int> key;

  /// Encoded value bytes (flag + CBOR; empty for delete / flush marker).
  final List<int> value;

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Returns a JSON-compatible representation of this record.
  ///
  /// The [key] field is hex-encoded (the raw 16-byte UUIDv7 binary is not
  /// human-readable and does not survive JSON serialisation). The [value]
  /// field is summarised as `{"compressionFlag": N, "byteLength": N}` —
  /// full CBOR decode of the value is out of scope for diagnostic output.
  ///
  /// The [sequence] is represented as a 16-character uppercase hex string
  /// for compact, unambiguous rendering.
  Map<String, dynamic> toMap() {
    final keyHex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final valueMap = value.isEmpty
        ? null
        : {
            'compressionFlag': value.isNotEmpty ? value[0] : 0,
            'byteLength': value.length,
          };
    return {
      'type': type.name,
      'sequence': sequence.toHex(),
      if (namespace.isNotEmpty) 'namespace': namespace,
      if (key.isNotEmpty) 'key': keyHex,
      'value': valueMap,
    }..removeWhere((_, v) => v == null);
  }

  // ── Encoding ──────────────────────────────────────────────────────────────

  /// Serialises this record to bytes, including the leading XXH64 checksum.
  ///
  /// The checksum covers all bytes after itself (type through value).
  Uint8List encode() {
    final nsBytes = _toUtf8(namespace);

    // Flush markers only carry type + seq; other record types carry full fields.
    // Payload = type(1) + seq(8) [ + nsLen(1) + ns + keyLen(2) + key + valLen(4) + val ]
    final isFlush = type == WalRecordType.flushMarker;
    final payloadLen = isFlush
        ? 9 // type(1) + seq(8)
        : 1 + 8 + 1 + nsBytes.length + 2 + key.length + 4 + value.length;
    final buf = Uint8List(8 + payloadLen);
    final bd = ByteData.sublistView(buf);

    var offset = 8; // reserve 8 bytes for checksum

    // type
    buf[offset++] = type.byte;

    // seq (big-endian int64)
    bd.setInt64(offset, sequence.encoded, Endian.big);
    offset += 8;

    if (!isFlush) {
      // nsLen + ns
      buf[offset++] = nsBytes.length;
      buf.setAll(offset, nsBytes);
      offset += nsBytes.length;

      // keyLen (big-endian uint16) + key
      bd.setUint16(offset, key.length, Endian.big);
      offset += 2;
      buf.setAll(offset, key);
      offset += key.length;

      // valLen (big-endian uint32) + val
      bd.setUint32(offset, value.length, Endian.big);
      offset += 4;
      buf.setAll(offset, value);
    }

    // Compute checksum over the payload region and write it at offset 0.
    final payload = Uint8List.sublistView(buf, 8);
    final checksum = XxHash64.digest(payload);
    bd.setInt64(0, checksum, Endian.big);

    return buf;
  }

  // ── Decoding ──────────────────────────────────────────────────────────────

  /// Attempts to decode a WAL record from [buf] at [offset].
  ///
  /// Returns `(record, bytesConsumed)` on success, or `null` if there are
  /// insufficient bytes or the checksum does not match (indicating truncation
  /// or corruption). The caller should stop replay on a `null` result.
  static (WalRecord record, int bytesConsumed)? tryDecode(
    Uint8List buf,
    int offset,
  ) {
    // Need at least 8 (checksum) + 1 (type) + 8 (seq) = 17 bytes minimum.
    if (buf.length - offset < 17) return null;

    final bd = ByteData.sublistView(buf);
    final storedChecksum = bd.getInt64(offset, Endian.big);

    // Parse type — we need it to know the payload structure.
    final typeByte = buf[offset + 8];
    final WalRecordType type;
    try {
      type = WalRecordType.fromByte(typeByte);
    } on FormatException {
      return null; // unrecognised type byte → truncation / corruption
    }

    final seqEncoded = bd.getInt64(offset + 9, Endian.big);
    final sequence = Hlc.fromEncoded(seqEncoded);

    int pos = offset + 17; // past checksum + type + seq

    String namespace = '';
    List<int> key = const [];
    List<int> value = const [];

    if (type != WalRecordType.flushMarker) {
      // nsLen + ns
      if (buf.length - pos < 1) return null;
      final nsLen = buf[pos++];
      if (buf.length - pos < nsLen) return null;
      namespace = String.fromCharCodes(buf, pos, pos + nsLen);
      pos += nsLen;

      // keyLen + key
      if (buf.length - pos < 2) return null;
      final keyLen = bd.getUint16(pos, Endian.big);
      pos += 2;
      if (buf.length - pos < keyLen) return null;
      key = buf.sublist(pos, pos + keyLen);
      pos += keyLen;

      // valLen + val
      if (buf.length - pos < 4) return null;
      final valLen = bd.getUint32(pos, Endian.big);
      pos += 4;
      if (buf.length - pos < valLen) return null;
      value = buf.sublist(pos, pos + valLen);
      pos += valLen;
    }

    // Verify checksum over [type..end].
    final payload = Uint8List.sublistView(buf, offset + 8, pos);
    final expectedChecksum = XxHash64.digest(payload);
    if (storedChecksum != expectedChecksum) return null;

    final record = WalRecord(
      type: type,
      sequence: sequence,
      namespace: namespace,
      key: key,
      value: value,
    );
    return (record, pos - offset);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static List<int> _toUtf8(String s) => s.codeUnits;
}
