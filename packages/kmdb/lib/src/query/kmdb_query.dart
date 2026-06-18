// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import 'dart:developer' as developer;

import '../encoding/value_codec.dart';
import 'exceptions.dart';
import 'filter/field_path.dart';
import 'filter/filter.dart';
import 'index/index_definition.dart';
import 'index/index_manager.dart';
import 'kmdb_collection.dart';
import 'query_plan.dart';

/// An immutable, lazy query pipeline over a [KmdbCollection].
///
/// Obtain a [KmdbQuery] from [KmdbCollection.all] or [KmdbCollection.where].
/// Chain pipeline methods to refine the query — each call returns a **new**
/// instance and leaves the original unchanged. No I/O occurs until a terminal
/// method is called.
///
/// ## Pipeline methods
///
/// ```dart
/// tasks
///   .where(Field('status').equals('active'))
///   .orderBy('priority', descending: true)
///   .limit(20)
///   .offset(0);
/// ```
///
/// ## Terminal methods
///
/// ```dart
/// final list  = await query.get();    // eager List<T>
/// final first = await query.first();  // T? or null
/// final count = await query.count();  // int (no decode)
/// final any   = await query.any();    // bool
/// final items = query.stream();       // Stream<T>
/// final live  = query.watch();        // Stream<List<T>> — reactive
/// ```
final class KmdbQuery<T> {
  KmdbQuery.fromCollection({
    required this._collection,
    List<Filter>? filters,
    this._orderByField,
    this._orderByDescending = false,
    this._limitCount,
    this._offsetCount,
    this._keyPrefixValue,
    this._requireFreshIndex = false,
  }) : _filters = filters ?? const [];

  final KmdbCollection<T> _collection;
  final List<Filter> _filters;
  final String? _orderByField;
  final bool _orderByDescending;
  final int? _limitCount;
  final int? _offsetCount;
  final String? _keyPrefixValue;

  /// Whether to throw [StaleIndexException] if any index for this namespace
  /// is not [IndexStatus.current] when a terminal is called.
  final bool _requireFreshIndex;

  // ── Pipeline methods ────────────────────────────────────────────────────────

  /// Adds [filter] to the pipeline, AND-ed with any existing filters.
  ///
  /// Returns a new [KmdbQuery] — the original is unchanged.
  KmdbQuery<T> where(Filter filter) => KmdbQuery.fromCollection(
    collection: _collection,
    filters: [..._filters, filter],
    orderByField: _orderByField,
    orderByDescending: _orderByDescending,
    limitCount: _limitCount,
    offsetCount: _offsetCount,
    keyPrefixValue: _keyPrefixValue,
    requireFreshIndex: _requireFreshIndex,
  );

  /// Orders results by [field].
  ///
  /// When [field] is `'_id'`, the ordering uses the natural LSM scan order
  /// (ascending by document key). For all other fields, documents are sorted
  /// in memory after the scan.
  ///
  /// Returns a new [KmdbQuery] — the original is unchanged.
  KmdbQuery<T> orderBy(String field, {bool descending = false}) =>
      KmdbQuery.fromCollection(
        collection: _collection,
        filters: _filters,
        orderByField: field,
        orderByDescending: descending,
        limitCount: _limitCount,
        offsetCount: _offsetCount,
        keyPrefixValue: _keyPrefixValue,
        requireFreshIndex: _requireFreshIndex,
      );

  /// Limits the result to [count] documents.
  ///
  /// Applied after filtering and sorting. Returns a new [KmdbQuery].
  KmdbQuery<T> limit(int count) => KmdbQuery.fromCollection(
    collection: _collection,
    filters: _filters,
    orderByField: _orderByField,
    orderByDescending: _orderByDescending,
    limitCount: count,
    offsetCount: _offsetCount,
    keyPrefixValue: _keyPrefixValue,
    requireFreshIndex: _requireFreshIndex,
  );

  /// Skips the first [count] documents from the result.
  ///
  /// Applied after filtering and sorting. Use with [orderBy] for stable
  /// pagination. Returns a new [KmdbQuery].
  KmdbQuery<T> offset(int count) => KmdbQuery.fromCollection(
    collection: _collection,
    filters: _filters,
    orderByField: _orderByField,
    orderByDescending: _orderByDescending,
    limitCount: _limitCount,
    offsetCount: count,
    keyPrefixValue: _keyPrefixValue,
    requireFreshIndex: _requireFreshIndex,
  );

