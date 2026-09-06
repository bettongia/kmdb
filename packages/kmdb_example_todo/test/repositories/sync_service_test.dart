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
import 'package:kmdb_example_todo/src/repositories/sync_service.dart';
import 'package:kmdb_example_todo/src/repositories/task_repository.dart';

import '../support/temp_dir.dart';

Task _newTask(String title) => Task(
  id: '',
  projectId: 'proj1',
  title: title,
  description: 'd',
  priority: TaskPriority.medium,
  status: TaskStatus.backlog,
  attachmentUris: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  // Sync depends on genuine filesystem semantics (SSTable files, directory
  // listing) — real StorageAdapterNative + temp dirs, per CLAUDE.md's note
  // on why in-memory adapters hide durability bugs.
  late Directory dirA;
  late Directory dirB;
  late Directory sharedSyncDir;
  late KmdbDatabase dbA;
  late KmdbDatabase dbB;

  setUp(() async {
    dirA = createTempDir();
    dirB = createTempDir();
    sharedSyncDir = createTempDir();
    dbA = await AppDatabase.open(path: dirA.path);
    dbB = await AppDatabase.open(path: dirB.path);
  });

  tearDown(() async {
    // flush: false — cleanup only, the temp dirs are deleted immediately
    // below regardless. A flushing close() can trigger a background
    // compaction that re-reads every peer's `.hwm` file (as the registered
    // tombstone-GC-horizon provider) — for the negative-authentication test
    // below, that peer file can no longer be authenticated with this
    // device's (deliberately different) root key, which would otherwise
    // throw during teardown itself rather than from the `sync()` call the
    // test actually exercises.
    await dbA.close(flush: false);
    await dbB.close(flush: false);
    dirA.deleteSync(recursive: true);
    dirB.deleteSync(recursive: true);
    sharedSyncDir.deleteSync(recursive: true);
  });

  group('SyncService — happy path convergence', () {
    test(
      'A writes, A.sync() then B.sync() — B reads A\'s task (LWW)',
      () async {
        final tasksA = TaskRepository(dbA);
        final tasksB = TaskRepository(dbB);
        final syncA = SyncService(dbA, sharedSyncDir.path);
        final syncB = SyncService(dbB, sharedSyncDir.path);

        final created = await tasksA.create(_newTask('Write the guide'));

        final resultA = await syncA.syncNow();
        expect(resultA, isA<SyncResult>());
        expect(resultA.pull.quarantined, isEmpty);
        expect(resultA.pull.deferred, isEmpty);

        final resultB = await syncB.syncNow();
        expect(resultB, isA<SyncResult>());
        expect(resultB.pull.quarantined, isEmpty);

        final fetched = await tasksB.get(created.id);
        expect(fetched, isNotNull);
        expect(fetched!.title, 'Write the guide');
      },
    );

    test(
      'concurrent edits to the same task resolve by HLC (last write wins)',
      () async {
        final tasksA = TaskRepository(dbA);
        final tasksB = TaskRepository(dbB);
        final syncA = SyncService(dbA, sharedSyncDir.path);
        final syncB = SyncService(dbB, sharedSyncDir.path);

        // Both devices start from the same document.
        final created = await tasksA.create(_newTask('Original'));
        await syncA.syncNow();
        await syncB.syncNow();

        // A edits first...
        final onA = (await tasksA.get(created.id))!;
        await tasksA.update(onA.copyWith(title: 'Edited by A'));
        await syncA.syncNow();

        // ...then B edits strictly later (higher HLC) — B's write must win
        // once both sides have seen both edits.
        final onB = (await tasksB.get(created.id))!;
        await tasksB.update(onB.copyWith(title: 'Edited by B'));
        await syncB.syncNow(); // push B's edit, pull A's (older) edit
        await syncA.syncNow(); // pull B's (newer) edit

        expect((await tasksA.get(created.id))!.title, 'Edited by B');
        expect((await tasksB.get(created.id))!.title, 'Edited by B');
      },
    );

    test(
      'a deleted task stays deleted after a re-sync (non-resurrection)',
      () async {
        final tasksA = TaskRepository(dbA);
        final tasksB = TaskRepository(dbB);
        final syncA = SyncService(dbA, sharedSyncDir.path);
        final syncB = SyncService(dbB, sharedSyncDir.path);

        final created = await tasksA.create(_newTask('Temporary'));
        await syncA.syncNow();
        await syncB.syncNow();
        expect(await tasksB.get(created.id), isNotNull);

        await tasksA.delete(created.id);
        await syncA.syncNow();
        await syncB.syncNow();
        expect(await tasksB.get(created.id), isNull);

        // Re-sync again (e.g. a stray re-consolidation or repeated pull) must
        // not resurrect the tombstoned document on either side.
        await syncA.syncNow();
        await syncB.syncNow();
        expect(await tasksA.get(created.id), isNull);
        expect(await tasksB.get(created.id), isNull);
      },
    );

    test(r'$$fts:/$$vec:/$$index: local-only namespaces are absent from the '
        'shared sync directory', () async {
      final tasksA = TaskRepository(dbA);
      final syncA = SyncService(dbA, sharedSyncDir.path);

      // Populate a task so the always-on secondary index and FTS indexes
      // (AppDatabase.open) have local-only derived data to write.
      final created = await tasksA.create(_newTask('Searchable title'));
      await tasksA.explainListByProject(created.projectId); // build index

      await syncA.syncNow();

      // The local sst/ directory has `.local.sst` files (derived index/FTS
      // data) — proof local-only data was written at all.
      final localSstDir = Directory('${dirA.path}/sst');
      final localFiles = localSstDir
          .listSync()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .toList();
      expect(localFiles.any((f) => f.endsWith('.local.sst')), isTrue);

      // None of those `.local.sst` files were uploaded to the shared sync
      // folder — spec §20's sync-exclusion guarantee.
      final syncedSstDir = Directory('${sharedSyncDir.path}/sstables');
      final syncedFiles = syncedSstDir.existsSync()
          ? syncedSstDir
                .listSync()
                .map((f) => f.path.split(Platform.pathSeparator).last)
                .toList()
          : <String>[];
      expect(syncedFiles.any((f) => f.endsWith('.local.sst')), isFalse);
    });
  });

  group('SyncService — negative authentication', () {
    test(
      'a differently-keyed peer\'s artefacts are quarantined, not applied',
      () async {
        final tasksA = TaskRepository(dbA);
        final tasksB = TaskRepository(dbB);
        final syncA = SyncService(dbA, sharedSyncDir.path); // demo key
        final differentKey = Uint8List.fromList(
          List<int>.generate(32, (i) => 255 - i),
        );
        final syncB = SyncService(
          dbB,
          sharedSyncDir.path,
          rootKey: differentKey,
        );

        final created = await tasksA.create(_newTask('Should be rejected'));
        await syncA.syncNow();

        final resultB = await syncB.syncNow();
        expect(resultB.pull.quarantined, isNotEmpty);

        // The artefact was rejected, not applied.
        expect(await tasksB.get(created.id), isNull);

        // The durable quarantine log records it too.
        expect(await syncB.quarantinedSstables(), isNotEmpty);

        // The host application's acknowledge mechanism: clearing the log
        // discards the historical record without un-quarantining the file.
        await syncB.clearQuarantineLog();
        expect(await syncB.quarantinedSstables(), isEmpty);
      },
    );
  });
}
