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

import 'package:kmdb/kmdb_config.dart';
import 'command.dart';

/// Manages named sync remotes for a KMDB database.
///
/// Remotes are stored in `{dbDir}/local/config.json` and are used by the
/// `push`, `pull`, and `sync` commands.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> remote add <name> --path <path> [--type local] [--force]
/// kmdb <db> remote remove <name>
/// kmdb <db> remote list
/// ```
///
/// The first positional argument is the subcommand. For `add` and `remove`,
/// the second positional argument is the remote name.
final class RemoteCommand extends CliCommand {
  /// Creates a [RemoteCommand].
  const RemoteCommand();

  @override
  String get name => 'remote';

  @override
  String get description => 'Manage named sync remotes (add, remove, list).';

  @override
  String get usage =>
      '''remote add <name> --path <path> [--type local] [--force]
       remote remove <name>
       remote list''';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'remote: subcommand required (add, remove, list).\n'
        'Usage: $usage',
      );
      return false;
    }

    final subcommand = args[0];
    switch (subcommand) {
      case 'add':
        return _add(ctx, args.sublist(1), flags);
      case 'remove':
        return _remove(ctx, args.sublist(1));
      case 'list':
        return _list(ctx);
      default:
        ctx.writeError(
          "remote: unknown subcommand '$subcommand'. "
          'Expected: add, remove, list.',
        );
        return false;
    }
  }

  // ── add ────────────────────────────────────────────────────────────────────

  Future<bool> _add(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('remote add: remote name required.');
      return false;
    }
    final name = args[0];

    // Resolve adapter type — default to 'local' since it is the only
    // supported type right now; allow explicit --type for future expansion.
    final type = (flags['type'] as String?) ?? 'local';
    final force = flags['force'] == true;

    final RemoteConfig remote;
    switch (type) {
      case 'local':
        final path = flags['path'] as String?;
        if (path == null) {
          ctx.writeError("remote add: --path is required for type 'local'.");
          return false;
        }
        remote = LocalRemoteConfig(path: path);
      default:
        ctx.writeError(
          "remote add: unknown type '$type'. Supported types: local.",
        );
        return false;
    }

    final dbDir = (await ctx.store.storeInfo()).dbDir;
    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    try {
      config.addRemote(name, remote, force: force);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await config.save();
    } catch (e) {
      ctx.writeError('remote add: failed to save config: $e');
      return false;
    }

    ctx.out.writeln("Remote '$name' added (type: $type).");
    return true;
  }

  // ── remove ─────────────────────────────────────────────────────────────────

  Future<bool> _remove(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('remote remove: remote name required.');
      return false;
    }
    final name = args[0];
    final dbDir = (await ctx.store.storeInfo()).dbDir;

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    try {
      config.removeRemote(name);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await config.save();
    } catch (e) {
      ctx.writeError('remote remove: failed to save config: $e');
      return false;
    }

    ctx.out.writeln("Remote '$name' removed.");
    return true;
  }

  // ── list ───────────────────────────────────────────────────────────────────

  Future<bool> _list(CommandContext ctx) async {
    final dbDir = (await ctx.store.storeInfo()).dbDir;

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    if (config.remotes.isEmpty) {
      ctx.out.writeln('No remotes configured.');
      return true;
    }

    // Print one line per remote with name, type, and the most relevant field.
    for (final entry in config.remotes.entries) {
      final name = entry.key;
      final remote = entry.value;
      switch (remote) {
        case LocalRemoteConfig(:final path):
          ctx.out.writeln('$name\tlocal\t$path');
      }
    }
    return true;
  }
}
