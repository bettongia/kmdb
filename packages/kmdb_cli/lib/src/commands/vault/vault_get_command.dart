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

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

import '../command.dart';

/// Fetches a vault object by its `kmdb-vault://` URI and writes the raw blob
/// bytes to stdout or an `--output` file.
///
/// When the vault object is a stub (manifest present, blob absent), the command
/// fails with a descriptive error because no sync adapter is configured at the
/// CLI layer. Hydration requires a wired [VaultStorageAdapter].
///
/// Usage:
/// ```
/// kmdb <db> vault get <uri>
/// kmdb <db> vault get <uri> --output photo.jpg
/// ```
final class VaultGetCommand implements CliCommand {
  const VaultGetCommand();

  @override
  String get name => 'get';

  @override
  String get description =>
      'Fetch a vault object by its kmdb-vault:// URI. '
      'Writes raw bytes to stdout or --output <file>.';

  @override
  String get usage => 'vault get <uri> [--output <file>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final vaultStore = ctx.vaultStore;
    if (vaultStore == null) {
      ctx.writeError('Vault is not configured for this database.');
      return false;
    }

    if (args.isEmpty) {
      ctx.writeError('vault get requires a URI argument.\nUsage: $usage');
      return false;
    }
    final uriStr = args[0];

    // Validate the URI format eagerly before touching the vault.
    final String sha256;
    try {
      final ref = VaultRef(uriStr);
      sha256 = ref.sha256;
    } on FormatException catch (e) {
      ctx.writeError('Invalid vault URI: ${e.message}');
      return false;
    }

    // Check whether the object exists locally.
    if (!await vaultStore.exists(sha256)) {
      ctx.writeError(
        'Vault object not found: $uriStr\n'
        'The object may not have been ingested on this device.',
      );
      return false;
    }

    // Check whether the blob is present (not a stub).
    if (!await vaultStore.isHydrated(sha256)) {
      ctx.writeError(
        'Vault object is a stub (metadata-only): $uriStr\n'
        'The blob has not been downloaded on this device. '
        'Configure a sync remote and run a pull to hydrate.',
      );
      return false;
    }

    // Retrieve the raw bytes.
    final Uint8List bytes;
    try {
      bytes = await vaultStore.getBytes(sha256);
    } catch (e) {
      ctx.writeError('Failed to read vault object: $e');
      return false;
    }

    // Write to --output file or stdout.
    final outputPath = flags['output'] as String?;
    if (outputPath != null) {
      try {
        await io.File(outputPath).writeAsBytes(bytes);
        ctx.writeValue({
          'uri': uriStr,
          'sha256': sha256,
          'size': bytes.length,
          'output': outputPath,
        });
      } on io.IOException catch (e) {
        ctx.writeError('Cannot write to "$outputPath": $e');
        return false;
      }
    } else {
      // Write raw bytes to stdout. The CommandContext.out is a StringSink, so
      // we bypass it and write directly to the binary stdout for binary data.
      io.stdout.add(bytes);
      await io.stdout.flush();
    }

    return true;
  }
}
