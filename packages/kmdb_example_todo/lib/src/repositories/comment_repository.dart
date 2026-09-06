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

import 'package:kmdb/kmdb.dart';

import '../codecs/task_comment_codec.dart';
import '../models/task_comment.dart';

/// Thin data-access layer over the `taskComments` sub-collection.
///
/// See [ProjectRepository]'s doc comment for the rationale behind this
/// class's shape, and [TaskComment]'s doc comment for why comments are a
/// separate collection rather than an embedded field on `Task`.
class CommentRepository {
  /// Creates a [CommentRepository] backed by [db].
  CommentRepository(KmdbDatabase db)
    : _collection = db.collection<TaskComment>(
        name: 'taskComments',
        codec: const TaskCommentCodec(),
      );

  final KmdbCollection<TaskComment> _collection;

  /// Adds a new comment and returns it with its assigned key.
  Future<TaskComment> add(TaskComment comment) => _collection.insert(comment);

  /// Deletes the comment with [id].
  Future<void> delete(String id) => _collection.delete(id);

  /// Returns every comment on [taskId], ordered oldest-first.
  ///
  /// Uses the `IndexDefinition('taskComments', 'taskId')` secondary index
  /// registered in `AppDatabase.open`.
  Future<List<TaskComment>> listByTask(String taskId) => _collection
      .where(Field('taskId').equals(taskId))
      .orderBy('createdAt')
      .get();

  /// Reactive stream of [taskId]'s comments.
  Stream<List<TaskComment>> watchByTask(String taskId) => _collection
      .where(Field('taskId').equals(taskId))
      .orderBy('createdAt')
      .watch();
}
