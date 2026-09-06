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

void main() {
  late KmdbDatabase db;
  late TaskRepository tasks;

  setUp(() async {
    db = await AppDatabase.open(
      path: '/mem/db',
      adapter: MemoryStorageAdapter(),
    );
    tasks = TaskRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Task validTask() => Task(
    id: '',
    projectId: 'proj1',
    title: 'Ship it',
    description: 'Get the release out',
    priority: TaskPriority.high,
    status: TaskStatus.backlog,
    attachmentUris: const [],
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  group('AppSchemas.tasks admission', () {
    test('a valid Task is admitted', () async {
      final created = await tasks.create(validTask());
      expect(created.id, isNotEmpty);
    });

    test('a priority outside the enum is rejected', () async {
      final invalid = Task(
        id: validTask().id,
        projectId: validTask().projectId,
        title: validTask().title,
        description: validTask().description,
        priority: 'urgent', // not one of TaskPriority.values
        status: validTask().status,
        attachmentUris: validTask().attachmentUris,
        createdAt: validTask().createdAt,
        updatedAt: validTask().updatedAt,
      );
      await expectLater(
        tasks.create(invalid),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('a status outside the enum is rejected', () async {
      final base = validTask();
      final invalid = Task(
        id: base.id,
        projectId: base.projectId,
        title: base.title,
        description: base.description,
        priority: base.priority,
        status: 'archived', // not one of TaskStatus.values
        attachmentUris: base.attachmentUris,
        createdAt: base.createdAt,
        updatedAt: base.updatedAt,
      );
      await expectLater(
        tasks.create(invalid),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('a missing required field is rejected', () async {
      // Bypass the typed Task/TaskCodec entirely to omit a required field —
      // exercises the schema gate directly via the raw collection.
      final raw = db.rawCollection('tasks');
      await expectLater(
        raw.insert({
          'projectId': 'proj1',
          // 'title' omitted — required by AppSchemas.tasks.
          'description': 'd',
          'priority': TaskPriority.high,
          'status': TaskStatus.backlog,
          'attachmentUris': <String>[],
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'updatedAt': DateTime.utc(2026).toIso8601String(),
        }),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test(
      'an unknown field is rejected (additionalProperties: false)',
      () async {
        final raw = db.rawCollection('tasks');
        final base = validTask();
        await expectLater(
          raw.insert({
            'projectId': base.projectId,
            'title': base.title,
            'description': base.description,
            'priority': base.priority,
            'status': base.status,
            'attachmentUris': base.attachmentUris,
            'createdAt': base.createdAt.toIso8601String(),
            'updatedAt': base.updatedAt.toIso8601String(),
            'unexpectedField': 'surprise',
          }),
          throwsA(isA<SchemaValidationException>()),
        );
      },
    );
  });
}
