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

import 'dart:typed_data';

import '../util/hlc.dart';
import '../util/namespace_codec.dart';
import '../util/xxhash.dart';

// ── Record type ──────────────────────────────────────────────────────────────

/// WAL record type byte.
enum WalRecordType {
  /// A live key-value write.
  put(0x01),

  /// A delete tombstone. Value field is absent (zero length).
  delete(0x02),

  /// Legacy boundary marker between two memtable generations.
  ///
  /// Older builds wrote this immediately before opening a new WAL file during
  /// memtable rotation, and recovery used it to skip already-flushed records.
  /// It is **no longer written**: recovery now replays each retained WAL file
  /// in full (idempotent under HLC last-write-wins), which removed a data-loss
  /// hazard where a marker fsync'd before its SSTable became durable hid still
  /// -live records (review finding C1). The value remains decodable so that
  /// databases written by older builds still replay — recovery skips any marker
  /// it encounters as a no-op.
  flushMarker(0x03),

  /// An atomic batch frame containing multiple entries under one checksum.
  ///
  /// A batch frame is written as a single append+fsync. Recovery either applies
  /// all entries in the frame or none (all-or-nothing). A truncated or
  /// checksum-failing frame is dropped whole, so the database is never left in
  /// a partial-batch state across a crash (review finding H2).
  batch(0x04);

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
    0x04 => batch,
    _ => throw FormatException(
      'Unknown WAL record type: 0x${byte.toRadixString(16)}',
    ),
  };

  /// Returns a JSON-compatible representation of this record type.
  ///
  /// Returns the enum name as a string (e.g. `"put"`, `"delete"`,
  /// `"flushMarker"`, `"batch"`).
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
    // namespaceToBytes uses UTF-8 encoding (not codeUnits) and enforces the
    // 255-byte limit. The namespace must already be NFC-normalised (the public
    // boundary in KvStoreImpl guarantees this).
    final nsBytes = namespaceToBytes(namespace);

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
      // bytesToNamespace uses UTF-8 decode (not String.fromCharCodes, which
      // would misinterpret multi-byte sequences as individual code points).
      namespace = bytesToNamespace(buf.sublist(pos, pos + nsLen));
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
}

// ── WAL batch frame ───────────────────────────────────────────────────────────

/// An atomic WAL batch frame that wraps multiple [WalRecord] entries under a
/// single checksum, one append, and one fsync.
///
/// ## Wire format
///
/// ```
/// [checksum 8B][type=batch 0x04 1B][count 4B][entry…]
/// entry := [recType 1B][seq 8B][nsLen 1B][ns NB][keyLen 2B][key KB][valLen 4B][val VB]
/// ```
///
/// The `checksum` covers all bytes from `type` through the last `val` byte.
/// A checksum failure or truncation causes [tryDecode] to return `null`,
/// discarding the entire frame — no partial batch is ever applied.
///
/// ## All-or-nothing guarantee
///
/// Recovery either applies every entry in a frame or none. Because the frame
/// is written in a single `appendFile` + `fsync`, a crash mid-write either
/// leaves the frame entirely absent (the OS never flushed the partial buffer)
/// or leaves a truncated frame whose checksum will not match, causing it to be
/// dropped. Either way the database cannot observe a partial batch (review
/// finding H2).
///
/// ## Back-compatibility
///
/// This type byte (0x04) is new. Older builds wrote individual `put`/`delete`
/// records for each batch entry. Recovery dispatches on the type byte and
/// handles both formats: legacy individual records apply as before; batch frames
/// apply atomically.
final class WalBatchFrame {
  /// Creates a batch frame from a list of [records].
  ///
  /// All records must have type [WalRecordType.put] or [WalRecordType.delete];
  /// [WalRecordType.flushMarker] and [WalRecordType.batch] are not permitted
  /// inside a frame.
  const WalBatchFrame(this.records);

  /// The individual records contained in this frame.
  ///
  /// Every entry is either a put or a delete; never a flush marker or another
  /// batch frame.
  final List<WalRecord> records;

  // ── Encoding ──────────────────────────────────────────────────────────────

