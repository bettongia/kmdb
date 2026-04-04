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

/// Lists all user collections in the database.
///
/// Usage: `kmdb <db> collections`
final class CollectionsCommand implements CliCommand {
  const CollectionsCommand();

  @override
  String get name => 'collections';

  @override
  String get description => 'List all user collections in the database.';

  @override
  String get usage => 'collections';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final namespaces = await ctx.store.listNamespaces();
    ctx.writeValue(namespaces);
    return true;
  }
}
