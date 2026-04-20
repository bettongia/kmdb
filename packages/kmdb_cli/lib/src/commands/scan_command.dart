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
///                   [--select <path1,path2,...>]
/// ```
///
/// The `--select` flag accepts a comma-separated list of field paths using the
/// full JSONPath subset supported by KMDB:
///
/// - Top-level fields: `name`
/// - Nested dot-paths: `address.city` (re-nested in output as `{"address":{"city":"..."}}`)
/// - Optional root sigil: `$.address.city` (same as `address.city`)
/// - Array wildcard: `tags[*]` or `tags[]` (flat key in output: `{"tags[]": [...]}`)
/// - Positional index: `tags[0]` (flat key in output: `{"tags[0]": value}`)
/// - Negative index: `tags[-1]` (last element, flat key: `{"tags[-1]": value}`)
///
/// Dot-child paths are re-nested in the output document so that
/// `--select="address.city"` produces `{"address": {"city": "..."}}`.
/// Bracket selections use the raw path token as a flat key to avoid ambiguity
/// about the output array structure.
///
/// Paths that do not resolve in a document are omitted from the output (no key
/// is emitted for that document).
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
      '[--select <path1,path2,...>]';

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
      docs.add(selectFields != null ? projectDocument(doc, selectFields) : doc);
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

  /// Parses a comma-separated `--select` value into an ordered list of path
  /// tokens.
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

/// Projects [doc] to only the [fields] paths, in [fields] order.
///
/// Each path in [fields] is resolved using [FieldPath.resolve]:
///
/// - **Dot-child paths** (e.g. `address.city`) are re-nested in the output:
///   the result is inserted at the same nesting level as specified by the path.
///   For example, `address.city` → `{"address": {"city": "London"}}`.
/// - **Bracket selections** (e.g. `tags[0]`, `tags[]`, `tags[-1]`) use the
///   raw path token as a flat key to avoid ambiguity about the output array
///   structure. For example, `tags[0]` → `{"tags[0]": "dart"}`.
/// - Paths that do not resolve (return [missing]) are omitted from the output.
///
/// This function is shared by [ScanCommand] and [GetCommand].
Map<String, dynamic> projectDocument(
  Map<String, dynamic> doc,
  List<String> fields,
) {
  final result = <String, dynamic>{};
  for (final field in fields) {
    final value = FieldPath.resolve(field, doc);
    if (value == missing) continue; // omit absent paths

    // Normalise the path so that the output key structure is based on the
    // canonical path form (e.g. "$.address.city" → "address.city").
    // FieldPath.resolve() already normalises internally; we normalise here
    // again so the output key structure matches the resolved path.
    final normField = FieldPath.normalisePath(field);

    // Determine whether this path contains a bracket expression anywhere.
    // If it does, use the normalised field token as a flat key to avoid
    // ambiguity about reconstructing array structure from a scalar value.
    if (normField.contains('[')) {
      result[normField] = value;
    } else {
      // Dot-child path: re-nest the resolved value back into the output map.
      // Split the normalised path on '.' and build nested maps from outside in.
      _insertNested(result, normField.split('.'), value);
    }
  }
  return result;
}

/// Recursively inserts [value] into [map] at the nested path described by
/// [segments], creating intermediate maps as needed.
///
/// Existing intermediate maps are merged (not replaced) so that multiple
/// selected sub-fields of the same parent produce a single merged object.
/// For example, `address.city` and `address.country` both selected will
/// produce `{"address": {"city": "...", "country": "..."}}`.
void _insertNested(
  Map<String, dynamic> map,
  List<String> segments,
  Object? value,
) {
  if (segments.isEmpty) return;
  if (segments.length == 1) {
    map[segments[0]] = value;
    return;
  }
  // Create or reuse the intermediate map for the first segment.
  final key = segments[0];
  final existing = map[key];
  final Map<String, dynamic> child;
  if (existing is Map<String, dynamic>) {
    child = existing;
  } else {
    child = <String, dynamic>{};
    map[key] = child;
  }
  _insertNested(child, segments.sublist(1), value);
}
