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

import '../platform/storage_adapter_interface.dart';
import '../util/varint.dart';
import '../util/xxhash.dart';
import 'bloom_filter.dart';
import 'sstable_writer.dart';

/// Exception thrown when an SSTable file fails its integrity check.
final class CorruptedSstableException implements Exception {
  const CorruptedSstableException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() => path != null
      ? 'CorruptedSstableException($path): $message'
      : 'CorruptedSstableException: $message';
}

/// A parsed index entry pointing to one data block within an SSTable.
///
/// Exposed via [SstableReader.index] for diagnostic tooling (see
/// `package:kmdb/kmdb_analysis.dart`). Each [BlockRef] corresponds to one
/// 4 KiB data block and records the offset and byte length of that block
/// together with the last key stored in it (used for binary search during
/// point lookups).
final class BlockRef {
  /// Creates a [BlockRef] with the given [lastKey], [offset], and [size].
  const BlockRef({
    required this.lastKey,
    required this.offset,
    required this.size,
  });

  /// The last (largest) key stored in this block.
  ///
  /// Used during point lookups to find the candidate block via binary search.
  final Uint8List lastKey;

  /// Byte offset of this block from the start of the SSTable file.
  final int offset;

  /// Size of this block in bytes, including the trailing XXH64 checksum.
  final int size;
}

/// A single decoded key-value entry from a data block.
final class SstEntry {
  const SstEntry(this.key, this.value);

  final Uint8List key;
  final Uint8List value;
}

/// Reads entries from an immutable SSTable file.
///
/// On [open] the footer is validated (XXH64 checksum), then the filter and
/// index blocks are loaded into memory. Data blocks are read on demand during
/// [get] and [scan].
///
/// ## Usage
///
/// ```dart
/// final reader = await SstableReader.open('/db/sst/abc.sst', adapter);
/// final entry = await reader.get(keyBytes);
/// await for (final e in reader.scan()) { ... }
/// ```
final class SstableReader {
  SstableReader._({
    required this.path,
    required this._adapter,
    required this._footer,
    required this._filter,
    required this._index,
  });

  /// Path of the SSTable file being read.
  final String path;

  final StorageAdapter _adapter;
  final SstableFooter _footer;
  final BloomFilter _filter;
  final List<BlockRef> _index;

  /// Total number of entries in this SSTable (from footer).
  int get entryCount => _footer.entryCount;

  /// Returns the first (smallest) key in this SSTable, or `null` if empty.
  ///
  /// Reads the first data block and returns its first entry's key. The index
  /// already carries [BlockRef.lastKey] for each block, but the minimum key
  /// of the file is only obtainable by decoding the first block itself — the
  /// index does not store the block's *first* key.
  ///
  /// This method is used solely for **diagnostic metadata derivation** (e.g.
  /// populating [SstableMeta.minKey] during peer-SSTable ingest). It must
  /// never be called on the hot read path. The caller is responsible for
  /// catching any [Exception] and falling back to an empty string if the
  /// derivation fails.
  Future<Uint8List?> firstKey() async {
    if (_index.isEmpty) return null;
    final entries = await _readBlock(_index.first);
    return entries.isEmpty ? null : entries.first.key;
  }

  /// The parsed SSTable footer containing block offsets, sizes, and checksum.
  ///
  /// Exposed for diagnostic tooling; prefer [entryCount] for normal use.
  SstableFooter get footer => _footer;

  /// The Bloom filter loaded from this SSTable's filter block.
  ///
  /// Exposed for diagnostic tooling to inspect filter metadata such as bit
  /// count and hash function count.
  BloomFilter get filter => _filter;

