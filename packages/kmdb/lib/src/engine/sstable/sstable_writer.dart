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

import '../util/varint.dart';
import '../util/xxhash.dart';
import 'bloom_filter.dart';

/// Target size for a single data block (4 KiB).
const int kBlockSize = 4 * 1024;

/// Number of key-value entries between restart points in a data block.
///
/// At every [kRestartInterval]-th entry the full key is written (no prefix
/// compression) and its offset within the block is recorded as a restart point.
/// Binary search during point lookups starts from the nearest restart point
/// below the target key.
const int kRestartInterval = 16;

/// Writes a single immutable SSTable file.
///
/// ## Usage
///
/// ```dart
/// final writer = SstableWriter();
/// writer.add(key1, value1);  // entries must arrive in key order
/// writer.add(key2, value2);
/// final bytes = writer.finish();
/// ```
///
/// ## File layout
///
/// ```
/// [data block 0][data block 1]...[filter block][index block][footer 48B]
/// ```
///
/// ### Data block layout (per block)
///
/// ```
/// [entries...][numRestarts 4B, LE][restart0 4B, LE]...[restartN 4B, LE][block checksum 8B]
/// ```
///
/// Each entry:
/// ```
/// [sharedLen varint][unsharedLen varint][valueLen varint][unsharedKeyBytes][valueBytes]
/// ```
///
/// ### Footer layout (48 bytes, big-endian)
///
/// ```
/// [filterOffset 8B][filterSize 8B][indexOffset 8B][indexSize 8B]
/// [entryCount 4B][reserved 4B][checksum 8B]
/// ```
///
/// The checksum covers all bytes from offset 0 to the start of the checksum
/// field (i.e. the first 40 bytes of the footer + all preceding blocks).
final class SstableWriter {
  SstableWriter();

  // Accumulated data blocks.
  final List<Uint8List> _blocks = [];

  // Index entries: one per finished block.
  // Each entry: [lastKeyLen varint][lastKeyBytes][blockOffset varint][blockSize varint]
  final List<_IndexEntry> _indexEntries = [];

  // All keys accumulated for the Bloom filter.
  final List<Uint8List> _allKeys = [];

  // Current block being built.
  final List<int> _blockBuf = [];
  final List<int> _restartOffsets = [];
  int _blockEntryCount = 0;
  Uint8List _lastKey = Uint8List(0);

  // Running byte offset into the output stream.
  int _offset = 0;

  // Total number of entries added.
  int _entryCount = 0;

  /// Adds an entry to the SSTable.
  ///
  /// Entries **must** be added in ascending internal-key order. Violating this
  /// invariant produces a corrupt SSTable.
  void add(Uint8List key, Uint8List value) {
    // Compute shared prefix length with the previous key.
    final shared = _sharedPrefix(_lastKey, key);
    final unshared = key.sublist(shared);

    // Emit a restart point for every kRestartInterval-th entry or on the
    // very first entry of each block.
    if (_blockEntryCount % kRestartInterval == 0) {
      _restartOffsets.add(_blockBuf.length);
      // At a restart point the shared length is 0 — full key is written.
      _appendEntry(0, key, value);
    } else {
      _appendEntry(shared, unshared, value);
    }

    _lastKey = key;
    _blockEntryCount++;
    _entryCount++;
    _allKeys.add(key);

    // Flush if the block buffer exceeds the target size.
    if (_blockBuf.length >= kBlockSize) {
      _flushBlock();
    }
  }

