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

/// Upserts a document.
///
/// The JSON document is read from `--value` (inline) or from stdin.
/// The document must contain a string `id` field that becomes the key,
/// or use `--autoid` to generate a new UUIDv7 identifier.
///
/// Usage: `kmdb <db> put <namespace> [--value '<json>'] [--autoid]`
final class PutCommand implements CliCommand {
  const PutCommand();

  @override
  String get name => 'put';

  @override
  String get description =>
      'Upsert a document. JSON read from --value or stdin.';

  @override
  String get usage => 'put <namespace> [--value <json>] [--autoid]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('put requires <namespace>.\nUsage: $usage');
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

    final autoid = flags['autoid'] == true;
    final keyRaw = doc['id'];
    final String key;
    if (keyRaw != null) {
      key = '$keyRaw';
    } else if (autoid) {
      key = const UuidV7KeyGenerator().next();
      doc['id'] = key;
    } else {
      ctx.writeError('Document must have a string "id" field, or use --autoid.');
      return false;
    }

    final encoded = ValueCodec.encode(doc);
    await ctx.store.put(namespace, key, encoded);
    ctx.writeDocuments([doc]);
    return true;
  }
}
