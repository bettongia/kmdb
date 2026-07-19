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

/// @docImport 'package:kmdb/src/engine/sstable/sstable_reader.dart';
library;

/// Generator for **checksum-valid, structurally hostile** SSTable fixtures.
///
/// ## Why a generator, not checked-in binary fixtures
///
/// The 2026-07-18 release-readiness review's S-1 finding notes that every
/// pre-existing SSTable parser test fed the parser well-formed output the
/// codebase itself produced, and the one negative test uploaded 64 bytes of
/// `0xAB` — which fails the *footer checksum* and therefore exercises only
/// the one path that was already handled correctly. No test constructed a
/// **checksum-valid, structurally hostile** file, which is exactly what an
/// attacker who controls the sync folder can produce (XXH64 is
/// non-cryptographic — see `sstable_reader.dart`'s doc comment on
/// [SstableReader.open]).
///
/// This module builds a valid SSTable via [SstableWriter], patches one named
/// field, and recomputes the checksum(s) so the file stays valid by the only
/// check the reader used to perform. Checked-in binary fixtures would rot
/// silently the next time the SSTable format changes; a generator built on
/// the same [SstableWriter] the production code uses cannot drift out of
/// sync with the format.

import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/util/varint.dart';
import 'package:kmdb/src/engine/util/xxhash.dart';

/// Builds a valid SSTable containing [entryCount] entries in the `test`
/// namespace, using sequential UUIDv7-shaped keys and small values.
///
/// The returned bytes pass every check [SstableReader.open] performs — this
/// is the starting point every `patch*` helper below mutates.
Uint8List buildValidSstable({
  int entryCount = 4,
  int basePhysical = 1000,
  Uint8List Function(int index)? valueBuilder,
}) {
  final writer = SstableWriter();
  for (var i = 0; i < entryCount; i++) {
    final hlc = Hlc(basePhysical + i, 0);
    final keyBytes = Uint8List(16)..fillRange(0, 16, i);
    final internalKey = KeyCodec.encodeInternalKey(
      'test',
      keyBytes,
      hlc,
      RecordType.put,
    );
    final value = valueBuilder != null
        ? valueBuilder(i)
        : Uint8List.fromList([i, i, i]);
    writer.add(internalKey, value);
  }
  return writer.finish();
}

/// Builds a valid SSTable with a single entry whose value is
/// [encodedBombValue] — a pre-encoded [ValueCodec] payload that decompresses
/// to something larger than [ValueCodec.kMaxDecodedValueBytes] (S-2).
///
/// Used to test that a decompression bomb sitting inert in an otherwise
/// well-formed SSTable is rejected at the [ValueCodec.decode] boundary — not
/// that the SSTable itself is rejected (ingest never decodes values; see the
/// class doc on `value_codec.dart`'s `kMaxDecodedValueBytes`).
Uint8List buildSstableWithValue(Uint8List encodedBombValue) {
  return buildValidSstable(
    entryCount: 1,
    valueBuilder: (_) => encodedBombValue,
  );
}

/// The footer fields that [patchFooterField] can target.
///
/// Byte offsets within the 48-byte footer, matching
/// `SstableWriter.finish()`'s layout (see its class doc):
/// `[filterOffset 8B][filterSize 8B][indexOffset 8B][indexSize 8B]
/// [entryCount 4B][reserved 4B][checksum 8B]`.
enum FooterField {
  /// Offset 0 (int64).
  filterOffset(0),

  /// Offset 8 (int64).
  filterSize(8),

  /// Offset 16 (int64).
  indexOffset(16),

  /// Offset 24 (int64).
  indexSize(24);

  const FooterField(this.byteOffset);

  /// Byte offset of this field within the 48-byte footer.
  final int byteOffset;
}

/// Returns a copy of [validBytes] with footer [field] set to [value], and the
/// trailing footer checksum recomputed so the file remains checksum-valid.
///
/// This is PROBE1 (`filterSize = 1<<40`) and PROBE2 (`filterOffset = -4096`)
/// from the 2026-07-18 release-readiness review, generalised to any footer
/// field.
Uint8List patchFooterField(
  Uint8List validBytes, {
  required FooterField field,
  required int value,
}) {
  final patched = Uint8List.fromList(validBytes);
  final footerStart = patched.length - 48;
  final bd = ByteData.sublistView(patched);
  bd.setInt64(footerStart + field.byteOffset, value, Endian.big);
  return _recomputeFooterChecksum(patched);
}

