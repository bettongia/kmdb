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
/// 3. stdin — JSON (object or array) or NDJSON auto-detected.
///
/// Usage: `kmdb <db> insert <collection> [--value <json>] [--file <path>]`
final class InsertCommand implements CliCommand {
  const InsertCommand();

  @override
  String get name => 'insert';

  @override
  String get description =>
      'Insert one or more documents. Accepts JSON object, JSON array, or NDJSON '
      'from --value, --file, or stdin.';

  @override
  String get usage => 'insert <collection> [--value <json>] [--file <path>]';

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

    final docs = await _readDocuments(ctx, flags);
    if (docs == null) return false;

    final inserted = <Map<String, dynamic>>[];
    for (final doc in docs) {
      final key = const UuidV7KeyGenerator().next();
      // Always assign a fresh system key; any caller-supplied _id is replaced.
      doc['_id'] = key;
      final encoded = ValueCodec.encode(doc);
      await ctx.store.put(collection, key, encoded);
      inserted.add(doc);
    }

    ctx.writeDocuments(inserted);
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
