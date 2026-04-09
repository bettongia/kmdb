# Basic ZStandard functionality

Zstd compression for KMDB.

A high-performance Zstandard (Zstd) compression wrapper for Dart, leveraging
native assets and FFI for maximum speed.

## Features

- **Zstandard (Zstd) Support**: Implements the powerful Zstd compression
  algorithm.
- **Native Performance**: Uses the official C implementation of Zstd via Dart
  FFI and Native Assets.
- **Simple API**: Easy-to-use synchronous `compress` and `decompress` methods.
- **Configurable**: Support for custom compression levels.
- **CLI Tool**: Includes a basic command-line tool for compressing and
  decompressing files.

## Getting started

Add `kmdb_zstd` to your `pubspec.yaml`:

```yaml
dependencies:
  kmdb_zstd:
    path: packages/kmdb_zstd
```

Ensure you have a C compiler installed for the native assets build process
(e.g., `gcc`, `clang`, or MSVC on Windows).

## Usage

### Simple Compression and Decompression

```dart
import 'dart:typed_data';
import 'package:kmdb_zstd/zstd.dart';

void main() {
  // Create a ZstdSimple instance with a specific compression level (default is 3)
  final zstd = ZstdSimple(level: 3);

  // Data to compress
  final data = Uint8List.fromList([1, 2, 3, 4, 5, 1, 2, 3, 4, 5]);

  // Compress
  final compressed = zstd.compress(data);
  print('Compressed size: ${compressed.length}');

  // Decompress
  final decompressed = zstd.decompress(compressed);
  print('Decompressed size: ${decompressed.length}');
}
```

### CLI Tool

The package includes a CLI tool `dartz` in `bin/dartz.dart`.

To compress a file:

```bash
dart run bin/dartz.dart myfile.txt
```

To decompress a file:

```bash
dart run bin/dartz.dart -d myfile.txt.zst myfile_restored.txt
```

### FFI

Once you've set up the Zstandard code and header files as per the
[README.md](third_party/zstd/README.md), run the following to produce
`lib/src/third_party/zstd.dart`:

```sh
dart run ffigen
```

You can also just run `make`.

## Additional information

Refer to the main [KMDB documentation](../../README.md) for more details.
