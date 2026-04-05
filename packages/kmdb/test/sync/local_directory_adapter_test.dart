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

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/src/sync/local/local_directory_adapter.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late LocalDirectoryAdapter adapter;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_directory_adapter_');
    adapter = LocalDirectoryAdapter(tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ── upload / download ────────────────────────────────────────────────────────

  test('upload and download a file', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await adapter.upload('dir/file.bin', bytes);
    final result = await adapter.download('dir/file.bin');
    expect(result, equals(bytes));
  });

  test('upload creates intermediate directories', () async {
    await adapter.upload('a/b/c/file.bin', Uint8List.fromList([9]));
    expect(File('${tempDir.path}/a/b/c/file.bin').existsSync(), isTrue);
  });

  test('download returns null for missing file', () async {
    final result = await adapter.download('missing.bin');
    expect(result, isNull);
  });

  test('upload overwrites existing content', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    await adapter.upload('f', Uint8List.fromList([2, 3]));
    final result = await adapter.download('f');
    expect(result, equals(Uint8List.fromList([2, 3])));
  });

  // ── list ─────────────────────────────────────────────────────────────────────

  test('list returns direct children of a directory', () async {
    await adapter.upload('dir/a.sst', Uint8List(0));
    await adapter.upload('dir/b.sst', Uint8List(0));
    // Nested file is not a direct child — expect it to be excluded since list()
    // uses non-recursive Directory.list().
    await adapter.upload('dir/sub/c.sst', Uint8List(0));
    await adapter.upload('other/d.sst', Uint8List(0));

    final files = await adapter.list('dir');
    expect(files, containsAll(['a.sst', 'b.sst']));
    expect(files, isNot(contains('c.sst')));
    expect(files, isNot(contains('d.sst')));
    expect(files.length, equals(2));
  });

  test('list with extension filter returns only matching files', () async {
    await adapter.upload('dir/a.sst', Uint8List(0));
    await adapter.upload('dir/b.hwm', Uint8List(0));
    final files = await adapter.list('dir', extension: '.sst');
    expect(files, equals(['a.sst']));
  });

  test('list returns empty list for non-existent directory', () async {
    final files = await adapter.list('nonexistent');
    expect(files, isEmpty);
  });

  // ── delete ───────────────────────────────────────────────────────────────────

  test('delete removes the file', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    await adapter.delete('f');
    final result = await adapter.download('f');
    expect(result, isNull);
  });

  test('delete is a no-op for missing file', () async {
    await expectLater(adapter.delete('missing'), completes);
  });

  // ── getEtag ──────────────────────────────────────────────────────────────────

  test('getEtag returns null for missing file', () async {
    expect(await adapter.getEtag('missing'), isNull);
  });

  test('getEtag returns a 16-char hex string after upload', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final etag = await adapter.getEtag('f');
    expect(etag, isNotNull);
    expect(etag, matches(RegExp(r'^[0-9A-F]{16}$')));
  });

  test('getEtag is deterministic for the same content', () async {
    final bytes = Uint8List.fromList([10, 20, 30]);
    await adapter.upload('f1', bytes);
    await adapter.upload('f2', bytes);
    expect(await adapter.getEtag('f1'), equals(await adapter.getEtag('f2')));
  });

  test('getEtag differs for files with different content', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final etag1 = await adapter.getEtag('f');
    await adapter.upload('f', Uint8List.fromList([2]));
    final etag2 = await adapter.getEtag('f');
    expect(etag1, isNot(equals(etag2)));
  });

  test(
    'getEtag differs for files that are the same size but different content',
    () async {
      // Regression: a file-size based approach would return equal ETags here.
      await adapter.upload('f', Uint8List.fromList([0x00]));
      final etag1 = await adapter.getEtag('f');
      await adapter.upload('f', Uint8List.fromList([0xff]));
      final etag2 = await adapter.getEtag('f');
      expect(etag1, isNot(equals(etag2)));
    },
  );

  test('getEtag returns null after delete', () async {
    await adapter.upload('f', Uint8List(1));
    await adapter.delete('f');
    expect(await adapter.getEtag('f'), isNull);
  });

  // ── compareAndSwap: if-none-match semantics ───────────────────────────────────

  test(
    'compareAndSwap with null ifMatchEtag succeeds when file absent',
    () async {
      final bytes = Uint8List.fromList([42]);
      final result = await adapter.compareAndSwap(
        'f',
        bytes,
        ifMatchEtag: null,
      );
      expect(result, isTrue);
      expect(await adapter.download('f'), equals(bytes));
    },
  );

  test('compareAndSwap with null ifMatchEtag fails when file exists', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final result = await adapter.compareAndSwap(
      'f',
      Uint8List.fromList([2]),
      ifMatchEtag: null,
    );
    expect(result, isFalse);
    // Original content is unchanged.
    expect(await adapter.download('f'), equals(Uint8List.fromList([1])));
  });

  test(
    'compareAndSwap with null ifMatchEtag creates parent directories',
    () async {
      final result = await adapter.compareAndSwap(
        'deep/nested/f',
        Uint8List.fromList([7]),
        ifMatchEtag: null,
      );
      expect(result, isTrue);
      expect(File('${tempDir.path}/deep/nested/f').existsSync(), isTrue);
    },
  );

  test(
    'compareAndSwap with null ifMatchEtag leaves no temp file on success',
    () async {
      await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([1]),
        ifMatchEtag: null,
      );
      // No .cas-tmp-* files should remain.
      final tmpFiles = tempDir
          .listSync(recursive: true)
          .where((e) => e.path.contains('.cas-tmp-'))
          .toList();
      expect(tmpFiles, isEmpty);
    },
  );

  // ── compareAndSwap: conditional update ────────────────────────────────────────

  test('compareAndSwap with matching etag succeeds', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final etag = await adapter.getEtag('f');
    final newBytes = Uint8List.fromList([99]);
    final result = await adapter.compareAndSwap(
      'f',
      newBytes,
      ifMatchEtag: etag,
    );
    expect(result, isTrue);
    expect(await adapter.download('f'), equals(newBytes));
  });

  test('compareAndSwap with stale etag fails', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final staleEtag = await adapter.getEtag('f');
    // Another writer updates the file.
    await adapter.upload('f', Uint8List.fromList([2]));
    // Now try with the stale etag.
    final result = await adapter.compareAndSwap(
      'f',
      Uint8List.fromList([3]),
      ifMatchEtag: staleEtag,
    );
    expect(result, isFalse);
    // File retains the value from the intervening write.
    expect(await adapter.download('f'), equals(Uint8List.fromList([2])));
  });

  test('compareAndSwap with etag fails when file does not exist', () async {
    final result = await adapter.compareAndSwap(
      'f',
      Uint8List.fromList([1]),
      ifMatchEtag: 'nonexistent-etag',
    );
    expect(result, isFalse);
  });

  test(
    'compareAndSwap with matching etag leaves no temp file on success',
    () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final etag = await adapter.getEtag('f');
      await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([2]),
        ifMatchEtag: etag,
      );
      final tmpFiles = tempDir
          .listSync(recursive: true)
          .where((e) => e.path.contains('.cas-tmp-'))
          .toList();
      expect(tmpFiles, isEmpty);
    },
  );

  test('compareAndSwap updates etag on success', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final etag1 = await adapter.getEtag('f');
    await adapter.compareAndSwap(
      'f',
      Uint8List.fromList([2]),
      ifMatchEtag: etag1,
    );
    final etag2 = await adapter.getEtag('f');
    expect(etag1, isNot(equals(etag2)));
  });
}
