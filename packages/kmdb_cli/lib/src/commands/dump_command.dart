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

/// Dumps the entire database as NDJSON.
///
/// Each collection is preceded by a header comment line:
/// `# collection: <name>`
///
/// Output is written to [CommandContext.out]. To redirect to a file, use the
/// global `--output <file>` flag:
///
/// ```
/// kmdb mydb --output backup.ndjson dump
/// ```
///
/// Usage: `kmdb <db> dump`
final class DumpCommand implements CliCommand {
  const DumpCommand();

  @override
  String get name => 'dump';

  @override
  String get description => 'Dump all collections to NDJSON.';

  @override
  String get usage => 'dump';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    const enc = JsonEncoder();
    final collections = await ctx.store.listNamespaces();
    for (final coll in collections) {
      ctx.out.writeln('# collection: $coll');
      await for (final entry in ctx.store.scan(coll)) {
        final doc = ValueCodec.decode(entry.value);
        ctx.out.writeln(enc.convert(doc));
      }
    }
    return true;
  }
}
