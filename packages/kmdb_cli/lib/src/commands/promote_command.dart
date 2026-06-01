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

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Promotes a prior version of a document to become the new latest write.
///
/// Usage: `kmdb <db> promote <collection> <key> <version>`
///
/// Where [version] is the HLC hex string from `kmdb versions`. The promoted
/// document value is written as a new put with a fresh HLC — from the
/// perspective of other devices this is a normal LWW-eligible update.
///
/// ## Effects
///
/// - A new `$ver:` entry is created with `promoted_from` set to [version].
/// - If [version] identifies a delete-version, the document is re-deleted.
/// - If [version] identifies a put-version and the document is currently
///   deleted, the promotion un-deletes the document.
///
/// ## Errors
///
/// Exits with code 1 if:
/// - [version] is not a valid HLC hex string.
/// - The version entry no longer exists (trimmed by compaction).
///
/// ## Example
///
/// ```bash
/// # Roll back to a specific version
/// kmdb mydb promote tasks 019501a3b4c5d6e7f8091a2b3c4d5e6f 000018fa2e3d4c5b
/// ```
final class PromoteCommand extends CliCommand {
  const PromoteCommand();

  @override
  String get name => 'promote';

  @override
  String get description => 'Promote a prior version of a document.';

  @override
  String get usage => 'promote <collection> <key> <version>';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 3) {
      ctx.writeError(
        'promote requires <collection>, <key>, and <version>.\n'
        'Usage: $usage',
      );
      return false;
    }
    final collection = args[0];
    final key = args[1];
    final versionHex = args[2];

    // Parse the HLC from its hex representation.
    final Hlc hlc;
    try {
      hlc = Hlc.fromHex(versionHex);
    } catch (_) {
      ctx.writeError(
        'Invalid version HLC: "$versionHex". '
        'Use the hex value from "kmdb versions".',
      );
      return false;
    }

    final col = ctx.rawCollection(collection);
    try {
      await col.promoteVersion(key, hlc);
    } on VersionNotFoundError catch (e) {
      ctx.writeError(e.toString());
      return false;
    }

    ctx.out.writeln('Promoted $collection/$key to version $versionHex');
    return true;
  }
}
