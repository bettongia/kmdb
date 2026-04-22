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
import 'vault/vault_import_helper.dart';

/// Inserts one or more new documents into a collection.
///
/// Each document receives a system-generated UUIDv7 identifier in its `_id`
/// field. Any `_id` supplied by the caller is replaced.
///
/// Note: this command operates at the KvStore layer and does not update any
/// secondary indexes defined via `KmdbDatabase.collection`. Secondary indexes
/// will be stale until the next Query Layer write or index rebuild.
///
/// **Input formats accepted:**
/// - A single JSON object: `{"name":"Alice"}`
/// - A JSON array of objects: `[{"name":"Alice"},{"name":"Bob"}]`
/// - NDJSON (one JSON object per line)
///
/// **Input sources (in priority order):**
/// 1. `--value <json>` — inline JSON string (object or array).
/// 2. `--file <path>` — file path. Files with a `.ndjson` or `.jsonl`
///    extension are parsed as NDJSON; all other files are parsed as JSON
///    (object or array).
/// 3. `--import <path>` — KVLT vault package file. Ingests vault blobs and
///    inserts the document from the package. Mutually exclusive with `--value`
///    and `--file`. Requires vault to be configured.
/// 4. stdin — JSON (object or array) or NDJSON auto-detected.
///
/// Usage:
/// ```
/// kmdb <db> insert <collection> [--value <json>]
/// kmdb <db> insert <collection> [--file <path>]
/// kmdb <db> insert <collection> [--import <package.kvlt>]
/// ```
final class InsertCommand extends CliCommand {
  const InsertCommand();

  @override
  String get name => 'insert';

  @override
  String get description =>
      'Insert one or more documents. Accepts JSON object, JSON array, or NDJSON '
      'from --value, --file, or stdin.';

  @override
  String get usage => 'insert <collection>';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption('value', valueHelp: 'json', help: 'Inline JSON document(s) to insert')
      ..addOption('file', valueHelp: 'path', help: 'Read document(s) from a JSON/NDJSON file')
      ..addOption('import', valueHelp: 'package.kvlt', help: 'Import from a vault KVLT package');
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('insert requires <collection>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    // ── Mutual exclusion check for --import ────────────────────────────────
    final importPath = flags['import'] as String?;
    if (importPath != null) {
      if (flags['value'] != null || flags['file'] != null) {
        ctx.writeError(
          '--import is mutually exclusive with --value and --file.',
        );
        return false;
      }
      return _executeImport(ctx, collection, importPath);
    }

    final docs = await _readDocuments(ctx, flags);
    if (docs == null) return false;

    // Validate all documents before any I/O to prevent partial writes.
    // _id is silently replaced by the system-generated key (documented);
    // all other _-prefixed keys are rejected as reserved.
    for (var i = 0; i < docs.length; i++) {
      final offending = docs[i].keys
          .where((k) => k.startsWith('_') && k != '_id')
          .toList(growable: false);
      if (offending.isNotEmpty) {
        ctx.writeError(
          'Document ${docs.length > 1 ? '#${i + 1} ' : ''}contains reserved '
          '"_"-prefixed field(s): '
          '${offending.map((k) => '"$k"').join(', ')}. '
          'The "_" prefix is reserved for KMDB system fields (e.g. "_id").',
        );
        return false;
      }
    }

    final inserted = <Map<String, dynamic>>[];
    for (final doc in docs) {
      final key = const UuidV7KeyGenerator().next();
      doc['_id'] = key;
      final encoded = ValueCodec.encode(doc);
      await ctx.store.put(collection, key, encoded);
      inserted.add(doc);
    }

    ctx.writeDocuments(inserted);
    return true;
  }

  // ── Vault package import ───────────────────────────────────────────────────

  /// Reads a KVLT vault package from [packagePath], ingests vault blobs, and
  /// inserts the document into [collection].
  ///
  /// The ref counts for all vault URIs in the document are incremented
  /// atomically with the document write in a single [WriteBatch].
  Future<bool> _executeImport(
    CommandContext ctx,
    String collection,
    String packagePath,
  ) async {
    final vaultStore = ctx.vaultStore;
    if (vaultStore == null) {
      ctx.writeError(
        '--import requires vault to be configured for this database.',
      );
      return false;
    }

    // Read and parse the vault package.
    final contents = readVaultPackage(
      packagePath: packagePath,
      packageBytes: null,
      errSink: ctx.err,
    );
    if (contents == null) return false;

    // Validate: all vault URIs in document are covered by attachments.
    try {
      VaultPackage.validate(
        documentJson: contents.documentJson,
        attachments: contents.attachments,
      );
    } on FormatException catch (e) {
      ctx.writeError('Invalid vault package: ${e.message}');
      return false;
    }

    // Ingest all vault blobs.
    final info = await ctx.store.storeInfo();
    final ingestedHashes = await ingestVaultAttachments(
      vaultStore: vaultStore,
      attachments: contents.attachments,
      hlcTimestamp: info.currentHlc,
      errSink: ctx.err,
    );
    if (ingestedHashes == null) return false;

    // Assign a new document key and build the document map.
    final doc = Map<String, dynamic>.of(contents.documentJson);
    final offending = doc.keys
        .where((k) => k.startsWith('_') && k != '_id')
        .toList(growable: false);
    if (offending.isNotEmpty) {
      ctx.writeError(
        'Vault package document contains reserved "_"-prefixed field(s): '
        '${offending.map((k) => '"$k"').join(', ')}. '
        'The "_" prefix is reserved for KMDB system fields (e.g. "_id").',
      );
      return false;
    }
    final key = const UuidV7KeyGenerator().next();
    doc['_id'] = key;

    // Build a WriteBatch: document write + vault ref count increments.
    final batch = WriteBatch();
    batch.put(collection, key, ValueCodec.encode(doc));
    await applyVaultRefCounts(
      doc: doc,
      oldDoc: null,
      store: ctx.store,
      vaultStore: vaultStore,
      batch: batch,
    );
    await ctx.store.writeBatch(batch);

    ctx.writeDocuments([doc]);
    return true;
  }

