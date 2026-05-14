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

import 'command.dart';

/// Manages secondary indexes on a KMDB collection.
///
/// Index definitions are persisted in the CLI config (`local/config.json`) so
/// they survive across sessions. Index entries are stored in `$index:*` system
/// namespaces and rebuilt lazily on first query.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> index list <collection>
/// kmdb <db> index create <collection> <path>
/// kmdb <db> index info <collection> <path>
/// kmdb <db> index delete <collection> <path>
/// ```
final class IndexCommand extends CliCommand {
  /// Creates an [IndexCommand].
  const IndexCommand();

  @override
  String get name => 'index';

  @override
  String get description =>
      'Manage secondary indexes (list, create, info, delete).';

  @override
  String get usage => '''index list <collection>
       index create <collection> <path>
       index info <collection> <path>
       index delete <collection> <path>''';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'index: subcommand required (list, create, info, delete).\n'
        'Usage: $usage',
      );
      return false;
    }

    final subcommand = args[0];
    switch (subcommand) {
      case 'list':
        return _list(ctx, args.sublist(1));
      case 'create':
        return _create(ctx, args.sublist(1));
      case 'info':
        return _info(ctx, args.sublist(1));
      case 'delete':
        return _delete(ctx, args.sublist(1));
      default:
        ctx.writeError(
          "index: unknown subcommand '$subcommand'. "
          'Expected: list, create, info, delete.',
        );
        return false;
    }
  }

  // ── list ───────────────────────────────────────────────────────────────────

  /// Lists all configured indexes for [collection] and their current status.
  ///
  /// Output columns: path, status, builtThrough generation, builtAt timestamp.
  Future<bool> _list(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('index list: collection name required.');
      return false;
    }
    final collection = args[0];
    final defined = ctx.config.indexesForCollection(collection);

    if (defined.isEmpty) {
      ctx.out.writeln('No indexes configured for collection "$collection".');
      return true;
    }

    // For each defined index, report the path and its current state.
    for (final record in defined) {
      final state = await ctx.indexManager.getState(collection, record.path);
      final builtAt = state.builtAt.isEmpty ? '-' : state.builtAt;
      ctx.out.writeln(
        '${record.path}\t${state.status.name}'
        '\tgen=${state.builtThrough}\tbuiltAt=$builtAt',
      );
    }
    return true;
  }

  // ── create ─────────────────────────────────────────────────────────────────

  /// Registers a new index definition in the CLI config.
  ///
  /// Validates that [path] does not start with `_` (reserved system prefix).
  /// Throws if an identical `(collection, path)` pair is already configured.
  Future<bool> _create(CommandContext ctx, List<String> args) async {
    if (args.length < 2) {
      ctx.writeError('index create: collection name and path required.');
      return false;
    }
    final collection = args[0];
    final path = args[1];

    // Validate the path — the same rule enforced by IndexDefinition.
    if (path.startsWith('_')) {
      ctx.writeError(
        "index create: path '$path' starts with '_'. "
        "Paths starting with '_' are reserved for system fields.",
      );
      return false;
    }

    try {
      ctx.config.addIndex(collection, path);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await ctx.config.save();
    } catch (e) {
      ctx.writeError('index create: failed to save config: $e');
      return false;
    }

    ctx.out.writeln(
      'Index on "$collection.$path" registered. '
      'It will be built on the next query that uses it.',
    );
    return true;
  }

  // ── info ───────────────────────────────────────────────────────────────────

  /// Prints detailed state information for the index on [collection]/[path].
  Future<bool> _info(CommandContext ctx, List<String> args) async {
    if (args.length < 2) {
      ctx.writeError('index info: collection name and path required.');
      return false;
    }
    final collection = args[0];
    final path = args[1];

    // Check that the index is registered in the config.
    final defined = ctx.config.indexesForCollection(collection);
    final isConfigured = defined.any((r) => r.path == path);
    if (!isConfigured) {
      ctx.writeError(
        "index info: no index on '$collection.$path' found in config. "
        "Use 'index create $collection $path' to register it.",
      );
      return false;
    }

    final state = await ctx.indexManager.getState(collection, path);
    ctx.out.writeln('collection:   $collection');
    ctx.out.writeln('path:         $path');
    ctx.out.writeln('status:       ${state.status.name}');
    ctx.out.writeln(
      'builtThrough: ${state.builtThrough == 0 ? "(not built)" : state.builtThrough}',
    );
    ctx.out.writeln(
      'builtAt:      ${state.builtAt.isEmpty ? "(not built)" : state.builtAt}',
    );
    return true;
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  /// Removes an index: deletes all stored entries and removes the config entry.
  Future<bool> _delete(CommandContext ctx, List<String> args) async {
    if (args.length < 2) {
      ctx.writeError('index delete: collection name and path required.');
      return false;
    }
    final collection = args[0];
    final path = args[1];

    // Verify the index is registered before attempting removal.
    final defined = ctx.config.indexesForCollection(collection);
    final isConfigured = defined.any((r) => r.path == path);
    if (!isConfigured) {
      ctx.writeError(
        "index delete: no index on '$collection.$path' found in config.",
      );
      return false;
    }

    // Remove all stored index entries via IndexManager.
    try {
      await ctx.indexManager.removeIndex(collection, path);
    } catch (e) {
      ctx.writeError('index delete: failed to remove index entries: $e');
      return false;
    }

    // Remove the config entry and persist.
    try {
      ctx.config.removeIndex(collection, path);
    } on ArgumentError catch (e) {
      // Should not happen given the check above, but handle defensively.
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await ctx.config.save();
    } catch (e) {
      ctx.writeError('index delete: failed to save config: $e');
      return false;
    }

    ctx.out.writeln('Index on "$collection.$path" deleted.');
    return true;
  }
}
