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

/// Inserts a new document.
///
/// A new system-generated UUIDv7 identifier is automatically assigned to the
/// document's `_id` field. To update an existing document, use the `import`
/// command or the typed API.
///
/// The JSON document is read from `--value` (inline) or from stdin.
///
/// Usage: `kmdb <db> put <collection> [--value '<json>']`
final class PutCommand implements CliCommand {
  const PutCommand();

  @override
  String get name => 'put';

  @override
  String get description =>
      'Insert a new document. JSON read from --value or stdin.';

  @override
  String get usage => 'put <collection> [--value <json>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('put requires <collection>.\nUsage: $usage');
      return false;
    }
    final namespace = args[0];

    // Read document JSON from --value flag or stdin.
    final String jsonString;
    if (flags['value'] != null) {
      jsonString = flags['value'] as String;
    } else {
      jsonString = await io.stdin.transform(utf8.decoder).join();
    }

    final Map<String, dynamic> doc;
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        ctx.writeError('Document must be a JSON object.');
        return false;
      }
      doc = decoded;
    } on FormatException catch (e) {
      ctx.writeError('Invalid JSON: ${e.message}');
      return false;
    }

    final String key = const UuidV7KeyGenerator().next();
    // Store the key as '_id' so the document echoed back to the caller
    // includes the authoritative system key field.
    doc['_id'] = key;

    final encoded = ValueCodec.encode(doc);
    await ctx.store.put(namespace, key, encoded);
    ctx.writeDocuments([doc]);
    return true;
  }
}
