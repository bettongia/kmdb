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
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Dumps the entire database as NDJSON to stdout or a file.
///
/// Each collection is preceded by a header comment line:
/// `# collection: <name>`
///
/// Usage: `kmdb <db> dump [--output <file>]`
final class DumpCommand implements CliCommand {
  const DumpCommand();

  @override
  String get name => 'dump';

  @override
  String get description => 'Dump all collections to NDJSON.';

  @override
  String get usage => 'dump [--output <file>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final outputPath = flags['output'] as String?;
    final io.IOSink sink = outputPath != null
        ? io.File(outputPath).openWrite()
        : io.stdout;

    const enc = JsonEncoder();
    var total = 0;
    try {
      final collections = await ctx.store.listNamespaces();
      for (final coll in collections) {
        sink.writeln('# collection: $coll');
        await for (final entry in ctx.store.scan(coll)) {
          final doc = ValueCodec.decode(entry.value);
          sink.writeln(enc.convert(doc));
          total++;
        }
      }
    } finally {
      if (outputPath != null) {
        await sink.flush();
        await sink.close();
      }
    }

    if (outputPath != null) {
      ctx.writeValue({'dumped': total, 'file': outputPath});
    }
    return true;
  }
}
