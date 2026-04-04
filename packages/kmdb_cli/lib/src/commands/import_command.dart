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

/// Imports NDJSON documents into a collection.
///
/// Each line in the input must be a valid JSON object with a string `id` field.
///
/// Usage:
/// ```
/// kmdb <db> import <collection> [--input <file>]
///                                [--on-conflict ignore|replace|error]
/// ```
final class ImportCommand implements CliCommand {
  const ImportCommand();

  @override
  String get name => 'import';

  @override
  String get description => 'Import NDJSON documents into a collection.';

  @override
  String get usage =>
      'import <collection> [--input <file>] [--on-conflict ignore|replace|error]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('import requires <collection>.\nUsage: $usage');
      return false;
    }
    final namespace = args[0];
    final inputPath = flags['input'] as String?;
    final onConflict = (flags['on-conflict'] as String?) ?? 'replace';

    if (!{'ignore', 'replace', 'error'}.contains(onConflict)) {
      ctx.writeError(
        'Unknown --on-conflict value "$onConflict". Use: ignore, replace, error',
      );
      return false;
    }

    final Stream<String> lines;
    if (inputPath != null) {
      lines = io.File(
        inputPath,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter());
    } else {
      lines = io.stdin.transform(utf8.decoder).transform(const LineSplitter());
    }

    var imported = 0;
    var skipped = 0;
    var lineNum = 0;

    await for (final line in lines) {
      lineNum++;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final Map<String, dynamic> doc;
      try {
        final decoded = json.decode(trimmed);
        if (decoded is! Map<String, dynamic>) {
          ctx.writeError(
            'Line $lineNum: expected JSON object, got ${decoded.runtimeType}',
          );
          return false;
        }
        doc = decoded;
      } on FormatException catch (e) {
        ctx.writeError('Line $lineNum: invalid JSON: ${e.message}');
        return false;
      }

      final keyRaw = doc['id'];
      if (keyRaw == null) {
        ctx.writeError('Line $lineNum: document missing "id" field');
        return false;
      }
      final key = '$keyRaw';

      if (onConflict != 'replace') {
        final existing = await ctx.store.get(namespace, key);
        if (existing != null) {
          if (onConflict == 'error') {
            ctx.writeError('Line $lineNum: document already exists: $key');
            return false;
          }
          // ignore
          skipped++;
          continue;
        }
      }

      final encoded = ValueCodec.encode(doc);
      await ctx.store.put(namespace, key, encoded);
      imported++;
    }

    ctx.writeValue({'imported': imported, 'skipped': skipped});
    return true;
  }
}
