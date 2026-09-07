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

/// A project groups a set of related [Task]s.
///
/// This is one of the two top-level collections the sample app
/// demonstrates (`projects`, `tasks`) — see the Integration Guide's "Define
/// collections and schemas" section.
class Project {
  /// Creates a [Project].
  ///
  /// [id] is the document key: a 32-character lowercase hex UUIDv7, or the
  /// empty string for a not-yet-inserted project (see [ProjectCodec.keyOf]).
  const Project({
    required this.id,
    required this.name,
    required this.description,
    required this.createdAt,
  });

  /// The document key. Empty string (`''`) before the project has been
  /// inserted via `KmdbCollection.insert` — a 32-character lowercase hex
  /// UUIDv7 afterwards.
  final String id;

  /// The project's display name.
  final String name;

  /// A free-text description of the project.
  final String description;

  /// When the project was created.
  final DateTime createdAt;

  /// Returns a copy of this project with the given fields replaced.
  Project copyWith({String? name, String? description}) => Project(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    createdAt: createdAt,
  );
}
