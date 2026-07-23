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

/// The equivalence test 0.10.01 WI-11 exists to add (see the plan's Phase 4,
/// "the point of this plan").
///
/// Neither `filter_test.dart` (which tests [Filter.evaluate] in isolation) nor
/// `index_query_test.dart` (which tests index selection with exact-case
/// predicates) asserts the property that actually matters: **the index path
/// and the full-scan path must return the same row set for the same filter.**
/// SC-15 is exactly a case where they silently diverged — `equals(value,
/// caseSensitive: false)` returned an index-eligible predicate
/// ([FieldFilter.equalityPredicate], now gated on `caseSensitive` — see
/// `field_filter.dart`), so the planner did an exact-token index lookup that
/// could never find a differently-cased match, while the (correct) full scan
/// found it. Nothing asserted the two had to agree.
///
/// For a sampled matrix of filter type x operator x `caseSensitive` flag, this
/// file opens two databases with identical fixture data — one with a
/// secondary index declared on the filtered field, one with none — and
/// asserts the returned document `_id` sets are identical. The mandatory
/// failing cell (documented inline below) is the *only* one that actually
/// diverges against the pre-Phase-1 code: every other operator here already
/// full-scans in both arms (only `eq` is index-eligible at all), so without
/// that cell the "fails before the fix" gate would be untestable and this
/// file would have silently read green against the broken code.
library;

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/filter/filter.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/index/index_manager.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/query/query_plan.dart';
import 'package:test/test.dart';

// ── Fixture ─────────────────────────────────────────────────────────────────

/// A minimal codec for `Map<String, dynamic>` documents — keeps every filter
/// field directly inspectable (`doc['_id']`) without a typed model.
final class _MapCodec implements KmdbCodec<Map<String, dynamic>> {
  const _MapCodec();

  @override
  Map<String, dynamic> decode(Map<String, dynamic> json) => json;

  @override
  Map<String, dynamic> encode(Map<String, dynamic> value) =>
      Map.of(value)..remove('_id');

  @override
  String keyOf(Map<String, dynamic> value) => value['_id'] as String;

  @override
  Map<String, dynamic> withKey(Map<String, dynamic> value, String key) => {
    ...value,
    '_id': key,
  };
}

const _codec = _MapCodec();

/// The fixed dataset every matrix cell runs against. Deliberately includes
/// one mixed-case city (`'London'`) with no other document sharing its
/// lowercased form, so the mandatory failing cell below is unambiguous.
///
/// Each document carries a fixed `_id` (rather than letting
/// [KmdbCollection.insert] mint a fresh UUIDv7 per call) so that the same
/// logical document has the *same* key across the two separately-opened
/// databases each matrix cell compares — [KmdbCollection.put] (which uses the
/// document's own key, via [_MapCodec.keyOf]) is used instead of `insert()`
/// for exactly this reason. Without fixed keys, comparing "row sets by `_id`"
/// between two independently-populated databases would be meaningless: every
/// `_id` would differ regardless of whether the index and full-scan paths
/// agree.
const _fixture = [
  {
    '_id': '01900000000070008000000000000001',
    'name': 'Alice',
    'city': 'London',
    'age': 30,
    'tags': ['red', 'blue'],
  },
  {
    '_id': '01900000000070008000000000000002',
    'name': 'Bob',
    'city': 'Paris',
    'age': 25,
    'tags': ['green'],
  },
  {
    '_id': '01900000000070008000000000000003',
    'name': 'Carol',
    'city': 'Berlin',
    'age': 35,
    'tags': ['blue'],
  },
  {
    '_id': '01900000000070008000000000000004',
    'name': 'Dave',
    'city': 'Paris',
    'age': 40,
    'tags': <String>[],
  },
];

/// Opens a fresh in-memory database, inserts [_fixture] into the `items`
/// namespace, optionally declares a secondary index on [indexField], runs
/// [filter] against it, and returns the set of matched `_id`s.
///
/// When [indexField] is non-null, a throwaway warm-up query is issued first
/// and polled until the index reaches [IndexStatus.current] — otherwise the
/// very first real query would itself trigger the lazy build and fall back to
/// a full scan for that call, never exercising [ScanStrategy.indexScan] at
/// all (see `index_query_test.dart`'s identical `openWithCurrentIndex`
/// pattern).
Future<({Set<String> ids, ScanStrategy strategy})> _idsFor(
  Filter filter, {
  String? indexField,
}) async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    indexes: indexField == null
        ? const []
        : [IndexDefinition('items', indexField)],
    config: KvStoreConfig.forTesting(),
  );
  final col = db.collection(name: 'items', codec: _codec);
  for (final doc in _fixture) {
    await col.put(Map.of(doc));
  }

  if (indexField != null) {
    // Warm the index so it is `current` by the time the real query runs.
    await col.where(Field(indexField).equals('__warm__')).get();
    var status = IndexStatus.undefined;
    for (var i = 0; i < 50; i++) {
      final state = await db.indexManager.getOrActivate('items', indexField);
      status = state.status;
      if (status == IndexStatus.current) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Without this assertion the poll can fall through with the index never
    // built: both arms would then full-scan, agree trivially, and every cell
    // in the matrix would pass while asserting nothing about the index path.
    expect(
      status,
      IndexStatus.current,
      reason:
          'the index on "$indexField" never reached `current` after the '
          'warm-up poll, so the "with index" arm would silently full-scan and '
          'every equivalence cell would pass vacuously',
    );
  }

  final (results, plan) = await col.where(filter).explainedGet();
  final ids = results.map((d) => d['_id'] as String).toSet();
  await db.close();
  return (ids: ids, strategy: plan.strategy);
}

