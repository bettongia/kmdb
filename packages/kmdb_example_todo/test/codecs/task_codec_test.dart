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
import 'package:kmdb_example_todo/src/codecs/task_codec.dart';
import 'package:kmdb_example_todo/src/models/task.dart';

Task _task({List<String> attachmentUris = const []}) => Task(
  id: 'abc',
  projectId: 'proj1',
  title: 'Title',
  description: 'Desc',
  priority: TaskPriority.high,
  status: TaskStatus.backlog,
  attachmentUris: attachmentUris,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
);

void main() {
  const codec = TaskCodec();

  group('TaskCodec', () {
    test('encode emits no top-level `_`-prefixed key', () {
      final json = codec.encode(_task());
      expect(json.keys.any((k) => k.startsWith('_')), isFalse);
    });

    test('round-trips createdAt/updatedAt via ISO-8601', () {
      final task = _task();
      final json = codec.encode(task);
      final decoded = codec.decode({...json, '_id': 'abc'});
      expect(decoded.createdAt, task.createdAt);
      expect(decoded.updatedAt, task.updatedAt);
      expect(decoded.priority, TaskPriority.high);
      expect(decoded.status, TaskStatus.backlog);
    });

    test('decode() normalises plain-string attachmentUris (no VaultStore '
        'wiring — e.g. a database opened without vault support)', () {
      final hash = 'a' * 64;
      final task = _task(attachmentUris: ['kmdb-vault://sha256/$hash']);
      final json = codec.encode(task);
      final decoded = codec.decode({...json, '_id': 'abc'});
      expect(decoded.attachmentUris, task.attachmentUris);
    });

    test('decode() unwraps VaultRef instances back to their URI string '
        "(simulating KmdbCollection.decodeDoc's pre-decode wiring)", () {
      final hash = 'b' * 64;
      final task = _task(attachmentUris: ['kmdb-vault://sha256/$hash']);
      final json = codec.encode(task);
      // Simulate the wiring KmdbCollection.decodeDoc performs before calling
      // decode() when a VaultStore is configured.
      final wired = {
        ...json,
        '_id': 'abc',
        'attachmentUris': [VaultRef(task.attachmentUris.single)],
      };
      final decoded = codec.decode(wired);
      expect(decoded.attachmentUris, task.attachmentUris);
    });
  });
}
