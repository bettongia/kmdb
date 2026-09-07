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

import '../codecs/project_codec.dart';
import '../models/project.dart';

/// Thin data-access layer over the `projects` collection.
///
/// Every method here is a one-line wrapper over `KmdbCollection` — the point
/// of this class is to give the UI layer a small, typed, task-oriented
/// surface (and to give the guide's "CRUD + queries" section something
/// concrete and testable to cite), not to hide any `kmdb` behaviour.
class ProjectRepository {
  /// Creates a [ProjectRepository] backed by [db].
  ProjectRepository(KmdbDatabase db)
    : _collection = db.collection<Project>(
        name: 'projects',
        codec: const ProjectCodec(),
      );

  final KmdbCollection<Project> _collection;

  /// Creates a new project and returns it with its assigned key.
  ///
  /// Throws [SchemaValidationException] if [project] violates
  /// `AppSchemas.projects` (e.g. an empty `name`).
  Future<Project> create(Project project) => _collection.insert(project);

  /// Returns the project with [id], or `null` if it does not exist.
  Future<Project?> get(String id) => _collection.get(id);

  /// Replaces an existing project's fields (name/description).
  ///
  /// Throws [DocumentNotFoundException] if [project]'s key does not exist.
  Future<void> update(Project project) => _collection.replace(project);

  /// Deletes the project with [id].
  ///
  /// This does **not** cascade-delete the project's tasks — a real
  /// application would either forbid deleting a non-empty project or
  /// explicitly delete its tasks (and their comments) first. Kept simple
  /// here since cascading delete is not part of what this guide teaches.
  Future<void> delete(String id) => _collection.delete(id);

  /// Returns every project, ordered by creation time (oldest first).
  Future<List<Project>> listAll() =>
      _collection.all().orderBy('createdAt').get();

  /// Reactive stream of every project, re-emitting whenever a write touches
  /// the `projects` namespace (debounced 50ms — spec §14).
  Stream<List<Project>> watchAll() =>
      _collection.all().orderBy('createdAt').watch();
}