  /// Narrows the underlying LSM scan to keys that start with [prefix].
  ///
  /// Since document keys are UUIDv7 hex strings, a key prefix is effectively a
  /// time-window query: UUIDv7 embeds a millisecond timestamp in its MSBs, so
  /// keys with a common prefix were generated within the same time window.
  ///
  /// Maps to `KvStore.scan(startKey: prefix, endKey: _nextPrefix(prefix))`.
  /// Returns a new [KmdbQuery].
  KmdbQuery<T> keyPrefix(String prefix) => KmdbQuery.fromCollection(
    collection: _collection,
    filters: _filters,
    orderByField: _orderByField,
    orderByDescending: _orderByDescending,
    limitCount: _limitCount,
    offsetCount: _offsetCount,
    keyPrefixValue: prefix,
    requireFreshIndex: _requireFreshIndex,
  );

  /// Asserts that all secondary indexes for this collection are fully built
  /// before the query executes.
  ///
  /// Returns a new [KmdbQuery]. When any terminal method is subsequently
  /// called, the query checks every index defined for the collection's
  /// namespace. If any index is [IndexStatus.stale] or [IndexStatus.building],
  /// [StaleIndexException] is thrown rather than falling back to a full scan.
  ///
  /// Use this when correctness requires up-to-date index data, for example
  /// when running scheduled background jobs that must not return stale results.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   final results = await collection
  ///       .where(Field('city').equals('London'))
  ///       .requireFreshIndex()
  ///       .get();
  /// } on StaleIndexException catch (e) {
  ///   // Index is rebuilding — retry after a short delay.
  /// }
  /// ```
  KmdbQuery<T> requireFreshIndex() => KmdbQuery.fromCollection(
    collection: _collection,
    filters: _filters,
    orderByField: _orderByField,
    orderByDescending: _orderByDescending,
    limitCount: _limitCount,
    offsetCount: _offsetCount,
    keyPrefixValue: _keyPrefixValue,
    requireFreshIndex: true,
  );

  // ── Terminal methods ────────────────────────────────────────────────────────

  /// Executes the query and returns all matching documents as a [List].
  ///
  /// The LSM snapshot is released immediately after the scan completes.
  Future<List<T>> get() async => (await _executeWithPlan()).$1;

  /// Executes the query and returns results together with a [QueryPlan]
  /// describing the execution strategy, index usage, and document counts.
  ///
  /// Equivalent to [get] but also exposes the query execution metadata for
  /// diagnostic or EXPLAIN-style display purposes.
  Future<(List<T>, QueryPlan)> explainedGet() => _executeWithPlan();

  /// Executes the query and returns results as a [Stream].
  ///
  /// Eagerly evaluated — identical to [get] internally, but emits each
  /// document as a `Stream<T>`. No LSM snapshot is held open. Prefer [watch]
  /// for reactive UI lists.
  Stream<T> stream() =>
      Stream.fromFuture(get()).asyncExpand((list) => Stream.fromIterable(list));

  /// Returns the first matching document, or `null` if none match.
  Future<T?> first() async {
    final results = await limit(1).get();
    return results.isEmpty ? null : results.first;
  }

  /// Returns the number of matching documents.
  ///
  /// When no filters are set, the scan avoids decoding document values.
  Future<int> count() async {
    if (_filters.isEmpty &&
        _orderByField == null &&
        _limitCount == null &&
        _offsetCount == null) {
      // Fast path: count without decoding.
      var n = 0;
      final (startKey, endKey) = _scanRange();
      await for (final _ in _collection.database.cache.scan(
        _collection.namespace,
        startKey: startKey,
        endKey: endKey,
      )) {
        n++;
      }
      return n;
    }
    // General path: decode and filter.
    final results = await get();
    return results.length;
  }

  /// Returns `true` if at least one document matches the query.
  Future<bool> any() async {
    final result = await first();
    return result != null;
  }

