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

/// Query-layer tests for UTF-8 namespace encoding (plan M2).
///
/// Covers:
/// - Reactivity: watch() on a non-ASCII namespace fires on write and returns
///   the correct documents.
/// - Secondary indexes: an index on a non-ASCII namespace is built correctly
///   and produces filtered results.
/// - NFC normalisation at the collection level: a collection opened under an
///   NFD-form name resolves to the same namespace as NFC.
library;

import 'dart:async';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Contact {
  const _Contact({required this.id, required this.name, this.city = ''});
  final String id;
  final String name;
  final String city;
}

final class _ContactCodec implements KmdbCodec<_Contact> {
  const _ContactCodec();

  @override
  String keyOf(_Contact v) => v.id;

  @override
  _Contact withKey(_Contact v, String key) =>
      _Contact(id: key, name: v.name, city: v.city);

  @override
  Map<String, dynamic> encode(_Contact v) => {'name': v.name, 'city': v.city};

  @override
  _Contact decode(Map<String, dynamic> j) => _Contact(
    id: j['_id'] as String,
    name: j['name'] as String,
    city: j['city'] as String? ?? '',
  );
}

// ── Helpers ────────────────────────────────────────────────────────────────────

const _codec = _ContactCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

// NFC: precomposed é (U+00E9)
const _nfcCollectionName = '联系人'; // CJK — always NFC
// French: "contacts" with accented character
const _accentedName = 'données';
// NFC/NFD pair for normalisation tests
const _nfcCafe = 'café'; // é as NFC (U+00E9)
// NFD: e + combining acute — same visual appearance, different bytes
// ignore: invalid_unicode_escape_sequences
final _nfdCafe = 'café'; // e + U+0301

Future<KmdbDatabase> _openDb({
  String path = '/nsq_test',
  List<IndexDefinition> indexes = const [],
}) async {
  final adapter = MemoryStorageAdapter();
  return KmdbDatabase.open(
    path: path,
    adapter: adapter,
    indexes: indexes,
    config: KvStoreConfig.forTesting(),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);
  setUp(() => _gen.reset());

  // ── CJK collection name ────────────────────────────────────────────────────

  group('KmdbCollection — CJK namespace', () {
    test('put and get round-trip under CJK collection name', () async {
      final db = await _openDb();
      final col = db.collection(name: _nfcCollectionName, codec: _codec);
      final contact = _Contact(id: _key(), name: 'Alice', city: 'Beijing');
      await col.put(contact);
      final result = await col.get(contact.id);
      expect(result, isNotNull);
      expect(result!.name, equals('Alice'));
      await db.close();
    });

    test(
      'query (full scan) under CJK collection name returns results',
      () async {
        final db = await _openDb();
        final col = db.collection(name: _nfcCollectionName, codec: _codec);
        await col.put(_Contact(id: _key(), name: 'Alice', city: 'Beijing'));
        await col.put(_Contact(id: _key(), name: 'Bob', city: 'Shanghai'));

        final results = await col.where(Field('city').equals('Beijing')).get();
        expect(results.length, equals(1));
        expect(results.first.name, equals('Alice'));
        await db.close();
      },
    );
  });

  // ── Reactivity (watch()) ───────────────────────────────────────────────────

  group('KmdbCollection.watch() — non-ASCII namespace', () {
    test('watch() fires on write under CJK namespace', () async {
      final db = await _openDb();
      final col = db.collection(name: _nfcCollectionName, codec: _codec);

      // Collect up to two watch events (initial empty + first write).
      final events = <List<_Contact>>[];
      final sub = col.all().watch().listen(events.add);

      // Wait for the initial (empty) emission.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await col.put(_Contact(id: _key(), name: 'Alice', city: 'Beijing'));

      // Wait for the reactive update.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      await db.close();

      // There should be at least one event after the write.
      expect(
        events.length,
        greaterThanOrEqualTo(2),
        reason: 'watch() must emit an updated list after a write',
      );
      final lastEvent = events.last;
      expect(lastEvent.length, equals(1));
      expect(lastEvent.first.name, equals('Alice'));
    });

    test('watch() fires on write under accented Latin namespace', () async {
      final db = await _openDb();
      final col = db.collection(name: _accentedName, codec: _codec);

      final events = <List<_Contact>>[];
      final sub = col.all().watch().listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await col.put(_Contact(id: _key(), name: 'Élodie', city: 'Paris'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      await db.close();

      expect(events.length, greaterThanOrEqualTo(2));
      expect(events.last.length, equals(1));
      expect(events.last.first.name, equals('Élodie'));
    });
  });

  // ── Secondary indexes on non-ASCII namespaces ─────────────────────────────

  group('Secondary indexes — non-ASCII namespace', () {
    test('index on CJK namespace is built and queried correctly', () async {
      final nameIndex = IndexDefinition(_nfcCollectionName, 'name');
      final db = await _openDb(indexes: [nameIndex]);
      final col = db.collection(name: _nfcCollectionName, codec: _codec);

      await col.put(_Contact(id: _key(), name: 'Alice', city: 'Beijing'));
      await col.put(_Contact(id: _key(), name: 'Bob', city: 'Shanghai'));

      // Trigger index build by querying.
      final results = await col.where(Field('name').equals('Alice')).get();
      expect(results.length, equals(1));
      expect(results.first.name, equals('Alice'));
      await db.close();
    });

    test(
      'index on accented Latin namespace produces correct results',
      () async {
        final cityIndex = IndexDefinition(_accentedName, 'city');
        final db = await _openDb(indexes: [cityIndex]);
        final col = db.collection(name: _accentedName, codec: _codec);

        await col.put(_Contact(id: _key(), name: 'Élodie', city: 'Paris'));
        await col.put(_Contact(id: _key(), name: 'Claude', city: 'Lyon'));

        final parisContacts = await col
            .where(Field('city').equals('Paris'))
            .get();
        expect(parisContacts.length, equals(1));
        expect(parisContacts.first.name, equals('Élodie'));
        await db.close();
      },
    );
  });

  // ── NFC normalisation at collection level ─────────────────────────────────

  group('NFC normalisation — collection name', () {
    test(
      'NFD and NFC collection names resolve to the same namespace',
      () async {
        final db = await _openDb();
        // Open a collection under the NFC form and write a document.
        final colNfc = db.collection(name: _nfcCafe, codec: _codec);
        await colNfc.put(_Contact(id: _key(), name: 'NFC', city: 'A'));

        // Open a collection under the NFD form — must see the same document.
        final colNfd = db.collection(name: _nfdCafe, codec: _codec);
        final all = await colNfd.all().get();
        expect(
          all.length,
          equals(1),
          reason:
              'NFD collection must share the same namespace as NFC collection',
        );
        expect(all.first.name, equals('NFC'));
        await db.close();
      },
    );

    test('writing under NFD collection and reading under NFC works', () async {
      final db = await _openDb();
      final colNfd = db.collection(name: _nfdCafe, codec: _codec);
      final contact = _Contact(id: _key(), name: 'Written via NFD', city: 'B');
      await colNfd.put(contact);

      final colNfc = db.collection(name: _nfcCafe, codec: _codec);
      final result = await colNfc.get(contact.id);
      expect(
        result,
        isNotNull,
        reason: 'NFC collection must find the NFD-written document',
      );
      expect(result!.name, equals('Written via NFD'));
      await db.close();
    });
  });
}
