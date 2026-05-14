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

import '../../commands/command.dart';
import '../../commands/collections_command.dart';
import '../../commands/index_command.dart';
import '../../commands/schema_command.dart';
import '../dot_command.dart';
import '../session_state.dart';

/// `.collections` — alias for `collections list`.
final class CollectionsAliasCommand extends DotCommand {
  const CollectionsAliasCommand();

  @override
  String get name => 'collections';

  @override
  String get description => 'List all user collections.';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) => const CollectionsCommand().execute(ctx, ['list'], {});
}

/// `.indexes [collection]` — alias for `index list [collection]`.
final class IndexesAliasCommand extends DotCommand {
  const IndexesAliasCommand();

  @override
  String get name => 'indexes';

  @override
  String get description => 'Show index definitions for a collection.';

  @override
  String get argSynopsis => '[collection]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) {
    final coll = args.isNotEmpty ? args[0] : state.activeCollection;
    if (coll == null) {
      ctx.err.writeln(
        'Error: .indexes requires a collection name or an active collection '
        '(set with .collection).',
      );
      return Future.value(false);
    }
    return const IndexCommand().execute(ctx, ['list', coll], {});
  }
}

/// `.schema [collection]` — alias for `schema show <collection>`.
final class SchemaAliasCommand extends DotCommand {
  const SchemaAliasCommand();

  @override
  String get name => 'schema';

  @override
  String get description => 'Show schema for a collection.';

  @override
  String get argSynopsis => '[collection]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) {
    final coll = args.isNotEmpty ? args[0] : state.activeCollection;
    if (coll == null) {
      ctx.err.writeln(
        'Error: .schema requires a collection name or an active collection '
        '(set with .collection).',
      );
      return Future.value(false);
    }
    return const SchemaCommand().execute(ctx, ['show', coll], {});
  }
}
