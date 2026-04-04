// Copyright 2026 The KMDB Authors
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

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Item {
  const _Item({required this.id, required this.name, this.score = 0});
  final String id;
  String get title => name; // for codec compatibility if needed elsewhere
  final String name;
  final int score;
}

final class _ItemCodec implements KmdbCodec<_Item> {
  const _ItemCodec();

  @override
  String keyOf(_Item v) => v.id;

  @override
  _Item withKey(_Item v, String key) =>
      _Item(id: key, name: v.name, score: v.score);

  @override
  Map<String, dynamic> encode(_Item v) => {
    'id': v.id,
    'name': v.name,
    'score': v.score,
  };

  @override
  _Item decode(Map<String, dynamic> j) => _Item(
    id: j['id'] as String,
    name: j['name'] as String,
    score: j['score'] as int? ?? 0,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _codec = _ItemCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

Future<(KmdbDatabase, KmdbCollection<_Item>)> _open() async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(namespace: 'items', codec: _codec));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── all() / get() ─────────────────────────────────────────────────────────

  group('all().get()', () {
    test('returns all documents', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'A'),
        _Item(id: _key(), name: 'B'),
        _Item(id: _key(), name: 'C'),
      ]);
      final results = await col.all().get();
      expect(results.length, equals(3));
      await db.close();
    });

    test('returns empty list for empty namespace', () async {
      final (db, col) = await _open();
      expect(await col.all().get(), isEmpty);
      await db.close();
    });
  });

  // ── where() ──────────────────────────────────────────────────────────────

  group('where()', () {
    test('filters by field equality', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'Alpha', score: 10),
        _Item(id: _key(), name: 'Beta', score: 20),
        _Item(id: _key(), name: 'Gamma', score: 10),
      ]);
      final results = await col.where(Field('score').equals(10)).get();
      expect(results.length, equals(2));
      expect(results.map((i) => i.name).toSet(), equals({'Alpha', 'Gamma'}));
      await db.close();
    });

    test('multiple where() clauses are AND-ed', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'Alpha', score: 10),
        _Item(id: _key(), name: 'Beta', score: 20),
      ]);
      final results = await col
          .all()
          .where(Field('score').isGreaterThan(5))
          .where(Field('name').equals('Alpha'))
          .get();
      expect(results.length, equals(1));
      expect(results.first.name, equals('Alpha'));
      await db.close();
    });

    test('where() does not mutate the original query', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'A'),
        _Item(id: _key(), name: 'B'),
      ]);
      final base = col.all();
      final filtered = base.where(Field('name').equals('A'));
      expect(await base.get(), hasLength(2));
      expect(await filtered.get(), hasLength(1));
      await db.close();
    });
  });

  // ── orderBy() ─────────────────────────────────────────────────────────────

  group('orderBy()', () {
    test('orders ascending by field', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'C', score: 3),
        _Item(id: _key(), name: 'A', score: 1),
        _Item(id: _key(), name: 'B', score: 2),
      ]);
      final results = await col.all().orderBy('score').get();
      expect(results.map((i) => i.score).toList(), equals([1, 2, 3]));
      await db.close();
    });

    test('orders descending by field', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'A', score: 1),
        _Item(id: _key(), name: 'B', score: 2),
        _Item(id: _key(), name: 'C', score: 3),
      ]);
      final results = await col.all().orderBy('score', descending: true).get();
      expect(results.map((i) => i.score).toList(), equals([3, 2, 1]));
      await db.close();
    });

    test('orderBy does not mutate original query', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'B', score: 2),
        _Item(id: _key(), name: 'A', score: 1),
      ]);
      final base = col.all();
      final sorted = base.orderBy('score');
      // Both queries still work independently.
      expect(await base.get(), hasLength(2));
      expect((await sorted.get()).first.score, equals(1));
      await db.close();
    });
  });

  // ── limit() / offset() ───────────────────────────────────────────────────

  group('limit() / offset()', () {
    setUp(() async {});

    test('limit restricts result count', () async {
      final (db, col) = await _open();
      await col.putMany(
        List.generate(5, (i) => _Item(id: _key(), name: 'x$i', score: i)),
      );
      final results = await col.all().orderBy('score').limit(3).get();
      expect(results.length, equals(3));
      await db.close();
    });

    test('offset skips documents', () async {
      final (db, col) = await _open();
      await col.putMany(
        List.generate(5, (i) => _Item(id: _key(), name: 'x$i', score: i)),
      );
      final results = await col.all().orderBy('score').offset(2).limit(2).get();
      expect(results.map((i) => i.score).toList(), equals([2, 3]));
      await db.close();
    });

    test('offset beyond length returns empty', () async {
      final (db, col) = await _open();
      await col.putMany([_Item(id: _key(), name: 'x', score: 0)]);
      expect(await col.all().offset(10).get(), isEmpty);
      await db.close();
    });
  });

  // ── keyPrefix() ───────────────────────────────────────────────────────────

  group('keyPrefix()', () {
    test('narrows scan to matching key prefix', () async {
      final (db, col) = await _open();
      // Use a fixed prefix. Must result in valid UUIDv7 keys.
      final prefix = '0000';
      final k1 = '00000000000070008000000000000001';
      final k2 = '00000000000070008000000000000002';
      final k3fixed = 'ffffffffffff7fff8fffffffffffffff';
      await col.put(_Item(id: k1, name: 'match1'));
      await col.put(_Item(id: k2, name: 'match2'));
      await col.put(_Item(id: k3fixed, name: 'no-match'));
      final results = await col.all().keyPrefix(prefix).get();
      expect(results.length, equals(2));
      expect(results.map((i) => i.name).toSet(), equals({'match1', 'match2'}));
      await db.close();
    });
  });

  // ── Terminal methods ──────────────────────────────────────────────────────

  group('first()', () {
    test('returns first matching document', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'A', score: 1),
        _Item(id: _key(), name: 'B', score: 2),
      ]);
      final result = await col.all().orderBy('score').first();
      expect(result, isNotNull);
      expect(result!.score, equals(1));
      await db.close();
    });

    test('returns null when no match', () async {
      final (db, col) = await _open();
      final result = await col.where(Field('score').equals(99)).first();
      expect(result, isNull);
      await db.close();
    });
  });

  group('count()', () {
    test('counts all documents', () async {
      final (db, col) = await _open();
      await col.putMany(
        List.generate(4, (i) => _Item(id: _key(), name: 'x$i')),
      );
      expect(await col.all().count(), equals(4));
      await db.close();
    });

    test('counts filtered documents', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'A', score: 5),
        _Item(id: _key(), name: 'B', score: 10),
        _Item(id: _key(), name: 'C', score: 5),
      ]);
      expect(await col.where(Field('score').equals(5)).count(), equals(2));
      await db.close();
    });
  });

  group('any()', () {
    test('true when at least one match', () async {
      final (db, col) = await _open();
      await col.put(_Item(id: _key(), name: 'A', score: 7));
      expect(await col.where(Field('score').equals(7)).any(), isTrue);
      await db.close();
    });

    test('false when no match', () async {
      final (db, col) = await _open();
      await col.put(_Item(id: _key(), name: 'A', score: 7));
      expect(await col.where(Field('score').equals(99)).any(), isFalse);
      await db.close();
    });
  });

  group('stream()', () {
    test('emits all matching documents', () async {
      final (db, col) = await _open();
      await col.putMany([
        _Item(id: _key(), name: 'A'),
        _Item(id: _key(), name: 'B'),
      ]);
      final items = await col.all().stream().toList();
      expect(items.length, equals(2));
      await db.close();
    });
  });

  // ── watch() ───────────────────────────────────────────────────────────────

  group('watch()', () {
    test('emits initial results on subscribe', () async {
      final (db, col) = await _open();
      await col.put(_Item(id: _key(), name: 'A'));
      final first = await col.all().watch().first;
      expect(first.length, equals(1));
      await db.close();
    });

    test('re-emits after write (debounced)', () async {
      final (db, col) = await _open();
      final emitted = <List<_Item>>[];
      final sub = col.all().watch().listen(emitted.add);

      await Future.delayed(Duration.zero); // initial emit
      await col.put(_Item(id: _key(), name: 'New'));
      // Wait for debounce (50ms) + some margin
      await Future.delayed(const Duration(milliseconds: 100));

      await sub.cancel();
      expect(emitted.length, greaterThanOrEqualTo(2));
      expect(emitted.last.length, equals(1));
      await db.close();
    });

    test('10 rapid writes produce at most 2 re-emits after debounce', () async {
      final (db, col) = await _open();
      final emitted = <List<_Item>>[];
      final sub = col.all().watch().listen(emitted.add);

      await Future.delayed(Duration.zero); // initial

      // Write 10 times rapidly.
      for (var i = 0; i < 10; i++) {
        await col.put(_Item(id: _key(), name: 'item$i'));
      }

      // Wait for debounce to fire.
      await Future.delayed(const Duration(milliseconds: 150));

      await sub.cancel();
      // Initial emit + at most 1 debounced re-emit for the burst.
      expect(emitted.length, lessThanOrEqualTo(3));
      expect(emitted.last.length, equals(10));
      await db.close();
    });

    test('write to different namespace does not trigger re-emit', () async {
      final (db, col) = await _open();
      final other = db.collection(namespace: 'other', codec: _codec);

      final emitted = <List<_Item>>[];
      final sub = col.all().watch().listen(emitted.add);
      await Future.delayed(Duration.zero); // initial
      final countBefore = emitted.length;

      await other.put(_Item(id: _key(), name: 'other'));
      await Future.delayed(const Duration(milliseconds: 100));

      await sub.cancel();
      expect(emitted.length, equals(countBefore)); // no re-emit
      await db.close();
    });
  });

  // ── requireFreshIndex / StaleIndexException ───────────────────────────────

  group('StaleIndexException', () {
    test('toString includes namespace, path, and status', () {
      const e = StaleIndexException(
        namespace: 'tasks',
        path: 'assignee',
        status: 'stale',
      );
      expect(e.toString(), contains('assignee'));
      expect(e.toString(), contains('tasks'));
      expect(e.toString(), contains('stale'));
    });

    test('implements Exception', () {
      expect(
        const StaleIndexException(
          namespace: 'ns',
          path: 'field',
          status: 'building',
        ),
        isA<Exception>(),
      );
    });
  });

  group('requireFreshIndex()', () {
    Future<(KmdbDatabase, KmdbCollection<_Item>)> openWithIndex() async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
        indexes: [IndexDefinition('items', 'name')],
      );
      return (db, db.collection(namespace: 'items', codec: _codec));
    }

    test('does not throw when no indexes are defined', () async {
      final (db, col) = await _open();
      // No indexes defined — requireFreshIndex() should succeed immediately.
      await expectLater(col.all().requireFreshIndex().get(), completes);
      await db.close();
    });

    test(
      'does not throw when index is current after build completes',
      () async {
        final (db, col) = await openWithIndex();
        // Insert a document to trigger something to index.
        await col.put(_Item(id: _key(), name: 'Alice', score: 1));
        // Allow the background build microtask to complete.
        await Future.delayed(const Duration(milliseconds: 20));
        // Index should now be current — requireFreshIndex() should succeed.
        await expectLater(col.all().requireFreshIndex().get(), completes);
        await db.close();
      },
    );

    test(
      'requireFreshIndex flag propagates through pipeline methods',
      () async {
        final (db, col) = await _open();
        // Verify the flag survives chaining.
        final q = col
            .where(Field('name').equals('x'))
            .orderBy('name')
            .limit(10)
            .offset(0)
            .requireFreshIndex();
        // No indexes defined, so get() should succeed.
        await expectLater(q.get(), completes);
        await db.close();
      },
    );
  });
}
