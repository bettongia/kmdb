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
    'id': value.id,
    'title': value.title,
    'done': value.done,
  };

  @override
  _Task decode(Map<String, dynamic> json) => _Task(
    id: json['id'] as String,
    title: json['title'] as String,
    done: json['done'] as bool? ?? false,
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

    test('throws DocumentAlreadyExistsException if key exists', () async {
      final (db, col) = await _open();
      // Force same key by resetting generator or just using two inserts
      // if it was random, but here we can just use put then insert with same key.
      final id = '00000000000070008000000000000001';
      final task = _Task(id: id, title: 'Existing');
      await col.put(task);

      // We need to control the generator to trigger the collision in insert()
      final col2 = KmdbCollection(
        namespace: 'tasks',
        codec: _codec,
        database: db,
        keyGenerator: SequentialKeyGenerator(start: 1),
      );

      expect(
        () => col2.insert(_Task(id: '', title: 'Collision')),
        throwsA(isA<DocumentAlreadyExistsException>()),
      );
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
