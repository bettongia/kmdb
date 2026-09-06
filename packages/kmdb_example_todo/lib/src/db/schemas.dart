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

/// JSON Schema (spec §25) admission gates for the sample app's three
/// collections, registered via `KmdbDatabase.open(schemas: ...)`.
///
/// `additionalProperties: false` on every schema below is what makes a typo'd
/// or removed field name a loud [SchemaValidationException] at write time
/// rather than a silently-dropped field — worth keeping in mind before adding
/// a new field to a model without also updating its schema here.
abstract final class AppSchemas {
  /// Schema for the `projects` collection.
  static final CollectionSchema projects = CollectionSchema(
    collection: 'projects',
    jsonSchema: {
      'required': ['name', 'description', 'createdAt'],
      'properties': {
        'name': {'type': 'string', 'minLength': 1},
        'description': {'type': 'string'},
        'createdAt': {'type': 'string', 'format': 'date-time'},
      },
      'additionalProperties': false,
    },
  );

  /// Schema for the `tasks` collection.
  ///
  /// `priority` and `status` are constrained to [TaskPriority.values] /
  /// [TaskStatus.values] via `enum` — this is the only place those value
  /// sets are enforced (`Task`/`TaskCodec` treat both fields as plain
  /// `String`).
  static final CollectionSchema tasks = CollectionSchema(
    collection: 'tasks',
    jsonSchema: {
      'required': [
        'projectId',
        'title',
        'description',
        'priority',
        'status',
        'attachmentUris',
        'createdAt',
        'updatedAt',
      ],
      'properties': {
        'projectId': {'type': 'string', 'minLength': 1},
        'title': {'type': 'string', 'minLength': 1},
        'description': {'type': 'string'},
        'priority': {
          'type': 'string',
          'enum': TaskPriority.values,
        },
        'status': {
          'type': 'string',
          'enum': TaskStatus.values,
        },
        'attachmentUris': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'createdAt': {'type': 'string', 'format': 'date-time'},
        'updatedAt': {'type': 'string', 'format': 'date-time'},
      },
      'additionalProperties': false,
    },
  );

  /// Schema for the `taskComments` sub-collection.
  static final CollectionSchema taskComments = CollectionSchema(
    collection: 'taskComments',
    jsonSchema: {
      'required': ['taskId', 'author', 'body', 'createdAt'],
      'properties': {
        'taskId': {'type': 'string', 'minLength': 1},
        'author': {'type': 'string', 'minLength': 1},
        'body': {'type': 'string', 'minLength': 1},
        'createdAt': {'type': 'string', 'format': 'date-time'},
      },
      'additionalProperties': false,
    },
  );

  /// All three schemas, in the order passed to `KmdbDatabase.open`.
  static final List<CollectionSchema> all = [projects, tasks, taskComments];
}
