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

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Task {
  const _Task({required this.id, required this.title, this.done = false});
  final String id;
  final String title;
  final bool done;
}

final class _TaskCodec implements KmdbCodec<_Task> {
  const _TaskCodec();

  @override
  String keyOf(_Task value) => value.id;

  @override
  _Task withKey(_Task value, String key) =>
      _Task(id: key, title: value.title, done: value.done);

  @override
  Map<String, dynamic> encode(_Task value) => {
    'title': value.title,
    'done': value.done,
  };

  @override
  _Task decode(Map<String, dynamic> json) => _Task(
    id: json['_id'] as String,
    title: json['title'] as String,
    done: json['done'] as bool? ?? false,
  );
}

/// A codec that unconditionally returns a fixed map from [encode], used to
/// test that [ReservedFieldException] is thrown when reserved keys are present.
final class _BadCodec implements KmdbCodec<_Task> {
  const _BadCodec(this._encodedMap);

  final Map<String, dynamic> _encodedMap;

  @override
  String keyOf(_Task value) => value.id;

  @override
  _Task withKey(_Task value, String key) =>
      _Task(id: key, title: value.title, done: value.done);

  @override
  Map<String, dynamic> encode(_Task value) => Map.of(_encodedMap);

  @override
  _Task decode(Map<String, dynamic> json) => _Task(
    id: json['_id'] as String? ?? '',
    title: json['title'] as String? ?? '',
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _codec = _TaskCodec();
final _gen = SequentialKeyGenerator();

String _key() => _gen.next();

Future<(KmdbDatabase, KmdbCollection<_Task>)> _open({
  List<IndexDefinition> indexes = const [],
}) async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    indexes: indexes,
    config: KvStoreConfig.forTesting(),
  );
  final col = db.collection(name: 'tasks', codec: _codec);
  return (db, col);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── put / get ─────────────────────────────────────────────────────────────

