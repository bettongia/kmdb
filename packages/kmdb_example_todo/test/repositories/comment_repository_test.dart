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
import 'package:kmdb_example_todo/src/models/task_comment.dart';
import 'package:kmdb_example_todo/src/repositories/comment_repository.dart';

void main() {
  late KmdbDatabase db;
  late CommentRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      path: '/mem/db',
      adapter: MemoryStorageAdapter(),
    );
    repo = CommentRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  TaskComment comment(String taskId, String body) => TaskComment(
    id: '',
    taskId: taskId,
    author: 'Alice',
    body: body,
    createdAt: DateTime.utc(2026),
  );

  group('CommentRepository secondary index (taskComments.taskId)', () {
    test(
      'listByTask returns only that task\'s comments, oldest first',
      () async {
        final c1 = await repo.add(comment('task1', 'first'));
        await repo.add(comment('task2', 'other task'));
        final c3 = await repo.add(comment('task1', 'second'));

        final task1Comments = await repo.listByTask('task1');
        expect(task1Comments.map((c) => c.id), [c1.id, c3.id]);
      },
    );

    test('delete() removes a comment', () async {
      final c = await repo.add(comment('task1', 'to be deleted'));
      await repo.delete(c.id);
      expect(await repo.listByTask('task1'), isEmpty);
    });

    test('watchByTask() re-emits after a write', () async {
      final emissions = <int>[];
      final sub = repo
          .watchByTask('task1')
          .listen((comments) => emissions.add(comments.length));

      await repo.add(comment('task1', 'first'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(emissions, isNotEmpty);
      expect(emissions.last, 1);
      await sub.cancel();
    });
  });
}
