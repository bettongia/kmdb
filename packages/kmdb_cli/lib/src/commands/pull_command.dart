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

/// Downloads peer SSTables from a sync folder and ingests them locally.
///
/// The remote is resolved in the same way as [PushCommand]: positional remote
/// name, `origin` default, or `--sync-dir` one-off.
///
/// No memtable flush is needed before a pull because pull only writes
/// incoming SSTables to the local store as a destination; the local
/// write path is unaffected by the memtable state.
///
/// ## Usage
///
/// ```
/// kmdb <db> pull                     # uses remote named "origin"
/// kmdb <db> pull dropbox             # uses remote named "dropbox"
/// kmdb <db> pull --sync-dir <path>   # one-off; bypasses config
/// kmdb <db> pull [<remote>] [--collection <coll>]...
/// ```
final class PullCommand implements CliCommand {
  /// Creates a [PullCommand].
  const PullCommand();

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Download peer SSTables from a sync folder and ingest them locally.';

  @override
  String get usage =>
      'pull [<remote>] [--sync-dir <path>] [--collection <coll>]...';

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
      ctx.out.writeln('pull: no user collections found; nothing to pull.');
      return true;
    }

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
      await engine.pull();
    } catch (e) {
      ctx.writeError('pull failed: $e');
      return false;
    }

    ctx.out.writeln('pull: complete (device: $deviceId).');
    return true;
  }
}