  /// Finalises the SSTable and returns the complete file bytes.
  ///
  /// Throws [StateError] if no entries have been added.
  Uint8List finish() {
    if (_entryCount == 0) throw StateError('Cannot finish an empty SSTable');

    // Flush any remaining entries.
    if (_blockBuf.isNotEmpty) _flushBlock();

    final output = <int>[];

    // ── Write data blocks ────────────────────────────────────────────────
    for (final block in _blocks) {
      output.addAll(block);
    }
    final filterOffset = output.length;

    // ── Write filter block ──────────────────────────────────────────────
    final filter = BloomFilter.build(_allKeys);
    final filterBytes = filter.toBytes();
    output.addAll(filterBytes);
    final filterSize = filterBytes.length;

    final indexOffset = output.length;

    // ── Write index block ────────────────────────────────────────────────
    final indexBuf = <int>[];
    for (final entry in _indexEntries) {
      // [lastKeyLen varint][lastKeyBytes][blockOffset varint][blockSize varint]
      final lenBuf = Varint.encodeToBytes(entry.lastKey.length);
      indexBuf.addAll(lenBuf);
      indexBuf.addAll(entry.lastKey);
      indexBuf.addAll(Varint.encodeToBytes(entry.blockOffset));
      indexBuf.addAll(Varint.encodeToBytes(entry.blockSize));
    }
    output.addAll(indexBuf);
    final indexSize = indexBuf.length;

    // ── Write footer (48 bytes) ──────────────────────────────────────────
    final footerStart = output.length;
    final footerBuf = Uint8List(48);
    final footerBd = ByteData.sublistView(footerBuf);

    footerBd.setInt64(0, filterOffset, Endian.big);
    footerBd.setInt64(8, filterSize, Endian.big);
    footerBd.setInt64(16, indexOffset, Endian.big);
    footerBd.setInt64(24, indexSize, Endian.big);
    footerBd.setUint32(32, _entryCount, Endian.big);
    footerBd.setUint32(36, 0, Endian.big); // reserved

    // Checksum covers all preceding bytes + the first 40 bytes of the footer.
    output.addAll(footerBuf.sublist(0, 40)); // add placeholder region
    final toHash = Uint8List.fromList(output);
    final checksum = XxHash64.digest(toHash);

    // Replace the placeholder with the real checksum.
    output.removeRange(footerStart, output.length); // remove placeholder
    footerBd.setInt64(40, checksum, Endian.big);
    output.addAll(footerBuf);

    return Uint8List.fromList(output);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _appendEntry(int sharedLen, Uint8List unsharedKey, Uint8List value) {
    _blockBuf.addAll(Varint.encodeToBytes(sharedLen));
    _blockBuf.addAll(Varint.encodeToBytes(unsharedKey.length));
    _blockBuf.addAll(Varint.encodeToBytes(value.length));
    _blockBuf.addAll(unsharedKey);
    _blockBuf.addAll(value);
  }

  void _flushBlock() {
    // Append restart array and its count.
    final numRestarts = _restartOffsets.length;
    final restartBuf = Uint8List(numRestarts * 4 + 4);
    final bd = ByteData.sublistView(restartBuf);
    for (var i = 0; i < numRestarts; i++) {
      bd.setUint32(i * 4, _restartOffsets[i], Endian.little);
    }
    bd.setUint32(numRestarts * 4, numRestarts, Endian.little);
    _blockBuf.addAll(restartBuf);

    // Compute and append block checksum.
    final blockData = Uint8List.fromList(_blockBuf);
    final checksum = XxHash64.digest(blockData);
    final checksumBuf = Uint8List(8);
    ByteData.sublistView(checksumBuf).setInt64(0, checksum, Endian.big);
    _blockBuf.addAll(checksumBuf);

    final block = Uint8List.fromList(_blockBuf);
    _blocks.add(block);

    _indexEntries.add(
      _IndexEntry(
        lastKey: Uint8List.fromList(_lastKey),
        blockOffset: _offset,
        blockSize: block.length,
      ),
    );
    _offset += block.length;

    // Reset block state.
    _blockBuf.clear();
    _restartOffsets.clear();
    _blockEntryCount = 0;
    _lastKey = Uint8List(0);
  }

  static int _sharedPrefix(Uint8List a, Uint8List b) {
    final limit = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < limit; i++) {
      if (a[i] != b[i]) return i;
    }
    return limit;
  }
}

// ── Supporting types ──────────────────────────────────────────────────────────

class _IndexEntry {
  const _IndexEntry({
    required this.lastKey,
    required this.blockOffset,
    required this.blockSize,
  });

  final Uint8List lastKey;
  final int blockOffset;
  final int blockSize;
}

/// Parsed SSTable footer returned by [SstableReader.readFooter].
final class SstableFooter {
  const SstableFooter({
    required this.filterOffset,
    required this.filterSize,
    required this.indexOffset,
    required this.indexSize,
    required this.entryCount,
    required this.checksum,
  });

  /// Byte offset of the filter block within the SSTable file.
  final int filterOffset;

  /// Size of the filter block in bytes.
  final int filterSize;

  /// Byte offset of the index block.
  final int indexOffset;

  /// Size of the index block in bytes.
  final int indexSize;

  /// Total number of key-value entries in this SSTable.
  final int entryCount;

  /// XXH64 checksum of all bytes preceding the checksum field.
  final int checksum;

  /// Serialises this footer to a JSON-compatible map.
  ///
  /// Intended for diagnostic output via `kmdb util sstable`. The checksum is
  /// represented as a hex string for readability.
  Map<String, dynamic> toMap() => {
    'filterOffset': filterOffset,
    'filterSize': filterSize,
    'indexOffset': indexOffset,
    'indexSize': indexSize,
    'entryCount': entryCount,
    'checksum':
        '0x${checksum.toUnsigned(64).toRadixString(16).padLeft(16, '0')}',
  };
}
