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
import 'package:kmdb_example_todo/src/models/project.dart';
import 'package:kmdb_example_todo/src/repositories/project_repository.dart';

void main() {
  late KmdbDatabase db;
  late ProjectRepository repo;

  setUp(() async {
    db = await AppDatabase.open(path: '/mem/db', adapter: MemoryStorageAdapter());
    repo = ProjectRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ProjectRepository', () {
    test('create assigns a 32-char hex key and round-trips fields', () async {
      final created = await repo.create(
        Project(
          id: '',
          name: 'Website Relaunch',
          description: 'Q1 marketing site refresh',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect(created.id, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(created.id), isTrue);
      expect(created.name, 'Website Relaunch');

      final fetched = await repo.get(created.id);
      expect(fetched, isNotNull);
      expect(fetched!.name, created.name);
      expect(fetched.description, created.description);
      expect(fetched.createdAt, created.createdAt);
    });

    test('update() on a missing key throws DocumentNotFoundException', () async {
      // A well-formed (valid UUIDv7) key that was never written, so the
      // failure exercises DocumentNotFoundException rather than the key
      // validator.
      final missingKey = const UuidV7KeyGenerator().next();
      final ghost = Project(
        id: missingKey,
        name: 'n',
        description: 'd',
        createdAt: DateTime.utc(2026),
      );
      await expectLater(
        repo.update(ghost),
        throwsA(isA<DocumentNotFoundException>()),
      );
    });

    test('delete() then get() returns null', () async {
      final created = await repo.create(
        Project(
          id: '',
          name: 'Temp',
          description: '',
          createdAt: DateTime.utc(2026),
        ),
      );
      await repo.delete(created.id);
      expect(await repo.get(created.id), isNull);
    });

    test('listAll() returns every project ordered by createdAt', () async {
      final p1 = await repo.create(
        Project(id: '', name: 'A', description: '', createdAt: DateTime.utc(2026, 1, 1)),
      );
      final p2 = await repo.create(
        Project(id: '', name: 'B', description: '', createdAt: DateTime.utc(2026, 1, 2)),
      );

      final all = await repo.listAll();
      expect(all.map((p) => p.id), [p1.id, p2.id]);
    });

    test('watchAll() re-emits after a write', () async {
      final stream = repo.watchAll();
      final emissions = <int>[];
      final sub = stream.listen((projects) => emissions.add(projects.length));

      await repo.create(
        Project(id: '', name: 'A', description: '', createdAt: DateTime.utc(2026)),
      );

      // watch() debounces at 50ms (spec §14) — give it time to fire.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(emissions, isNotEmpty);
      expect(emissions.last, 1);

      await sub.cancel();
    });
  });
}
