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
import 'scan_command.dart';

/// Retrieves a single document by key.
///
/// Usage: `kmdb <db> get <coll> <key>`
///
/// The optional `--select` flag accepts a comma-separated list of field paths
/// using the full JSONPath subset supported by KMDB. See [ScanCommand] for the
/// complete path syntax documentation.
///
/// Dot-child paths are re-nested in the output (e.g. `address.city` →
/// `{"address": {"city": "London"}}`). Bracket selections use the raw path
/// token as a flat key.
final class GetCommand implements CliCommand {
  const GetCommand();

  @override
  String get name => 'get';

  @override
  String get description => 'Retrieve a document by key.';

  @override
  String get usage =>
      'get <coll> <key> [--select <path1,path2,...>]  '
      r'Paths: "name", "address.city", "$.name", "tags[0]", "tags[-1]", "tags[]"';

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

    final doc = ValueCodec.decode(bytes);
    final selectValue = flags['select'];
    if (selectValue != null) {
      final fields = '$selectValue'
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (fields.isNotEmpty) {
        ctx.writeDocuments([projectDocument(doc, fields)]);
        return true;
      }
    }
    ctx.writeDocuments([doc]);
    return true;
  }
}
