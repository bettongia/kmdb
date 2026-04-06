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

/// Retrieves a single document by key.
///
/// Usage: `kmdb <db> get <coll> <key>`
final class GetCommand implements CliCommand {
  const GetCommand();

  @override
  String get name => 'get';

  @override
  String get description => 'Retrieve a document by key.';

  @override
  String get usage => 'get <coll> <key> [--select <field1,field2,...>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 2) {
      ctx.writeError('get requires <coll> and <key>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];
    final key = args[1];

    final bytes = await ctx.store.get(collection, key);
    if (bytes == null) {
      ctx.writeError('Document not found: $collection/$key');
      return false;
    }

    var doc = ValueCodec.decode(bytes);
    final selectValue = flags['select'];
    if (selectValue != null) {
      final fields = '$selectValue'
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
      if (fields.isNotEmpty) {
        doc = {
          for (final entry in doc.entries)
            if (fields.contains(entry.key)) entry.key: entry.value,
        };
      }
    }
    ctx.writeDocuments([doc]);
    return true;
  }
}
