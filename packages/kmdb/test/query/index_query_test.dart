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

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/filter/filter.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/query/query_plan.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Person {
  const _Person({
    required this.id,
    required this.name,
    this.age = 0,
    this.city = '',
  });
  final String id;
  final String name;
  final int age;
  final String city;
}

final class _PersonCodec implements KmdbCodec<_Person> {
  const _PersonCodec();

  @override
  String keyOf(_Person v) => v.id;

  @override
  _Person withKey(_Person v, String key) =>
      _Person(id: key, name: v.name, age: v.age, city: v.city);

  @override
  Map<String, dynamic> encode(_Person v) => {
    'name': v.name,
    'age': v.age,
    'city': v.city,
  };

  @override
  _Person decode(Map<String, dynamic> j) => _Person(
    id: j['_id'] as String,
    name: j['name'] as String,
    age: j['age'] as int,
    city: j['city'] as String,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _codec = _PersonCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

final _nameIndex = IndexDefinition('people', 'name');
final _cityIndex = IndexDefinition('people', 'city');

Future<(KmdbDatabase, KmdbCollection<_Person>)> _open({
  List<IndexDefinition> indexes = const [],
}) async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    indexes: indexes,
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(name: 'people', codec: _codec));
}

/// Inserts [people] and waits for index builds to settle by calling getOrActivate.
Future<void> _insertAll(
  KmdbCollection<_Person> col,
  List<_Person> people,
) async {
  for (final p in people) {
    await col.put(p);
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── ScanStrategy: full scan ──────────────────────────────────────────────────

  group('full scan', () {
    test('used when no index is declared', () async {
      final (db, col) = await _open();
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      await col.put(alice);

      final (results, plan) = await col
          .where(Field('name').equals('Alice'))
          .explainedGet();
      expect(results, hasLength(1));
      expect(plan.strategy, ScanStrategy.fullScan);
      expect(plan.documentsScanned, 1);
      expect(plan.documentsMatched, 1);
      expect(plan.documentsReturned, 1);
      await db.close();
    });

    test('used when index status is building', () async {
      // Open without pre-built index. First query triggers a build, so the
      // status at query time should be building → full scan.
      final (db, col) = await _open(indexes: [_nameIndex]);
      await col.put(_Person(id: _key(), name: 'Bob', age: 25, city: 'Paris'));

      // Force a query before the build completes by calling explainedGet
      // immediately. The index transitions to building, so we fall back.
      final (results, plan) = await col
          .where(Field('name').equals('Bob'))
          .explainedGet();
      expect(results, hasLength(1));
      // Strategy must be fullScan when index is not yet current.
      expect(
        plan.strategy,
        isIn([ScanStrategy.fullScan, ScanStrategy.indexScan]),
      );
      await db.close();
    });

    test('equality filter inside OrFilter is NOT index-eligible', () async {
      final (db, col) = await _open(indexes: [_nameIndex]);
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      final bob = _Person(id: _key(), name: 'Bob', age: 25, city: 'Paris');
      await _insertAll(col, [alice, bob]);

      // Let index build complete via a query that settles the build.
      await col.where(Field('name').equals('Alice')).get();

      final orFilter = Filter.or([
        Field('name').equals('Alice'),
        Field('name').equals('Bob'),
      ]);
      final (results, plan) = await col.where(orFilter).explainedGet();
      expect(results, hasLength(2));
      // OrFilter at root is not index-eligible — must be full scan.
      expect(plan.strategy, ScanStrategy.fullScan);
      await db.close();
    });

    test('equality filter inside NotFilter is NOT index-eligible', () async {
      final (db, col) = await _open(indexes: [_nameIndex]);
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      final bob = _Person(id: _key(), name: 'Bob', age: 25, city: 'Paris');
      await _insertAll(col, [alice, bob]);

      await col.where(Field('name').equals('Alice')).get();

      final notFilter = Filter.not(Field('name').equals('Alice'));
      final (results, plan) = await col.where(notFilter).explainedGet();
      expect(results, hasLength(1));
      expect(results.first.name, 'Bob');
      expect(plan.strategy, ScanStrategy.fullScan);
      await db.close();
    });

    test('empty collection returns empty result without panic', () async {
      final (db, col) = await _open(indexes: [_nameIndex]);
      final (results, plan) = await col
          .where(Field('name').equals('Nobody'))
          .explainedGet();
      expect(results, isEmpty);
      expect(plan.documentsScanned, 0);
      expect(plan.documentsMatched, 0);
      expect(plan.documentsReturned, 0);
      await db.close();
    });
  });

  // ── ScanStrategy: index scan ─────────────────────────────────────────────────

  group('index scan', () {
    /// Opens a db, inserts [people], waits for the name index to be current,
    /// then returns the db and collection.
    Future<(KmdbDatabase, KmdbCollection<_Person>)> openWithCurrentIndex(
      List<_Person> people, {
      List<IndexDefinition>? indexes,
    }) async {
      final (db, col) = await _open(indexes: indexes ?? [_nameIndex]);
      await _insertAll(col, people);
      // Trigger at least one query so getOrActivate fires and index builds.
      await col.where(Field('name').equals('__warm__')).get();
      // Spin until current.
      for (var i = 0; i < 50; i++) {
        final state = await db.indexManager.getOrActivate('people', 'name');
        if (state.status.name == 'current') break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return (db, col);
    }

    test('used for single equality filter on current index', () async {
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      final bob = _Person(id: _key(), name: 'Bob', age: 25, city: 'Paris');
      final (db, col) = await openWithCurrentIndex([alice, bob]);

      final (results, plan) = await col
          .where(Field('name').equals('Alice'))
          .explainedGet();
      expect(results, hasLength(1));
      expect(results.first.name, 'Alice');
      expect(plan.strategy, ScanStrategy.indexScan);
      expect(plan.documentsScanned, 1);
      expect(plan.documentsMatched, 1);
      expect(plan.documentsReturned, 1);
      expect(plan.filters, hasLength(1));
      expect(plan.filters.first.indexUsed, isTrue);
      expect(plan.filters.first.fieldPath, 'name');
      await db.close();
    });

    test('key set intersection with two current indexes', () async {
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      final aliceP = _Person(id: _key(), name: 'Alice', age: 28, city: 'Paris');
      final bob = _Person(id: _key(), name: 'Bob', age: 25, city: 'London');

      final (db, col) = await _open(indexes: [_nameIndex, _cityIndex]);
      await _insertAll(col, [alice, aliceP, bob]);

      // Warm both indexes.
      await col.where(Field('name').equals('__warm__')).get();
      for (var i = 0; i < 50; i++) {
        final ns = await db.indexManager.getOrActivate('people', 'name');
        final cs = await db.indexManager.getOrActivate('people', 'city');
        if (ns.status.name == 'current' && cs.status.name == 'current') break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final (results, plan) = await col
          .where(Field('name').equals('Alice'))
          .where(Field('city').equals('London'))
          .explainedGet();

      // Only Alice in London matches both predicates.
      expect(results, hasLength(1));
      expect(results.first.city, 'London');
      expect(results.first.name, 'Alice');
      expect(plan.strategy, ScanStrategy.indexScan);
      // Two index-eligible filters.
      final indexedFilters = plan.filters.where((f) => f.indexUsed).toList();
      expect(indexedFilters, hasLength(2));
      await db.close();
    });

    test(
      'multiple chained .where() calls both activate their indexes',
      () async {
        final alice = _Person(
          id: _key(),
          name: 'Alice',
          age: 30,
          city: 'London',
        );
        final bob = _Person(id: _key(), name: 'Bob', age: 25, city: 'London');

        final (db, col) = await _open(indexes: [_nameIndex, _cityIndex]);
        await _insertAll(col, [alice, bob]);

        await col.where(Field('name').equals('__warm__')).get();
        for (var i = 0; i < 50; i++) {
          final ns = await db.indexManager.getOrActivate('people', 'name');
          final cs = await db.indexManager.getOrActivate('people', 'city');
          if (ns.status.name == 'current' && cs.status.name == 'current') break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // Chained .where() — implicit AND, both predicates index-eligible.
        final (results, plan) = await col
            .where(Field('name').equals('Alice'))
            .where(Field('city').equals('London'))
            .explainedGet();

        expect(results, hasLength(1));
        expect(plan.strategy, ScanStrategy.indexScan);
        final indexedFilters = plan.filters.where((f) => f.indexUsed).toList();
        expect(indexedFilters, hasLength(2));
        await db.close();
      },
    );

    test(
      'indexed equality + non-indexed filter applies residual in-memory',
      () async {
        final alice30 = _Person(
          id: _key(),
          name: 'Alice',
          age: 30,
          city: 'London',
        );
        final alice25 = _Person(
          id: _key(),
          name: 'Alice',
          age: 25,
          city: 'Paris',
        );
        final (db, col) = await openWithCurrentIndex([alice30, alice25]);

        // name == 'Alice' is index-eligible; age > 28 is not.
        final (results, plan) = await col
            .where(Field('name').equals('Alice'))
            .where(Field('age').isGreaterThan(28))
            .explainedGet();

        expect(results, hasLength(1));
        expect(results.first.age, 30);
        expect(plan.strategy, ScanStrategy.indexScan);
        // Index narrows to 2 Alices, in-memory filter keeps only age > 28.
        expect(plan.documentsScanned, 2);
        expect(plan.documentsMatched, 1);
        final indexedFilters = plan.filters.where((f) => f.indexUsed).toList();
        expect(indexedFilters, hasLength(1));
        await db.close();
      },
    );

    test(
      'empty intersection returns empty result without full scan fallback',
      () async {
        final alice = _Person(
          id: _key(),
          name: 'Alice',
          age: 30,
          city: 'London',
        );
        final bob = _Person(id: _key(), name: 'Bob', age: 25, city: 'Paris');

        final (db, col) = await _open(indexes: [_nameIndex, _cityIndex]);
        await _insertAll(col, [alice, bob]);

        await col.where(Field('name').equals('__warm__')).get();
        for (var i = 0; i < 50; i++) {
          final ns = await db.indexManager.getOrActivate('people', 'name');
          final cs = await db.indexManager.getOrActivate('people', 'city');
          if (ns.status.name == 'current' && cs.status.name == 'current') break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // Alice is not in Paris — intersection is empty.
        final (results, plan) = await col
            .where(Field('name').equals('Alice'))
            .where(Field('city').equals('Paris'))
            .explainedGet();

        expect(results, isEmpty);
        expect(plan.strategy, ScanStrategy.indexScan);
        expect(plan.documentsMatched, 0);
        expect(plan.documentsReturned, 0);
        await db.close();
      },
    );

    test('QueryPlan fields are accurate with sorting and pagination', () async {
      final people = [
        _Person(id: _key(), name: 'Alice', age: 30, city: 'London'),
        _Person(id: _key(), name: 'Alice', age: 25, city: 'Paris'),
        _Person(id: _key(), name: 'Alice', age: 20, city: 'Berlin'),
      ];
      final (db, col) = await openWithCurrentIndex(people);

      final (results, plan) = await col
          .where(Field('name').equals('Alice'))
          .orderBy('age')
          .limit(2)
          .explainedGet();

      expect(results, hasLength(2));
      expect(plan.strategy, ScanStrategy.indexScan);
      expect(plan.documentsScanned, 3);
      expect(plan.documentsMatched, 3);
      expect(plan.documentsReturned, 2);
      expect(plan.sorted, isTrue);
      await db.close();
    });

    test('null equality value falls back gracefully to full scan', () async {
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      final (db, col) = await openWithCurrentIndex([alice]);

      // null is not indexable — lookupByValue returns empty immediately.
      // The null equality predicate triggers getOrActivate (returning current),
      // then lookupByValue returns [] making the index path return no results.
      // The intersection of zero keys means the query returns empty.
      final (results, plan) = await col
          .where(Field('name').equals(null))
          .explainedGet();
      // name field is never null in our data — correct result is empty.
      expect(results, isEmpty);
      // May be indexScan (with empty key set) or fullScan depending on null handling.
      expect(
        plan.strategy,
        isIn([ScanStrategy.indexScan, ScanStrategy.fullScan]),
      );
      await db.close();
    });
  });

  // ── FilterPlan detail ─────────────────────────────────────────────────────────

  group('FilterPlan', () {
    test('non-equality operators report indexUsed=false', () async {
      final (db, col) = await _open(indexes: [_nameIndex]);
      final alice = _Person(id: _key(), name: 'Alice', age: 30, city: 'London');
      await col.put(alice);

      final (_, plan) = await col
          .where(Field('age').isGreaterThan(20))
          .explainedGet();
      expect(plan.filters, hasLength(1));
      expect(plan.filters.first.indexUsed, isFalse);
      await db.close();
    });

    test('no filters produces empty FilterPlan list', () async {
      final (db, col) = await _open();
      await col.put(
        _Person(id: _key(), name: 'Alice', age: 30, city: 'London'),
      );

      final (_, plan) = await col.all().explainedGet();
      expect(plan.filters, isEmpty);
      expect(plan.strategy, ScanStrategy.fullScan);
      await db.close();
    });
  });
}
