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
import 'dart:io';

import 'output_mode.dart';

/// Formats a list of documents and writes them to [sink].
///
/// Each public method corresponds to an [OutputMode]. The caller is responsible
/// for choosing the correct method; use [format] to dispatch by mode.
abstract final class DocumentFormatter {
  DocumentFormatter._();

  /// Formats [docs] according to [mode] and writes to [sink].
  ///
  /// [sink] defaults to [stdout].
  static void format(
    List<Map<String, dynamic>> docs,
    OutputMode mode, {
    StringSink? sink,
  }) {
    final out = sink ?? stdout;
    switch (mode) {
      case OutputMode.json:
        _writeJson(docs, out, indent: true);
      case OutputMode.compact:
        _writeJson(docs, out, indent: false);
      case OutputMode.ndjson:
        _writeNdjson(docs, out);
      case OutputMode.table:
        _writeTable(docs, out);
      case OutputMode.csv:
        _writeCsv(docs, out);
      case OutputMode.line:
        _writeLine(docs, out);
    }
  }

  // ── JSON / compact ─────────────────────────────────────────────────────────

  static void _writeJson(
    List<Map<String, dynamic>> docs,
    StringSink out, {
    required bool indent,
  }) {
    final encoder =
        indent ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    out.writeln(encoder.convert(docs));
  }

  // ── NDJSON ─────────────────────────────────────────────────────────────────

  static void _writeNdjson(
    List<Map<String, dynamic>> docs,
    StringSink out,
  ) {
    const enc = JsonEncoder();
    for (final doc in docs) {
      out.writeln(enc.convert(doc));
    }
  }

  // ── Table ──────────────────────────────────────────────────────────────────

  static void _writeTable(
    List<Map<String, dynamic>> docs,
    StringSink out,
  ) {
    if (docs.isEmpty) {
      out.writeln('(no results)');
      return;
    }

    // Collect the union of column names from the first 100 documents, preserving
    // insertion order of the first occurrence.
    final columns = _collectColumns(docs);
    if (columns.isEmpty) {
      out.writeln('(no fields)');
      return;
    }

    // Compute column widths: max of header length and widest cell.
    final widths = {for (final c in columns) c: c.length};
    for (final doc in docs) {
      for (final col in columns) {
        final cell = _cellString(doc[col]);
        final w = widths[col]!;
        if (cell.length > w) widths[col] = cell.length;
      }
    }

    // Header row.
    final header = columns.map((c) => c.padRight(widths[c]!)).join('  ');
    final separator = columns.map((c) => '─' * widths[c]!).join('──');
    out.writeln(header);
    out.writeln(separator);

    // Data rows.
    for (final doc in docs) {
      final row = columns.map((c) => _cellString(doc[c]).padRight(widths[c]!)).join('  ');
      out.writeln(row);
    }
  }

  // ── CSV ────────────────────────────────────────────────────────────────────

  static void _writeCsv(
    List<Map<String, dynamic>> docs,
    StringSink out,
  ) {
    if (docs.isEmpty) return;

    final columns = _collectColumns(docs);

    // Header.
    out.writeln(columns.map(_csvEscape).join(','));

    // Data rows.
    for (final doc in docs) {
      out.writeln(columns.map((c) => _csvEscape(_cellString(doc[c]))).join(','));
    }
  }

  // ── Line ───────────────────────────────────────────────────────────────────

  static void _writeLine(
    List<Map<String, dynamic>> docs,
    StringSink out,
  ) {
    for (var i = 0; i < docs.length; i++) {
      if (i > 0) out.writeln();
      for (final entry in docs[i].entries) {
        out.writeln('${entry.key} = ${_cellString(entry.value)}');
      }
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Collects the union of column names from up to the first 100 documents.
  static List<String> _collectColumns(List<Map<String, dynamic>> docs) {
    final seen = <String>{};
    final ordered = <String>[];
    final limit = docs.length < 100 ? docs.length : 100;
    for (var i = 0; i < limit; i++) {
      for (final key in docs[i].keys) {
        if (seen.add(key)) ordered.add(key);
      }
    }
    return ordered;
  }

  /// Converts a document field value to a display string.
  static String _cellString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is Map || value is List) return const JsonEncoder().convert(value);
    return '$value';
  }

  /// Escapes a string for RFC 4180 CSV.
  ///
  /// Wraps the value in double-quotes if it contains a comma, double-quote,
  /// or newline. Doubles any embedded double-quotes.
  static String _csvEscape(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
