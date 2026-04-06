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

import 'dart:convert';

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Exports a collection to newline-delimited JSON (NDJSON).
///
/// Output is written to [CommandContext.out]. To redirect to a file, use the
/// global `--output <file>` flag:
///
/// ```
/// kmdb mydb --output backup.ndjson export notes
/// ```
///
/// Usage: `kmdb <db> export <collection>`
final class ExportCommand implements CliCommand {
  const ExportCommand();

  @override
  String get name => 'export';

  @override
  String get description => 'Export a collection to NDJSON.';

  @override
  String get usage => 'export <collection>';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('export requires <collection>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    const enc = JsonEncoder();
    await for (final entry in ctx.store.scan(collection)) {
      final doc = ValueCodec.decode(entry.value);
      ctx.out.writeln(enc.convert(doc));
    }
    return true;
  }
}
