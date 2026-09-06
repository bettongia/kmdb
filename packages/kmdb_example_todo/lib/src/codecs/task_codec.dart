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

import '../models/task.dart';

/// [KmdbCodec] for [Task].
///
/// ## Vault URI re-wrapping in [decode]
///
/// `KmdbCollection.decodeDoc` walks the raw document map *before* calling
/// [decode] and replaces every `kmdb-vault://` URI string it finds — at any
/// depth, including inside lists — with a wired [VaultRef] instance (so that
/// application code can call `VaultRef.getBlob()`/`getMetadata()` directly).
/// This only happens when the database was opened with a `vaultStore`; a
/// database opened without one (e.g. a plain unit test with no vault) leaves
/// the list elements as plain [String]s.
///
/// [Task.attachmentUris] is deliberately typed `List<String>` — a `VaultRef`
/// is just `VaultRef(uri)` away should a screen need blob access — so
/// [decode] must normalise each element back to its bare URI string
/// regardless of which of the two shapes it arrives in.
class TaskCodec implements KmdbCodec<Task> {
  /// Creates a [TaskCodec].
  const TaskCodec();

  @override
  String? keyOf(Task value) => value.id;

  @override
  Task withKey(Task value, String key) => Task(
    id: key,
    projectId: value.projectId,
    title: value.title,
    description: value.description,
    priority: value.priority,
    status: value.status,
    attachmentUris: value.attachmentUris,
    createdAt: value.createdAt,
    updatedAt: value.updatedAt,
  );

  @override
  Map<String, dynamic> encode(Task value) => {
    'projectId': value.projectId,
    'title': value.title,
    'description': value.description,
    'priority': value.priority,
    'status': value.status,
    'attachmentUris': value.attachmentUris,
    'createdAt': value.createdAt.toIso8601String(),
    'updatedAt': value.updatedAt.toIso8601String(),
  };

  @override
  Task decode(Map<String, dynamic> json) => Task(
    id: json['_id'] as String,
    projectId: json['projectId'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    priority: json['priority'] as String,
    status: json['status'] as String,
    attachmentUris: (json['attachmentUris'] as List<dynamic>)
        .map((e) => e is VaultRef ? e.uri : e as String)
        .toList(),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}
