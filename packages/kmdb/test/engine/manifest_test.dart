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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/manifest/current_file.dart';
import 'package:kmdb/src/engine/manifest/manifest_reader.dart';
import 'package:kmdb/src/engine/manifest/manifest_writer.dart';
import 'package:kmdb/src/engine/manifest/version_edit.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';

const _dir = '/db';
const _manifestName = 'MANIFEST-00001';
const _manifestPath = '$_dir/$_manifestName';

VersionEdit _edit({
  int log = 1,
  int seq = 100,
  List<SstableMeta> added = const [],
  List<SstableRef> removed = const [],
}) => VersionEdit(logNumber: log, nextSeq: seq, added: added, removed: removed);

SstableMeta _meta(String filename, {int level = 0}) => SstableMeta(
  level: level,
  filename: filename,
  minKey: '0' * 32,
  maxKey: 'f' * 32,
  entryCount: 10,
);

/// Extracts bare filenames from a [ManifestState] level list for use in
/// assertions. The state now carries full [SstableMeta]; callers that only
/// care about filename membership use this helper.
List<String> _levelFiles(ManifestState state, int level) =>
    (state.levels[level] ?? []).map((m) => m.filename).toList();

void main() {
  group('VersionEdit CBOR round-trip', () {
    test('empty edit round-trips', () {
      final edit = _edit();
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.logNumber, equals(1));
      expect(decoded.nextSeq, equals(100));
      expect(decoded.added, isEmpty);
      expect(decoded.removed, isEmpty);
    });

    // The `cbor` library can return BigInt for integers that exceed 32 bits.
    // _toInt() handles this transparently; SstableMeta.fromMap uses _toInt()
    // on every integer field, so a round-trip through toCbor/fromCbor with a
    // large HLC value exercises the BigInt branch.
    test('BigInt integers (large HLC values) round-trip via _toInt', () {
      // Use a nextSeq value > 2^32 to ensure the cbor library may return BigInt.
      final largeSeq = 0x1FFFFFFFF; // 8 589 934 591 — exceeds int32 range.
      final edit = VersionEdit(
        logNumber: 42,
        nextSeq: largeSeq,
        added: [
          SstableMeta(
            level: 1,
            filename: 'dev-${largeSeq}00-${largeSeq}01.sst',
            minKey: '0' * 32,
            maxKey: 'f' * 32,
            entryCount: largeSeq,
            walSequence: largeSeq,
          ),
        ],
        removed: [const SstableRef(level: 1, filename: 'old-big.sst')],
      );
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.logNumber, equals(42));
      expect(decoded.nextSeq, equals(largeSeq));
      expect(decoded.added.first.entryCount, equals(largeSeq));
      expect(decoded.added.first.walSequence, equals(largeSeq));
    });

    // toMap() is the diagnostic representation used by `kmdb util manifest --full`.
    // Exercise it directly to cover the code path.
    test('VersionEdit.toMap returns JSON-compatible map', () {
      final edit = _edit(
        log: 7,
        seq: 12345,
        added: [_meta('add-file.sst')],
        removed: [const SstableRef(level: 0, filename: 'rem-file.sst')],
      );
      final m = edit.toMap();
      expect(m['logNumber'], equals(7));
      expect(m['nextSeq'], equals(12345));
      expect((m['added'] as List).length, equals(1));
      expect((m['removed'] as List).length, equals(1));
      // Added entry map should have the filename key.
      expect((m['added'] as List).first['filename'], equals('add-file.sst'));
      // Removed entry map should have the filename key.
      expect((m['removed'] as List).first['filename'], equals('rem-file.sst'));
    });

    test('fromCbor throws FormatException on non-CBOR-map bytes', () {
      // CBOR uint(42) = 0x18 0x2A — a valid CBOR value but not a CborMap.
      // VersionEdit.fromCbor must reject it with FormatException.
      expect(
        () => VersionEdit.fromCbor([0x18, 0x2A]),
        throwsA(isA<FormatException>()),
      );
    });

    test('add and remove entries survive round-trip', () {
      final edit = _edit(
        log: 3,
        seq: 5000,
        added: [
          SstableMeta(
            level: 0,
            filename: 'abc-000001-000002.sst',
            minKey: '0' * 32,
            maxKey: 'f' * 32,
            entryCount: 128,
            walSequence: 3,
          ),
        ],
        removed: [
          const SstableRef(level: 0, filename: 'old-000000-000001.sst'),
        ],
      );
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.added.length, equals(1));
      expect(decoded.added[0].walSequence, equals(3));
      expect(decoded.removed.length, equals(1));
      expect(decoded.removed[0].filename, equals('old-000000-000001.sst'));
    });
  });

  group('ManifestWriter / ManifestReader', () {
    test('single edit is readable after write', () async {
      final adapter = MemoryStorageAdapter();
      final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
      final edit = _edit(
        log: 1,
        seq: 200,
        added: [_meta('a1b2c3d4-000001-000002.sst')],
      );
      await writer.append(edit);

      final reader = ManifestReader(adapter: adapter);
      final state = await reader.replay(_manifestPath);
      expect(_levelFiles(state, 0), contains('a1b2c3d4-000001-000002.sst'));
      // Verify metadata is carried through replay (not just the filename).
      final meta = state.levels[0]!.first;
      expect(meta.minKey, equals('0' * 32));
      expect(meta.maxKey, equals('f' * 32));
      expect(meta.entryCount, equals(10));
      expect(state.maxLogNumber, equals(1));
      expect(state.maxNextSeq, equals(200));
    });

    test('multiple edits accumulate level state', () async {
      final adapter = MemoryStorageAdapter();
      final writer = ManifestWriter(path: _manifestPath, adapter: adapter);

      await writer.append(_edit(log: 1, seq: 100, added: [_meta('file1.sst')]));
      await writer.append(
        _edit(
          log: 2,
          seq: 200,
          added: [_meta('file2.sst')],
          removed: [const SstableRef(level: 0, filename: 'file1.sst')],
        ),
      );
      await writer.append(
        _edit(log: 3, seq: 300, added: [_meta('file3.sst', level: 1)]),
      );

      final state = await ManifestReader(
        adapter: adapter,
      ).replay(_manifestPath);
      expect(_levelFiles(state, 0), equals(['file2.sst']));
      expect(_levelFiles(state, 1), contains('file3.sst'));
      expect(state.maxLogNumber, equals(3));
      expect(state.maxNextSeq, equals(300));
    });

    test('corrupted last record is silently ignored', () async {
      final adapter = MemoryStorageAdapter();
      final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
      await writer.append(_edit(log: 1, seq: 100, added: [_meta('file1.sst')]));
      await writer.append(_edit(log: 2, seq: 200, added: [_meta('file2.sst')]));

      // Corrupt the last few bytes of the file to simulate truncation.
      final raw = adapter.files[_manifestPath]!;
      final corrupted = Uint8List.fromList(raw);
      corrupted[corrupted.length - 1] ^= 0xFF;
      adapter.files[_manifestPath] = corrupted;

      final state = await ManifestReader(
        adapter: adapter,
      ).replay(_manifestPath);
      // Only the first record should be visible.
      expect(_levelFiles(state, 0), equals(['file1.sst']));
    });

    test('returns empty state when file does not exist', () async {
      final adapter = MemoryStorageAdapter();
      final state = await ManifestReader(
        adapter: adapter,
      ).replay('/nonexistent/MANIFEST-00001');
      expect(state.levels[0], isEmpty);
      expect(state.maxLogNumber, equals(0));
    });

    test('allFiles spans all levels', () async {
      final adapter = MemoryStorageAdapter();
      final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
      await writer.append(
        _edit(
          added: [
            _meta('l0.sst', level: 0),
            _meta('l1.sst', level: 1),
            _meta('l2.sst', level: 2),
          ],
        ),
      );
      final state = await ManifestReader(
        adapter: adapter,
      ).replay(_manifestPath);
      expect(state.allFiles.toSet(), equals({'l0.sst', 'l1.sst', 'l2.sst'}));
    });
  });

  group('ManifestReader — filename reuse within a single edit', () {
    // Regression test for the manifest-replay data-loss bug
    // (plan_manifest_replay_added_removed_ordering.md).
    //
    // `_fromEdits` folds `added`/`removed` into `liveMeta[level][filename]` —
    // keyed by the PAIR (level, filename), not filename alone. A compaction
    // output can legitimately reuse an input's filename in place (same
    // deviceId + minHlc/maxHlc, e.g. `_compactAll` merging an existing L2
    // file with a new entry whose HLC falls entirely inside that file's
    // existing range, so the merged range — and therefore the filename — is
    // unchanged). When that reused input was *already at the same level* as
    // the compaction's output (both level 2 for `_compactAll`), the SAME
    // (level, filename) pair appears in both `added` and `removed` of one
    // edit. Before the fix, `_fromEdits` applied `added` before `removed`
    // within an edit, so the `removed` loop deleted the entry the `added`
    // loop had just inserted into the SAME map bucket — the file was
    // incorrectly dropped from the reconstructed state, and crash recovery's
    // orphan sweep would then delete the still-live SSTable from disk.
    //
    // Note: a filename reused across DIFFERENT levels (e.g. an L1 file
    // recompacted to L2, unchanged) does NOT hit this bug — `added` and
    // `removed` land in different `liveMeta[level]` buckets and the ordering
    // is immaterial. Only a same-level collision (level(added) ==
    // level(removed), reachable via `_compactAll`) exposes it; see the
    // engine-level regression in
    // `manifest_replay_filename_reuse_regression_test.dart` for the
    // real-compaction reproduction and why the naive "single L1/L0 input"
    // recipe does not trigger it.
    test(
      'a filename present in both added and removed of one edit at the '
      'SAME level resolves to present, with the added entry\'s metadata',
      () async {
        final adapter = MemoryStorageAdapter();
        final writer = ManifestWriter(path: _manifestPath, adapter: adapter);

        // Seed state: an unrelated live file (level 0, untouched by the
        // second edit — proves the fold is otherwise intact) plus the file
        // that will be "reused" in place by a later same-level compaction.
        await writer.append(
          _edit(
            log: 1,
            seq: 100,
            added: [
              _meta('unrelated-000001-000002.sst'),
              _meta('reused-000003-000004.sst', level: 2),
            ],
          ),
        );

        // The degenerate compaction edit: the output filename equals the
        // sole surviving input's filename (identical deviceId/minHlc/maxHlc
        // — an in-place overwrite), AND it is recorded at the SAME level (2)
        // as the removed input it reuses. This is the exact (level,
        // filename) collision `_compactAll` can produce.
        final reusedMeta = SstableMeta(
          level: 2,
          filename: 'reused-000003-000004.sst',
          minKey: '1' * 32,
          maxKey: 'e' * 32,
          entryCount: 42,
        );
        await writer.append(
          _edit(
            log: 2,
            seq: 200,
            added: [reusedMeta],
            removed: [
              const SstableRef(level: 2, filename: 'reused-000003-000004.sst'),
            ],
          ),
        );

        final state = await ManifestReader(
          adapter: adapter,
        ).replay(_manifestPath);

        // The unrelated file must still be present, proving the fold is
        // otherwise intact.
        expect(_levelFiles(state, 0), contains('unrelated-000001-000002.sst'));

        // The reused file must be present at level 2 — not dropped.
        expect(_levelFiles(state, 2), contains('reused-000003-000004.sst'));

        // The surviving metadata must be the *added* entry's, not stale data
        // from the earlier edit.
        final survivor = state.levels[2]!.firstWhere(
          (m) => m.filename == 'reused-000003-000004.sst',
        );
        expect(survivor.minKey, equals('1' * 32));
        expect(survivor.maxKey, equals('e' * 32));
        expect(survivor.entryCount, equals(42));
      },
    );
  });

  group('ManifestReader — truncation edge cases', () {
    test('truncated header (< 12 bytes) yields empty state', () async {
      final adapter = MemoryStorageAdapter();
      // Write 8 bytes — less than the minimum 12-byte header.
      adapter.files[_manifestPath] = Uint8List.fromList(List.filled(8, 0xAB));
      final state = await ManifestReader(
        adapter: adapter,
      ).replay(_manifestPath);
      expect(state.levels[0], isEmpty);
    });

    test(
      'record whose declared CBOR length exceeds remaining bytes is skipped',
      () async {
        // Write a valid first record then a second record whose length field
        // claims more bytes than the file contains.
        final adapter = MemoryStorageAdapter();
        final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
        await writer.append(_edit(log: 1, seq: 50, added: [_meta('good.sst')]));

        // Append a malformed header: checksum (8B) + length (4B) declaring
        // 1 000 000 bytes, but no payload follows.
        final raw = adapter.files[_manifestPath]!;
        final corrupt = ByteData(raw.length + 12);
        for (var i = 0; i < raw.length; i++) {
          corrupt.setUint8(i, raw[i]);
        }
        // Length = 1_000_000 with no payload
        corrupt.setInt64(raw.length, 0, Endian.big);
        corrupt.setUint32(raw.length + 8, 1000000, Endian.big);
        adapter.files[_manifestPath] = corrupt.buffer.asUint8List();

        final state = await ManifestReader(
          adapter: adapter,
        ).replay(_manifestPath);
        // Only the valid first record should contribute.
        expect(_levelFiles(state, 0), contains('good.sst'));
        expect(state.maxLogNumber, equals(1));
      },
    );
  });

  group('ManifestReader.replayEdits()', () {
    test('returns raw edits in order', () async {
      final adapter = MemoryStorageAdapter();
      final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
      await writer.append(_edit(log: 1, seq: 100, added: [_meta('a.sst')]));
      await writer.append(_edit(log: 2, seq: 200, added: [_meta('b.sst')]));

      final edits = await ManifestReader(
        adapter: adapter,
      ).replayEdits(_manifestPath);
      expect(edits, hasLength(2));
      expect(edits[0].logNumber, equals(1));
      expect(edits[1].logNumber, equals(2));
    });

    test('returns empty list for missing file', () async {
      final adapter = MemoryStorageAdapter();
      final edits = await ManifestReader(
        adapter: adapter,
      ).replayEdits('/nonexistent/MANIFEST-00001');
      expect(edits, isEmpty);
    });

    test(
      'stops at corrupted record and returns only prior valid edits',
      () async {
        final adapter = MemoryStorageAdapter();
        final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
        await writer.append(_edit(log: 1, seq: 100, added: [_meta('ok.sst')]));
        await writer.append(_edit(log: 2, seq: 200, added: [_meta('ok2.sst')]));

        // Corrupt the last byte of the second record.
        final raw = adapter.files[_manifestPath]!;
        final corrupted = Uint8List.fromList(raw);
        corrupted[corrupted.length - 1] ^= 0xFF;
        adapter.files[_manifestPath] = corrupted;

        final edits = await ManifestReader(
          adapter: adapter,
        ).replayEdits(_manifestPath);
        expect(edits, hasLength(1));
        expect(edits[0].added.first.filename, equals('ok.sst'));
      },
    );

    test('truncated header in replayEdits returns prior valid edits', () async {
      final adapter = MemoryStorageAdapter();
      final writer = ManifestWriter(path: _manifestPath, adapter: adapter);
      await writer.append(_edit(log: 1, seq: 10, added: [_meta('x.sst')]));

      final raw = adapter.files[_manifestPath]!;
      // Append 5 trailing bytes — less than the 12-byte minimum header.
      final withTrail = Uint8List(raw.length + 5);
      withTrail.setAll(0, raw);
      adapter.files[_manifestPath] = withTrail;

      final edits = await ManifestReader(
        adapter: adapter,
      ).replayEdits(_manifestPath);
      expect(edits, hasLength(1));
    });
  });

  group('CurrentFile', () {
    test('write then read returns same manifest name', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(await cf.read(), equals(_manifestName));
    });

    test('manifestPath returns full path', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(await cf.manifestPath(), equals(_manifestPath));
    });

    test('exists returns false before write', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      expect(await cf.exists(), isFalse);
    });

    test('exists returns true after write', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(await cf.exists(), isTrue);
    });

    test('nextManifestName increments sequence', () {
      expect(
        CurrentFile.nextManifestName('MANIFEST-00001'),
        equals('MANIFEST-00002'),
      );
      expect(
        CurrentFile.nextManifestName('MANIFEST-00009'),
        equals('MANIFEST-00010'),
      );
    });

    test('nextManifestName throws on invalid format', () {
      expect(
        () => CurrentFile.nextManifestName('INVALID'),
        throwsA(isA<FormatException>()),
      );
    });

    test('write is atomic — uses rename', () async {
      // In the memory adapter rename is atomic; check the tmp file is cleaned up.
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(adapter.files.containsKey('$_dir/CURRENT.tmp'), isFalse);
      expect(adapter.files.containsKey('$_dir/CURRENT'), isTrue);
    });
  });
}
