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
import 'dart:io';
import 'package:kmdb/kmdb.dart';

/// Handles maintenance operations such as compacting and integrity checks.
class MaintenanceManager {
  /// Compacts the specified database file.
  Future<void> compact(String dbPath) async {
    final engine = StorageEngine(dbPath);
    try {
      await engine.open();
      await engine.compact();
    } finally {
      await engine.close();
    }
  }

  /// Checks the integrity of the specified database file.
  Future<bool> checkIntegrity(String dbPath) async {
    final engine = StorageEngine(dbPath);
    try {
      await engine.open();
      // If open succeeds without throwing corruption errors, we consider it valid for now.
      // The current engine performs checksum verification during load.
      return true;
    } catch (e) {
      return false;
    } finally {
      await engine.close();
    }
  }

  /// Creates a backup of the specified database file.
  Future<void> backup(String dbPath, String backupPath) async {
    final source = File(dbPath);
    if (!await source.exists()) {
      throw FileSystemException('Source database file not found', dbPath);
    }
    await source.copy(backupPath);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MaintenanceManager && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {};
}
