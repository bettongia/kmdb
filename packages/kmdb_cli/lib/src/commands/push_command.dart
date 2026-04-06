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

/// Flushes the local memtable and uploads new SSTables to a sync folder.
///
/// The remote is resolved in order:
///
/// 1. `--sync-dir <path>` — one-off local path (does not require a saved
///    remote).
/// 2. `<remote-name>` — named remote from `{dbDir}/local/config.json`.
/// 3. Default remote named `origin` if no explicit remote is specified.
///
/// It is an error to supply both a positional remote name and `--sync-dir`.
///
/// ## Usage
///
/// ```
/// kmdb <db> push                     # uses remote named "origin"
/// kmdb <db> push dropbox             # uses remote named "dropbox"
/// kmdb <db> push --sync-dir <path>   # one-off; bypasses config
/// kmdb <db> push [<remote>] [--collection <coll>]...
/// ```
final class PushCommand implements CliCommand {
  /// Creates a [PushCommand].
  const PushCommand();

  @override
  String get name => 'push';

  @override
  String get description =>
      'Flush local SSTables and upload them to a sync folder.';

  @override
  String get usage =>
      'push [<remote>] [--sync-dir <path>] [--collection <coll>]...';

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
      ctx.out.writeln('push: no user collections found; nothing to push.');
      return true;
    }

    // Flush the memtable so all recent writes are materialised as SSTables
    // before we try to upload them.  Without this flush, data still in the
    // memtable would be silently excluded from the push.
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
      await engine.push();
    } catch (e) {
      ctx.writeError('push failed: $e');
      return false;
    }

    ctx.out.writeln('push: complete (device: $deviceId).');
    return true;
  }
}