  /// The index entries for this SSTable, one per data block.
  ///
  /// Each [BlockRef] records the last key, byte offset, and byte size of one
  /// data block. Exposed for diagnostic tooling; do not mutate the returned list.
  List<BlockRef> get index => List.unmodifiable(_index);

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Opens an SSTable file and validates its footer checksum.
  ///
  /// Throws [CorruptedSstableException] if the footer checksum is invalid, if
  /// any footer offset/size field is out of range, or if the filter/index
  /// blocks fail to parse — this includes structural failures that would
  /// otherwise surface as [RangeError], [FormatException] (varint overflow),
  /// or [StorageException] (an out-of-file-bounds range read), all of which
  /// are caught inside this method and rethrown as
  /// [CorruptedSstableException] so every caller has exactly one type to
  /// handle.
  /// Throws [StorageException] if the file **itself** does not exist — that
  /// check (`adapter.fileSize`) runs before the try block below, so it is not
  /// swallowed by the blanket rethrow.
  ///
  /// ## Security note (S-1)
  ///
  /// An SSTable is the only on-disk format that crosses a trust boundary — it
  /// is written by this device but also ingested from peers via sync. The
  /// XXH64 checksum above defends against accidental corruption, but it is
  /// **not cryptographic**: an attacker who controls the file body can simply
  /// recompute the checksum after tampering with any field. Every offset and
  /// size read from the footer or index is therefore validated against the
  /// actual file size *before* it is used to allocate or slice, mirroring the
  /// pattern already used by [ManifestReader] (`manifest_reader.dart`) for the
  /// Manifest's local-only format. Any structural failure surfaces as
  /// [CorruptedSstableException] so existing callers (`SyncEngine.pull`,
  /// `LsmEngine.ingestAt0`, `ConsolidationCoordinator`) — which already treat
  /// that type as "reject this file" — handle it correctly without change.
  static Future<SstableReader> open(String path, StorageAdapter adapter) async {
    final fileSize = await adapter.fileSize(path);
    if (fileSize < 48) {
      throw CorruptedSstableException(
        'File too small to contain a footer ($fileSize bytes)',
        path: path,
      );
    }

    try {
      // Read and validate the footer.
      final footerBytes = await adapter.readFileRange(path, fileSize - 48, 48);
      final footer = _parseFooter(footerBytes, path);
      _validateFooterBounds(footer, fileSize, path);

      // Validate checksum: hash all bytes from 0 to (fileSize - 8).
      final toHash = await adapter.readFileRange(path, 0, fileSize - 8);
      final actualChecksum = XxHash64.digest(toHash);
      if (actualChecksum != footer.checksum) {
        throw CorruptedSstableException(
          'Footer checksum mismatch: '
          'expected ${XxHash64.toHex(footer.checksum)} '
          'got ${XxHash64.toHex(actualChecksum)}',
          path: path,
        );
      }

      // Load filter block.
      final filterBytes = await adapter.readFileRange(
        path,
        footer.filterOffset,
        footer.filterSize,
      );
      final filter = BloomFilter.fromBytes(filterBytes);

      // Load and parse index block.
      final indexBytes = await adapter.readFileRange(
        path,
        footer.indexOffset,
        footer.indexSize,
      );
      final index = _parseIndex(indexBytes, path);

      return SstableReader._(
        path: path,
        adapter: adapter,
        footer: footer,
        filter: filter,
        index: index,
      );
    } on CorruptedSstableException {
      rethrow;
    } on RangeError catch (e) {
      // Belt-and-suspenders: the explicit validation above should make this
      // unreachable, but any RangeError that slips through a slicing
      // operation (e.g. inside BloomFilter.fromBytes) must still surface as
      // the type every ingest call site already knows to reject, not escape
      // as a bare RangeError (S-1's second contributing factor).
      throw CorruptedSstableException(
        'Structural parse failure: $e',
        path: path,
      );
    } on FormatException catch (e) {
      // A corrupted/adversarial varint reached through footer or index
      // parsing (e.g. `Varint.decode` rejecting a sign-bit-overflowing
      // encoding) surfaces here as a `FormatException`, not a `RangeError`.
      // Every caller of `open()` (`SyncEngine.pull`, `LsmEngine.ingestAt0`,
      // `ConsolidationCoordinator.consolidate`) treats
      // `CorruptedSstableException` as "reject this file" — a bare
      // `FormatException` escaping here would bypass that handling at
      // exactly the call site (`consolidate()`) that does not separately
      // catch it (QA finding B1).
      throw CorruptedSstableException(
        'Structural parse failure: $e',
        path: path,
      );
    } on StorageException catch (e) {
      // A footer/index field describing a range that lies within the
      // *validated* bounds check above but still fails at the storage layer
      // — most notably `blockOffset`/`blockSize` values that pass
      // `Varint.decode`'s non-negativity check but exceed the actual file
      // size, which `StorageAdapterNative.readFileRange` rejects with
      // `StorageException` rather than allocating unbounded (S-1 fix 7) —
      // must surface the same way. This clause only ever fires for a range
      // violation raised *inside* this try block; `adapter.fileSize(path)`
      // above (which throws `StorageException` for a missing file) runs
      // outside it, so the "file does not exist" contract in this method's
      // doc comment still holds (QA finding B1).
      throw CorruptedSstableException(
        'Structural parse failure: $e',
        path: path,
      );
    }
  }

