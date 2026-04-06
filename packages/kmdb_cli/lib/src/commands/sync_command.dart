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
final class SyncCommand implements CliCommand {
  /// Creates a [SyncCommand].
  const SyncCommand();

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Push local SSTables to a sync folder then pull peer SSTables.';

  @override
  String get usage =>
      'sync [<remote>] [--sync-dir <path>] [--collection <coll>]...';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final storeInfo = await ctx.store.storeInfo();
    final dbDir = storeInfo.dbDir;
    final deviceId = storeInfo.deviceId;

    // Resolve the remote configuration.
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

    if (collections.isEmpty) {
      ctx.out.writeln('sync: no user collections found; nothing to sync.');
      return true;
    }

    // Flush the memtable before the push phase so all recent writes are
    // materialised as SSTables.  Without this, data still in the memtable
    // would be silently excluded from the upload half of sync.
    await ctx.store.flush();

    final adapter = adapterFor(remote);
    final engine = SyncEngine(
      store: ctx.store,
      cloudAdapter: adapter,
      localAdapter: StorageAdapterNative(),
      deviceId: deviceId,
      dbDir: dbDir,
      syncRoot: '',
      syncNamespaces: collections,
    );

    try {
      await engine.sync();
    } catch (e) {
      ctx.writeError('sync failed: $e');
      return false;
    }

    ctx.out.writeln('sync: complete (device: $deviceId).');
    return true;
  }
}
