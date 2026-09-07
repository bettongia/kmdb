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

/// The allowed [Task.priority] values.
///
/// These are enforced at the storage layer by the JSON Schema (§25)
/// registered for the `tasks` collection in `db/schemas.dart` — **not** by
/// the [Task] class or `TaskCodec` itself, which treat `priority` as a plain
/// [String]. See the Integration Guide's "Define collections and schemas"
/// section for why the enum constraint lives in the schema rather than the
/// codec.
abstract final class TaskPriority {
  /// The task is high priority.
  static const String high = 'high';

  /// The task is medium priority.
  static const String medium = 'medium';

  /// The task is low priority.
  static const String low = 'low';

  /// All valid priority values, in the order the JSON Schema enumerates them.
  static const List<String> values = [high, medium, low];
}

/// The allowed [Task.status] values. See [TaskPriority] for why these are
/// plain [String] constants rather than a Dart `enum`.
abstract final class TaskStatus {
  /// The task has not been started.
  static const String backlog = 'backlog';

  /// The task is being worked on.
  static const String inProgress = 'in-progress';

  /// The task is complete.
  static const String done = 'done';

  /// All valid status values, in the order the JSON Schema enumerates them.
  static const List<String> values = [backlog, inProgress, done];
}

/// A unit of work belonging to a [Project].
///
/// Attachments are stored as `kmdb-vault://sha256/<64hex>` URI strings in
/// [attachmentUris] — see the Integration Guide's "Vault: attachments"
/// section for how these are produced by `VaultStore.ingest` and kept
/// reference-counted automatically by `VaultRefInterceptor` whenever a
/// [Task] document is written through `KmdbCollection`.
///
/// Comments are **not** an embedded field on [Task] — see `TaskComment` and
/// the guide's "Comments: a sub-collection, not an embedded list" section
/// for why full-text search over comment bodies forces a separate
/// `taskComments` collection.
class Task {
  /// Creates a [Task].
  const Task({
    required this.id,
    required this.projectId,
    required this.title,
    required this.description,
    required this.priority,
    required this.status,
    required this.attachmentUris,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The document key. Empty string (`''`) before the task has been
  /// inserted via `KmdbCollection.insert` — a 32-character lowercase hex
  /// UUIDv7 afterwards.
  final String id;

  /// The key of the owning [Project].
  final String projectId;

  /// A short summary of the task.
  final String title;

  /// A longer free-text description of the task.
  final String description;

  /// One of [TaskPriority.values].
  final String priority;

  /// One of [TaskStatus.values].
  final String status;

  /// `kmdb-vault://sha256/<64hex>` URIs for every file attached to this
  /// task.
  final List<String> attachmentUris;

  /// When the task was created.
  final DateTime createdAt;

  /// When the task was last updated.
  final DateTime updatedAt;

  /// Returns a copy of this task with the given fields replaced.
  ///
  /// [updatedAt] is always refreshed to [now] (or `DateTime.now()` if
  /// omitted) — callers should not need to remember to bump it themselves.
  Task copyWith({
    String? title,
    String? description,
    String? priority,
    String? status,
    List<String>? attachmentUris,
    DateTime? now,
  }) => Task(
    id: id,
    projectId: projectId,
    title: title ?? this.title,
    description: description ?? this.description,
    priority: priority ?? this.priority,
    status: status ?? this.status,
    attachmentUris: attachmentUris ?? this.attachmentUris,
    createdAt: createdAt,
    updatedAt: now ?? DateTime.now(),
  );
}
