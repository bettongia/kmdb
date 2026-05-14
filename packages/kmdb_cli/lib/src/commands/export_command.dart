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

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Exports a collection to newline-delimited JSON (NDJSON).
///
/// Output is written to [CommandContext.out]. To redirect to a file, use the
/// global `--output <file>` flag:
///
/// ```
/// kmdb mydb --output backup.ndjson export notes
/// ```
///
/// With `--vault`, exports each document that contains vault references as a
/// KVLT package file alongside the NDJSON. The package files are written to an
/// `<output-dir>/` directory next to the NDJSON file. Stub vault objects
/// (metadata-only, no local blob) are silently skipped; the summary reports
/// how many stubs were skipped.
///
/// Usage:
/// ```
/// kmdb <db> export <collection>
/// kmdb <db> export <collection> --vault [--output <dir>]
/// ```
final class ExportCommand extends CliCommand {
  const ExportCommand();

  @override
  String get name => 'export';

  @override
  String get description =>
      'Export a collection to NDJSON. '
      'With --vault, exports vault attachments as KVLT packages.';

  @override
  String get usage => 'export <collection>';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addFlag(
        'vault',
        negatable: false,
        help: 'Export vault attachments as KVLT packages alongside NDJSON',
      )
      ..addOption(
        'output',
        valueHelp: 'dir',
        help:
            'Output directory for vault packages (default: <collection>_vault_export)',
      );
  }

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
    final vaultFlag = flags['vault'] == true;

    if (vaultFlag) {
      return _executeVaultExport(ctx, collection, flags);
    }

    const enc = JsonEncoder();
    await for (final entry in ctx.store.scan(collection)) {
      // Inject _id from the entry key — documents are stored without _id in
      // the value bytes (the key is the canonical identity). The exported NDJSON
      // must include _id so that import can restore documents to their original
      // keys rather than generating new ones.
      final doc = ValueCodec.decode(entry.value)..['_id'] = entry.key;
      ctx.out.writeln(enc.convert(doc));
    }
    return true;
  }

  // ── Vault export ───────────────────────────────────────────────────────────

  /// Exports a collection as NDJSON + KVLT packages for documents with vault
  /// attachments.
  ///
  /// Each document that contains vault URIs is written as a KVLT package file
  /// to `<outputDir>/<collection>/<docId>.kvlt`. Plain documents are written
  /// only to the NDJSON stream.
  ///
  /// [flags] may contain `output` (the output directory path). If not provided,
  /// packages are written to `<collection>_vault_export/`.
  Future<bool> _executeVaultExport(
    CommandContext ctx,
    String collection,
    Map<String, dynamic> flags,
  ) async {
    final vaultStore = ctx.vaultStore;
    if (vaultStore == null) {
      ctx.writeError(
        '--vault requires vault to be configured for this database.',
      );
      return false;
    }

    final outputDir =
        flags['output'] as String? ?? '${collection}_vault_export';
    final dir = io.Directory(outputDir);
    try {
      await dir.create(recursive: true);
    } on io.IOException catch (e) {
      ctx.writeError('Cannot create output directory "$outputDir": $e');
      return false;
    }

    var exported = 0;
    var stubsSkipped = 0;
    const enc = JsonEncoder();

    await for (final entry in ctx.store.scan(collection)) {
      // Inject _id from the entry key — documents are stored without _id in
      // the value bytes (the key is the canonical identity).
      final doc = ValueCodec.decode(entry.value)..['_id'] = entry.key;
      final docId = entry.key;

      // Find vault URIs in this document.
      final vaultUris = _scanForVaultUris(doc);

      if (vaultUris.isEmpty) {
        // Plain document: write to NDJSON only.
        ctx.out.writeln(enc.convert(doc));
        exported++;
        continue;
      }

      // Document has vault references: build a KVLT package.
      final attachments = <VaultAttachment>[];
      var subdirIndex = 0;

      for (final uri in vaultUris) {
        final sha256 = VaultRef(uri).sha256;
        if (!await vaultStore.isHydrated(sha256)) {
          // Stub: log and skip.
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

      // Write the KVLT package file.
      final packageBytes = VaultPackage.write(
        documentJson: doc,
        attachments: attachments,
      );
      final packagePath = '$outputDir/$docId.kvlt';
      try {
        await io.File(packagePath).writeAsBytes(packageBytes);
      } on io.IOException catch (e) {
        ctx.writeError('Cannot write package "$packagePath": $e');
        return false;
      }

      // Also write the document JSON line for discoverability.
      ctx.out.writeln(enc.convert(doc));
      exported++;
    }

    ctx.writeValue({
      'exported': exported,
      'stubsSkipped': stubsSkipped,
      'outputDir': outputDir,
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