  // ── Input reading ──────────────────────────────────────────────────────────

  /// Reads and normalises input from [flags] into a list of document maps.
  ///
  /// Input priority: `--value` > `--file` > stdin.
  /// Returns `null` after writing an error to [ctx] on any failure.
  Future<List<Map<String, dynamic>>?> _readDocuments(
    CommandContext ctx,
    Map<String, dynamic> flags,
  ) async {
    if (flags['value'] != null) {
      return _parseJson(ctx, flags['value'] as String, source: '--value');
    }

    if (flags['file'] != null) {
      final path = flags['file'] as String;
      if (_isNdjsonPath(path)) {
        return _readNdjsonFile(ctx, path);
      }
      final String content;
      try {
        content = await io.File(path).readAsString();
      } on io.IOException catch (e) {
        ctx.writeError('Cannot read file "$path": $e');
        return null;
      }
      return _parseJson(ctx, content, source: path);
    }

    // Stdin: buffer everything, then auto-detect JSON vs NDJSON.
    final content = await io.stdin.transform(utf8.decoder).join();
    return _parseJsonOrNdjson(ctx, content, source: 'stdin');
  }

  // ── Format detection ───────────────────────────────────────────────────────

  /// Returns true when [path] has an NDJSON/JSONL extension.
  bool _isNdjsonPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.ndjson') || lower.endsWith('.jsonl');
  }

  // ── Parsers ────────────────────────────────────────────────────────────────

  /// Parses [input] as JSON. Accepts an object or an array of objects.
  ///
  /// A single object is returned as a one-item list.
  /// Returns `null` and writes an error to [ctx] on failure.
  List<Map<String, dynamic>>? _parseJson(
    CommandContext ctx,
    String input, {
    required String source,
  }) {
    final Object? decoded;
    try {
      decoded = json.decode(input);
    } on FormatException catch (e) {
      ctx.writeError('Invalid JSON from $source: ${e.message}');
      return null;
    }

    if (decoded is Map<String, dynamic>) return [decoded];
    if (decoded is List) return _expandArray(ctx, decoded, source: source);

    ctx.writeError(
      'Input from $source must be a JSON object or array of objects.',
    );
    return null;
  }

  /// Auto-detects JSON vs NDJSON by attempting JSON decode first.
  ///
  /// Content starting with `{` or `[` is tried as JSON. If parsing fails or
  /// the content looks like multi-line records, it falls back to NDJSON.
  List<Map<String, dynamic>>? _parseJsonOrNdjson(
    CommandContext ctx,
    String input, {
    required String source,
  }) {
    final trimmed = input.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = json.decode(trimmed);
        if (decoded is Map<String, dynamic>) return [decoded];
        if (decoded is List) return _expandArray(ctx, decoded, source: source);
        ctx.writeError(
          'Input from $source must be a JSON object or array of objects.',
        );
        return null;
      } on FormatException {
        // Not valid JSON — fall through to NDJSON.
      }
    }
    return _parseNdjson(ctx, trimmed.split('\n'), source: source);
  }

  /// Validates and flattens a JSON [array] into a list of document maps.
  List<Map<String, dynamic>>? _expandArray(
    CommandContext ctx,
    List<dynamic> array, {
    required String source,
  }) {
    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < array.length; i++) {
      if (array[i] is! Map<String, dynamic>) {
        ctx.writeError('Array item $i from $source is not a JSON object.');
        return null;
      }
      result.add(array[i] as Map<String, dynamic>);
    }
    return result;
  }

  /// Reads an NDJSON/JSONL file and returns all non-empty documents.
  Future<List<Map<String, dynamic>>?> _readNdjsonFile(
    CommandContext ctx,
    String path,
  ) async {
    final List<String> lines;
    try {
      lines = await io.File(path).readAsLines();
    } on io.IOException catch (e) {
      ctx.writeError('Cannot read file "$path": $e');
      return null;
    }
    return _parseNdjson(ctx, lines, source: path);
  }

  /// Parses NDJSON [lines] into a list of document maps.
  ///
  /// Blank lines are skipped. Returns `null` on the first parse or type error.
  List<Map<String, dynamic>>? _parseNdjson(
    CommandContext ctx,
    List<String> lines, {
    required String source,
  }) {
    final result = <Map<String, dynamic>>[];
    var lineNum = 0;
    for (final line in lines) {
      lineNum++;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final Object? decoded;
      try {
        decoded = json.decode(trimmed);
      } on FormatException catch (e) {
        ctx.writeError(
          'Line $lineNum from $source: invalid JSON: ${e.message}',
        );
        return null;
      }

      if (decoded is! Map<String, dynamic>) {
        ctx.writeError(
          'Line $lineNum from $source: expected JSON object, got ${decoded.runtimeType}',
        );
        return null;
      }
      result.add(decoded);
    }
    return result;
  }
}