  group('put / get', () {
    test('put and get round-trip', () async {
      final (db, col) = await _open();
      final task = _Task(id: _key(), title: 'Buy milk');
      await col.put(task);
      final result = await col.get(task.id);
      expect(result, isNotNull);
      expect(result!.title, equals('Buy milk'));
      await db.close();
    });

    test('get returns null for absent key', () async {
      final (db, col) = await _open();
      expect(await col.get(_key()), isNull);
      await db.close();
    });

    test('put overwrites existing document', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'Original'));
      await col.put(_Task(id: id, title: 'Updated'));
      final result = await col.get(id);
      expect(result!.title, equals('Updated'));
      await db.close();
    });

    test('put of a keyless value mints a fresh key and returns it', () async {
      final (db, col) = await _open();
      final result = await col.put(_Task(id: '', title: 'Mint me'));

      // The returned document carries the minted key — the only way to
      // recover it for a keyless put().
      expect(result.id, isNotEmpty);
      expect(await col.get(result.id), isNotNull);

      // A brand-new logical document starts a fresh $ver: chain of length 1.
      final versions = await col.getVersions(result.id);
      expect(versions, hasLength(1));
      await db.close();
    });

    test('put of a keyed value with an absent key creates it at that key '
        'with a chain of length 1', () async {
      final (db, col) = await _open();
      final id = _key();
      final result = await col.put(_Task(id: id, title: 'Created at key'));

      expect(result.id, equals(id));
      expect((await col.get(id))!.title, equals('Created at key'));

      final versions = await col.getVersions(id);
      expect(versions, hasLength(1));
      await db.close();
    });
  });

  // ── insert / replace ──────────────────────────────────────────────────────

  group('insert', () {
    test('inserts new document and returns updated model', () async {
      final (db, col) = await _open();
      final task = _Task(id: '', title: 'New task');
      final inserted = await col.insert(task);

      expect(inserted.id, isNotEmpty);
      expect(inserted.title, equals('New task'));
      expect(await col.get(inserted.id), isNotNull);
      await db.close();
    });

    test('uses collection keyGenerator', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(path: '/db', adapter: adapter);
      final myGen = SequentialKeyGenerator(start: 100);
      final col = KmdbCollection(
        namespace: 'tasks',
        codec: _codec,
        database: db,
        keyGenerator: myGen,
      );

      final task = await col.insert(_Task(id: '', title: 'T'));
      expect(task.id, equals(SequentialKeyGenerator(start: 100).next()));
      await db.close();
    });

    test('throws ArgumentError if value already carries a key', () async {
      final (db, col) = await _open();
      // insert() is a strict-create guard: a value that already carries a
      // key must never be silently duplicated under a fresh key (the SC-16
      // bug). It throws instead of minting a second copy.
      final id = '00000000000070008000000000000001';
      final task = _Task(id: id, title: 'Existing');

      expect(() => col.insert(task), throwsA(isA<ArgumentError>()));
      // Nothing was written — the guard fires before any I/O.
      expect(await col.get(id), isNull);
      await db.close();
    });

    test(
      'the SC-16 raw-doc silent-duplicate reproduction (read-back doc)',
      () async {
        // Reproduces the reported bug: a keyless raw doc is put (mints key
        // K), read back (carrying _id: K), then passed to insert(). On
        // unfixed main this silently mints a NEW key and writes a second
        // copy under it, orphaning K's $ver: chain. Fixed: insert() must
        // throw and the namespace must still hold exactly one document.
        final adapter = MemoryStorageAdapter();
        final db = await KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          config: KvStoreConfig.forTesting(),
        );
        final raw = db.rawCollection('contacts');

        final inserted = await raw.insert({'name': 'Alice'});
        final key = inserted['_id'] as String;
        final readBack = await raw.get(key);
        expect(readBack, isNotNull);
        expect(readBack!['_id'], equals(key));

        await expectLater(raw.insert(readBack), throwsA(isA<ArgumentError>()));

        // Exactly one document exists in the namespace.
        var count = 0;
        await for (final _ in db.store.scan('contacts')) {
          count++;
        }
        expect(count, equals(1));

        // Exactly one key exists in the $ver: chain, with a single entry.
        final versions = await raw.getVersions(key);
        expect(versions, hasLength(1));

        await db.close();
      },
    );

    test('put(readBackDoc) updates in place — no orphaned chain', () async {
      // The correct path for the SC-16 scenario: put() (not insert()) on a
      // read-back doc updates K in place rather than forking a new chain.
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
      );
      final raw = db.rawCollection('contacts');

      final inserted = await raw.insert({'name': 'Alice'});
      final key = inserted['_id'] as String;
      final readBack = await raw.get(key);
      final updated = Map<String, dynamic>.of(readBack!)..['name'] = 'Alicia';
      await raw.put(updated);

      var count = 0;
      await for (final _ in db.store.scan('contacts')) {
        count++;
      }
      expect(count, equals(1));

      final versions = await raw.getVersions(key);
      expect(versions, hasLength(2));

      final doc = await raw.get(key);
      expect(doc!['name'], equals('Alicia'));

      await db.close();
    });

    test('typed equivalent: insert throws for a real id, put appends; '
        'a blank id mints on both', () async {
      final (db, col) = await _open();

      // A typed model carrying a real (caller-supplied) id: insert()
      // rejects it, put() appends to its chain.
      final id = _key();
      final task = _Task(id: id, title: 'Has id');
      expect(() => col.insert(task), throwsA(isA<ArgumentError>()));
      expect(await col.get(id), isNull); // insert() wrote nothing

      await col.put(task);
      await col.put(_Task(id: id, title: 'Has id v2'));
      final versions = await col.getVersions(id);
      expect(versions, hasLength(2));

      // The typed keyless sentinel (`id: ''`) mints on both insert() and
      // put(), same as the raw-doc keyless case above.
      final insertedBlank = await col.insert(_Task(id: '', title: 'Blank'));
      expect(insertedBlank.id, isNotEmpty);
      expect(await col.getVersions(insertedBlank.id), hasLength(1));

      final putBlank = await col.put(_Task(id: '', title: 'Blank2'));
      expect(putBlank.id, isNotEmpty);
      expect(putBlank.id, isNot(equals(insertedBlank.id)));
      expect(await col.getVersions(putBlank.id), hasLength(1));

      await db.close();
    });

    test('N-put orphan-chain lock: repeated read-modify-put round trips never '
        'fork a second key or chain', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
      );
      final raw = db.rawCollection('contacts');

      final inserted = await raw.insert({'name': 'v0'});
      final key = inserted['_id'] as String;

      const roundTrips = 5;
      for (var i = 1; i <= roundTrips; i++) {
        final current = await raw.get(key);
        final updated = Map<String, dynamic>.of(current!)..['name'] = 'v$i';
        await raw.put(updated);
      }

      // Exactly one document in the namespace — no forked key.
      var count = 0;
      await for (final _ in db.store.scan('contacts')) {
        count++;
      }
      expect(count, equals(1));

      // Exactly one $ver: chain, with one entry per write (initial insert
      // + each round trip).
      final versions = await raw.getVersions(key);
      expect(versions, hasLength(roundTrips + 1));

      expect((await raw.get(key))!['name'], equals('v$roundTrips'));
      await db.close();
    });
  });

  group('replace', () {
    test('replaces existing document', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'Old'));
      await col.replace(_Task(id: id, title: 'New'));
      expect((await col.get(id))!.title, equals('New'));
      await db.close();
    });

    test('throws DocumentNotFoundException if key absent', () async {
      final (db, col) = await _open();
      expect(
        () => col.replace(_Task(id: _key(), title: 'Ghost')),
        throwsA(isA<DocumentNotFoundException>()),
      );
      await db.close();
    });

    test('throws ArgumentError for a keyless value', () async {
      final (db, col) = await _open();
      expect(
        () => col.replace(_Task(id: '', title: 'No key')),
        throwsA(isA<ArgumentError>()),
      );
      await db.close();
    });
  });

  // ── keyless detection (_keyOrNull) ────────────────────────────────────────

  group('keyless detection', () {
    test('empty-string typed id takes the mint path on put', () async {
      final (db, col) = await _open();
      final result = await col.put(_Task(id: '', title: 'Blank id'));
      expect(result.id, isNotEmpty);
      await db.close();
    });

    test('absent _id on a raw doc takes the mint path on put', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
      );
      final raw = db.rawCollection('contacts');
      final result = await raw.put({'name': 'No id'});
      expect(result['_id'], isA<String>());
      expect((result['_id'] as String), isNotEmpty);
      await db.close();
    });

    test('a valid key takes the update path on put', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'First'));
      final result = await col.put(_Task(id: id, title: 'Second'));
      expect(result.id, equals(id));
      expect(await col.getVersions(id), hasLength(2));
      await db.close();
    });
  });

  // ── delete ────────────────────────────────────────────────────────────────

  group('delete', () {
    test('deletes existing document', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'To delete'));
      await col.delete(id);
      expect(await col.get(id), isNull);
      await db.close();
    });

    test('delete is a no-op for absent key', () async {
      final (db, col) = await _open();
      await expectLater(col.delete(_key()), completes);
      await db.close();
    });
  });

  // ── update ────────────────────────────────────────────────────────────────

  group('update', () {
    test('reads, modifies, and writes back', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'Draft', done: false));
      final result = await col.update(
        id,
        (t) => _Task(id: t.id, title: t.title, done: true),
      );
      expect(result, isNotNull);
      expect(result!.done, isTrue);
      expect((await col.get(id))!.done, isTrue);
      await db.close();
    });

    test('returns null if document absent', () async {
      final (db, col) = await _open();
      final result = await col.update(_key(), (t) => t);
      expect(result, isNull);
      await db.close();
    });
  });

  // ── getMany / exists ──────────────────────────────────────────────────────

  group('getMany', () {
    test('returns map with nulls for absent keys', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'T'));
      final missing = _key();
      final result = await col.getMany([id, missing]);
      expect(result[id], isNotNull);
      expect(result[missing], isNull);
      await db.close();
    });
  });

  group('exists', () {
    test('true for present key', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'T'));
      expect(await col.exists(id), isTrue);
      await db.close();
    });

    test('false for absent key', () async {
      final (db, col) = await _open();
      expect(await col.exists(_key()), isFalse);
      await db.close();
    });
  });

  // ── putMany ───────────────────────────────────────────────────────────────

  group('putMany', () {
    test('writes all documents', () async {
      final (db, col) = await _open();
      final tasks = [
        _Task(id: _key(), title: 'A'),
        _Task(id: _key(), title: 'B'),
        _Task(id: _key(), title: 'C'),
      ];
      await col.putMany(tasks);
      for (final t in tasks) {
        expect(await col.get(t.id), isNotNull);
      }
      await db.close();
    });
  });

  // ── ReservedFieldException ────────────────────────────────────────────────

  group('ReservedFieldException', () {
    // A codec that deliberately emits a single '_'-prefixed key.
    final badCodecSingle = _BadCodec({'_secret': 'value', 'title': 'ok'});

    // A codec that emits multiple '_'-prefixed keys.
    final badCodecMultiple = _BadCodec({'_foo': 1, '_bar': 2, 'title': 'ok'});

    // A codec that specifically emits '_id', which is the most common mistake.
    final badCodecId = _BadCodec({'_id': 'some-id', 'title': 'ok'});

    // A codec that emits a nested key starting with '_' — this must NOT throw
    // because only top-level keys are reserved.
    final okNestedCodec = _BadCodec({
      'nested': {'_internal': true},
      'title': 'ok',
    });

    test('single _-prefixed key throws ReservedFieldException', () async {
      final (db, _) = await _open();
      final col = db.collection(name: 'tasks', codec: badCodecSingle);
      final task = _Task(id: _key(), title: 'Bad');
      expect(
        () => col.put(task),
        throwsA(
          isA<ReservedFieldException>().having(
            (e) => e.offendingKeys,
            'offendingKeys',
            contains('_secret'),
          ),
        ),
      );
      await db.close();
    });

    test('multiple _-prefixed keys listed in exception', () async {
      final (db, _) = await _open();
      final col = db.collection(name: 'tasks', codec: badCodecMultiple);
      final task = _Task(id: _key(), title: 'Bad');
      expect(
        () => col.put(task),
        throwsA(
          isA<ReservedFieldException>().having(
            (e) => e.offendingKeys,
            'offendingKeys',
            containsAll(['_foo', '_bar']),
          ),
        ),
      );
      await db.close();
    });

    test('_id in encode() output throws ReservedFieldException', () async {
      final (db, _) = await _open();
      final col = db.collection(name: 'tasks', codec: badCodecId);
      final task = _Task(id: _key(), title: 'Bad');
      expect(
        () => col.put(task),
        throwsA(
          isA<ReservedFieldException>().having(
            (e) => e.offendingKeys,
            'offendingKeys',
            contains('_id'),
          ),
        ),
      );
      await db.close();
    });

    test('nested _ field allowed — only top-level is reserved', () async {
      final (db, _) = await _open();
      final col = db.collection(name: 'tasks', codec: okNestedCodec);
      final task = _Task(id: _key(), title: 'Ok');
      // Should complete without error.
      await expectLater(col.put(task), completes);
      await db.close();
    });

    test('ReservedFieldException toString contains offending keys', () {
      final ex = ReservedFieldException(['_id', '_rev']);
      expect(ex.toString(), contains('"_id"'));
      expect(ex.toString(), contains('"_rev"'));
    });

    test('insert also validates reserved keys', () async {
      final (db, _) = await _open();
      final col = db.collection(name: 'tasks', codec: badCodecId);
      final task = _Task(id: '', title: 'Bad');
      expect(() => col.insert(task), throwsA(isA<ReservedFieldException>()));
      await db.close();
    });

    test('replace also validates reserved keys', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'Good'));

      final badCol = db.collection(name: 'tasks', codec: badCodecSingle);
      expect(
        () => badCol.replace(_Task(id: id, title: 'Bad')),
        throwsA(isA<ReservedFieldException>()),
      );
      await db.close();
    });
  });

  // ── watchKey ──────────────────────────────────────────────────────────────

  group('watchKey', () {
    test('emits current value on subscribe', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'Watch me'));
      final value = await col.watchKey(id).first;
      expect(value, isNotNull);
      expect(value!.title, equals('Watch me'));
      await db.close();
    });

    test('emits null for absent key on subscribe', () async {
      final (db, col) = await _open();
      final value = await col.watchKey(_key()).first;
      expect(value, isNull);
      await db.close();
    });

    test('re-emits after put', () async {
      final (db, col) = await _open();
      final id = _key();
      final emitted = <_Task?>[];

      final sub = col.watchKey(id).listen(emitted.add);
      await Future.delayed(Duration.zero); // let first emission arrive

      await col.put(_Task(id: id, title: 'v1'));
      await Future.delayed(Duration.zero);
      await col.put(_Task(id: id, title: 'v2'));
      await Future.delayed(Duration.zero);

      await sub.cancel();
      expect(emitted.length, greaterThanOrEqualTo(2));
      expect(emitted.last!.title, equals('v2'));
      await db.close();
    });

    test('re-emits null after delete', () async {
      final (db, col) = await _open();
      final id = _key();
      await col.put(_Task(id: id, title: 'Temp'));
      final emitted = <_Task?>[];
      final sub = col.watchKey(id).listen(emitted.add);
      await Future.delayed(Duration.zero);

      await col.delete(id);
      await Future.delayed(Duration.zero);

      await sub.cancel();
      expect(emitted.last, isNull);
      await db.close();
    });
  });
}
