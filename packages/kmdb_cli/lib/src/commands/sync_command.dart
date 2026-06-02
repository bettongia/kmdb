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

import '../config/remote_config.dart';
import 'command.dart';
import 'sync_helpers.dart';

/// Convenience command that runs push then pull in one step.
///
/// Equivalent to running `push` immediately followed by `pull` against the
/// same remote. The memtable is flushed before the push phase so that all
/// recent local writes are included in the upload.
///
/// ## Usage
///
/// ```
/// kmdb <db> sync                     # uses remote named "origin"
/// kmdb <db> sync dropbox             # uses remote named "dropbox"
/// kmdb <db> sync --sync-dir <path>   # one-off; bypasses config
/// kmdb <db> sync [<remote>] [--collection <coll>]...
/// ```
final class SyncCommand extends CliCommand {
  /// Creates a [SyncCommand].
  const SyncCommand();

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Push local SSTables to a sync folder then pull peer SSTables.';

  @override
  String get usage => 'sync [<remote>]';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption(
        'sync-dir',
        valueHelp: 'path',
        help: 'One-off sync directory path (bypasses saved remotes)',
      )
      ..addOption(
        'collection',
        valueHelp: 'coll,...',
        help: 'Restrict sync to these collections (comma-separated)',
      );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final storeInfo = await ctx.store.storeInfo();
    final dbDir = storeInfo.dbDir;
    final deviceId = storeInfo.deviceId;

    // Resolve the remote configuration (CLI-specific: reads local/config.json).
    final RemoteConfig remote;
    try {
      remote = await SyncHelpers.resolveRemote(dbDir, args, flags);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    // Resolve collection set: all non-$ collections, or --collection overrides.
    final Set<String> collections;
    try {
      collections = await SyncHelpers.resolveCollections(ctx.store, flags);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    final syncAdapter = await adapterFor(remote, dbDir: dbDir);

    try {
      await ctx.db.sync(syncAdapter: syncAdapter, syncNamespaces: collections);
    } catch (e) {
      ctx.writeError('sync failed: $e');
      return false;
    }

    // After ingesting peer SSTables, check whether any indexed collection has
    // been entirely tombstoned. If so, cascade the same cleanup as
    // `collections delete` to keep index entries and config in sync.
    // This is CLI-specific logic that belongs here, not in KmdbDatabase.
    await SyncHelpers.purgeOrphanedIndexes(ctx, dbDir);

    ctx.out.writeln('sync: complete (device: $deviceId).');
    return true;
  }
}