  /// Returns a [Stream] that re-emits the full result list whenever the
  /// collection changes (debounced at 50 ms).
  ///
  /// The stream emits immediately on subscription with the current results,
  /// then re-emits after each debounce window that saw at least one write to
  /// the collection's namespace.
  ///
  /// Cancel the stream subscription to stop watching.
  Stream<List<T>> watch() {
    late StreamController<List<T>> controller;
    late StreamSubscription<String> sub;
    Timer? debounceTimer;

    Future<void> emitCurrent() async {
      try {
        final results = await get();
        if (!controller.isClosed) controller.add(results);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller = StreamController<List<T>>(
      onListen: () {
        emitCurrent();
        sub = _collection.database.cache.writeEvents.listen((ns) {
          if (ns != _collection.namespace) return;
          debounceTimer?.cancel();
          debounceTimer = Timer(const Duration(milliseconds: 50), emitCurrent);
        });
      },
      onCancel: () {
        debounceTimer?.cancel();
        sub.cancel();
      },
    );

    return controller.stream;
  }

  // ── Execution ───────────────────────────────────────────────────────────────

  Future<(List<T>, QueryPlan)> _executeWithPlan() async {
    if (_requireFreshIndex) await _checkIndexFreshness();

    final ns = _collection.namespace;
    final manager = _collection.database.indexManager;

    // ── Index selection ────────────────────────────────────────────────────────
    // For each equality predicate in _filters, attempt to find a current index.
    // Only top-level filters (implicit AND via chained .where()) are eligible —
    // predicates buried inside OrFilter / NotFilter are skipped.

    final eligible =
        <({IndexDefinition def, Object? value, int filterIndex})>[];
    final filterPlans = <FilterPlan>[];

    for (var i = 0; i < _filters.length; i++) {
      final f = _filters[i];
      final eq = f.equalityPredicate;
      if (eq == null) {
        // Non-equality filter — always full-scan for this predicate.
        filterPlans.add(
          FilterPlan(
            fieldPath: '?',
            operator: 'other',
            indexUsed: false,
            indexStatus: 'none',
          ),
        );
        continue;
      }
      final (path, value) = eq;
      IndexState state;
      try {
        state = await manager.getOrActivate(ns, path);
      } catch (e) {
        developer.log(
          'IndexManager.getOrActivate failed for $ns/$path: $e',
          name: 'kmdb.query',
        );
        filterPlans.add(
          FilterPlan(
            fieldPath: path,
            operator: 'eq',
            indexUsed: false,
            indexStatus: 'none',
          ),
        );
        continue;
      }

      if (state.status == IndexStatus.current) {
        final def = manager.definitions.firstWhere(
          (d) => d.namespace == ns && d.path == path,
        );
        eligible.add((def: def, value: value, filterIndex: i));
        // Status is filled in after we confirm the lookup succeeds; mark now.
        filterPlans.add(
          FilterPlan(fieldPath: path, operator: 'eq', indexUsed: true),
        );
      } else {
        developer.log(
          'Index $ns/$path is ${state.status.name} — falling back to full scan',
          name: 'kmdb.query',
        );
        filterPlans.add(
          FilterPlan(
            fieldPath: path,
            operator: 'eq',
            indexUsed: false,
            indexStatus: state.status.name,
          ),
        );
      }
    }

    // ── Candidate set ──────────────────────────────────────────────────────────
    final List<(String key, Map<String, dynamic> doc)> raw;
    final ScanStrategy strategy;
    int documentsScanned;

    if (eligible.isNotEmpty) {
      // Index path: look up each eligible predicate, intersect key sets.
      List<String>? keySet;
      bool lookupFailed = false;

      for (final e in eligible) {
        List<String> keys;
        try {
          keys = await manager.lookupByValue(e.def, e.value);
        } catch (err) {
          developer.log(
            'lookupByValue failed for ${e.def.namespace}/${e.def.path}: $err — '
            'falling back to full scan',
            name: 'kmdb.query',
          );
          lookupFailed = true;
          break;
        }
        if (keySet == null) {
          keySet = keys;
        } else {
          // Intersect: keep only keys present in both sets (smallest-first
          // iteration to minimise work).
          final smaller = keySet.length <= keys.length ? keySet : keys;
          final larger = keySet.length <= keys.length ? keys : keySet;
          final largerSet = larger.toSet();
          keySet = smaller.where(largerSet.contains).toList();
        }
        if (keySet.isEmpty) break; // short-circuit
      }

      if (!lookupFailed) {
        // Fetch only the documents in the intersected key set.
        final candidates = <(String key, Map<String, dynamic> doc)>[];
        for (final key in keySet!) {
          final bytes = await _collection.database.cache.get(ns, key);
          if (bytes == null) continue;
          final Map<String, dynamic> doc;
          try {
            doc = await ValueCodec.decode(
              bytes,
              encryption: _collection.database.encryption,
            );
          } catch (_) {
            continue;
          }
          doc['_id'] = key;
          candidates.add((key, doc));
        }
        raw = candidates;
        strategy = ScanStrategy.indexScan;
        documentsScanned = keySet.length;
      } else {
        // Lookup failed — fall back to full scan; fix up filter plans.
        for (var i = 0; i < filterPlans.length; i++) {
          if (filterPlans[i].indexUsed) {
            filterPlans[i] = FilterPlan(
              fieldPath: filterPlans[i].fieldPath,
              operator: filterPlans[i].operator,
              indexUsed: false,
              indexStatus: 'error',
            );
          }
        }
        (raw, documentsScanned) = await _fullScan();
        strategy = ScanStrategy.fullScan;
      }
    } else {
      // No eligible indexes — full scan.
      (raw, documentsScanned) = await _fullScan();
      strategy = ScanStrategy.fullScan;
    }

    // ── In-memory filter pass ──────────────────────────────────────────────────
    // For index scans, re-apply ALL filters (indexed predicates are cheap to
    // re-evaluate and ensure correctness against any race on the index).
    final filtered = _filters.isEmpty
        ? raw
        : raw
              .where((pair) => _filters.every((f) => f.evaluate(pair.$2)))
              .toList();

    final documentsMatched = filtered.length;

    // ── Sort ───────────────────────────────────────────────────────────────────
    final orderField = _orderByField;
    if (orderField != null) {
      filtered.sort((a, b) {
        final va = FieldPath.resolve(orderField, a.$2);
        final vb = FieldPath.resolve(orderField, b.$2);
        final cmp = _compareValues(va, vb);
        return _orderByDescending ? -cmp : cmp;
      });
    }

    // ── Offset and limit ───────────────────────────────────────────────────────
    var results = filtered;
    final off = _offsetCount;
    if (off != null && off > 0) {
      results = results.length <= off ? [] : results.sublist(off);
    }
    final lim = _limitCount;
    if (lim != null && results.length > lim) {
      results = results.sublist(0, lim);
    }

    final plan = QueryPlan(
      strategy: strategy,
      filters: filterPlans,
      documentsScanned: documentsScanned,
      documentsMatched: documentsMatched,
      documentsReturned: results.length,
      sorted: orderField != null,
    );

    final typed = results
        .map((pair) => _collection.decodeDoc(pair.$2))
        .toList();
    return (typed, plan);
  }

  /// Performs a full namespace scan and returns all decoded documents with the
  /// total count of documents examined.
  Future<(List<(String, Map<String, dynamic>)>, int)> _fullScan() async {
    final (startKey, endKey) = _scanRange();
    final docs = <(String key, Map<String, dynamic> doc)>[];
    var count = 0;
    await for (final entry in _collection.database.cache.scan(
      _collection.namespace,
      startKey: startKey,
      endKey: endKey,
    )) {
      count++;
      final Map<String, dynamic> doc;
      try {
        doc = await ValueCodec.decode(
          entry.value,
          encryption: _collection.database.encryption,
        );
      } catch (_) {
        continue;
      }
      doc['_id'] = entry.key;
      docs.add((entry.key, doc));
    }
    return (docs, count);
  }

  /// Checks that all secondary indexes for this collection's namespace are
  /// [IndexStatus.current].
  ///
  /// Throws [StaleIndexException] for the first non-current index found.
  Future<void> _checkIndexFreshness() async {
    final ns = _collection.namespace;
    final manager = _collection.database.indexManager;
    for (final def in manager.definitions) {
      if (def.namespace != ns) continue;
      final state = await manager.getOrActivate(ns, def.path);
      if (state.status != IndexStatus.current) {
        throw StaleIndexException(
          namespace: ns,
          path: def.path,
          status: state.status.name,
        );
      }
    }
  }

  /// Computes the [startKey, endKey) range for the LSM scan from [_keyPrefixValue].
  ///
  /// Document keys are 32-char hex strings, so the prefix is padded with `'0'`
  /// to produce 32-char startKey/endKey bounds. UUIDv7 structural bits (version
  /// 7 and variant 2) are forced into the bounds to pass validation in the
  /// storage layer.
  (String? startKey, String? endKey) _scanRange() {
    final prefix = _keyPrefixValue;
    if (prefix == null) return (null, null);

    String forceBits(String key) {
      final chars = key.split('');
      if (chars.length > 12) chars[12] = '7';
      if (chars.length > 16) {
        final v = chars[16].toLowerCase();
        if (v != '8' && v != '9' && v != 'a' && v != 'b') {
          chars[16] = '8';
        }
      }
      return chars.join();
    }

    final start = forceBits(prefix.padRight(32, '0'));
    final next = _nextPrefix(prefix);
    final end = next == null ? null : forceBits(next.padRight(32, '0'));

    return (start, end);
  }

  /// Returns the exclusive upper bound for a lexicographic prefix scan.
  ///
  /// Increments the last character that can be incremented. Returns `null`
  /// when the prefix ends in the maximum character and has no upper bound.
  static String? _nextPrefix(String prefix) {
    for (var i = prefix.length - 1; i >= 0; i--) {
      final code = prefix.codeUnitAt(i);
      if (code < 0x7E) {
        // Increment this character and truncate.
        return prefix.substring(0, i) + String.fromCharCode(code + 1);
      }
    }
    return null; // all chars at max — no upper bound
  }

  /// Compares two resolved field values for sorting.
  ///
  /// Handles `null`, [missing], numeric coercion, and strings. Values that
  /// cannot be compared (e.g. different types) are treated as equal (0).
  static int _compareValues(Object? a, Object? b) {
    // missing / null sort last.
    final aMissing = a == missing || a == null;
    final bMissing = b == missing || b == null;
    if (aMissing && bMissing) return 0;
    if (aMissing) return 1;
    if (bMissing) return -1;

    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
    return 0;
  }
}
