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

import 'package:kmdb/kmdb.dart';

import '../filter/filter_parser.dart';
import '../output/output_mode.dart';
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
final class ScanCommand extends CliCommand {
  const ScanCommand();

  @override
  String get name => 'scan';

  @override
  String get description => 'Scan documents in a collection.';

  @override
  String get usage => 'scan <collection>';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption('filter', valueHelp: 'json', help: 'JSON filter expression')
      ..addOption('order-by', valueHelp: 'field', help: 'Sort by field name')
      ..addFlag('desc', negatable: false, help: 'Sort descending')
      ..addOption('limit', valueHelp: 'n', help: 'Maximum documents to return')
      ..addOption('offset', valueHelp: 'n', help: 'Number of documents to skip')
      ..addOption(
        'key-prefix',
        valueHelp: 'str',
        help: 'Filter documents whose key starts with this prefix',
      )
      ..addOption(
        'select',
        valueHelp: 'path1,path2,...',
        help:
            'Comma-separated field paths to project '
            '(e.g. name, address.city, tags[0])',
      )
      ..addFlag('explain', negatable: false, help: 'Show query execution plan');
  }

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
    final explain = flags['explain'] == true;

    // ── Candidate set ──────────────────────────────────────────────────────────
    final List<Map<String, dynamic>> candidates;
    int documentsScanned;
    final List<FilterPlan> filterPlans;
    final ScanStrategy strategy;

    if (explain && filter != null) {
      // Attempt index selection for a top-level equality predicate.
      final eq = filter.equalityPredicate;
      if (eq != null) {
        final (path, value) = eq;
        final def = ctx.indexManager.definitions
            .where((d) => d.namespace == collection && d.path == path)
            .firstOrNull;
        if (def != null) {
          final state = await ctx.indexManager.getOrActivate(collection, path);
          if (state.status == IndexStatus.current) {
            List<String> keys;
            try {
              keys = await ctx.indexManager.lookupByValue(def, value);
            } catch (_) {
              keys = const [];
            }
            // Fetch and filter the narrowed candidate set via the Query Layer.
            final col = ctx.rawCollection(collection);
            final fetched = <Map<String, dynamic>>[];
            for (final key in keys) {
              final doc = await col.get(key);
              if (doc == null) continue;
              if (!filter.evaluate(doc)) continue;
              fetched.add(doc);
            }
            candidates = fetched;
            documentsScanned = keys.length;
            strategy = ScanStrategy.indexScan;
            filterPlans = [
              FilterPlan(fieldPath: path, operator: 'eq', indexUsed: true),
            ];
          } else {
            // Index exists but not current — full scan.
            (candidates, documentsScanned) = await _fullScan(
              ctx,
              collection,
              filter,
              keyPrefix,
            );
            strategy = ScanStrategy.fullScan;
            filterPlans = [
              FilterPlan(
                fieldPath: path,
                operator: 'eq',
                indexUsed: false,
                indexStatus: state.status.name,
              ),
            ];
          }
        } else {
          // No index declared for this field — full scan.
          (candidates, documentsScanned) = await _fullScan(
            ctx,
            collection,
            filter,
            keyPrefix,
          );
          strategy = ScanStrategy.fullScan;
          filterPlans = [
            FilterPlan(
              fieldPath: path,
              operator: 'eq',
              indexUsed: false,
              indexStatus: 'none',
            ),
          ];
        }
      } else {
        // Non-equality or complex filter — full scan, no index info.
        (candidates, documentsScanned) = await _fullScan(
          ctx,
          collection,
          filter,
          keyPrefix,
        );
        strategy = ScanStrategy.fullScan;
        filterPlans = [
          FilterPlan(
            fieldPath: '(complex)',
            operator: 'other',
            indexUsed: false,
            indexStatus: 'none',
          ),
        ];
      }
    } else {
      // No explain flag or no filter — standard full scan.
      (candidates, documentsScanned) = await _fullScan(
        ctx,
        collection,
        filter,
        keyPrefix,
      );
      strategy = ScanStrategy.fullScan;
      filterPlans = filter == null
          ? []
          : [
              FilterPlan(
                fieldPath: filter.equalityPredicate?.$1 ?? '(filter)',
                operator: filter.equalityPredicate != null ? 'eq' : 'other',
                indexUsed: false,
                indexStatus: 'none',
              ),
            ];
    }

    final documentsMatched = candidates.length;

    // ── Project fields ─────────────────────────────────────────────────────────
    // Use flat keys for table/csv/line so dot-path selections appear as column
    // headers (e.g. "name.en") with the resolved scalar value rather than a
    // re-nested object under the parent key.
    final flatProjection =
        ctx.mode == OutputMode.table ||
        ctx.mode == OutputMode.csv ||
        ctx.mode == OutputMode.line;
    final projected = selectFields == null
        ? candidates
        : candidates
              .map(
                (doc) =>
                    projectDocument(doc, selectFields, flat: flatProjection),
              )
              .toList();

    // ── Sort ───────────────────────────────────────────────────────────────────
    final sorted = orderBy != null;
    if (sorted) {
      projected.sort((a, b) {
        final av = a[orderBy];
        final bv = b[orderBy];
        final cmp = _compareValues(av, bv);
        return descending ? -cmp : cmp;
      });
    }

    // ── Paginate ───────────────────────────────────────────────────────────────
    final start = offset ?? 0;
    final end = limit != null
        ? (start + limit).clamp(0, projected.length)
        : projected.length;
    final page = projected.sublist(start.clamp(0, projected.length), end);

    // ── Output ─────────────────────────────────────────────────────────────────
    if (explain) {
      final plan = QueryPlan(
        strategy: strategy,
        filters: filterPlans,
        documentsScanned: documentsScanned,
        documentsMatched: documentsMatched,
        documentsReturned: page.length,
        sorted: sorted,
      );
      _writePlan(ctx, plan);
    }

    ctx.writeDocuments(page);
    return true;
  }

  /// Fetches documents from [collection], filtered by [filter] and/or
  /// [keyPrefix], returning matching documents and the total examined count.
  ///
  /// When [keyPrefix] is set, the scan operates at the store level (key-prefix
  /// scanning has no [Filter] DSL equivalent). Without a prefix, the scan
  /// routes through the Query Layer so the Cache Layer and secondary indexes
  /// can be consulted.
  static Future<(List<Map<String, dynamic>>, int)> _fullScan(
    CommandContext ctx,
    String collection,
    Filter? filter,
    String? keyPrefix,
  ) async {
    // Key-prefix scanning must remain at the store layer: it is a storage-level
    // operation with no Query Layer equivalent.
    if (keyPrefix != null) {
      final docs = <Map<String, dynamic>>[];
      var count = 0;
      await for (final entry in ctx.store.scan(
        collection,
        startKey: keyPrefix,
      )) {
        count++;
        final doc = ValueCodec.decode(entry.value)..['_id'] = entry.key;
        if (filter != null && !filter.evaluate(doc)) continue;
        docs.add(doc);
      }
      return (docs, count);
    }

    // No key prefix: route through the Query Layer. This allows secondary
    // indexes to be consulted and the Cache Layer to be used.
    final col = ctx.rawCollection(collection);
    final docs = filter != null
        ? await col.where(filter).get()
        : await col.all().get();
    // documentsScanned equals the total collection size for a full scan.
    // When a filter is given, we report the matched count as the scanned count
    // because the Query Layer may have used an index to narrow the set.
    return (docs, docs.length);
  }

  /// Writes the query plan block to [ctx.out] in the appropriate format.
  static void _writePlan(CommandContext ctx, QueryPlan plan) {
    final isJson = ctx.mode.name == 'json';
    if (isJson) {
      // Prepend plan as a standalone JSON object before the results array.
      final planMap = {
        '_explain': {
          'strategy': plan.strategy.name,
          'filters': [
            for (final f in plan.filters)
              {
                'field': f.fieldPath,
                'operator': f.operator,
                'indexUsed': f.indexUsed,
                if (!f.indexUsed && f.indexStatus != null)
                  'indexStatus': f.indexStatus,
              },
          ],
          'documentsScanned': plan.documentsScanned,
          'documentsMatched': plan.documentsMatched,
          'documentsReturned': plan.documentsReturned,
          'sorted': plan.sorted,
        },
      };
      ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(planMap));
    } else {
      // Human-readable plan block.
      final strategyLabel = plan.strategy == ScanStrategy.indexScan
          ? 'index scan'
          : 'full scan';
      ctx.out.writeln('Query plan');
      ctx.out.writeln('  Strategy : $strategyLabel');
      if (plan.filters.isNotEmpty) {
        for (var i = 0; i < plan.filters.length; i++) {
          final f = plan.filters[i];
          final label = i == 0 ? '  Filters  :' : '            ';
          final indexNote = f.indexUsed ? '[index: current]' : '[full scan]';
          ctx.out.writeln('$label ${f.fieldPath} ${f.operator} $indexNote');
        }
      }
      ctx.out.writeln('  Scanned  : ${plan.documentsScanned}');
      ctx.out.writeln('  Matched  : ${plan.documentsMatched}');
      ctx.out.writeln('  Returned : ${plan.documentsReturned}');
      ctx.out.writeln('');
    }
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
  List<String> fields, {
  bool flat = false,
}) {
  final result = <String, dynamic>{};
  for (final field in fields) {
    final value = FieldPath.resolve(field, doc);
    if (value == missing) continue; // omit absent paths

    // Normalise the path so that the output key structure is based on the
    // canonical path form (e.g. "$.address.city" → "address.city").
    // FieldPath.resolve() already normalises internally; we normalise here
    // again so the output key structure matches the resolved path.
    final normField = FieldPath.normalisePath(field);

    // Bracket expressions always use flat keys to avoid ambiguity about
    // reconstructing array structure from a scalar value.  Dot-paths use flat
    // keys too when [flat] is true (table/csv/line modes), so that the path
    // itself appears as the column header rather than the parent key.
    if (normField.contains('[') || flat) {
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
