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

import 'package:kmdb/kmdb.dart' show SecretStore;
import 'package:kmdb/kmdb_config.dart' show GoogleDriveRemoteConfig, KmdbConfig;

import '../config/secret_store/directory_secret_store.dart';
import '../config/secret_store/secret_key.dart';
import 'command.dart';

/// Manages secrets held in the CLI's permission-hardened [SecretStore]
/// (currently: the Google Drive OAuth credential blob written by `kmdb
/// remote add --type google-drive`).
///
/// ## Subcommands
///
/// ```
/// kmdb <db> credentials prune [--dry-run]
/// ```
///
/// [DirectorySecretStore.forPlatform]'s root is a single directory shared by
/// every KMDB database on the machine (`%APPDATA%\kmdb` /
/// `~/.config/kmdb`) — unlike the config file's remotes, which are
/// per-database. `prune` therefore only ever considers keys scoped to the
/// *current* database (via [dbScopedSecretKey]/[isSecretKeyForDb]); a key
/// belonging to a different database is never inspected or deleted, even if
/// it would look orphaned against this database's [KmdbConfig].
///
/// An "orphaned" secret is one whose key does not correspond to any
/// currently-configured `google-drive` remote in this database's
/// `RemoteConfig` — typically left behind by a `remote remove` that ran
/// before this cleanup existed, or by manual edits to `local/config.json`.
final class CredentialsCommand extends CliCommand {
  /// Creates a [CredentialsCommand].
  const CredentialsCommand();

  @override
  String get name => 'credentials';

  @override
  String get description =>
      'Manage stored CLI secrets (prune orphaned credentials).';

  @override
  String get usage => 'credentials prune [--dry-run]';

  @override
  void configureArgParser(ArgParser parser) {
    parser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Print what would be removed without deleting anything',
    );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags, {
    // Injectable secret store, used by tests to avoid exercising the real
    // permission-hardened filesystem store. Not part of the
    // `CliCommand.execute` contract — see `RemoteCommand`'s identical
    // pattern for why this is legal and safe for `cli_runner.dart`.
    SecretStore? secretStoreOverride,
  }) async {
    if (args.isEmpty) {
      ctx.writeError(
        'credentials: subcommand required (prune).\nUsage: $usage',
      );
      return false;
    }

    final subcommand = args[0];
    switch (subcommand) {
      case 'prune':
        return _prune(ctx, flags, secretStoreOverride: secretStoreOverride);
      default:
        ctx.writeError(
          "credentials: unknown subcommand '$subcommand'. Expected: prune.",
        );
        return false;
    }
  }

  // ── prune ──────────────────────────────────────────────────────────────────

  Future<bool> _prune(
    CommandContext ctx,
    Map<String, dynamic> flags, {
    SecretStore? secretStoreOverride,
  }) async {
    final dbDir = (await ctx.store.storeInfo()).dbDir;
    final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
    final dryRun = flags['dry-run'] == true;

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    // Every key a *live* google-drive remote in this database currently
    // points at — anything scoped to this database but not in this set is
    // orphaned.
    final liveKeys = <String>{
      for (final remote in config.remotes.values)
        if (remote is GoogleDriveRemoteConfig)
          dbScopedSecretKey(dbDir, remote.credentialsPath),
    };

    // list() returns every key in the shared global store, across every
    // database on this machine — filter down to just this database's keys
    // before computing orphans, so a differently-scoped key is never even
    // considered, let alone deleted.
    final allKeys = await store.list();
    final dbKeys = allKeys.where((k) => isSecretKeyForDb(k, dbDir)).toList();
    final orphaned = dbKeys.where((k) => !liveKeys.contains(k)).toList()
      ..sort();

    if (orphaned.isEmpty) {
      ctx.out.writeln('credentials prune: no orphaned secrets found.');
      return true;
    }

    for (final key in orphaned) {
      if (dryRun) {
        ctx.out.writeln('Would remove: $key');
      } else {
        await store.delete(key);
        ctx.out.writeln('Removed: $key');
      }
    }
    return true;
  }
}