/// Returns a copy of [validBytes] with the index block's first entry's
/// `keyLen` varint overwritten to [newKeyLen] (default 127 — the exact
/// PROBE3 value from the review), and the footer checksum recomputed.
///
/// [newKeyLen] must fit in a single-byte varint (0–127) so the overwrite is
/// in place — no other offset in the file shifts. 127 comfortably overflows
/// any test fixture's short keys, reproducing PROBE3
/// (`RangeError (end): Not in inclusive range ...`) without needing to
/// touch `indexSize`/`filterOffset`.
Uint8List patchIndexKeyLen(Uint8List validBytes, {int newKeyLen = 127}) {
  if (newKeyLen < 0 || newKeyLen > 127) {
    throw ArgumentError.value(
      newKeyLen,
      'newKeyLen',
      'must fit in a single-byte varint (0-127) for an in-place patch',
    );
  }
  final patched = Uint8List.fromList(validBytes);
  final indexOffset = _readFooterField(patched, FooterField.indexOffset);
  // The first byte of the index block is always the keyLen varint for the
  // first index entry (see SstableWriter.finish()'s index block layout).
  patched[indexOffset] = newKeyLen;
  return _recomputeFooterChecksum(patched);
}

/// Which index-entry field [patchIndexBlockOffsetOrSize] should overwrite.
enum IndexEntryField {
  /// `blockOffset` — the byte offset of the data block within the file.
  blockOffset,

  /// `blockSize` — the byte length of the data block.
  blockSize,
}

/// Returns a copy of [validBytes] with the first index entry's [field]
/// (`blockOffset` or `blockSize`) replaced by [newValue] — a value large
/// enough that `offset + size` exceeds the actual file size, reproducing the
/// `StorageException` `StorageAdapterNative.readFileRange` raises for an
/// out-of-file-bounds range (S-1 fix 7), reached via the *index* rather than
/// the footer.
///
/// Unlike [patchIndexKeyLen]/[patchBlockShared], this is **not** an in-place
/// single-byte patch: [newValue] (default large enough to exceed any test
/// fixture's file size) does not fit in the same varint width as the
/// original, so the index block is rebuilt and the footer's `indexSize` and
/// whole-file checksum are updated to match. The index block is always the
/// second-to-last section of the file (`[data blocks][filter][index][footer]`
/// — see `SstableWriter`'s class doc), so everything before it is copied
/// unchanged.
Uint8List patchIndexBlockOffsetOrSize(
  Uint8List validBytes, {
  required IndexEntryField field,
  int newValue = 1 << 32,
}) {
  final indexOffset = _readFooterField(validBytes, FooterField.indexOffset);
  final indexSize = _readFooterField(validBytes, FooterField.indexSize);
  final indexBytes = Uint8List.sublistView(
    validBytes,
    indexOffset,
    indexOffset + indexSize,
  );

  // Parse just the first entry's layout:
  // [keyLen varint][keyBytes][blockOffset varint][blockSize varint].
  var pos = 0;
  final (keyLen, n1) = Varint.decode(indexBytes, pos);
  pos += n1 + keyLen; // skip past keyLen varint + key bytes
  final blockOffsetStart = pos;
  final (blockOffset, n2) = Varint.decode(indexBytes, pos);
  pos += n2;
  final (blockSize, n3) = Varint.decode(indexBytes, pos);
  pos += n3;
  final restOfIndex = Uint8List.sublistView(indexBytes, pos);

  final newBlockOffset = field == IndexEntryField.blockOffset
      ? newValue
      : blockOffset;
  final newBlockSize = field == IndexEntryField.blockSize
      ? newValue
      : blockSize;

  final newIndexBytes = Uint8List.fromList([
    ...indexBytes.sublist(0, blockOffsetStart), // keyLen varint + key bytes
    ...Varint.encodeToBytes(newBlockOffset),
    ...Varint.encodeToBytes(newBlockSize),
    ...restOfIndex,
  ]);

  return _rebuildWithIndex(validBytes, indexOffset, newIndexBytes);
}

