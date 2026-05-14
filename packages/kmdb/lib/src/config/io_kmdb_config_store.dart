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

import 'dart:io' as io;
import 'dart:math' as math;

import 'kmdb_config_store.dart';

/// A [KmdbConfigStore] that reads and writes the config file via `dart:io`.
///
/// The config file is stored at `{dbDir}/local/config.json`.  The `local/`
/// subdirectory is created lazily on the first [write] call, preserving the
/// same behaviour as the original `KmdbConfig.save` method.
///
/// **Not supported on web.**  Web callers must supply their own
/// [KmdbConfigStore] implementation (e.g. one backed by IndexedDB or
/// localStorage).
///
/// ## Atomic writes
///
/// [write] uses a write-to-temp-then-rename strategy: the new content is
/// written to `{configPath}.tmp.{randomHex}` and then atomically renamed to
/// the final path.  The file is therefore either fully written or absent —
/// never partially written.
///
/// ## Usage
///
/// Prefer the [KmdbConfig.forDatabase] convenience factory, which wires up
/// an [IoKmdbConfigStore] automatically:
///
/// ```dart
/// final config = await KmdbConfig.forDatabase('/path/to/db');
/// ```
///
/// To construct the store manually:
///
/// ```dart
/// final store = IoKmdbConfigStore(dbDir: '/path/to/db');
/// final config = await KmdbConfig.load(store);
/// ```
final class IoKmdbConfigStore implements KmdbConfigStore {
  /// Creates an [IoKmdbConfigStore] for the given [dbDir].
  ///
  /// The config file path is `{dbDir}/local/config.json`.
  IoKmdbConfigStore({required String dbDir}) : _dbDir = dbDir;

  final String _dbDir;

  /// The `local/` subdirectory path for the configured database directory.
  String get localDir => '$_dbDir/local';

  /// The full path of the config file.
  String get configPath => '$_dbDir/local/config.json';

  /// Reads the raw JSON string from the config file.
  ///
  /// Returns `null` when the file does not exist.  Throws [FormatException]
  /// when the file exists but cannot be read (e.g. permission error).
  @override
  Future<String?> read() async {
    final file = io.File(configPath);
    if (!await file.exists()) {
      return null;
    }
    try {
      return await file.readAsString();
    } on io.FileSystemException catch (e) {
      throw FormatException(
        'Failed to read config file "$configPath": ${e.message}',
      );
    }
  }

  /// Atomically writes [json] to the config file.
  ///
  /// Creates the `local/` subdirectory lazily if it does not exist.  Uses
  /// write-to-temp-then-rename for atomicity.
  @override
  Future<void> write(String json) async {
    // Lazily create local/ directory on first write.
    final dir = io.Directory(localDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final configFile = io.File(configPath);

    // Write-to-temp-then-rename: file is never partially written.
    final tmpPath = '$configPath.tmp.${_randomHex()}';
    final tmpFile = io.File(tmpPath);
    try {
      await tmpFile.writeAsString(json, flush: true);
      await tmpFile.rename(configFile.path);
    } catch (_) {
      // Best-effort cleanup of the temp file if the rename or write fails.
      try {
        await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Returns a short random hex string for temporary file naming.
  static String _randomHex() {
    final r = math.Random();
    return r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0');
  }
}
