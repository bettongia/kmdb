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

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'remote_config.dart';

/// Manages the per-database CLI configuration file at
/// `{dbDir}/local/config.json`.
///
/// The config file stores named sync remotes. This class provides atomic read
/// and write operations, lazy directory creation, and a clean API for
/// adding/removing remotes.
///
/// ## File format
///
/// ```json
/// {
///   "remotes": {
///     "origin": {
///       "type": "local",
///       "path": "/Volumes/NAS/myapp-sync"
///     }
///   }
/// }
/// ```
///
/// ## Usage
///
/// ```dart
/// final config = await KmdbConfig.load('/path/to/db');
/// config.addRemote('origin', LocalRemoteConfig(path: '/mnt/nas/kmdb'));
/// await config.save('/path/to/db');
/// ```
final class KmdbConfig {
  /// Creates a [KmdbConfig] with the given mutable [remotes] map.
  KmdbConfig._({required Map<String, RemoteConfig> remotes})
    : _remotes = remotes;

  /// An empty config with no remotes.
  KmdbConfig.empty() : _remotes = {};

  // Mutable backing map.  All public mutation goes through [addRemote] /
  // [removeRemote] so invariants are enforced centrally.
  final Map<String, RemoteConfig> _remotes;

  /// Returns an unmodifiable view of the remotes map, keyed by name.
  Map<String, RemoteConfig> get remotes => Map.unmodifiable(_remotes);

  // ── Factory ────────────────────────────────────────────────────────────────

  /// Loads (or creates) the config from `{dbDir}/local/config.json`.
  ///
  /// If the file does not exist, returns an empty [KmdbConfig]. If the file
  /// exists but is corrupt (invalid JSON or invalid remote type), throws a
  /// [FormatException] with a descriptive message rather than silently
  /// returning empty config.
  ///
  /// The [dbDir] parameter is the local database root directory (the one that
  /// contains `LOCK`, `MANIFEST-*`, etc.).
  static Future<KmdbConfig> load(String dbDir) async {
    final file = io.File(_configPath(dbDir));
    if (!await file.exists()) {
      return KmdbConfig.empty();
    }

    final String raw;
    try {
      raw = await file.readAsString();
    } on io.FileSystemException catch (e) {
      throw FormatException(
        'Failed to read config file "${file.path}": ${e.message}',
      );
    }

    // Decode the JSON — surface parse errors rather than silently returning
    // an empty config so the user knows something is wrong.
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException(
        'Corrupt config.json at "${file.path}": ${e.message}',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Corrupt config.json at "${file.path}": expected a JSON object.',
      );
    }

    // Parse remotes section.
    final remotesRaw = decoded['remotes'];
    final remotes = <String, RemoteConfig>{};
    if (remotesRaw != null) {
      if (remotesRaw is! Map<String, dynamic>) {
        throw FormatException(
          'Corrupt config.json at "${file.path}": '
          "'remotes' must be a JSON object.",
        );
      }
      for (final entry in remotesRaw.entries) {
        final name = entry.key;
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "remote '$name' must be a JSON object.",
          );
        }
        // FormatException from RemoteConfig.fromJson propagates directly.
        remotes[name] = RemoteConfig.fromJson(value);
      }
    }

    return KmdbConfig._(remotes: remotes);
  }

  // ── Mutation ───────────────────────────────────────────────────────────────

  /// Adds a remote under [name].
  ///
  /// Throws [ArgumentError] if a remote named [name] already exists and
  /// [force] is `false` (the default). Pass `force: true` to overwrite.
  void addRemote(String name, RemoteConfig remote, {bool force = false}) {
    if (_remotes.containsKey(name) && !force) {
      throw ArgumentError(
        "A remote named '$name' already exists. "
        'Use --force to overwrite.',
      );
    }
    _remotes[name] = remote;
  }

  /// Removes the remote named [name].
  ///
  /// Throws [ArgumentError] if no remote with that name exists.
  void removeRemote(String name) {
    if (!_remotes.containsKey(name)) {
      throw ArgumentError("No remote named '$name' found.");
    }
    _remotes.remove(name);
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Atomically writes the config to `{dbDir}/local/config.json`.
  ///
  /// Creates the `{dbDir}/local/` directory lazily on first write. Uses a
  /// write-to-temp-then-rename strategy so the file is never partially written.
  Future<void> save(String dbDir) async {
    final localDir = io.Directory(_localDir(dbDir));
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    final configFile = io.File(_configPath(dbDir));

    // Build the JSON payload.
    final payload = {
      'remotes': {
        for (final entry in _remotes.entries) entry.key: entry.value.toJson(),
      },
    };
    final content = const JsonEncoder.withIndent('  ').convert(payload);

    // Write-to-temp-then-rename for atomicity: the file is either fully
    // written or not present — never half-written.
    final tmpPath = '${configFile.path}.tmp.${_randomHex()}';
    final tmpFile = io.File(tmpPath);
    try {
      await tmpFile.writeAsString(content, flush: true);
      await tmpFile.rename(configFile.path);
    } catch (_) {
      // Best-effort cleanup of the temp file if the rename or write fails.
      try {
        await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  // ── Static helpers ─────────────────────────────────────────────────────────

  /// The `local/` subdirectory path for [dbDir].
  static String localDir(String dbDir) => '$dbDir/local';

  /// The full config file path for [dbDir].
  static String configPath(String dbDir) => '$dbDir/local/config.json';

  // ── Private helpers ────────────────────────────────────────────────────────

  static String _localDir(String dbDir) => localDir(dbDir);

  static String _configPath(String dbDir) => configPath(dbDir);

  /// Returns a short random hex string for temporary file naming.
  static String _randomHex() {
    final r = math.Random();
    return r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0');
  }
}
