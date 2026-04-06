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

import '../config/kmdb_config.dart';
import '../config/remote_config.dart';

/// Shared logic for `push`, `pull`, and `sync` commands.
abstract final class SyncHelpers {
  SyncHelpers._();

  /// Resolves a [RemoteConfig] from the command's positional [args] and [flags].
  ///
  /// Resolution order:
  ///
  /// 1. If `--sync-dir` is present in [flags], return an ad-hoc
  ///    [LocalRemoteConfig] pointing at that path.
  /// 2. If [args] is non-empty, look up the named remote in config.
  /// 3. If [args] is empty, look up the remote named `'origin'` in config.
  ///
  /// Throws [ArgumentError] if:
  /// - Both a positional remote name and `--sync-dir` are supplied.
  /// - The named remote is not found in config.
  /// - No positional remote and no `origin` remote is configured.
  ///
  /// Throws [FormatException] if config.json is corrupt.
  static Future<RemoteConfig> resolveRemote(
    String dbDir,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final syncDir = flags['sync-dir'] as String?;
    final remoteName = args.isNotEmpty ? args[0] : null;

    // Mutual exclusion: --sync-dir and a named remote cannot both be provided.
    if (syncDir != null && remoteName != null) {
      throw ArgumentError(
        '--sync-dir and a named remote are mutually exclusive.',
      );
    }

    // One-off sync-dir: bypass config entirely.
    if (syncDir != null) {
      return LocalRemoteConfig(path: syncDir);
    }

    // Look up by name or default to 'origin'.
    final name = remoteName ?? 'origin';
    // FormatException propagates directly (corrupt config).
    final config = await KmdbConfig.load(dbDir);

    final remote = config.remotes[name];
    if (remote == null) {
      if (remoteName == null) {
        // No explicit name — no 'origin' defined.
        throw ArgumentError(
          "no remote specified and no 'origin' remote is configured. "
          "Use 'remote add origin --path <path>' to configure one.",
        );
      }
      throw ArgumentError("remote '$name' not found.");
    }

    return remote;
  }

  /// Returns the set of collections to sync.
  ///
  /// If the `collection` flag is present (it can appear multiple times as a
  /// space-separated list because the CLI tokeniser treats each flag value
  /// as a single token), the result is restricted to those collections.
  /// Otherwise, all non-`$`-prefixed collections from the store are returned.
  ///
  /// Throws [ArgumentError] if an explicitly requested collection begins with
  /// `$` (system collections cannot be synced via CLI).
  static Future<Set<String>> resolveCollections(
    KvStore store,
    Map<String, dynamic> flags,
  ) async {
    final collectionFlag = flags['collection'];

    if (collectionFlag != null) {
      // The CLI flag parser stores each flag value as a single String token.
      // To support multiple collections, callers can repeat --collection or
      // pass a single comma-separated list; we handle both.
      final requested = <String>{};
      if (collectionFlag is String) {
        requested.addAll(collectionFlag.split(',').map((s) => s.trim()));
      }
      for (final coll in requested) {
        if (coll.startsWith(r'$')) {
          throw ArgumentError(
            "Cannot sync system collection '$coll'. "
            'Only user collections (not starting with \$) can be synced.',
          );
        }
      }
      return requested;
    }

    // Default: all user (non-$) collections.
    final all = await store.listNamespaces();
    return all.where((coll) => !coll.startsWith(r'$')).toSet();
  }
}