/// Returns a copy of [validBytes] with the first index entry's `keyLen`
/// varint replaced by a **malformed** 10-byte varint whose final byte sets
/// bit 63 — the same sign-bit-overflow shape covered directly by
/// `Varint.decode`'s own unit test (`varint_test.dart`), but reached here
/// *through* SSTable index parsing rather than calling `Varint.decode`
/// directly. `SstableReader.open` must reject this with
/// `CorruptedSstableException` (surfacing the underlying `FormatException`),
/// not let it escape.
///
/// Like [patchIndexBlockOffsetOrSize], this rebuilds the index block rather
/// than patching in place — a 10-byte malformed varint cannot replace a
/// legitimate encoder's 1-byte `keyLen` without shifting everything after it.
Uint8List patchIndexVarintOverflow(Uint8List validBytes) {
  final indexOffset = _readFooterField(validBytes, FooterField.indexOffset);
  final indexSize = _readFooterField(validBytes, FooterField.indexSize);
  final indexBytes = Uint8List.sublistView(
    validBytes,
    indexOffset,
    indexOffset + indexSize,
  );

  final (_, n1) = Varint.decode(indexBytes, 0);
  final restOfIndex = Uint8List.sublistView(indexBytes, n1);

  // 9 continuation bytes (all 0xFF) followed by a 10th byte with the
  // continuation bit clear and a non-zero low 7 bits — see varint_test.dart
  // for why this specific shape triggers the shift-63 rejection.
  const malformedVarint = [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, //
    0x01,
  ];

  final newIndexBytes = Uint8List.fromList([
    ...malformedVarint,
    ...restOfIndex,
  ]);

  return _rebuildWithIndex(validBytes, indexOffset, newIndexBytes);
}

/// Rebuilds the whole file with the index block replaced by [newIndexBytes],
/// starting at the same [indexOffset] (the section before it — data blocks
/// and the filter block — is unchanged). Updates the footer's `indexSize`
/// field and recomputes the whole-file checksum.
Uint8List _rebuildWithIndex(
  Uint8List validBytes,
  int indexOffset,
  Uint8List newIndexBytes,
) {
  final beforeIndex = Uint8List.sublistView(validBytes, 0, indexOffset);
  final oldFooter = Uint8List.sublistView(validBytes, validBytes.length - 48);

  final rebuilt = Uint8List.fromList([
    ...beforeIndex,
    ...newIndexBytes,
    ...oldFooter,
  ]);

  final footerStart = rebuilt.length - 48;
  ByteData.sublistView(rebuilt).setInt64(
    footerStart + FooterField.indexSize.byteOffset,
    newIndexBytes.length,
    Endian.big,
  );

  return _recomputeFooterChecksum(rebuilt);
}

/// Returns a copy of [validBytes] with the first data block's first entry's
/// `shared` (shared-prefix-length) varint overwritten to [newShared], the
/// block's own checksum recomputed, and the footer checksum recomputed.
///
/// The very first entry of a data block is always a restart point (`shared`
/// encoded as 0 by [SstableWriter]), so any non-zero value here is invalid —
/// `currentKey` is empty when the first entry is decoded, so
/// `shared > currentKey.length` for any `newShared > 0`. [newShared] must fit
/// in a single-byte varint so this is an in-place overwrite.
Uint8List patchBlockShared(Uint8List validBytes, {int newShared = 127}) =>
    _patchFirstBlockByte(validBytes, byteIndex: 0, newValue: newShared);

/// Returns a copy of [validBytes] with the first data block's first entry's
/// `unsharedLen` varint overwritten to [newUnsharedLen] — one byte after
/// `shared` (byte offset 1, assuming `shared` is the standard single-byte `0`
/// a restart point always encodes). Both block and footer checksums are
/// recomputed.
///
/// Use with a small (e.g. single-entry) SSTable so [newUnsharedLen] reliably
/// exceeds the remaining block bytes — the point of this helper is to
/// reproduce an `unsharedLen` that overflows the block, not merely a
/// numerically large one that still happens to fit.
Uint8List patchBlockUnsharedLen(
  Uint8List validBytes, {
  int newUnsharedLen = 127,
}) => _patchFirstBlockByte(validBytes, byteIndex: 1, newValue: newUnsharedLen);