  // ── Point lookup ──────────────────────────────────────────────────────────

  /// Returns the value for [key], or `null` if not present.
  ///
  /// Uses the Bloom filter to skip blocks that definitely do not contain [key],
  /// then binary-searches the index to find the candidate block.
  Future<Uint8List?> get(Uint8List key) async {
    if (!_filter.mayContain(key)) return null;

    final blockRef = _findBlock(key);
    if (blockRef == null) return null;

    final entries = await _readBlock(blockRef);
    for (final e in entries) {
      final cmp = _compareKeys(e.key, key);
      if (cmp == 0) return e.value;
      if (cmp > 0) break; // block is sorted — key not present
    }
    return null;
  }

  // ── Scan ──────────────────────────────────────────────────────────────────

  /// Returns all entries in ascending key order.
  ///
  /// If [start] is provided, yields only entries with key ≥ [start].
  /// If [end] is provided, stops before the first entry with key ≥ [end].
  Stream<SstEntry> scan({Uint8List? start, Uint8List? end}) async* {
    for (var i = 0; i < _index.length; i++) {
      final ref = _index[i];

      // Skip blocks whose lastKey < start.
      if (start != null && _compareKeys(ref.lastKey, start) < 0) continue;

      // Stop when the first key of the block would be ≥ end — but we don't
      // store firstKey in the index. Instead we read the block and skip.
      final entries = await _readBlock(ref);
      for (final e in entries) {
        if (start != null && _compareKeys(e.key, start) < 0) continue;
        if (end != null && _compareKeys(e.key, end) >= 0) return;
        yield e;
      }
    }
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Binary-searches the index for the block whose lastKey ≥ [key].
  BlockRef? _findBlock(Uint8List key) {
    if (_index.isEmpty) return null;
    // Binary search: find the first block whose lastKey ≥ key.
    var lo = 0;
    var hi = _index.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compareKeys(_index[mid].lastKey, key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (_compareKeys(_index[lo].lastKey, key) < 0) return null;
    return _index[lo];
  }

  /// Reads, validates, and decodes a single data block.
  ///
  /// Wraps every structural-failure type `readFileRange`/[_decodeBlock] can
  /// raise ([RangeError], [FormatException] from `Varint.decode`, and
  /// [StorageException] from an out-of-file-bounds `blockOffset`/`blockSize`)
  /// as [CorruptedSstableException]: unlike [open], this method also runs on
  /// the hot [get]/[scan] path and from [firstKey] — both of which are
  /// reachable on peer-ingested data (S-1) after the reader has already been
  /// successfully opened, so the same hardening is needed here too. The
  /// `readFileRange` call is inside the `try` (not before it, as an earlier
  /// draft had it) precisely so a `StorageException` raised by an
  /// out-of-bounds `ref` is caught here rather than escaping uncaught
  /// (QA finding B1).
  Future<List<SstEntry>> _readBlock(BlockRef ref) async {
    try {
      final blockBytes = await _adapter.readFileRange(
        path,
        ref.offset,
        ref.size,
      );
      return _decodeBlock(blockBytes, path);
    } on RangeError catch (e) {
      throw CorruptedSstableException(
        'Structural parse failure decoding data block: $e',
        path: path,
      );
    } on FormatException catch (e) {
      throw CorruptedSstableException(
        'Structural parse failure decoding data block: $e',
        path: path,
      );
    } on StorageException catch (e) {
      throw CorruptedSstableException(
        'Structural parse failure decoding data block: $e',
        path: path,
      );
    }
  }

  // ── Static helpers ────────────────────────────────────────────────────────

  static SstableFooter _parseFooter(Uint8List bytes, String path) {
    if (bytes.length != 48) {
      throw CorruptedSstableException(
        'Footer must be 48 bytes, got ${bytes.length}',
        path: path,
      );
    }
    final bd = ByteData.sublistView(bytes);
    return SstableFooter(
      filterOffset: bd.getInt64(0, Endian.big),
      filterSize: bd.getInt64(8, Endian.big),
      indexOffset: bd.getInt64(16, Endian.big),
      indexSize: bd.getInt64(24, Endian.big),
      entryCount: bd.getUint32(32, Endian.big),
      checksum: bd.getInt64(40, Endian.big),
    );
  }

  /// Validates that every offset/size field in [footer] is non-negative and
  /// falls entirely within `[0, fileSize)` (S-1).
  ///
  /// These fields are read as **signed** 64-bit integers directly off disk
  /// ([_parseFooter]); an adversarial or corrupted file can set any bit
  /// pattern, including a negative value or one that points past the end of
  /// the file. Validating here — before either field is used to allocate a
  /// buffer or seek within the file — is what turns PROBE1
  /// (`filterSize = 1<<40`, an `OutOfMemoryError` on the native adapter) and
  /// PROBE2 (`filterOffset = -4096`, a `StorageException` from
  /// `setPosition`) into a single, uniform, pre-allocation rejection.
  static void _validateFooterBounds(
    SstableFooter footer,
    int fileSize,
    String path,
  ) {
    void checkRange(String name, int offset, int size) {
      if (offset < 0 || size < 0) {
        throw CorruptedSstableException(
          'Footer field "$name" has a negative offset/size '
          '(offset=$offset, size=$size)',
          path: path,
        );
      }
      // Use a widening-safe comparison: `offset + size` cannot overflow a
      // 64-bit Dart int for any pair of values that individually passed the
      // non-negative check above and are bounded by a real file's size.
      if (offset + size > fileSize) {
        throw CorruptedSstableException(
          'Footer field "$name" extends past end of file '
          '(offset=$offset, size=$size, fileSize=$fileSize)',
          path: path,
        );
      }
    }

    checkRange('filter', footer.filterOffset, footer.filterSize);
    checkRange('index', footer.indexOffset, footer.indexSize);
  }

  static List<BlockRef> _parseIndex(Uint8List bytes, String path) {
    final refs = <BlockRef>[];
    var pos = 0;
    while (pos < bytes.length) {
      final (keyLen, n1) = Varint.decode(bytes, pos);
      pos += n1;
      // Bounds-check keyLen against the remaining index bytes *before*
      // slicing (S-1 PROBE3: a corrupted keyLen larger than the buffer would
      // otherwise reach `sublistView` and throw a bare `RangeError`).
      if (keyLen < 0 || pos + keyLen > bytes.length) {
        throw CorruptedSstableException(
          'Index entry keyLen=$keyLen overflows the index block '
          '(remaining=${bytes.length - pos})',
          path: path,
        );
      }
      final lastKey = Uint8List.sublistView(bytes, pos, pos + keyLen);
      pos += keyLen;
      final (blockOffset, n2) = Varint.decode(bytes, pos);
      pos += n2;
      final (blockSize, n3) = Varint.decode(bytes, pos);
      pos += n3;
      // blockOffset/blockSize are validated for non-negativity by
      // Varint.decode; the "does this stay within the file" bound is enforced
      // where they are actually used — StorageAdapterNative.readFileRange
      // now bounds every range read against the real file size (S-1 fix 7).
      refs.add(
        BlockRef(lastKey: lastKey, offset: blockOffset, size: blockSize),
      );
    }
    return refs;
  }

  /// Decodes all entries from a data block.
  ///
  /// Block layout:
  /// ```
  /// [entries...][numRestarts 4B LE][restart0 4B LE]...[checksum 8B]
  /// ```
  ///
  /// Each entry:
  /// ```
  /// [sharedLen varint][unsharedLen varint][valueLen varint][unsharedKey][value]
  /// ```
  static List<SstEntry> _decodeBlock(Uint8List block, String path) {
    if (block.length < 8 + 4) {
      throw CorruptedSstableException('Data block too short', path: path);
    }

    // Validate block checksum: last 8 bytes are the checksum.
    final data = Uint8List.sublistView(block, 0, block.length - 8);
    final bd = ByteData.sublistView(block);
    final storedChecksum = bd.getInt64(block.length - 8, Endian.big);
    final actualChecksum = XxHash64.digest(data);
    if (storedChecksum != actualChecksum) {
      throw CorruptedSstableException(
        'Data block checksum mismatch',
        path: path,
      );
    }

    // Read the restart array: it sits between the entries and the checksum.
    // The 4 bytes before the checksum (at offset data.length - 4) are numRestarts.
    final numRestarts = ByteData.sublistView(
      data,
    ).getUint32(data.length - 4, Endian.little);
    // Entries occupy data[0, data.length - (numRestarts+1)*4).
    final entriesEnd = data.length - (numRestarts + 1) * 4;
    if (entriesEnd < 0) {
      throw CorruptedSstableException(
        'Data block restart array overflows block',
        path: path,
      );
    }

    // Decode entries.
    final entries = <SstEntry>[];
    var pos = 0;
    var currentKey = Uint8List(0);

    while (pos < entriesEnd) {
      final (shared, n1) = Varint.decode(data, pos);
      pos += n1;
      final (unsharedLen, n2) = Varint.decode(data, pos);
      pos += n2;
      final (valueLen, n3) = Varint.decode(data, pos);
      pos += n3;

      // S-1: validate every length against the enclosing buffer *before*
      // using it to size an allocation or slice. In particular, `shared` must
      // never exceed `currentKey.length` — the review's confirmed failure
      // mode was allocating `Uint8List(shared + unsharedLen)` first and only
      // discovering the mismatch when `setRange` throws, by which point an
      // attacker-controlled `shared` has already sized the allocation.
      if (shared < 0 || shared > currentKey.length) {
        throw CorruptedSstableException(
          'Data block entry has invalid shared-prefix length $shared '
          '(currentKey.length=${currentKey.length})',
          path: path,
        );
      }
      if (unsharedLen < 0 || pos + unsharedLen > entriesEnd) {
        throw CorruptedSstableException(
          'Data block entry unsharedLen=$unsharedLen overflows the block',
          path: path,
        );
      }
      final unshared = Uint8List.sublistView(data, pos, pos + unsharedLen);
      pos += unsharedLen;
      if (valueLen < 0 || pos + valueLen > entriesEnd) {
        throw CorruptedSstableException(
          'Data block entry valueLen=$valueLen overflows the block',
          path: path,
        );
      }
      final value = Uint8List.sublistView(data, pos, pos + valueLen);
      pos += valueLen;

      // Reconstruct the full key from shared prefix + unshared suffix.
      final fullKey = Uint8List(shared + unsharedLen);
      fullKey.setRange(0, shared, currentKey);
      fullKey.setRange(shared, shared + unsharedLen, unshared);
      currentKey = fullKey;

      entries.add(SstEntry(fullKey, value));
    }
    return entries;
  }

  static int _compareKeys(Uint8List a, Uint8List b) {
    final minLen = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < minLen; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }
}
