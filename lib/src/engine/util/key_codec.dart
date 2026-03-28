import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'hlc.dart';

// ── Record type byte ───────────────────────────────────────────────────────

/// Identifies whether a storage entry is a live value or a delete tombstone.
enum RecordType {
  /// A live key-value entry.
  put(0x01),

  /// A delete tombstone. The associated value is empty.
  delete(0x02);

  const RecordType(this.byte);

  /// The single-byte wire encoding of this record type.
  final int byte;

  /// Parses a record type from its byte encoding.
  ///
  /// Throws [ArgumentError] for unrecognised bytes.
  static RecordType fromByte(int byte) => switch (byte) {
        0x01 => put,
        0x02 => delete,
        _ => throw ArgumentError.value(byte, 'byte', 'Unknown RecordType byte'),
      };
}

// ── User key encoding ─────────────────────────────────────────────────────

/// Converts between the UUIDv7 hex-string representation used at the
/// [KvStore] boundary and the 16-byte binary form stored in SSTables and WAL
/// records.
///
/// UUIDv7 keys embed a millisecond-precision timestamp in the most significant
/// bits, so binary-sorted keys are also roughly time-sorted — giving good
/// SSTable write locality (sequential inserts land at the tail of the file).
final class KeyCodec {
  KeyCodec._();

  static const _uuid = Uuid();

  // ── Key generation ──────────────────────────────────────────────────────

  /// Generates a new UUIDv7 key using the current system time.
  ///
  /// Returns the key as a 32-character lowercase hex string without hyphens,
  /// matching the format expected by [KvStore] methods.
  static String generate() => _uuid.v7().replaceAll('-', '');

  // ── Conversion ─────────────────────────────────────────────────────────

  /// Converts a 32-character hex key string to its 16-byte binary form.
  ///
  /// Accepts both hyphenated (`xxxxxxxx-xxxx-...`) and unhyphenated
  /// (`xxxxxxxxxxxxxxxx...`) UUID strings.
  ///
  /// Throws [FormatException] if [hexKey] is not a valid 32-character hex
  /// string (after stripping hyphens).
  static Uint8List keyToBytes(String hexKey) {
    final stripped = hexKey.replaceAll('-', '');
    if (stripped.length != 32) {
      throw FormatException(
        'Key must be 32 hex characters (got ${stripped.length}): $hexKey',
      );
    }
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(stripped.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Converts a 16-byte binary key to its 32-character lowercase hex string.
  ///
  /// Throws [ArgumentError] if [bytes] is not exactly 16 bytes.
  static String bytesToKey(Uint8List bytes) {
    if (bytes.length != 16) {
      throw ArgumentError.value(bytes.length, 'bytes.length', 'Must be 16');
    }
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  // ── Internal key encoding (SSTable / WAL format) ─────────────────────────

  /// Encodes the namespace as a length-prefixed byte sequence.
  ///
  /// Format: `[nsLen 1B][ns UTF-8 bytes]`. The namespace length is limited
  /// to 255 bytes (enforced by the 1-byte length prefix).
  static Uint8List encodeNamespace(String namespace) {
    final nsBytes = _toUtf8(namespace);
    if (nsBytes.length > 255) {
      throw ArgumentError('Namespace exceeds 255 bytes: $namespace');
    }
    final out = Uint8List(1 + nsBytes.length);
    out[0] = nsBytes.length;
    out.setAll(1, nsBytes);
    return out;
  }

  /// Builds the composite internal key written to the SSTable data block.
  ///
  /// Format: `[nsLen 1B][ns NB][userKey 16B][hlc 8B][type 1B]`
  ///
  /// The internal key ordering drives the merge iterator's sort order:
  /// primary on `(nsLen + ns + userKey)` ascending, secondary on `hlc`
  /// descending (higher sequence = newer, emitted first during merge).
  static Uint8List encodeInternalKey(
    String namespace,
    Uint8List userKeyBytes,
    Hlc hlc,
    RecordType type,
  ) {
    final nsBytes = _toUtf8(namespace);
    if (nsBytes.length > 255) {
      throw ArgumentError('Namespace exceeds 255 bytes: $namespace');
    }
    if (userKeyBytes.length != 16) {
      throw ArgumentError('userKeyBytes must be 16 bytes');
    }
    // Layout: 1 (nsLen) + nsLen + 16 (key) + 8 (hlc) + 1 (type)
    final out = Uint8List(1 + nsBytes.length + 16 + 8 + 1);
    var offset = 0;

    out[offset++] = nsBytes.length;
    out.setAll(offset, nsBytes);
    offset += nsBytes.length;

    out.setAll(offset, userKeyBytes);
    offset += 16;

    // HLC encoded as big-endian int64 so byte-order comparison is correct.
    final bd = ByteData.sublistView(out);
    bd.setInt64(offset, hlc.encoded, Endian.big);
    offset += 8;

    out[offset] = type.byte;
    return out;
  }

  /// Decodes the namespace from an internal key produced by [encodeInternalKey].
  static String decodeNamespace(Uint8List internalKey) {
    final nsLen = internalKey[0];
    return String.fromCharCodes(internalKey.sublist(1, 1 + nsLen));
  }

  /// Decodes the user key bytes from an internal key.
  static Uint8List decodeUserKey(Uint8List internalKey) {
    final nsLen = internalKey[0];
    final start = 1 + nsLen;
    return internalKey.sublist(start, start + 16);
  }

  /// Decodes the [Hlc] from an internal key.
  static Hlc decodeHlc(Uint8List internalKey) {
    final nsLen = internalKey[0];
    final hlcOffset = 1 + nsLen + 16;
    final bd = ByteData.sublistView(internalKey);
    return Hlc.fromEncoded(bd.getInt64(hlcOffset, Endian.big));
  }

  /// Decodes the [RecordType] from an internal key.
  static RecordType decodeRecordType(Uint8List internalKey) {
    return RecordType.fromByte(internalKey.last);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static Uint8List _toUtf8(String s) =>
      Uint8List.fromList(s.codeUnits); // ASCII-safe; full UTF-8 for Phase 8
}

// ── KeyGenerator interface ────────────────────────────────────────────────

/// Generates document keys.
///
/// The default implementation produces UUIDv7 keys via [KeyCodec.generate].
/// Tests inject [SequentialKeyGenerator] for deterministic key sequences.
abstract interface class KeyGenerator {
  /// Returns a new unique key as a 32-character lowercase hex string.
  String next();
}

/// Default [KeyGenerator]: produces UUIDv7 keys.
final class UuidV7KeyGenerator implements KeyGenerator {
  const UuidV7KeyGenerator();

  @override
  String next() => KeyCodec.generate();
}

/// Deterministic [KeyGenerator] for tests.
///
/// Produces keys of the form `000000000000000000000000000000xx` where `xx` is
/// a zero-padded decimal counter. Keys are not valid UUIDs but are 16 bytes
/// and sort predictably, which is all the storage engine requires.
final class SequentialKeyGenerator implements KeyGenerator {
  SequentialKeyGenerator({int start = 0}) : _next = start;

  int _next;

  @override
  String next() {
    final key = _next.toRadixString(16).padLeft(32, '0');
    _next++;
    return key;
  }

  /// Resets the counter to [value] (default 0).
  void reset([int value = 0]) => _next = value;
}
