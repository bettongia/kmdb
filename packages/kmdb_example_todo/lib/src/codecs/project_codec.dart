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

import '../models/project.dart';

/// [KmdbCodec] for [Project].
///
/// See the class-level `KmdbCodec` doc comment (`package:kmdb`) for the
/// `_`-prefix / `_id`-injection contract this implementation follows.
class ProjectCodec implements KmdbCodec<Project> {
  /// Creates a [ProjectCodec].
  const ProjectCodec();

  @override
  String? keyOf(Project value) => value.id;

  @override
  Project withKey(Project value, String key) => Project(
    id: key,
    name: value.name,
    description: value.description,
    createdAt: value.createdAt,
  );

  @override
  Map<String, dynamic> encode(Project value) => {
    'name': value.name,
    'description': value.description,
    // DateTime is not a JSON-compatible scalar — serialize as ISO-8601 and
    // parse it back in decode().
    'createdAt': value.createdAt.toIso8601String(),
  };

  @override
  Project decode(Map<String, dynamic> json) => Project(
    // The framework injects '_id' into the map before calling decode().
    id: json['_id'] as String,
    name: json['name'] as String,
    description: json['description'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
