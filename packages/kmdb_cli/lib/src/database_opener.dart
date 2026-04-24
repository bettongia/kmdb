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

import 'config/kmdb_config.dart';

/// Opens a [KmdbDatabase] from a filesystem path.
///
/// [DatabaseOpener] is the CLI's entry point for database access. It performs
/// the two-phase device-ID initialisation and then opens a full [KmdbDatabase]
/// so that all write pipeline validation and augmentation (schema enforcement,
/// secondary index maintenance, FTS updates, vault ref counts) run for every
/// CLI write.
///
/// ## Two-phase open
///
/// The device ID must be established before the full open so that SSTable
/// names use the correct stable identity:
///
/// 1. Open a minimal [KvStoreImpl] with the default device ID.
/// 2. Load (or generate) the stable device ID from `$meta`.
/// 3. If the device ID differs from the default, close the store without
///    flushing. The WAL will replay any writes from this phase on reopen.
/// 4. Open [KmdbDatabase] with the stable device ID and the index definitions
///    loaded from `local/config.json`.
abstract final class DatabaseOpener {
  DatabaseOpener._();

  /// Opens the database at [dbPath] and returns the database and a creation
  /// flag.
  ///
  /// The returned record is `(db, created)` where [created] is `true` when
  /// the database did not previously exist (i.e. no `CURRENT` file was present
  /// before this call) and `false` when an existing database was reopened.
  ///
  /// [config] supplies the index and FTS index definitions to register with
  /// [KmdbDatabase.open]. Pass [KmdbConfig.empty] when the config file is
  /// absent or cannot be parsed.
  ///
  /// Creates the directory if it does not exist.
  ///
  /// Throws [LockException] if another process has the database open.
  /// Throws [ArgumentError] if [dbPath] is empty.
  static Future<(KmdbDatabase, bool created)> open(
    String dbPath,
    KmdbConfig config,
  ) async {
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

    // ── Phase 1: establish stable device ID ───────────────────────────────────
    // Open with the default device ID first so we can read or generate the
    // persisted stable identity. The WAL records any writes from this phase
    // (e.g. the ensureDeviceId write) so they are replayed correctly on the
    // full KmdbDatabase open below.
    var (store, _) = await KvStoreImpl.open(dbPath, adapter);

    // Load (or generate) the stable device ID. On first open this generates
    // and persists a new 8-character hex ID; on subsequent opens it returns
    // the previously stored value.
    final deviceId = await store.ensureDeviceId();

    // If the stable device ID differs from the default, close the store
    // without flushing. The WAL will replay the ensureDeviceId write on the
    // KmdbDatabase open below, which uses the correct device ID.
    const defaultDeviceId = '00000000';
    if (deviceId != defaultDeviceId) {
      await store.close(flush: false);
    }

    // ── Phase 2: open KmdbDatabase with config-derived index definitions ──────
    // Build index definitions from the persisted CLI config so that secondary
    // index maintenance and FTS updates run automatically for every CLI write.
    final indexDefinitions = config.indexes
        .map((r) => IndexDefinition(r.collection, r.path))
        .toList();
    final ftsDefinitions = config.ftsIndexes
        .map(
          (r) => FtsIndexDefinition(collection: r.collection, field: r.field),
        )
        .toList();

    final db = await KmdbDatabase.open(
      path: dbPath,
      adapter: adapter,
      deviceId: deviceId,
      indexes: indexDefinitions,
      ftsIndexes: ftsDefinitions,
      // Schemas are loaded automatically from $meta — no caller parameter needed.
    );

    return (db, created);
  }
}
