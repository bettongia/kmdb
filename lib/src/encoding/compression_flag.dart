/// Single-byte flag prefixed to every stored value that identifies the
/// compression algorithm applied to the payload.
///
/// The on-disk layout for a stored value is:
/// ```
/// [flag 1B][compressed-or-raw payload]
/// ```
///
/// This flag is written by [ValueCodec.encode] and consumed by
/// [ValueCodec.decode].
enum CompressionFlag {
  /// No compression — payload is raw CBOR bytes.
  none(0x00),

  /// Zstandard compression (native FFI or WASM).
  zstd(0x01),

  /// Deflate compression — fallback when Zstd/WASM is unavailable.
  deflate(0x02);

  const CompressionFlag(this.byte);

  /// The single-byte wire encoding.
  final int byte;

  /// Parses a [CompressionFlag] from its byte value.
  ///
  /// Throws [ArgumentError] for unrecognised bytes.
  static CompressionFlag fromByte(int byte) => switch (byte) {
        0x00 => none,
        0x01 => zstd,
        0x02 => deflate,
        _ => throw ArgumentError.value(
            byte, 'byte', 'Unknown CompressionFlag byte'),
      };
}