/// Asserts that running [filter] against [field] returns the same document
/// `_id` set whether or not a secondary index is declared on [field] — the
/// equivalence property this whole file exists to check.
///
/// [expectRows] pins the absolute expected `_id` set. The equivalence
/// assertion on its own is purely *relative*: if the fixture ever stopped
/// loading, every cell would pass as `{} == {}`. Pinning at least the
/// discriminating cells anchors the matrix to real data.
///
/// [indexStrategy] asserts which path the *index-declared* arm actually took.
/// This is what makes the SC-15 cells meaningful: the fix is precisely that
/// the planner **declines** the index for a predicate it cannot fully answer,
/// so a case-insensitive `eq` must report [ScanStrategy.fullScan] while an
/// exact-case `eq` must report [ScanStrategy.indexScan].
Future<void> _expectEquivalent(
  String field,
  Filter filter, {
  Set<String>? expectRows,
  ScanStrategy? indexStrategy,
}) async {
  final withIndex = await _idsFor(filter, indexField: field);
  final withoutIndex = await _idsFor(filter);
  expect(
    withIndex.ids,
    equals(withoutIndex.ids),
    reason:
        'index-path and full-scan-path row sets diverged for a filter on '
        '"$field" — the index answered a predicate it cannot fully answer',
  );
  if (expectRows != null) {
    expect(
      withoutIndex.ids,
      equals(expectRows),
      reason:
          'the full-scan arm did not return the expected rows for "$field" — '
          'the fixture or filter is wrong, and the equivalence assertion above '
          'would have passed vacuously on an empty result set',
    );
  }
  if (indexStrategy != null) {
    expect(
      withIndex.strategy,
      indexStrategy,
      reason:
          'the index-declared arm took the wrong path for "$field": expected '
          '$indexStrategy. An unexpected fullScan means the index was never '
          'exercised; an unexpected indexScan means the planner accepted a '
          'predicate it cannot fully answer (the SC-15 defect).',
    );
  }
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('index vs full-scan equivalence — sampled matrix', () {
    test('eq, caseSensitive: false — THE MANDATORY FAILING CELL '
        '(only cell that diverges against the pre-fix code)', () async {
      // Filter.field('city').equals('london', caseSensitive: false) against
      // a doc with city: 'London'. Before the SC-15 fix,
      // FieldFilter.equalityPredicate ignored `caseSensitive` entirely, so
      // the index-declared arm did an exact-token lookup for 'london' and
      // never found 'London' — 0 rows — while the full-scan arm correctly
      // matched via case-insensitive comparison — 1 row. This is the
      // *only* cell in this matrix that fails against the pre-fix code:
      // every other operator here already agrees between both arms because
      // only `eq` is index-eligible at all today (a matrix of exact-case
      // operators would pass against the broken code and falsely read
      // green — see this file's own doc comment).
      await _expectEquivalent(
        'city',
        Field('city').equals('london', caseSensitive: false),
        // Absolute pin: Alice is the only London row. Without this the
        // equivalence check alone would pass on an empty fixture.
        expectRows: {'01900000000070008000000000000001'},
        // The SC-15 fix itself: the planner must *decline* the index for a
        // case-insensitive equality and fall through to the full scan. If
        // this reads indexScan, the defect is back.
        indexStrategy: ScanStrategy.fullScan,
      );
    });

    test('eq, caseSensitive: true (control — same case)', () async {
      await _expectEquivalent(
        'city',
        Field('city').equals('London'),
        expectRows: {'01900000000070008000000000000001'},
        // The complementary half of the contract: an exact-case equality is
        // fully answerable from the index, so the planner must still use it.
        // Together with the cell above this proves the gate discriminates
        // rather than simply disabling the index path wholesale.
        indexStrategy: ScanStrategy.indexScan,
      );
    });

    test('eq, caseSensitive: true, mismatched case (control — correctly '
        'no-match in both arms)', () async {
      await _expectEquivalent(
        'city',
        Field('city').equals('london'),
        expectRows: const <String>{},
        indexStrategy: ScanStrategy.indexScan,
      );
    });

    test('startsWith, caseSensitive: true', () async {
      await _expectEquivalent('city', Field('city').startsWith('Lon'));
    });

    test('startsWith, caseSensitive: false', () async {
      await _expectEquivalent(
        'city',
        Field('city').startsWith('lon', caseSensitive: false),
      );
    });

    test('contains (substring), caseSensitive: false', () async {
      await _expectEquivalent(
        'city',
        Field('city').contains('ARIS', caseSensitive: false),
      );
    });

    test('notEquals', () async {
      await _expectEquivalent('city', Field('city').notEquals('Paris'));
    });

    test('isGreaterThan (numeric field)', () async {
      await _expectEquivalent('age', Field('age').isGreaterThan(28));
    });

    test('isBetween (numeric field)', () async {
      await _expectEquivalent('age', Field('age').isBetween(25, 35));
    });

    test('isIn', () async {
      await _expectEquivalent('age', Field('age').isIn([25, 40]));
    });

    test('containsAny (array field)', () async {
      await _expectEquivalent('tags', Field('tags').containsAny(['red']));
    });

    test('containsAll (array field)', () async {
      await _expectEquivalent('tags', Field('tags').containsAll(['blue']));
    });
  });
}
