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

import 'package:kmdb/kmdb.dart';

import '../filter/filter_parser.dart';
import 'command.dart';

/// Scans a collection with optional filtering, ordering, and pagination.
///
/// Usage:
/// ```
/// scan <collection> [--filter <json>] [--order-by <field>] [--desc]
///                   [--limit <n>] [--offset <n>] [--key-prefix <str>]
/// ```
final class ScanCommand implements CliCommand {
  const ScanCommand();

  @override
  String get name => 'scan';

  @override
  String get description => 'Scan documents in a collection.';

  @override
  String get usage =>
      'scan <collection> [--filter <json>] [--order-by <field>] [--desc] '
      '[--limit <n>] [--offset <n>] [--key-prefix <str>] '
      '[--select <field1,field2,...>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('scan requires <collection>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    // Parse optional filter.
    Filter? filter;
    final filterJson = flags['filter'] as String?;
    if (filterJson != null) {
      try {
        filter = FilterParser.parse(filterJson);
      } on ArgumentError catch (e) {
        ctx.writeError('Invalid filter: ${e.message}');
        return false;
      } on FormatException catch (e) {
        ctx.writeError('Invalid filter JSON: ${e.message}');
        return false;
      }
    }

    final orderBy = flags['order-by'] as String?;
    final descending = flags['desc'] == true;
    final limit = _parseInt(flags['limit']);
    final offset = _parseInt(flags['offset']);
    final keyPrefix = flags['key-prefix'] as String?;
    final selectFields = _parseSelect(flags['select']);

    // Collect all matching documents.
    final docs = <Map<String, dynamic>>[];

    await for (final entry in ctx.store.scan(collection, startKey: keyPrefix)) {
      final doc = ValueCodec.decode(entry.value);
      if (filter != null && !filter.evaluate(doc)) continue;
      docs.add(selectFields != null ? _project(doc, selectFields) : doc);
    }

    // Sort.
    if (orderBy != null) {
      docs.sort((a, b) {
        final av = a[orderBy];
        final bv = b[orderBy];
        final cmp = _compareValues(av, bv);
        return descending ? -cmp : cmp;
      });
    }

    // Paginate.
    final start = offset ?? 0;
    final end = limit != null
        ? (start + limit).clamp(0, docs.length)
        : docs.length;
    final page = docs.sublist(start.clamp(0, docs.length), end);

    ctx.writeDocuments(page);
    return true;
  }

  /// Parses a comma-separated `--select` value into an ordered list of field names.
  ///
  /// Returns `null` when [value] is null (no projection requested).
  static List<String>? _parseSelect(dynamic value) {
    if (value == null) return null;
    final parts = '$value'
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts;
  }

  /// Returns a copy of [doc] containing only the keys in [fields], in [fields] order.
  static Map<String, dynamic> _project(
    Map<String, dynamic> doc,
    List<String> fields,
  ) => {
    for (final field in fields)
      if (doc.containsKey(field)) field: doc[field],
  };

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse('$value');
  }

  static int _compareValues(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    return '$a'.compareTo('$b');
  }
}
