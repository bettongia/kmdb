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

import '../output/output_mode.dart';
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
/// For JSON/YAML output, dot-child paths are re-nested (e.g. `address.city` →
/// `{"address": {"city": "London"}}`). For table/csv/line output, dot-paths
/// are kept as flat keys so the path itself appears as the column header.
/// Bracket selections always use the raw path token as a flat key.
///
/// Reads pass through the Cache Layer, so recently-written documents are served
/// from the session cache without a store scan.
final class GetCommand extends CliCommand {
  const GetCommand();

  @override
  String get name => 'get';

  @override
  String get description => 'Retrieve a document by key.';

  @override
  String get usage => 'get <collection> <key>';

  @override
  void configureArgParser(ArgParser parser) {
    parser.addOption(
      'select',
      valueHelp: 'path1,path2,...',
      help:
          'Comma-separated field paths to project '
          '(e.g. name, address.city, tags[0])',
    );
  }

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

    // Route through the Query Layer so the Cache Layer is consulted before
    // going to the LSM engine.
    final col = ctx.rawCollection(collection);
    final doc = await col.get(key);
    if (doc == null) {
      ctx.writeError('Document not found: $collection/$key');
      return false;
    }

    final selectValue = flags['select'];
    if (selectValue != null) {
      final fields = '$selectValue'
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (fields.isNotEmpty) {
        final flat =
            ctx.mode == OutputMode.table ||
            ctx.mode == OutputMode.csv ||
            ctx.mode == OutputMode.line;
        ctx.writeDocuments([projectDocument(doc, fields, flat: flat)]);
        return true;
      }
    }
    ctx.writeDocuments([doc]);
    return true;
  }
}
