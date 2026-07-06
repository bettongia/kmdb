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

import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:test/test.dart';

import 'faulty_storage_adapter.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late FaultyStorageAdapter adapter;

  setUp(() => adapter = FaultyStorageAdapter());

  group('FaultyStorageAdapter — content durability', () {
    test('un-synced write vanishes on crash', () async {
      await adapter.writeFile('/db/a', _b('hello'));
      expect(await adapter.fileExists('/db/a'), isTrue);

      adapter.crash();
      expect(await adapter.fileExists('/db/a'), isFalse);
    });

    test(
      'synced write survives crash (after syncDir links the name)',
      () async {
        await adapter.writeFile('/db/a', _b('hello'));
        await adapter.syncFile('/db/a');
        await adapter.syncDir('/db');

        adapter.crash();
        expect(await adapter.readFile('/db/a'), equals(_b('hello')));
      },
    );

    test(
      'content synced but directory not synced still vanishes (H1)',
      () async {
        await adapter.writeFile('/db/sst/x.sst', _b('data'));
        await adapter.syncFile('/db/sst/x.sst');
        // No syncDir('/db/sst') — the directory entry is not durable.

        adapter.crash();
        expect(
          await adapter.fileExists('/db/sst/x.sst'),
          isFalse,
          reason: 'fsync of content does not durably link a new name on Linux',
        );
      },
    );

    test(
      'append without a following syncFile reverts to last durable content',
      () async {
        await adapter.writeFile('/db/log', _b('AAAA'));
        await adapter.syncFile('/db/log');
        await adapter.syncDir('/db');

        await adapter.appendFile('/db/log', _b('BBBB')); // not synced
        expect(await adapter.readFile('/db/log'), equals(_b('AAAABBBB')));

        adapter.crash();
        expect(await adapter.readFile('/db/log'), equals(_b('AAAA')));
      },
    );

    test(
      'append followed by syncFile is durable (name already durable)',
      () async {
        await adapter.writeFile('/db/log', _b('AAAA'));
        await adapter.syncFile('/db/log');
        await adapter.syncDir('/db');

        await adapter.appendFile('/db/log', _b('BBBB'));
        await adapter.syncFile('/db/log');

        adapter.crash();
        expect(await adapter.readFile('/db/log'), equals(_b('AAAABBBB')));
      },
    );
  });

  group('FaultyStorageAdapter — directory durability', () {
    test('un-committed delete is rolled back on crash', () async {
      await adapter.writeFile('/db/a', _b('v'));
      await adapter.syncFile('/db/a');
      await adapter.syncDir('/db');

      await adapter.deleteFile('/db/a'); // delete not yet committed
      expect(await adapter.fileExists('/db/a'), isFalse);

      adapter.crash();
      expect(
        await adapter.fileExists('/db/a'),
        isTrue,
        reason: 'a delete whose directory was not synced is undone by a crash',
      );
    });

    test('committed delete stays deleted after crash', () async {
      await adapter.writeFile('/db/a', _b('v'));
      await adapter.syncFile('/db/a');
      await adapter.syncDir('/db');

      await adapter.deleteFile('/db/a');
      await adapter.syncDir('/db'); // commit the deletion

      adapter.crash();
      expect(await adapter.fileExists('/db/a'), isFalse);
    });

    test(
      'rename not committed reverts: destination keeps prior durable content',
      () async {
        // Establish a durable destination (the "old CURRENT").
        await adapter.writeFile('/db/CURRENT', _b('OLD'));
        await adapter.syncFile('/db/CURRENT');
        await adapter.syncDir('/db');

        // Stage a replacement via tmp + rename, but do not syncDir.
        await adapter.writeFile('/db/CURRENT.tmp', _b('NEW'));
        await adapter.syncFile('/db/CURRENT.tmp');
        await adapter.renameFile('/db/CURRENT.tmp', '/db/CURRENT');
        expect(await adapter.readFile('/db/CURRENT'), equals(_b('NEW')));

        adapter.crash();
        expect(
          await adapter.readFile('/db/CURRENT'),
          equals(_b('OLD')),
          reason:
              'an un-synced rename leaves the destination at its prior content',
        );
        expect(await adapter.fileExists('/db/CURRENT.tmp'), isFalse);
      },
    );

    test('rename committed by syncDir survives crash', () async {
      await adapter.writeFile('/db/CURRENT', _b('OLD'));
      await adapter.syncFile('/db/CURRENT');
      await adapter.syncDir('/db');

      await adapter.writeFile('/db/CURRENT.tmp', _b('NEW'));
      await adapter.syncFile('/db/CURRENT.tmp');
      await adapter.renameFile('/db/CURRENT.tmp', '/db/CURRENT');
      await adapter.syncDir('/db');

      adapter.crash();
      expect(await adapter.readFile('/db/CURRENT'), equals(_b('NEW')));
      expect(await adapter.fileExists('/db/CURRENT.tmp'), isFalse);
    });
  });

  group('FaultyStorageAdapter — locks', () {
    test('crash releases held locks', () async {
      await adapter.acquireLock('/db/LOCK');
      await expectLater(
        adapter.acquireLock('/db/LOCK'),
        throwsA(isA<LockException>()),
      );

      adapter.crash();
      // Lock is released by the crash, so it can be re-acquired on reopen.
      await adapter.acquireLock('/db/LOCK');
    });
  });

  // Exercises the real, non-overridden FaultyStorageAdapter.listFilesRecursive
  // implementation directly. This is the fault-injection harness the plan's
  // VaultGc/VaultRecovery tests exercise, so its own listFilesRecursive must
  // be genuinely tested, not merely assumed correct because it's a real scan.
  group('FaultyStorageAdapter — listFilesRecursive', () {
    test('includes files nested arbitrarily deep', () async {
      await adapter.writeFile('/db/vault/ab/cdef/manifest.json', _b(''));
      final paths = await adapter.listFilesRecursive('/db/vault');
      expect(paths, equals(['ab/cdef/manifest.json']));
    });

    test('returned paths have no leading path separator', () async {
      await adapter.writeFile('/db/vault/ab/cdef/manifest.json', _b(''));
      final paths = await adapter.listFilesRecursive('/db/vault');
      for (final path in paths) {
        expect(path.startsWith('/'), isFalse);
      }
    });

    test('reflects only live (non-crashed) content', () async {
      await adapter.writeFile('/db/vault/ab/cdef/manifest.json', _b(''));
      // The write is un-synced, so a crash discards it — listFilesRecursive
      // must reflect the live view, consistent with listFiles/fileExists.
      adapter.crash();
      expect(await adapter.listFilesRecursive('/db/vault'), isEmpty);
    });

    test('empty list for missing directory', () async {
      expect(await adapter.listFilesRecursive('/db/nonexistent'), isEmpty);
    });
  });
}
