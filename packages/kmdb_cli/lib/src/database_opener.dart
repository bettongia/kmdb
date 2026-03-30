// Copyright 2026 The KMDB Authors.
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

/// Opens a [KvStoreImpl] from a filesystem path.
///
/// The CLI opens the raw [KvStoreImpl] rather than [KmdbDatabase] because it
/// operates without a user-supplied typed codec: all documents are read as
/// plain [Map<String, dynamic>] via the engine's [ValueCodec].
///
/// The device ID is loaded from (or generated into) `$meta` so CLI writes are
/// attributed to the same device across sessions.
abstract final class DatabaseOpener {
  DatabaseOpener._();

  /// Opens the database at [dbPath] and returns the underlying [KvStoreImpl].
  ///
  /// Creates the directory if it does not exist.
  ///
  /// Throws [LockException] if another process has the database open.
  /// Throws [ArgumentError] if [dbPath] is empty.
  static Future<KvStoreImpl> open(String dbPath) async {
    if (dbPath.isEmpty) {
      throw ArgumentError.value(
          dbPath, 'dbPath', 'Database path must not be empty');
    }

    final adapter = StorageAdapterNative();
    await adapter.createDirectory(dbPath);

    final (store, _) = await KvStoreImpl.open(dbPath, adapter);

    // Ensure a stable device ID is set in $meta (generates one on first open).
    await store.ensureDeviceId();

    return store;
  }
}
