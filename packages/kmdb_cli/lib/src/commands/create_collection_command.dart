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

/// Creates a new (empty) collection in the database.
///
/// If the collection already exists the command succeeds silently and sets
/// `created` to `false`, mirroring the behaviour of `init` on an existing
/// database.
///
/// Output fields:
/// - `name`    — the collection name supplied by the caller.
/// - `created` — `true` if the collection was newly registered, `false` if it
///               already existed.
///
/// Usage: `kmdb <db> create-collection <name>`
final class CreateCollectionCommand extends CliCommand {
  const CreateCollectionCommand();

  @override
  String get name => 'create-collection';

  @override
  String get description =>
      'Create an empty collection. No-op if the collection already exists.';

  @override
  String get usage => 'create-collection <name>';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // Print a one-line deprecation notice to stderr so scripts that parse
    // stdout are unaffected.
    ctx.err.writeln(
      "create-collection is deprecated; use 'collections create <name>' instead.",
    );

    if (args.isEmpty) {
      ctx.writeError('create-collection requires a collection name.');
      return false;
    }

    final name = args[0];
    final created = await ctx.store.createNamespace(name);
    ctx.writeValue({'name': name, 'created': created});
    return true;
  }
}
