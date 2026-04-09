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

import 'command.dart';

/// Manages user collections in a KMDB database.
///
/// Collections are the user-visible groupings of documents. This command
/// replaces the older flat-style `collections` command with a subcommand
/// dispatcher modelled on the `remote` command.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> collections list
/// kmdb <db> collections create <name>
/// kmdb <db> collections delete <name>
/// ```
///
/// ## Deleting a collection
///
/// `collections delete` is a destructive operation that:
/// 1. Removes all documents in the collection.
/// 2. Removes all secondary index entries and config definitions for the
///    collection.
/// 3. Unregisters the collection from the namespace registry in `$meta`.
///
/// After deletion the collection no longer appears in `collections list` on
/// the current device. Note that other devices that have synced this
/// collection will still show it until they sync and detect that all documents
/// have been tombstoned (or the CLI applies its own post-sync cleanup).
final class CollectionsCommand implements CliCommand {
  /// Creates a [CollectionsCommand].
  const CollectionsCommand();

  @override
  String get name => 'collections';

  @override
  String get description => 'Manage user collections (list, create, delete).';

  @override
  String get usage => '''collections list
       collections create <name>
       collections delete <name>''';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'collections: subcommand required (list, create, delete).\n'
        'Usage: $usage',
      );
      return false;
    }

    final subcommand = args[0];
    switch (subcommand) {
      case 'list':
        return _list(ctx);
      case 'create':
        return _create(ctx, args.sublist(1));
      case 'delete':
        return _delete(ctx, args.sublist(1));
      default:
        ctx.writeError(
          "collections: unknown subcommand '$subcommand'. "
          'Expected: list, create, delete.',
        );
        return false;
    }
  }

  // ── list ───────────────────────────────────────────────────────────────────

  /// Lists all user collections registered in the namespace registry.
  Future<bool> _list(CommandContext ctx) async {
    final namespaces = await ctx.store.listNamespaces();
    ctx.writeValue(namespaces);
    return true;
  }

  // ── create ─────────────────────────────────────────────────────────────────

  /// Creates an empty collection (namespace) with [name].
  ///
  /// Returns `true` if the namespace was newly created, `false` if it already
  /// existed (idempotent).
  Future<bool> _create(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('collections create: collection name required.');
      return false;
    }
    final name = args[0];

    final bool created;
    try {
      created = await ctx.store.createNamespace(name);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    ctx.writeValue(
      created
          ? 'Collection "$name" created.'
          : 'Collection "$name" already exists.',
    );
    return true;
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  /// Deletes a collection and all its contents.
  ///
  /// Steps:
  /// 1. Verify the collection is registered (fails fast if unknown).
  /// 2. Scan all documents and delete them in batches of 200.
  /// 3. For each index defined on the collection, call
  ///    [IndexManager.removeIndex] to purge the stored entries.
  /// 4. Remove index definitions from the CLI config and save.
  /// 5. Unregister the collection from the namespace registry in `$meta`.
  Future<bool> _delete(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('collections delete: collection name required.');
      return false;
    }
    final name = args[0];

    // Verify the collection exists before doing any destructive work.
    final namespaces = await ctx.store.listNamespaces();
    if (!namespaces.contains(name)) {
      ctx.writeError("collections delete: collection '$name' not found.");
      return false;
    }

    // 1. Delete all documents in the collection in batches of 200.
    //    Uses the public writeBatch (which increments gen counters and
    //    registers the namespace) rather than writeBatchInternal, because we
    //    want the write events to fire so that any active watch() streams
    //    are notified.
    const batchSize = 200;
    var batch = WriteBatch();
    var count = 0;

    await for (final entry in ctx.store.scan(name)) {
      batch.delete(name, entry.key);
      count++;
      if (count >= batchSize) {
        await ctx.store.writeBatch(batch);
        batch = WriteBatch();
        count = 0;
      }
    }
    if (!batch.isEmpty) {
      await ctx.store.writeBatch(batch);
    }

    // 2. Remove all secondary indexes for this collection.
    final indexRecords = ctx.config.indexesForCollection(name);
    for (final record in indexRecords) {
      try {
        await ctx.indexManager.removeIndex(name, record.path);
      } catch (e) {
        ctx.writeError(
          "collections delete: failed to remove index "
          "'$name.${record.path}': $e",
        );
        return false;
      }
      ctx.config.removeIndex(name, record.path);
    }

    // Persist the updated config (if any index definitions were removed).
    if (indexRecords.isNotEmpty) {
      final dbDir = (await ctx.store.storeInfo()).dbDir;
      try {
        await ctx.config.save(dbDir);
      } catch (e) {
        ctx.writeError('collections delete: failed to save config: $e');
        return false;
      }
    }

    // 3. Unregister the collection from the $meta namespace registry so it no
    //    longer appears in `collections list`.
    await ctx.store.unregisterNamespace(name);

    ctx.out.writeln('Collection "$name" deleted.');
    return true;
  }
}
