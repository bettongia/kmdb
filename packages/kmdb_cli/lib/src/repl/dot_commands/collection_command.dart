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

import '../../commands/command.dart';
import '../dot_command.dart';
import '../session_state.dart';

/// `.collection [name]` — sets or clears the active collection.
///
/// When [name] is supplied, prints a brief summary:
/// - Document count in the collection.
/// - Name of the registered schema, if any.
///
/// With no arguments, clears the active collection.
final class CollectionCommand extends DotCommand {
  const CollectionCommand();

  @override
  String get name => 'collection';

  @override
  String get description =>
      'Set the active collection; shows document count and schema name.';

  @override
  String get argSynopsis => '[name]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      state.activeCollection = null;
      ctx.out.writeln('collection: cleared.');
      return true;
    }

    final name = args[0];

    // Verify the collection exists.
    final collections = await ctx.store.listNamespaces();
    if (!collections.contains(name)) {
      ctx.err.writeln("Error: collection '$name' does not exist.");
      return false;
    }

    state.activeCollection = name;

    // Show document count.
    final col = ctx.rawCollection(name);
    final count = await col.all().count();

    // Show schema name if registered.
    final schema = ctx.db.schemaManager.getSchema(name);
    final schemaNote = schema != null
        ? '  schema: ${schema['title'] ?? name}'
        : '';

    ctx.out.writeln('$name  $count documents$schemaNote');
    return true;
  }
}
