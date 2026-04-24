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

/// Dumps the entire database as NDJSON.
///
/// Each collection is preceded by a header comment line:
/// `# collection: <name>`
///
/// Output is written to [CommandContext.out]. To redirect to a file, use the
/// global `--output <file>` flag:
///
/// ```
/// kmdb mydb --output backup.ndjson dump
/// ```
///
/// With `--vault`, exports vault attachments alongside each document that
/// contains vault references. KVLT package files are written to `<outputDir>/`,
/// where `<outputDir>` defaults to `vault_dump/` when `--output` is used to
/// redirect the NDJSON and `vault_dump/` otherwise.
/// Stub vault objects (no local blob) are silently skipped.
///
/// Usage: `kmdb <db> dump [--vault] [--vault-dir <dir>]`
final class DumpCommand extends CliCommand {
  const DumpCommand();

  @override
  String get name => 'dump';

  @override
  String get description =>
      'Dump all collections to NDJSON. '
      'With --vault, exports vault attachments as KVLT packages.';

  @override
  String get usage => 'dump';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addFlag(
        'vault',
        negatable: false,
        help: 'Export vault attachments as KVLT packages',
      )
      ..addOption(
        'vault-dir',
        valueHelp: 'dir',
        help: 'Output directory for vault packages (default: vault_dump)',
      );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final vaultFlag = flags['vault'] == true;

    if (vaultFlag) {
      return _executeVaultDump(ctx, flags);
    }

    // Standard NDJSON dump.
    const enc = JsonEncoder();
    final collections = await ctx.store.listNamespaces();
    for (final coll in collections) {
      ctx.out.writeln('# collection: $coll');
      await for (final entry in ctx.store.scan(coll)) {
        // Inject _id from the entry key — documents are stored without _id in
        // the value bytes; the key is the canonical identity.
        final doc = ValueCodec.decode(entry.value)..['_id'] = entry.key;
        ctx.out.writeln(enc.convert(doc));
      }
    }
    return true;
  }

  // ── Vault dump ─────────────────────────────────────────────────────────────

  /// Dumps the entire database as NDJSON, writing vault attachments as KVLT
  /// packages to [vaultDir].
  ///
  /// Each document with vault URIs gets a `<docId>.kvlt` file in
  /// `<vaultDir>/<collection>/`. Stubs (no local blob) are silently skipped.
  Future<bool> _executeVaultDump(
    CommandContext ctx,
    Map<String, dynamic> flags,
  ) async {
    final vaultStore = ctx.vaultStore;
    if (vaultStore == null) {
      ctx.writeError(
        '--vault requires vault to be configured for this database.',
      );
      return false;
    }

    final vaultDirPath = flags['vault-dir'] as String? ?? 'vault_dump';
    final vaultRootDir = io.Directory(vaultDirPath);
    try {
      await vaultRootDir.create(recursive: true);
    } on io.IOException catch (e) {
      ctx.writeError('Cannot create vault directory "$vaultDirPath": $e');
      return false;
    }

    const enc = JsonEncoder();
    final collections = await ctx.store.listNamespaces();
    var stubsSkipped = 0;
    var packagesWritten = 0;

    for (final coll in collections) {
      ctx.out.writeln('# collection: $coll');
      final collDir = io.Directory('$vaultDirPath/$coll');

      await for (final entry in ctx.store.scan(coll)) {
        final doc = ValueCodec.decode(entry.value)..['_id'] = entry.key;
        final docId = entry.key;

        ctx.out.writeln(enc.convert(doc));

        // Find vault URIs in this document.
        final vaultUris = _scanForVaultUris(doc);
        if (vaultUris.isEmpty) continue;

        // Create per-collection vault dir lazily.
        if (!collDir.existsSync()) {
          try {
            await collDir.create(recursive: true);
          } on io.IOException catch (e) {
            ctx.writeError(
              'Cannot create vault directory "${collDir.path}": $e',
            );
            return false;
          }
        }

        final attachments = <VaultAttachment>[];
        var subdirIndex = 0;
        for (final uri in vaultUris) {
          final sha256 = VaultRef(uri).sha256;
          if (!await vaultStore.isHydrated(sha256)) {
            stubsSkipped++;
            continue;
          }
          try {
            final bytes = await vaultStore.getBytes(sha256);
            final manifest = await vaultStore.getManifest(sha256);
            attachments.add(
              VaultAttachment(
                subdirName: '$subdirIndex',
                bytes: bytes,
                uploadManifest: manifest,
              ),
            );
            subdirIndex++;
          } catch (e) {
            ctx.writeError('Failed to read vault object $sha256: $e');
            return false;
          }
        }

        if (attachments.isEmpty) continue;

        final packageBytes = VaultPackage.write(
          documentJson: doc,
          attachments: attachments,
        );
        final packagePath = '${collDir.path}/$docId.kvlt';
        try {
          await io.File(packagePath).writeAsBytes(packageBytes);
          packagesWritten++;
        } on io.IOException catch (e) {
          ctx.writeError('Cannot write package "$packagePath": $e');
          return false;
        }
      }
    }

    ctx.writeValue({
      'packagesWritten': packagesWritten,
      'stubsSkipped': stubsSkipped,
      'vaultDir': vaultDirPath,
    });
    return true;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns all vault URI strings found anywhere in [doc].
  Set<String> _scanForVaultUris(Map<String, dynamic> doc) {
    final result = <String>{};
    _scan(doc, result);
    return result;
  }

  void _scan(dynamic value, Set<String> result) {
    if (value is String && VaultRef.isVaultUri(value)) {
      result.add(value);
    } else if (value is Map<String, dynamic>) {
      for (final v in value.values) {
        _scan(v, result);
      }
    } else if (value is List<dynamic>) {
      for (final item in value) {
        _scan(item, result);
      }
    }
  }
}
