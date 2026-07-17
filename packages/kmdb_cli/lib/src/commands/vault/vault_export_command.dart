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

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:path/path.dart' as p;

import '../command.dart';

/// Fetches a vault object by its `kmdb-vault://` URI and writes the raw blob
/// bytes to an `--output` file or directory.
///
/// Unlike [VaultGetCommand], `--output` is **required** — this command has no
/// stdout fallback, since exporting to a file is its sole purpose.
///
/// When `--output` names an existing directory, the object is written inside
/// it under a filename derived from the vault manifest's `originalName`
/// (sanitised with [p.basename] to strip any path segments, defending against
/// a hostile or absolute `originalName`, then trimmed), falling back to
/// `blob` when `originalName` is empty, all whitespace, or has no basename
/// component (e.g. it is all path separators). When `--output` names a file
/// path (or a non-existent path without a trailing directory), the bytes are
/// written there exactly, overwriting any existing file — the parent
/// directory must already exist.
///
/// When the vault object is a stub (manifest present, blob absent), the
/// command fails with a descriptive error because no sync adapter is
/// configured at the CLI layer. Hydration requires a wired
/// [VaultStorageAdapter].
///
/// Usage:
/// ```
/// kmdb <db> vault export <uri> --output photo.jpg
/// kmdb <db> vault export <uri> --output ./downloads/
/// ```
final class VaultExportCommand extends CliCommand {
  const VaultExportCommand();

  @override
  String get name => 'export';

  @override
  String get description =>
      'Fetch a vault object by its kmdb-vault:// URI and write it to a '
      'required --output file or directory.';

  @override
  String get usage => 'vault export <uri> --output <path>';

  @override
  void configureArgParser(ArgParser parser) {
    parser.addOption(
      'output',
      valueHelp: 'path',
      help:
          'Write blob bytes to this file, or into this directory using a '
          'name derived from the vault object (required)',
    );
  }

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
      ctx.writeError('vault export requires a URI argument.\nUsage: $usage');
      return false;
    }
    final uriStr = args[0];

    final outputPath = (flags['output'] as String?)?.trim();
    if (outputPath == null || outputPath.isEmpty) {
      ctx.writeError('vault export requires --output <path>.\nUsage: $usage');
      return false;
    }

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

    // Fetch the manifest to derive a filename when --output is a directory.
    // getManifest is the sole decryption point for originalName — never
    // decode manifest.json directly.
    final VaultManifest manifest;
    try {
      manifest = await vaultStore.getManifest(sha256);
    } catch (e) {
      ctx.writeError('Failed to read vault manifest: $e');
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

    // Resolve the target path: a directory target derives its filename from
    // the manifest, sanitised via p.basename to strip any path segments an
    // untrusted originalName might carry (absolute paths, traversal, etc.).
    // A non-directory target is written to exactly as given; its parent
    // directory must already exist (no auto-create).
    final String targetPath;
    if (io.Directory(outputPath).existsSync()) {
      final base = p.basename(manifest.originalName).trim();
      targetPath = p.join(outputPath, base.isEmpty ? 'blob' : base);
    } else {
      final parent = p.dirname(outputPath);
      if (parent.isNotEmpty && !io.Directory(parent).existsSync()) {
        ctx.writeError(
          'Cannot write to "$outputPath": parent directory does not exist.',
        );
        return false;
      }
      targetPath = outputPath;
    }

    try {
      await io.File(targetPath).writeAsBytes(bytes);
    } on io.IOException catch (e) {
      ctx.writeError('Cannot write to "$targetPath": $e');
      return false;
    }

    ctx.writeValue({
      'uri': uriStr,
      'sha256': sha256,
      'size': bytes.length,
      'output': targetPath,
    });

    return true;
  }
}
