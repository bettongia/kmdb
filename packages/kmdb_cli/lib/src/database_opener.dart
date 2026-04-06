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

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';

/// Opens a [KvStoreImpl] from a filesystem path.
///
/// The CLI opens the raw [KvStoreImpl] rather than [KmdbDatabase] because it
/// operates without a user-supplied typed codec: all documents are read as
/// plain [Map<String, dynamic>] via the engine's [ValueCodec].
///
/// The device ID is loaded from (or generated into) `$meta` so CLI writes are
/// attributed to the same device across sessions. Crucially, the engine is
/// opened with the stored device ID so that SSTable filenames are consistent
/// with the device identity used by [SyncEngine].
abstract final class DatabaseOpener {
  DatabaseOpener._();

  /// Opens the database at [dbPath] and returns the store and a creation flag.
  ///
  /// The returned record is `(store, created)` where [created] is `true` when
  /// the database did not previously exist (i.e. no `CURRENT` file was present
  /// before this call) and `false` when an existing database was reopened.
  ///
  /// Creates the directory if it does not exist.
  ///
  /// The first open of a fresh database generates a new device ID and stores it
  /// in `$meta`. On every subsequent open, the stored device ID is loaded and
  /// used to name SSTables, ensuring consistent device identity across CLI
  /// sessions and compatibility with [SyncEngine].
  ///
  /// ## Two-phase open
  ///
  /// To correctly initialise the engine device ID:
  ///
  /// 1. Open with the default device ID (`'00000000'`).
  /// 2. Load (or generate) the stable device ID from `$meta`.
  /// 3. If the device ID differs from the default, reopen with the correct ID
  ///    so all subsequent SSTable writes use the stable identity.
  ///
  /// Throws [LockException] if another process has the database open.
  /// Throws [ArgumentError] if [dbPath] is empty.
  static Future<(KvStoreImpl, bool created)> open(String dbPath) async {
    if (dbPath.isEmpty) {
      throw ArgumentError.value(
        dbPath,
        'dbPath',
        'Database path must not be empty',
      );
    }

    // Detect whether this is a fresh database before any files are written.
    // The CURRENT file is created on the very first open, so its absence means
    // the database does not yet exist.
    final created = !io.File('$dbPath/CURRENT').existsSync();

    final adapter = StorageAdapterNative();
    await adapter.createDirectory(dbPath);

    // Phase 1: open with the default device ID.
    var (store, _) = await KvStoreImpl.open(dbPath, adapter);

    // Load (or generate) the stable device ID.  On first open this generates
    // and persists a new 8-character hex ID; on subsequent opens it returns
    // the previously stored value.
    final deviceId = await store.ensureDeviceId();

    // Phase 2: if the stored device ID differs from the default, close and
    // reopen so the LSM engine uses the correct ID for all future SSTable
    // names.  This ensures SyncEngine.push() can match local SSTables against
    // the device identity exposed by storeInfo().
    const defaultDeviceId = '00000000';
    if (deviceId != defaultDeviceId) {
      // Close without flushing — the WAL records the writes from phase 1
      // (i.e. the ensureDeviceId write) and will be replayed on reopen.
      await store.close(flush: false);

      final result = await KvStoreImpl.open(
        dbPath,
        adapter,
        deviceId: deviceId,
      );
      store = result.$1;
    }

    return (store, created);
  }
}
