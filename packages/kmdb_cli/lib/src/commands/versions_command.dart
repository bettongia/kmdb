// Copyright 2026 The Authors.
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

import 'command.dart';

/// Lists all historical version entries for a document.
///
/// Usage: `kmdb <db> versions <collection> <key>`
///
/// Outputs a table of versions sorted HLC descending (newest first). Each
/// row shows:
/// - `version` — the HLC hex string (pass to `promote` to restore this version)
/// - `timestamp` — human-readable wall-clock time from the HLC physical component
/// - `promoted_from` — the HLC of the source version if this is a promotion
/// - `is_delete` — `true` for delete-version entries
///
/// Returns exit code 1 if the collection or document is not found.
///
/// ## Example
///
/// ```bash
/// kmdb mydb versions tasks 019501a3b4c5d6e7f8091a2b3c4d5e6f
/// ```
final class VersionsCommand extends CliCommand {
  const VersionsCommand();

  @override
  String get name => 'versions';

  @override
  String get description => 'List historical version entries for a document.';

  @override
  String get usage => 'versions <collection> <key>';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 2) {
      ctx.writeError(
        'versions requires <collection> and <key>.\nUsage: $usage',
      );
      return false;
    }
    final collection = args[0];
    final key = args[1];

    final col = ctx.rawCollection(collection);
    final versions = await col.getVersions(key);

    if (versions.isEmpty) {
      ctx.writeError(
        'No version history found for $collection/$key. '
        'Versioning may be disabled for this collection.',
      );
      return false;
    }

    // Output as JSON documents — each version becomes a metadata map.
    final docs = versions.map((v) {
      final doc = <String, dynamic>{
        'version': v.hlc.toHex(),
        'timestamp': v.timestamp.toIso8601String(),
        'is_delete': v.isDelete,
      };
      if (v.promotedFrom != null) {
        doc['promoted_from'] = v.promotedFrom!.toHex();
      }
      // Include the document value for non-delete versions.
      if (!v.isDelete && v.value != null) {
        doc['value'] = v.value;
      }
      return doc;
    }).toList();

    ctx.writeDocuments(docs);
    return true;
  }
}
