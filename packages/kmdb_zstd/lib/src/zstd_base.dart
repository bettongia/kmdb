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

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'third_party/zstd.dart';

/// Default compression level for Zstd.
const int defaultLevel = ZSTD_CLEVEL_DEFAULT;

/// Maximum input buffer length for Zstd.
const int maxInputBufferLength = ZSTD_BLOCKSIZE_MAX;

/// Version of the Zstd library being used.
const String zStdVersion = ZSTD_VERSION_STRING;

/// Returns the minimum compression level supported by the Zstd library.
@Native<Int32 Function()>(symbol: 'ZSTD_minCLevel')
external int minCLevel();

/// Returns the maximum compression level supported by the Zstd library.
@Native<Int32 Function()>(symbol: 'ZSTD_maxCLevel')
external int maxCLevel();

@Native<Size Function(Size)>(symbol: 'ZSTD_compressBound')
external int _compressBound(int srcSize);

@Native<Size Function(Pointer<Void>, Size, Pointer<Void>, Size, Int32)>(
  symbol: 'ZSTD_compress',
)
external int _compress(
  Pointer<Void> dst,
  int dstCapacity,
  Pointer<Void> src,
  int srcSize,
  int compressionLevel,
);

@Native<Size Function(Pointer<Void>, Size, Pointer<Void>, Size)>(
  symbol: 'ZSTD_decompress',
)
external int _decompress(
  Pointer<Void> dst,
  int dstCapacity,
  Pointer<Void> src,
  int compressedSize,
);

@Native<Uint64 Function(Pointer<Void>, Size)>(
  symbol: 'ZSTD_getFrameContentSize',
)
external int _getFrameContentSize(Pointer<Void> src, int srcSize);

@Native<Uint32 Function(Size)>(symbol: 'ZSTD_isError')
external int _isError(int result);

@Native<Pointer<Utf8> Function(Size)>(symbol: 'ZSTD_getErrorName')
external Pointer<Utf8> _getErrorName(int result);

/// A simple interface for Zstd compression and decompression.
///
/// Use this class for synchronous compression and decompression of byte arrays.
class ZstdSimple {
  /// The compression level to use (default: [defaultLevel]).
  final int level;

  /// The input buffer length.
  final int inputBufferLength;

  /// The output buffer length.
  final int outputBufferLength;

  /// Creates a new [ZstdSimple] instance with the given [level].
  ///
  /// Throws [ArgumentError] if the [level] is invalid.
  ZstdSimple({
    this.level = defaultLevel,
    this.inputBufferLength = maxInputBufferLength,
    this.outputBufferLength = -1,
  }) {
    if (!_isValidCLevel(level)) {
      throw ArgumentError.value(level, 'level', 'Invalid compression level');
    }
  }

  /// Returns the Zstd version string.
  String get version => zStdVersion.toString();

  bool _isValidCLevel(int level) =>
      level >= minCLevel() && level <= maxCLevel();

  /// Compresses the given [data].
  ///
  /// Returns the compressed data as a [Uint8List].
  /// Throws an [Exception] if an error occurs during compression.
  Uint8List compress(List<int> data) {
    final srcSize = data.length;
    final dstCapacity = _compressBound(srcSize);

    if (_isError(dstCapacity) != 0) {
      final errorName = _getErrorName(dstCapacity).toDartString();
      throw Exception('Zstd compressBound error: $errorName');
    }

    final srcPtr = malloc<Uint8>(srcSize);
    final dstPtr = malloc<Uint8>(dstCapacity);

    try {
      srcPtr.asTypedList(srcSize).setAll(0, data);

      final compressedSize = _compress(
        dstPtr.cast(),
        dstCapacity,
        srcPtr.cast(),
        srcSize,
        level,
      );

      if (_isError(compressedSize) != 0) {
        final errorName = _getErrorName(compressedSize).toDartString();
        throw Exception('Zstd compression error: $errorName');
      }

      final result = Uint8List.fromList(dstPtr.asTypedList(compressedSize));
      return result;
    } finally {
      malloc.free(srcPtr);
      malloc.free(dstPtr);
    }
  }

  /// Decompresses the given [data].
  ///
  /// Returns the decompressed data as a [Uint8List].
  /// Throws an [Exception] if an error occurs during decompression.
  Uint8List decompress(List<int> data) {
    final compressedSize = data.length;
    final srcPtr = malloc<Uint8>(compressedSize);
    try {
      srcPtr.asTypedList(compressedSize).setAll(0, data);
      final decompressedSize = _getFrameContentSize(
        srcPtr.cast(),
        compressedSize,
      );

      if (decompressedSize == -1) {
        throw Exception(
          'Zstd decompression error: Unknown content size. Use streaming API.',
        );
      }
      if (decompressedSize == -2) {
        throw Exception('Zstd decompression error: Invalid frame header.');
      }

      final dstPtr = malloc<Uint8>(decompressedSize);
      try {
        final resultSize = _decompress(
          dstPtr.cast(),
          decompressedSize,
          srcPtr.cast(),
          compressedSize,
        );

        if (_isError(resultSize) != 0) {
          final errorName = _getErrorName(resultSize).toDartString();
          throw Exception('Zstd decompression error: $errorName');
        }

        final result = Uint8List.fromList(dstPtr.asTypedList(resultSize));
        return result;
      } finally {
        malloc.free(dstPtr);
      }
    } finally {
      malloc.free(srcPtr);
    }
  }
}
