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

import 'command.dart';

/// Deletes a document by key.
///
/// Usage: `kmdb <db> delete <collection> <key>`
final class DeleteCommand implements CliCommand {
  const DeleteCommand();

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a document by key.';

  @override
  String get usage => 'delete <collection> <key>';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 2) {
      ctx.writeError('delete requires <collection> and <key>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];
    final key = args[1];

    await ctx.store.delete(collection, key);
    ctx.writeValue({'deleted': key});
    return true;
  }
}
