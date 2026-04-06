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

/// Exports a collection to newline-delimited JSON (NDJSON).
///
/// Usage: `kmdb <db> export <collection> [--output <file>]`
final class ExportCommand implements CliCommand {
  const ExportCommand();

  @override
  String get name => 'export';

  @override
  String get description => 'Export a collection to NDJSON.';

  @override
  String get usage => 'export <collection> [--output <file>]';

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
    final outputPath = flags['output'] as String?;

    final io.IOSink sink = outputPath != null
        ? io.File(outputPath).openWrite()
        : io.stdout;

    const enc = JsonEncoder();
    var count = 0;
    try {
      await for (final entry in ctx.store.scan(collection)) {
        final doc = ValueCodec.decode(entry.value);
        sink.writeln(enc.convert(doc));
        count++;
      }
    } finally {
      if (outputPath != null) {
        await sink.flush();
        await sink.close();
      }
    }

    if (outputPath != null) {
      ctx.writeValue({'exported': count, 'file': outputPath});
    }
    return true;
  }
}