/// Returns a copy of [validBytes] with the first data block's first entry's
/// `valueLen` varint overwritten to [newValueLen] — two bytes after `shared`
/// (byte offset 2, assuming both `shared` and `unsharedLen` are standard
/// single-byte varints for the first entry of a small SSTable). Both block
/// and footer checksums are recomputed.
Uint8List patchBlockValueLen(Uint8List validBytes, {int newValueLen = 127}) =>
    _patchFirstBlockByte(validBytes, byteIndex: 2, newValue: newValueLen);

/// Overwrites a single byte at [byteIndex] within the first data block (which
/// always starts at file offset 0) and recomputes both the block's own
/// trailing checksum and the footer's whole-file checksum.
///
/// [newValue] must fit in a single-byte varint (0–127) so this is a pure
/// in-place overwrite — no other offset in the file shifts.
Uint8List _patchFirstBlockByte(
  Uint8List validBytes, {
  required int byteIndex,
  required int newValue,
}) {
  if (newValue < 0 || newValue > 127) {
    throw ArgumentError.value(
      newValue,
      'newValue',
      'must fit in a single-byte varint (0-127) for an in-place patch',
    );
  }
  final patched = Uint8List.fromList(validBytes);
  patched[byteIndex] = newValue;

  // The block's own trailing 8-byte checksum must be recomputed too — it is
  // a *separate* XXH64 from the footer's, covering only this block's bytes
  // (see SstableReader._decodeBlock's doc comment).
  final filterOffset = _readFooterField(patched, FooterField.filterOffset);
  final blockBytes = Uint8List.sublistView(patched, 0, filterOffset);
  final blockChecksum = XxHash64.digest(
    Uint8List.sublistView(blockBytes, 0, blockBytes.length - 8),
  );
  ByteData.sublistView(
    patched,
  ).setInt64(filterOffset - 8, blockChecksum, Endian.big);

  return _recomputeFooterChecksum(patched);
}

/// Reads a single footer field from [bytes] without going through
/// [SstableReader] (which now validates bounds before this generator has a
/// chance to patch them).
int _readFooterField(Uint8List bytes, FooterField field) {
  final footerStart = bytes.length - 48;
  return ByteData.sublistView(
    bytes,
  ).getInt64(footerStart + field.byteOffset, Endian.big);
}

/// Recomputes and overwrites the trailing 8-byte footer checksum so [bytes]
/// (already mutated in place) passes [SstableReader.open]'s checksum check —
/// the review's central point that XXH64 is **not** a defence: an attacker
/// who controls the file body can simply do exactly this.
Uint8List _recomputeFooterChecksum(Uint8List bytes) {
  final toHash = Uint8List.sublistView(bytes, 0, bytes.length - 8);
  final checksum = XxHash64.digest(toHash);
  ByteData.sublistView(bytes).setInt64(bytes.length - 8, checksum, Endian.big);
  return bytes;
}

/// Builds a [ValueCodec]-encoded value that decompresses to
/// [decodedSizeBytes] bytes of highly-compressible content — small on the
/// wire, large once decoded (S-2's decompression-bomb shape, without needing
/// to forge a raw Zstd frame header).
///
/// Reuses the real compressor via [ValueCodec.encode] rather than
/// hand-crafting a Zstd frame — consistent with CLAUDE.md's "prefer existing
/// primitives" guidance, and it is what actually flows through the write
/// path being tested.
Future<Uint8List> buildDecompressionBombValue({
  required int decodedSizeBytes,
}) async {
  // A single repeated string field compresses extremely well and is trivial
  // to build; the CBOR map wrapper overhead is negligible against a
  // multi-megabyte payload.
  final map = {'bomb': 'A' * decodedSizeBytes};
  return ValueCodec.encode(map);
}
