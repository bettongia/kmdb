/*
 Copyright 2026 The Aurochs KMesh Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:convert';

/// Manages database metadata such as listing namespaces and indexes.
class MetadataManager {
  /// Lists the databases available.
  /// Currently, the core engine is single-file, so this just returns the
  /// current database path if provided.
  Future<List<String>> listDatabases(String? currentDb) async {
    if (currentDb == null) return [];
    return [currentDb];
  }

  /// Lists the namespaces in the specified database.
  /// Note: The current core engine does not yet support multiple namespaces.
  /// It defaults to a single 'default' namespace.
  Future<List<String>> listNamespaces(String dbPath) async {
    // For now, return a default namespace as a stub.
    return ['default'];
  }

  /// Lists the secondary indexes in the specified database.
  /// Note: The current core engine does not yet support secondary indexes.
  Future<List<String>> listIndexes(String dbPath) async {
    // Return an empty list as a stub.
    return [];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MetadataManager && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {};
}
