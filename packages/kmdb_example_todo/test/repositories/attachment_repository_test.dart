// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_example_todo/src/db/app_database.dart';
import 'package:kmdb_example_todo/src/models/task.dart';
import 'package:kmdb_example_todo/src/repositories/attachment_repository.dart';
import 'package:kmdb_example_todo/src/repositories/task_repository.dart';

import '../support/temp_dir.dart';

Task _newTask(String projectId, String title) => Task(
  id: '',
  projectId: projectId,
  title: title,
  description: 'd',
  priority: TaskPriority.medium,
  status: TaskStatus.backlog,
  attachmentUris: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  // Vault behaviour depends on genuine filesystem semantics (atomic
  // rename, directory structure) — a real StorageAdapterNative + temp dir,
  // not MemoryStorageAdapter, per CLAUDE.md's note on why in-memory
  // adapters hide durability bugs.
  late Directory tempDir;
  late KmdbDatabase db;
  late TaskRepository tasks;
  late AttachmentRepository attachments;

  setUp(() async {
    tempDir = createTempDir();
    db = await AppDatabase.open(path: tempDir.path);
    tasks = TaskRepository(db);
    attachments = AttachmentRepository(db, tasks);
  });

  tearDown(() async {
    await db.close();
    tempDir.deleteSync(recursive: true);
  });

  group('AttachmentRepository', () {
    test(
      'attach() returns a kmdb-vault://sha256/<64hex> URI and getBlob() '
      'round-trips identical bytes',
      () async {
        final task = await tasks.create(_newTask('proj1', 'With attachment'));
        final bytes = Uint8List.fromList('hello world'.codeUnits);

        final updated = await attachments.attach(
          task: task,
          bytes: bytes,
          originalName: 'hello.txt',
        );

        expect(updated.attachmentUris, hasLength(1));
        final uri = updated.attachmentUris.single;
        expect(
          RegExp(r'^kmdb-vault://sha256/[0-9a-f]{64}$').hasMatch(uri),
          isTrue,
        );

        final roundTripped = await attachments.getBlob(uri);
        expect(roundTripped, bytes);
      },
    );

    test('ingesting identical bytes from two tasks dedupes to one vault object', () async {
      final bytes = Uint8List.fromList('shared content'.codeUnits);
      final taskA = await tasks.create(_newTask('proj1', 'A'));
      final taskB = await tasks.create(_newTask('proj1', 'B'));

      final updatedA = await attachments.attach(
        task: taskA,
        bytes: bytes,
        originalName: 'shared.txt',
      );
      final updatedB = await attachments.attach(
        task: taskB,
        bytes: bytes,
        originalName: 'shared.txt',
      );

      expect(updatedA.attachmentUris.single, updatedB.attachmentUris.single);
    });

    test(
      'a shared vault object survives while any task still references it, '
      'and is only swept once the last reference is removed',
      () async {
        final bytes = Uint8List.fromList('shared content'.codeUnits);
        var taskA = await tasks.create(_newTask('proj1', 'A'));
        var taskB = await tasks.create(_newTask('proj1', 'B'));

        taskA = await attachments.attach(
          task: taskA,
          bytes: bytes,
          originalName: 'shared.txt',
        );
        taskB = await attachments.attach(
          task: taskB,
          bytes: bytes,
          originalName: 'shared.txt',
        );
        final sha256 = VaultRef(taskA.attachmentUris.single).sha256;

        final vaultStore = db.vaultStore!;
        final gc = VaultGc(store: vaultStore, kvStore: db.store);

        // Removing task A's reference leaves task B's reference intact —
        // the object must survive a GC sweep.
        taskA = await attachments.detach(
          task: taskA,
          uri: taskA.attachmentUris.single,
        );
        await gc.sweep();
        expect(await vaultStore.exists(sha256), isTrue);

        // Removing the last reference (task B's) makes the object eligible
        // for collection — the next sweep deletes it.
        taskB = await attachments.detach(
          task: taskB,
          uri: taskB.attachmentUris.single,
        );
        await gc.sweep();
        expect(await vaultStore.exists(sha256), isFalse);
      },
    );

    test('attachment content search (searchVault) finds the hosting task', () async {
      final task = await tasks.create(_newTask('proj1', 'Quarterly report'));
      final markdown = '# Report\n\nRevenue grew substantially this quarter.\n';
      await attachments.attach(
        task: task,
        bytes: Uint8List.fromList(markdown.codeUnits),
        originalName: 'report.md',
      );

      // Vault content extraction/indexing runs asynchronously in a
      // background isolate queue (spec §24 "Vault Search") — poll until the
      // hit appears rather than assuming a fixed delay is always enough.
      var found = false;
      for (var i = 0; i < 100 && !found; i++) {
        final result = await tasks.collection.searchVault(
          'revenue',
          mode: SearchMode.lexical,
        );
        found = result.hits.any((h) => h.id == task.id);
        if (!found) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(found, isTrue);
    });
  });
}
