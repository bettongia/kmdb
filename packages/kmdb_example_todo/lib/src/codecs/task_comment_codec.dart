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

import '../models/task_comment.dart';

/// [KmdbCodec] for [TaskComment].
class TaskCommentCodec implements KmdbCodec<TaskComment> {
  /// Creates a [TaskCommentCodec].
  const TaskCommentCodec();

  @override
  String? keyOf(TaskComment value) => value.id;

  @override
  TaskComment withKey(TaskComment value, String key) => TaskComment(
    id: key,
    taskId: value.taskId,
    author: value.author,
    body: value.body,
    createdAt: value.createdAt,
  );

  @override
  Map<String, dynamic> encode(TaskComment value) => {
    'taskId': value.taskId,
    'author': value.author,
    'body': value.body,
    'createdAt': value.createdAt.toIso8601String(),
  };

  @override
  TaskComment decode(Map<String, dynamic> json) => TaskComment(
    id: json['_id'] as String,
    taskId: json['taskId'] as String,
    author: json['author'] as String,
    body: json['body'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