  /// Serialises this batch frame to bytes.
  ///
  /// The layout is:
  /// ```
  /// [checksum 8B][type=0x04 1B][count 4B][entry…]
  /// entry := [recType 1B][seq 8B][nsLen 1B][ns][keyLen 2B][key][valLen 4B][val]
  /// ```
  ///
  /// The checksum covers every byte after the 8-byte checksum field.
  Uint8List encode() {
    // Pre-compute each entry's encoded size so we can allocate one buffer.
    // entry layout: recType(1) + seq(8) + nsLen(1) + ns + keyLen(2) + key + valLen(4) + val
    int payloadLen = 1 + 4; // type(1) + count(4)
    final nsBytesPerEntry = <List<int>>[];
    for (final r in records) {
      // namespaceToBytes uses real UTF-8 encoding and enforces the 255-byte
      // limit. The namespace must already be NFC-normalised (the public
      // boundary in KvStoreImpl guarantees this).
      final nsBytes = namespaceToBytes(r.namespace);
      nsBytesPerEntry.add(nsBytes);
      payloadLen +=
          1 + 8 + 1 + nsBytes.length + 2 + r.key.length + 4 + r.value.length;
    }

    final buf = Uint8List(8 + payloadLen);
    final bd = ByteData.sublistView(buf);

    var offset = 8; // reserve checksum slot

    // Frame header: type byte + entry count (big-endian uint32).
    buf[offset++] = WalRecordType.batch.byte;
    bd.setUint32(offset, records.length, Endian.big);
    offset += 4;

    // Encode each entry.
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      final nsBytes = nsBytesPerEntry[i];

      buf[offset++] = r.type.byte; // recType
      bd.setInt64(offset, r.sequence.encoded, Endian.big); // seq
      offset += 8;
      buf[offset++] = nsBytes.length; // nsLen
      buf.setAll(offset, nsBytes); // ns
      offset += nsBytes.length;
      bd.setUint16(offset, r.key.length, Endian.big); // keyLen
      offset += 2;
      buf.setAll(offset, r.key); // key
      offset += r.key.length;
      bd.setUint32(offset, r.value.length, Endian.big); // valLen
      offset += 4;
      buf.setAll(offset, r.value); // val
      offset += r.value.length;
    }

    // Compute checksum over [type..last val byte] and store it at offset 0.
    final payload = Uint8List.sublistView(buf, 8);
    final checksum = XxHash64.digest(payload);
    bd.setInt64(0, checksum, Endian.big);

    return buf;
  }

  // ── Decoding ──────────────────────────────────────────────────────────────

  /// Attempts to decode a WAL batch frame from [buf] at [offset].
  ///
  /// Returns `(frame, bytesConsumed)` on success, or `null` if there are
  /// insufficient bytes, the type byte is not [WalRecordType.batch], or the
  /// checksum does not match (indicating truncation or corruption). The
  /// all-or-nothing guarantee means a `null` result discards the entire frame.
  ///
  /// The caller is responsible for checking the type byte before deciding
  /// whether to call this method or [WalRecord.tryDecode].
  static (WalBatchFrame frame, int bytesConsumed)? tryDecode(
    Uint8List buf,
    int offset,
  ) {
    // Minimum: 8 (checksum) + 1 (type) + 4 (count) = 13 bytes.
    if (buf.length - offset < 13) return null;

    final bd = ByteData.sublistView(buf);
    final storedChecksum = bd.getInt64(offset, Endian.big);

    // Verify this is a batch frame.
    if (buf[offset + 8] != WalRecordType.batch.byte) return null;

    final count = bd.getUint32(offset + 9, Endian.big);
    var pos = offset + 13; // past checksum + type + count

    final records = <WalRecord>[];
    for (var i = 0; i < count; i++) {
      // Each entry: recType(1) + seq(8) + nsLen(1) + ns + keyLen(2) + key + valLen(4) + val
      if (buf.length - pos < 12) return null; // minimum for one entry header
      final recTypeByte = buf[pos++];
      final WalRecordType recType;
      try {
        recType = WalRecordType.fromByte(recTypeByte);
      } on FormatException {
        return null;
      }
      // Only put and delete are valid inside a batch frame.
      if (recType != WalRecordType.put && recType != WalRecordType.delete) {
        return null;
      }

      final seqEncoded = bd.getInt64(pos, Endian.big);
      pos += 8;
      final sequence = Hlc.fromEncoded(seqEncoded);

      if (buf.length - pos < 1) return null;
      final nsLen = buf[pos++];
      if (buf.length - pos < nsLen) return null;
      // bytesToNamespace uses UTF-8 decode to correctly reconstruct non-ASCII
      // namespace strings.
      final namespace = bytesToNamespace(buf.sublist(pos, pos + nsLen));
      pos += nsLen;

      if (buf.length - pos < 2) return null;
      final keyLen = bd.getUint16(pos, Endian.big);
      pos += 2;
      if (buf.length - pos < keyLen) return null;
      final key = buf.sublist(pos, pos + keyLen);
      pos += keyLen;

      if (buf.length - pos < 4) return null;
      final valLen = bd.getUint32(pos, Endian.big);
      pos += 4;
      if (buf.length - pos < valLen) return null;
      final value = buf.sublist(pos, pos + valLen);
      pos += valLen;

      records.add(
        WalRecord(
          type: recType,
          sequence: sequence,
          namespace: namespace,
          key: key,
          value: value,
        ),
      );
    }

    // Verify checksum over [type..last val byte].
    final payload = Uint8List.sublistView(buf, offset + 8, pos);
    final expectedChecksum = XxHash64.digest(payload);
    if (storedChecksum != expectedChecksum) return null;

    return (WalBatchFrame(records), pos - offset);
  }
}
