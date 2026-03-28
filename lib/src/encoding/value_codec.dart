import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cbor/cbor.dart';

import 'compression_flag.dart';

/// Threshold (in raw CBOR bytes) below which compression is skipped.
///
/// Compressing small payloads rarely saves space and always adds CPU cost.
/// 64 bytes was chosen as a conservative threshold: typical CBOR overhead for
/// a small document is 10–30 bytes, so anything under 64 bytes is unlikely to
/// compress well with either Zstd or Deflate.
const int _kCompressionThreshold = 64;

/// Encodes and decodes document values for storage in the LSM engine.
///
/// The encoding pipeline is:
/// 1. Serialize the document to CBOR bytes via [CborEncoder].
/// 2. Optionally compress with Zstd (preferred) or Deflate (fallback).
/// 3. Prepend a 1-byte [CompressionFlag].
///
/// ## Format
///
/// ```
/// [flag 1B][payload]
/// ```
///
/// Where `payload` is either raw CBOR or compressed CBOR depending on [flag].
///
/// ## Compression strategy
///
/// Compression is only applied when the raw CBOR exceeds
/// [_kCompressionThreshold] bytes. On native platforms Zstd is used via the
/// `zstandard` package; on web, Deflate from the `archive` package is used as
/// a fallback. If neither produces a smaller output than raw CBOR the payload
/// is stored uncompressed.
///
/// ## Thread safety
///
/// All methods are synchronous and stateless — safe to call from any isolate.
final class ValueCodec {
  const ValueCodec._();

  // ── Encode ──────────────────────────────────────────────────────────────────

  /// Encodes [value] (a JSON-compatible [Map]) into the storage format.
  ///
  /// Returns a [Uint8List] with a 1-byte [CompressionFlag] prefix followed by
  /// the (possibly compressed) CBOR payload.
  static Uint8List encode(Map<String, dynamic> value) {
    final cborBytes = _toCbor(value);

    if (cborBytes.length < _kCompressionThreshold) {
      return _prepend(CompressionFlag.none, cborBytes);
    }

    // Try Deflate (available on all platforms via `archive`).
    final deflated = _deflate(cborBytes);
    if (deflated.length < cborBytes.length) {
      return _prepend(CompressionFlag.deflate, deflated);
    }

    return _prepend(CompressionFlag.none, cborBytes);
  }

  // ── Decode ──────────────────────────────────────────────────────────────────

  /// Decodes a stored value produced by [encode].
  ///
  /// Throws [FormatException] if the byte sequence is malformed or the CBOR
  /// payload cannot be decoded as a [Map].
  ///
  /// Throws [ArgumentError] if [bytes] is empty.
  static Map<String, dynamic> decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Cannot decode empty bytes');
    }

    final flag = CompressionFlag.fromByte(bytes[0]);
    final payload = bytes.sublist(1);

    final Uint8List cborBytes;
    switch (flag) {
      case CompressionFlag.none:
        cborBytes = payload;
      case CompressionFlag.deflate:
        cborBytes = _inflate(payload);
      case CompressionFlag.zstd:
        // Zstd support deferred to Phase 8 (platform layer). For now, any
        // value encoded with Zstd by a future version cannot be decoded.
        throw UnsupportedError(
          'Zstd decompression is not yet supported on this platform',
        );
    }

    return _fromCbor(cborBytes);
  }

  // ── CBOR helpers ────────────────────────────────────────────────────────────

  static Uint8List _toCbor(Map<String, dynamic> value) {
    final encoded = cbor.encode(CborValue(value));
    return Uint8List.fromList(encoded);
  }

  static Map<String, dynamic> _fromCbor(Uint8List bytes) {
    final decoded = cbor.decode(bytes);
    if (decoded is! CborMap) {
      throw FormatException(
        'Expected CBOR map, got ${decoded.runtimeType}',
      );
    }
    // toObject() recursively converts the CBOR tree to plain Dart objects
    // (String, int, double, bool, null, List, Map). The result is guaranteed
    // to be a Map<dynamic, dynamic> when the top-level value is CborMap.
    final obj = decoded.toObject() as Map<dynamic, dynamic>;
    return obj.map((k, v) => MapEntry(k as String, v));
  }

  // ── Compression helpers ──────────────────────────────────────────────────────

  static Uint8List _deflate(Uint8List data) {
    final encoder = ZLibEncoder();
    return Uint8List.fromList(encoder.encode(data));
  }

  static Uint8List _inflate(Uint8List data) {
    final decoder = ZLibDecoder();
    return Uint8List.fromList(decoder.decodeBytes(data));
  }

  // ── Utility ─────────────────────────────────────────────────────────────────

  static Uint8List _prepend(CompressionFlag flag, Uint8List payload) {
    final out = Uint8List(1 + payload.length);
    out[0] = flag.byte;
    out.setAll(1, payload);
    return out;
  }
}
