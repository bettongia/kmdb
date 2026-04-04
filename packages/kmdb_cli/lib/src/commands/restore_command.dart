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

/// Restores a database from a dump file produced by [DumpCommand].
///
/// Usage: `kmdb <db> restore [--input <file>]`
final class RestoreCommand implements CliCommand {
  const RestoreCommand();

  @override
  String get name => 'restore';

  @override
  String get description => 'Restore all namespaces from a NDJSON dump.';

  @override
  String get usage => 'restore [--input <file>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final inputPath = flags['input'] as String?;

    final Stream<String> lines;
    if (inputPath != null) {
      lines = io.File(
        inputPath,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter());
    } else {
      lines = io.stdin.transform(utf8.decoder).transform(const LineSplitter());
    }

    String? currentNamespace;
    var imported = 0;
    var lineNum = 0;

    await for (final line in lines) {
      lineNum++;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Namespace header line emitted by dump.
      if (trimmed.startsWith('# namespace: ')) {
        currentNamespace = trimmed.substring('# namespace: '.length).trim();
        continue;
      }

      // Skip other comment lines.
      if (trimmed.startsWith('#')) continue;

      if (currentNamespace == null) {
        ctx.writeError(
          'Line $lineNum: encountered document before any namespace header.',
        );
        return false;
      }

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

      final encoded = ValueCodec.encode(doc);
      await ctx.store.put(currentNamespace, '$keyRaw', encoded);
      imported++;
    }

    ctx.writeValue({'restored': imported});
    return true;
  }
}
