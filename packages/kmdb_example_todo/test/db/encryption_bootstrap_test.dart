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
import 'package:kmdb_example_todo/src/repositories/project_repository.dart';
import 'package:kmdb_example_todo/src/models/project.dart';

void main() {
  // The bootstrap logic under test operates purely on `$meta` CBOR state —
  // no filesystem/durability behaviour is exercised here — so a single,
  // reused MemoryStorageAdapter is fast and sufficient across the
  // close/reopen sequences below.
  group('AppDatabase.open — encryption bootstrap', () {
    test('createResult provisions a new encrypted database, which reopens '
        'correctly with the same passphrase', () async {
      final adapter = MemoryStorageAdapter();

      final setup = await EncryptionConfig.createResult(
        passphrase: 'correct horse battery staple',
      );
      final created = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: setup.config,
      );
      // The 16-word recovery code is shown to the user exactly once at
      // provisioning time — assert it looks like the documented format
      // rather than asserting an exact value.
      expect(setup.recoveryCode.split(' '), hasLength(16));

      final repo = ProjectRepository(created);
      await repo.create(
        Project(id: '', name: 'p', description: '', createdAt: DateTime.utc(2026)),
      );
      await created.close();

      final reopened = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: EncryptionConfig(
          passphrase: 'correct horse battery staple',
        ),
      );
      final reopenedProjects = await ProjectRepository(reopened).listAll();
      expect(reopenedProjects, hasLength(1));
      expect(reopenedProjects.single.name, 'p');
      await reopened.close();
    });

    test('a wrong passphrase throws badCredentials, and a subsequent open '
        'with the correct passphrase still succeeds (the lock was released)', () async {
      final adapter = MemoryStorageAdapter();
      final setup = await EncryptionConfig.createResult(passphrase: 'right-pass');
      final db = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: setup.config,
      );
      await db.close();

      await expectLater(
        AppDatabase.open(
          path: '/mem/db',
          adapter: adapter,
          encryptionConfig: EncryptionConfig(passphrase: 'wrong-pass'),
        ),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.badCredentials,
          ),
        ),
      );

      // The failed open above must have released the database lock.
      final retried = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: EncryptionConfig(passphrase: 'right-pass'),
      );
      await retried.close();
    });

    test('opening an encrypted database with no encryptionConfig throws '
        'databaseIsEncrypted', () async {
      final adapter = MemoryStorageAdapter();
      final setup = await EncryptionConfig.createResult(passphrase: 'p');
      final db = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: setup.config,
      );
      await db.close();

      await expectLater(
        AppDatabase.open(path: '/mem/db', adapter: adapter),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.databaseIsEncrypted,
          ),
        ),
      );
    });

    test('unlocking with the recovery code succeeds', () async {
      final adapter = MemoryStorageAdapter();
      final setup = await EncryptionConfig.createResult(passphrase: 'p');
      final db = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: setup.config,
      );
      await db.close();

      final reopened = await AppDatabase.open(
        path: '/mem/db',
        adapter: adapter,
        encryptionConfig: EncryptionConfig(recoveryCode: setup.recoveryCode),
      );
      await reopened.close();
    });

    test('provisioning against a non-empty database throws '
        'cannotProvisionNonEmptyDatabase', () async {
      final adapter = MemoryStorageAdapter();
      final db = await AppDatabase.open(path: '/mem/db', adapter: adapter);
      await ProjectRepository(db).create(
        Project(id: '', name: 'p', description: '', createdAt: DateTime.utc(2026)),
      );
      await db.close();

      final setup = await EncryptionConfig.createResult(passphrase: 'p');
      await expectLater(
        AppDatabase.open(
          path: '/mem/db',
          adapter: adapter,
          encryptionConfig: setup.config,
        ),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.cannotProvisionNonEmptyDatabase,
          ),
        ),
      );
    });
  });
}
