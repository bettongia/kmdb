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

/// Counts documents in a namespace, optionally filtered.
///
/// Usage: `kmdb <db> count <namespace> [--filter <json>]`
final class CountCommand implements CliCommand {
  const CountCommand();

  @override
  String get name => 'count';

  @override
  String get description => 'Count documents in a namespace.';

  @override
  String get usage => 'count <namespace> [--filter <json>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('count requires <namespace>.\nUsage: $usage');
      return false;
    }
    final namespace = args[0];

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

    var count = 0;
    await for (final entry in ctx.store.scan(namespace)) {
      if (filter != null) {
        final doc = ValueCodec.decode(entry.value);
        if (!filter.evaluate(doc)) continue;
      }
      count++;
    }

    ctx.writeValue({'count': count});
    return true;
  }
}
