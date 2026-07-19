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

/// Regression tests reproducing the 2026-07-18 release-readiness review's
/// confirmed S-1 probes (PROBE1–3) against the checksum-valid, structurally
/// hostile fixtures built by `test/util/hostile_sstable.dart`.
///
/// Run against [StorageAdapterNative] — not [MemoryStorageAdapter] — because
/// the review found the memory adapter's own bounds-checking in
/// `readFileRange` hides the most severe form of these failures (an
/// uncatchable `OutOfMemoryError` on the native adapter, vs. a catchable
/// `StorageException` on the memory one). This is exactly the "run the sync
/// tests against `StorageAdapterNative`" item from Phase 8 of the
/// sync-trust-boundary plan, scoped to the SSTable reader itself.
library;

import 'dart:io';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_native.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:test/test.dart';

import '../util/hostile_sstable.dart';

void main() {
  late Directory tempDir;
  late StorageAdapterNative adapter;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kmdb_hostile_sstable_');
    adapter = StorageAdapterNative();
    path = '${tempDir.path}/hostile.sst';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('checksum-valid, structurally hostile SSTables (S-1)', () {
    test('PROBE1 — filterSize = 1<<40 is rejected before allocation, not an '
        'OutOfMemoryError', () async {
      final valid = buildValidSstable();
      final hostile = patchFooterField(
        valid,
        field: FooterField.filterSize,
        value: 1 << 40,
      );
      await File(path).writeAsBytes(hostile);

      // Before the S-1 fix this reached `malloc` and threw
      // `OutOfMemoryError` — an `Error`, uncatchable by the `Exception`
      // hierarchy that every ingest call site was written against.
      await expectLater(
        SstableReader.open(path, adapter),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('PROBE2 — filterOffset = -4096 is rejected as a negative offset, not '
        'a StorageException from setPosition', () async {
      final valid = buildValidSstable();
      final hostile = patchFooterField(
        valid,
        field: FooterField.filterOffset,
        value: -4096,
      );
      await File(path).writeAsBytes(hostile);

      await expectLater(
        SstableReader.open(path, adapter),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('PROBE3 — an oversized index keyLen (127) is rejected before '
        'sublistView, not a bare RangeError', () async {
      final valid = buildValidSstable();
      final hostile = patchIndexKeyLen(valid, newKeyLen: 127);
      await File(path).writeAsBytes(hostile);

      await expectLater(
        SstableReader.open(path, adapter),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test(
      'an index blockOffset large enough to exceed the file is rejected as '
      'CorruptedSstableException, not a bare StorageException (QA finding B1)',
      () async {
        final valid = buildValidSstable();
        final hostile = patchIndexBlockOffsetOrSize(
          valid,
          field: IndexEntryField.blockOffset,
        );
        await File(path).writeAsBytes(hostile);

        // The bad blockOffset is only touched once the corresponding block
        // is read, not at open() itself.
        final reader = await SstableReader.open(path, adapter);
        await expectLater(
          reader.firstKey(),
          throwsA(isA<CorruptedSstableException>()),
        );
      },
    );

    test(
      'an index blockSize large enough to exceed the file is rejected as '
      'CorruptedSstableException, not a bare StorageException (QA finding B1)',
      () async {
        final valid = buildValidSstable();
        final hostile = patchIndexBlockOffsetOrSize(
          valid,
          field: IndexEntryField.blockSize,
        );
        await File(path).writeAsBytes(hostile);

        final reader = await SstableReader.open(path, adapter);
        await expectLater(
          reader.firstKey(),
          throwsA(isA<CorruptedSstableException>()),
        );
      },
    );

    test(
      'a malformed 10-byte sign-bit-overflowing varint reached through index '
      'parsing is rejected as CorruptedSstableException, not a bare '
      'FormatException (QA finding B1)',
      () async {
        final valid = buildValidSstable();
        final hostile = patchIndexVarintOverflow(valid);
        await File(path).writeAsBytes(hostile);

        await expectLater(
          SstableReader.open(path, adapter),
          throwsA(isA<CorruptedSstableException>()),
        );
      },
    );

    test('a data block whose first entry has a non-zero shared-prefix length '
        'is rejected before the reconstruction allocation', () async {
      final valid = buildValidSstable();
      final hostile = patchBlockShared(valid, newShared: 127);
      await File(path).writeAsBytes(hostile);

      // firstKey() decodes the first block; open() itself only loads the
      // filter/index, so the corruption surfaces on the first block read.
      final reader = await SstableReader.open(path, adapter);
      await expectLater(
        reader.firstKey(),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('a data block whose first entry has an oversized unsharedLen is '
        'rejected before the key-slice allocation', () async {
      // A single-entry SSTable keeps the block small enough that 127
      // reliably overflows the remaining bytes.
      final valid = buildValidSstable(entryCount: 1);
      final hostile = patchBlockUnsharedLen(valid, newUnsharedLen: 127);
      await File(path).writeAsBytes(hostile);

      final reader = await SstableReader.open(path, adapter);
      await expectLater(
        reader.firstKey(),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('a data block whose first entry has an oversized valueLen is '
        'rejected before the value-slice allocation', () async {
      final valid = buildValidSstable(entryCount: 1);
      final hostile = patchBlockValueLen(valid, newValueLen: 127);
      await File(path).writeAsBytes(hostile);

      final reader = await SstableReader.open(path, adapter);
      await expectLater(
        reader.firstKey(),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('negative footer offsets/sizes are all rejected uniformly', () async {
      for (final field in FooterField.values) {
        final valid = buildValidSstable();
        final hostile = patchFooterField(valid, field: field, value: -1);
        final fieldPath = '${tempDir.path}/hostile-${field.name}.sst';
        await File(fieldPath).writeAsBytes(hostile);

        await expectLater(
          SstableReader.open(fieldPath, adapter),
          throwsA(isA<CorruptedSstableException>()),
          reason: 'field ${field.name} = -1 should be rejected',
        );
      }
    });

    test(
      'a decompression-bomb value sitting inert in an otherwise valid '
      'SSTable is rejected at ValueCodec.decode, not at ingest (S-2)',
      () async {
        // 2 MiB decoded, well over ValueCodec.kMaxDecodedValueBytes (1 MiB),
        // but highly compressible so the encoded bytes are tiny.
        final bombValue = await buildDecompressionBombValue(
          decodedSizeBytes: 2 * 1024 * 1024,
        );
        final sstableBytes = buildSstableWithValue(bombValue);
        await File(path).writeAsBytes(sstableBytes);

        // Ingest-equivalent: opening the reader and reading the raw value
        // bytes must succeed — ingest never decodes values (verified in the
        // review's S-2 "detonation point" analysis).
        final reader = await SstableReader.open(path, adapter);
        final key = (await reader.firstKey())!;
        final rawValue = await reader.get(key);
        expect(rawValue, isNotNull);

        // The bomb only detonates when something actually decodes the value.
        await expectLater(
          ValueCodec.decode(rawValue!),
          throwsA(isA<DecodedValueTooLargeException>()),
        );
      },
    );
  });
}
