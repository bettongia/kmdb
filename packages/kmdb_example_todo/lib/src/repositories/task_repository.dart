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

import '../codecs/task_codec.dart';
import '../models/task.dart';

/// Thin data-access layer over the `tasks` collection.
///
/// See [ProjectRepository] for the rationale behind this class's shape.
class TaskRepository {
  /// Creates a [TaskRepository] backed by [db].
  TaskRepository(KmdbDatabase db)
    : _collection = db.collection<Task>(
        name: 'tasks',
        codec: const TaskCodec(),
      );

  final KmdbCollection<Task> _collection;

  /// The underlying `KmdbCollection`, exposed so `AttachmentRepository` and
  /// the search screen can call `search()`/`searchVault()` and vault-aware
  /// document decoding without duplicating this repository's construction.
  KmdbCollection<Task> get collection => _collection;

  /// Creates a new task and returns it with its assigned key.
  Future<Task> create(Task task) => _collection.insert(task);

  /// Returns the task with [id], or `null` if it does not exist.
  Future<Task?> get(String id) => _collection.get(id);

  /// Upserts [task] — used for in-place edits (title/description/priority/
  /// status/attachments), where the caller already has the existing key.
  Future<void> update(Task task) => _collection.put(task);

  /// Deletes the task with [id].
  ///
  /// Note: this does not delete the task's `taskComments` — see
  /// [ProjectRepository.delete]'s doc comment for the same simplification.
  Future<void> delete(String id) => _collection.delete(id);

  /// Returns every task belonging to [projectId], ordered by creation time.
  ///
  /// Uses the `IndexDefinition('tasks', 'projectId')` secondary index
  /// registered in `AppDatabase.open` once it has finished its lazy build
  /// (spec §16) — see [explainListByProject] to observe whether a given call
  /// actually used the index.
  Future<List<Task>> listByProject(String projectId) => _collection
      .where(Field('projectId').equals(projectId))
      .orderBy('createdAt')
      .get();

  /// Same query as [listByProject], but also returns the [QueryPlan] the
  /// query executed with — `plan.strategy` is [ScanStrategy.indexScan] once
  /// the secondary index has finished building, and [ScanStrategy.fullScan]
  /// beforehand (or if the index was never registered). Exists to give the
  /// guide's secondary-index section something concrete to assert on.
  Future<(List<Task>, QueryPlan)> explainListByProject(String projectId) =>
      _collection
          .where(Field('projectId').equals(projectId))
          .orderBy('createdAt')
          .explainedGet();

  /// Reactive stream of [projectId]'s tasks.
  Stream<List<Task>> watchByProject(String projectId) => _collection
      .where(Field('projectId').equals(projectId))
      .orderBy('createdAt')
      .watch();

  /// Reactive stream of a single task by [id] — emits `null` if deleted.
  ///
  /// Uses `KmdbCollection.watchKey`, which is cheaper than [watchByProject]
  /// for a single-document detail screen: it re-fetches only the one key on
  /// every write to `tasks`, rather than re-running a filtered scan.
  Stream<Task?> watchTask(String id) => _collection.watchKey(id);
}
