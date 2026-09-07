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

import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_example_todo/src/db/app_database.dart';
import 'package:kmdb_example_todo/src/models/task.dart';
import 'package:kmdb_example_todo/src/repositories/task_repository.dart';

Task _task(String projectId, String title) => Task(
  id: '',
  projectId: projectId,
  title: title,
  description: 'Some description mentioning quarterly revenue figures',
  priority: TaskPriority.medium,
  status: TaskStatus.backlog,
  attachmentUris: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  late KmdbDatabase db;
  late TaskRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      path: '/mem/db',
      adapter: MemoryStorageAdapter(),
    );
    repo = TaskRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('TaskRepository CRUD', () {
    test('create assigns a 32-char hex key', () async {
      final created = await repo.create(_task('proj1', 'Write guide'));
      expect(created.id, hasLength(32));
    });

    test('delete() then get() returns null', () async {
      final created = await repo.create(_task('proj1', 'Temp'));
      await repo.delete(created.id);
      expect(await repo.get(created.id), isNull);
    });

    test('update() upserts fields in place', () async {
      final created = await repo.create(_task('proj1', 'Original title'));
      final updated = created.copyWith(status: TaskStatus.done);
      await repo.update(updated);

      final fetched = await repo.get(created.id);
      expect(fetched!.status, TaskStatus.done);
      expect(fetched.title, 'Original title');
    });
  });

  group('TaskRepository secondary index (tasks.projectId)', () {
    test('listByProject returns only that project\'s tasks', () async {
      final t1 = await repo.create(_task('proj1', 'A'));
      await repo.create(_task('proj2', 'B'));
      final t3 = await repo.create(_task('proj1', 'C'));

      final proj1Tasks = await repo.listByProject('proj1');
      expect(proj1Tasks.map((t) => t.id), containsAll([t1.id, t3.id]));
      expect(proj1Tasks, hasLength(2));
    });

    test('QueryPlan shows the index is used once built', () async {
      await repo.create(_task('proj1', 'A'));

      // Trigger at least one query so the index build activates (spec §16
      // lazy build), then poll until it transitions to `current` — the
      // build itself runs in the background, so the very next query may
      // still observe a full scan.
      await repo.explainListByProject('proj1');
      for (var i = 0; i < 50; i++) {
        final state = await db.indexManager.getOrActivate('tasks', 'projectId');
        if (state.status == IndexStatus.current) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final (results, plan) = await repo.explainListByProject('proj1');
      expect(results, hasLength(1));
      expect(plan.strategy, ScanStrategy.indexScan);
      expect(plan.filters, isNotEmpty);
      expect(plan.filters.first.indexUsed, isTrue);
    });
  });

  group('TaskRepository reactivity', () {
    test('watchByProject() re-emits after a write', () async {
      final emissions = <int>[];
      final sub = repo
          .watchByProject('proj1')
          .listen((tasks) => emissions.add(tasks.length));

      await repo.create(_task('proj1', 'A'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(emissions, isNotEmpty);
      expect(emissions.last, 1);
      await sub.cancel();
    });

    test('watchTask() emits the current value, then updates, then null '
        'after delete', () async {
      final created = await repo.create(_task('proj1', 'Watched'));
      final emissions = <String?>[];
      final sub = repo
          .watchTask(created.id)
          .listen((task) => emissions.add(task?.title));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await repo.update(created.copyWith(title: 'Renamed'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await repo.delete(created.id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(emissions, contains('Watched'));
      expect(emissions, contains('Renamed'));
      expect(emissions.last, isNull);
      await sub.cancel();
    });
  });
}
