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

import '../filter/filter_parser.dart';
import 'command.dart';

/// Counts documents in a collection, optionally filtered.
///
/// Usage: `kmdb <db> count <collection> [--filter <json>]`
///
/// Counts route through the Query Layer so secondary-index acceleration (when
/// available) and the Cache Layer are used automatically.
final class CountCommand extends CliCommand {
  const CountCommand();

  @override
  String get name => 'count';

  @override
  String get description => 'Count documents in a collection.';

  @override
  String get usage => 'count <collection>';

  @override
  void configureArgParser(ArgParser parser) {
    parser.addOption(
      'filter',
      valueHelp: 'json',
      help: 'JSON filter expression',
    );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('count requires <collection>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    Filter? filter;
    final filterJson = flags['filter'] as String?;
    if (filterJson != null) {
      try {
        filter = FilterParser.parse(filterJson);
      } on ArgumentError catch (e) {
        ctx.writeError('Invalid filter: ${e.message}');
        return false;
      } on FormatException catch (e) {
        ctx.writeError('Invalid filter JSON: ${e.message}');
        return false;
      }
    }

    // Route through the Query Layer. When a filter is present, use
    // col.where(filter).count() which can leverage secondary indexes.
    // When no filter is present, count all documents via col.all().count().
    final col = ctx.rawCollection(collection);
    final count = filter != null
        ? await col.where(filter).count()
        : await col.all().count();

    ctx.writeValue({'count': count});
    return true;
  }
}
