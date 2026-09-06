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
import 'package:kmdb_example_todo/src/codecs/task_comment_codec.dart';
import 'package:kmdb_example_todo/src/models/task_comment.dart';

void main() {
  const codec = TaskCommentCodec();

  group('TaskCommentCodec', () {
    test('encode emits no top-level `_`-prefixed key', () {
      final c = TaskComment(
        id: 'abc',
        taskId: 'task1',
        author: 'Alice',
        body: 'Looks good',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final json = codec.encode(c);
      expect(json.keys.any((k) => k.startsWith('_')), isFalse);
    });

    test('round-trips a DateTime via ISO-8601', () {
      final createdAt = DateTime.utc(2026, 5, 6, 7, 8, 9);
      final c = TaskComment(
        id: 'abc',
        taskId: 'task1',
        author: 'Alice',
        body: 'Looks good',
        createdAt: createdAt,
      );
      final json = codec.encode(c);
      final decoded = codec.decode({...json, '_id': 'abc'});
      expect(decoded.createdAt, createdAt);
      expect(decoded.taskId, 'task1');
      expect(decoded.author, 'Alice');
      expect(decoded.body, 'Looks good');
      expect(decoded.id, 'abc');
    });
  });
}
