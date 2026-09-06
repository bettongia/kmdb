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

/// A comment/update left on a [Task], stored in the `taskComments`
/// sub-collection.
///
/// Comments live in their own top-level collection — **not** an embedded
/// `List<Comment>` field on `Task` — because `FtsManager`'s field extractor
/// only walks `Map`s and only recognises non-empty `String` leaves (no array
/// fan-out, unlike secondary indexes). An embedded list of comments would
/// therefore be invisible to full-text search, and the roadmap explicitly
/// asks the guide to demonstrate searching comment text. See the Integration
/// Guide's "Comments: a sub-collection, not an embedded list" section.
class TaskComment {
  /// Creates a [TaskComment].
  const TaskComment({
    required this.id,
    required this.taskId,
    required this.author,
    required this.body,
    required this.createdAt,
  });

  /// The document key. Empty string (`''`) before the comment has been
  /// inserted via `KmdbCollection.insert` — a 32-character lowercase hex
  /// UUIDv7 afterwards.
  final String id;

  /// The key of the [Task] this comment belongs to.
  final String taskId;

  /// The display name of the comment's author.
  final String author;

  /// The comment text. Indexed by `FtsIndexDefinition(collection:
  /// 'taskComments', field: 'body')`.
  final String body;

  /// When the comment was created.
  final DateTime createdAt;
}
