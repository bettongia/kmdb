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

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:kmdb/src/encryption/encryption_envelope.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/index/index_manager.dart';
import 'package:kmdb/src/query/index/index_reader.dart';
import 'package:kmdb/src/query/index/index_writer.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Contact {
  const _Contact({required this.id, required this.city, this.tags = const []});
  final String id;
  final String city;
  final List<String> tags;
}

final class _ContactCodec implements KmdbCodec<_Contact> {
  const _ContactCodec();

  @override
  String keyOf(_Contact v) => v.id;

  @override
  _Contact withKey(_Contact v, String key) =>
      _Contact(id: key, city: v.city, tags: v.tags);

  @override
  Map<String, dynamic> encode(_Contact v) => {'city': v.city, 'tags': v.tags};

  @override
  _Contact decode(Map<String, dynamic> j) => _Contact(
    id: j['_id'] as String,
    city: j['city'] as String,
    tags: (j['tags'] as List?)?.cast<String>() ?? [],
  );
}

/// Minimal codec for raw [Map<String,dynamic>] documents.
///
/// [keyOf] reads `_id`; [encode] strips `_id` so the collection can manage it;
/// [decode] passes through the decoded map (which already has `_id` added by
/// the collection layer).
final class _IdentityCodec implements KmdbCodec<Map<String, dynamic>> {
  const _IdentityCodec();

  @override
  String keyOf(Map<String, dynamic> v) => v['_id'] as String;

  @override
  Map<String, dynamic> withKey(Map<String, dynamic> v, String key) => {
    ...v,
    '_id': key,
  };

  @override
  Map<String, dynamic> encode(Map<String, dynamic> v) {
    // Exclude '_id' — the collection layer manages it separately.
    final out = Map<String, dynamic>.from(v)..remove('_id');
    return out;
  }

  @override
  Map<String, dynamic> decode(Map<String, dynamic> j) => j;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _codec = _ContactCodec();
final _gen = SequentialKeyGenerator();
String _key() => _gen.next();

final _cityIndex = IndexDefinition('contacts', 'city');
final _tagsIndex = IndexDefinition('contacts', 'tags[]');

Future<(KmdbDatabase, KmdbCollection<_Contact>)> _openWithIndexes() async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    indexes: [_cityIndex, _tagsIndex],
    config: KvStoreConfig.forTesting(),
  );
  return (db, db.collection(name: 'contacts', codec: _codec));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── IndexWriter — value encoding ──────────────────────────────────────────

  group('IndexWriter.encodeValueHex', () {
    test('string produces non-empty hex', () {
      final h = IndexWriter.encodeValueHex('London');
      expect(h, isNotNull);
      expect(h!.length, greaterThan(0));
    });

    test('different strings produce different hex', () {
      expect(
        IndexWriter.encodeValueHex('London'),
        isNot(equals(IndexWriter.encodeValueHex('Paris'))),
      );
    });

    test('int encoding preserves sort order (positive)', () {
      final h1 = IndexWriter.encodeValueHex(1)!;
      final h2 = IndexWriter.encodeValueHex(2)!;
      expect(h1.compareTo(h2), lessThan(0));
    });

    test('int encoding: negative sorts before positive', () {
      final hNeg = IndexWriter.encodeValueHex(-1)!;
      final hPos = IndexWriter.encodeValueHex(1)!;
      expect(hNeg.compareTo(hPos), lessThan(0));
    });

    test('double encoding preserves sort order', () {
      final h1 = IndexWriter.encodeValueHex(1.5)!;
      final h2 = IndexWriter.encodeValueHex(2.5)!;
      expect(h1.compareTo(h2), lessThan(0));
    });

    test('bool false sorts before true', () {
      final hF = IndexWriter.encodeValueHex(false)!;
      final hT = IndexWriter.encodeValueHex(true)!;
      expect(hF.compareTo(hT), lessThan(0));
    });

    test('map (non-indexable) returns null', () {
      expect(IndexWriter.encodeValueHex(<String, dynamic>{}), isNull);
    });
  });

  // ── IndexWriter add/remove entries ────────────────────────────────────────

  group('IndexWriter add/remove entries', () {
    test('entry namespace encodes field value', () async {
      final batch = WriteBatch();
      await IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: _key(),
        document: {'city': 'London'},
      );
      expect(batch.length, equals(1));
      final expectedNs = (await IndexWriter.indexNamespaceForValue(
        _cityIndex,
        'London',
      ))!;
      expect(batch.entries.first.namespace, equals(expectedNs));
    });

    test('entry key is the document key', () async {
      final docKey = _key();
      final batch = WriteBatch();
      await IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: docKey,
        document: {'city': 'London'},
      );
      expect(batch.entries.first.key, equals(docKey));
    });

    test(
      'fan-out: one entry per array element in separate namespaces',
      () async {
        final batch = WriteBatch();
        final def = IndexDefinition('contacts', 'tags[]');
        await IndexWriter.addEntries(
          batch: batch,
          definition: def,
          docKey: _key(),
          document: {
            'tags': ['dart', 'flutter'],
          },
        );
        expect(batch.length, equals(2));
        // Each element has its own namespace.
        final ns0 = batch.entries[0].namespace;
        final ns1 = batch.entries[1].namespace;
        expect(ns0, isNot(equals(ns1)));
      },
    );

    test('skips null field', () async {
      final batch = WriteBatch();
      await IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: _key(),
        document: {'city': null},
      );
      expect(batch.isEmpty, isTrue);
    });

    test('skips missing field', () async {
      final batch = WriteBatch();
      await IndexWriter.addEntries(
        batch: batch,
        definition: _cityIndex,
        docKey: _key(),
        document: {},
      );
      expect(batch.isEmpty, isTrue);
    });

    test('remove entries adds delete with same namespace and key', () async {
      final docKey = _key();
      final addBatch = WriteBatch();
      await IndexWriter.addEntries(
        batch: addBatch,
        definition: _cityIndex,
        docKey: docKey,
        document: {'city': 'London'},
      );

      final delBatch = WriteBatch();
      await IndexWriter.removeEntries(
        batch: delBatch,
        definition: _cityIndex,
        docKey: docKey,
        document: {'city': 'London'},
      );

      expect(delBatch.length, equals(1));
      expect(delBatch.entries.first.isDelete, isTrue);
      expect(
        delBatch.entries.first.namespace,
        equals(addBatch.entries.first.namespace),
      );
      expect(delBatch.entries.first.key, equals(addBatch.entries.first.key));
    });
  });

  // ── IndexManager state transitions ────────────────────────────────────────

  group('IndexManager states', () {
    test('freshly opened database has undefined index state', () async {
      final (db, _) = await _openWithIndexes();
      final state = await db.indexManager.getState('contacts', 'city');
      expect(state.status, equals(IndexStatus.undefined));
      await db.close();
    });

    test('getOrActivate transitions undefined → building', () async {
      final (db, _) = await _openWithIndexes();
      final state = await db.indexManager.getOrActivate('contacts', 'city');
      expect(state.status, equals(IndexStatus.building));
      await db.close();
    });

    test('index transitions to current after build completes', () async {
      final (db, col) = await _openWithIndexes();
      await col.put(_Contact(id: _key(), city: 'London'));

      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final state = await db.indexManager.getState('contacts', 'city');
      expect(state.status, equals(IndexStatus.current));
      await db.close();
    });

    test('concurrent writes may leave index stale', () async {
      final (db, col) = await _openWithIndexes();

      for (var i = 0; i < 5; i++) {
        await col.put(_Contact(id: _key(), city: 'City$i'));
      }

      await db.indexManager.getOrActivate('contacts', 'city');

      for (var i = 0; i < 3; i++) {
        await col.put(_Contact(id: _key(), city: 'New$i'));
      }

      await Future.delayed(const Duration(milliseconds: 100));

      final state = await db.indexManager.getState('contacts', 'city');
      expect(
        state.status,
        anyOf(equals(IndexStatus.current), equals(IndexStatus.stale)),
      );
      await db.close();
    });
  });

  // ── IndexReader ───────────────────────────────────────────────────────────

  group('IndexReader.lookupByValue', () {
    test('returns doc keys for matching value after build', () async {
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      final k2 = _key();
      final k3 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.put(_Contact(id: k2, city: 'Paris'));
      await col.put(_Contact(id: k3, city: 'London'));

      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(docKeys.toSet(), equals({k1, k3}));
      await db.close();
    });

    test('returns empty for value with no matches', () async {
      final (db, col) = await _openWithIndexes();
      await col.put(_Contact(id: _key(), city: 'London'));

      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'Berlin',
      );
      expect(docKeys, isEmpty);
      await db.close();
    });

    test('fan-out: returns correct doc keys for array index', () async {
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      final k2 = _key();
      await col.put(_Contact(id: k1, city: 'x', tags: ['dart', 'flutter']));
      await col.put(_Contact(id: k2, city: 'x', tags: ['flutter', 'web']));

      await db.indexManager.getOrActivate('contacts', 'tags[]');
      await Future.delayed(const Duration(milliseconds: 100));

      final flutterKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _tagsIndex,
        value: 'flutter',
      );
      expect(flutterKeys.toSet(), equals({k1, k2}));

      final dartKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _tagsIndex,
        value: 'dart',
      );
      expect(dartKeys.toSet(), equals({k1}));
      await db.close();
    });
  });

  // ── Write interception consistency ────────────────────────────────────────

  group('write interception', () {
    test('index entries written after activate + put', () async {
      final (db, col) = await _openWithIndexes();
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 50));

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(docKeys, contains(k1));
      await db.close();
    });

    test('old index entry removed when city changes', () async {
      final (db, col) = await _openWithIndexes();
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 50));

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.put(_Contact(id: k1, city: 'Paris'));

      expect(
        (await IndexReader.lookupByValue(
          store: db.store,
          definition: _cityIndex,
          value: 'London',
        )).contains(k1),
        isFalse,
      );
      expect(
        (await IndexReader.lookupByValue(
          store: db.store,
          definition: _cityIndex,
          value: 'Paris',
        )).contains(k1),
        isTrue,
      );
      await db.close();
    });

    test('index entry removed on document delete', () async {
      final (db, col) = await _openWithIndexes();
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 50));

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.delete(k1);

      final docKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(docKeys, isNot(contains(k1)));
      await db.close();
    });

    test('undefined index produces no write overhead', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        indexes: [_cityIndex],
        config: KvStoreConfig.forTesting(),
      );
      final col = db.collection(name: 'contacts', codec: _codec);

      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London'));

      // The value-specific index namespace should not exist yet.
      final ns = (await IndexWriter.indexNamespaceForValue(
        _cityIndex,
        'London',
      ))!;
      final indexKeys = await db.store.scan(ns).toList();
      expect(indexKeys, isEmpty);
      await db.close();
    });
  });

  // ── IndexManager.removeIndex ──────────────────────────────────────────────

  group('IndexManager.removeIndex', () {
    test(r'removes all $index entries after a build', () async {
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      final k2 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.put(_Contact(id: k2, city: 'Paris'));

      // Activate and wait for build to complete.
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      final stateBefore = await db.indexManager.getState('contacts', 'city');
      expect(stateBefore.status, equals(IndexStatus.current));

      // Remove the index.
      await db.indexManager.removeIndex('contacts', 'city');

      // All index sub-namespaces should be gone.
      final londonKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'London',
      );
      expect(londonKeys, isEmpty);

      final parisKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _cityIndex,
        value: 'Paris',
      );
      expect(parisKeys, isEmpty);
      await db.close();
    });

    test(r'removes $meta state entry after removal', () async {
      final (db, col) = await _openWithIndexes();
      await col.put(_Contact(id: _key(), city: 'London'));
      await db.indexManager.getOrActivate('contacts', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      await db.indexManager.removeIndex('contacts', 'city');

      // State should now be undefined (no persisted state).
      final stateAfter = await db.indexManager.getState('contacts', 'city');
      expect(stateAfter.status, equals(IndexStatus.undefined));
      await db.close();
    });

    test('no-op for an index that was never built', () async {
      final (db, _) = await _openWithIndexes();

      // Index is in undefined state — removeIndex should complete without error.
      await expectLater(
        db.indexManager.removeIndex('contacts', 'city'),
        completes,
      );
      // State is still undefined.
      final state = await db.indexManager.getState('contacts', 'city');
      expect(state.status, equals(IndexStatus.undefined));
      await db.close();
    });

    test('other indexes on same collection are unaffected', () async {
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      await col.put(_Contact(id: k1, city: 'London', tags: ['flutter']));

      await db.indexManager.getOrActivate('contacts', 'city');
      await db.indexManager.getOrActivate('contacts', 'tags[]');
      await Future.delayed(const Duration(milliseconds: 100));

      // Remove only the city index.
      await db.indexManager.removeIndex('contacts', 'city');

      // The tags[] index should still have its entry.
      final tagKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: _tagsIndex,
        value: 'flutter',
      );
      expect(tagKeys, contains(k1));

      // tags[] index state should still be current (or stale, but not gone).
      final tagsState = await db.indexManager.getState('contacts', 'tags[]');
      expect(tagsState.status, isNot(equals(IndexStatus.undefined)));
      await db.close();
    });

    test('removing index on one collection does not affect another', () async {
      final adapter = MemoryStorageAdapter();
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        indexes: [
          IndexDefinition('contacts', 'city'),
          IndexDefinition('items', 'city'),
        ],
        config: KvStoreConfig.forTesting(),
      );
      final itemsCol = db.collection<Map<String, dynamic>>(
        name: 'items',
        codec: _IdentityCodec(),
      );
      final k1 = _key();
      await itemsCol.put({'_id': k1, 'city': 'London'});

      await db.indexManager.getOrActivate('items', 'city');
      await Future.delayed(const Duration(milliseconds: 100));

      // Remove contacts/city (which has no entries) — items/city should be fine.
      await db.indexManager.removeIndex('contacts', 'city');

      final itemsKeys = await IndexReader.lookupByValue(
        store: db.store,
        definition: IndexDefinition('items', 'city'),
        value: 'London',
      );
      expect(itemsKeys, contains(k1));
      await db.close();
    });
  });

  // ── ReservedIndexPathException ────────────────────────────────────────────

  group('ReservedIndexPathException', () {
    test('IndexDefinition with _id path throws immediately', () {
      expect(
        () => IndexDefinition('contacts', '_id'),
        throwsA(
          isA<ReservedIndexPathException>()
              .having((e) => e.namespace, 'namespace', 'contacts')
              .having((e) => e.path, 'path', '_id'),
        ),
      );
    });

    test('IndexDefinition with arbitrary _ prefix throws', () {
      expect(
        () => IndexDefinition('users', '_rev'),
        throwsA(isA<ReservedIndexPathException>()),
      );
    });

    test('nested path containing _ mid-segment does not throw', () {
      // 'meta._internal' starts with 'm', not '_', so it is allowed.
      expect(() => IndexDefinition('users', 'meta._internal'), returnsNormally);
    });

    test('ReservedIndexPathException toString contains path and namespace', () {
      final ex = ReservedIndexPathException('users', '_rev');
      expect(ex.toString(), contains('_rev'));
      expect(ex.toString(), contains('users'));
    });
  });

  // ── IndexDefinition path normalisation ───────────────────────────────────

  group('IndexDefinition path normalisation', () {
    test(r'$.-prefixed path is normalised to bare path', () {
      // "$.address.city" must be stored as "address.city".
      final def = IndexDefinition('contacts', r'$.address.city');
      expect(def.path, equals('address.city'));
    });

    test(r'$.path produces the same indexNamespace as bare path', () {
      final defBare = IndexDefinition('contacts', 'address.city');
      final defSigil = IndexDefinition('contacts', r'$.address.city');
      expect(defSigil.indexNamespace, equals(defBare.indexNamespace));
    });

    test('[*] is rewritten to [] in the stored path', () {
      final def = IndexDefinition('contacts', 'tags[*]');
      expect(def.path, equals('tags[]'));
    });

    test(r'bare $ path throws ArgumentError', () {
      expect(() => IndexDefinition('contacts', r'$'), throwsArgumentError);
    });

    test(
      r'$-prefixed path with dot child is queryable (integration)',
      () async {
        // Define an index using the $.city sigil path.
        final sigilDef = IndexDefinition('contacts', r'$.city');
        // The normalised path is 'city', so the index namespace must match
        // a bare-path definition.
        final bareDef = IndexDefinition('contacts', 'city');
        expect(sigilDef.path, equals(bareDef.path));
        expect(sigilDef.indexNamespace, equals(bareDef.indexNamespace));

        // Full integration: insert a document, activate the index defined with
        // the sigil path, and query it.
        final db = await KmdbDatabase.open(
          path: '/test_sigil',
          adapter: MemoryStorageAdapter(),
          indexes: [sigilDef],
          config: KvStoreConfig.forTesting(),
        );
        addTearDown(db.close);
        addTearDown(MemoryStorageAdapter.releaseAllLocks);

        final col = db.collection<Map<String, dynamic>>(
          name: 'contacts',
          codec: _IdentityCodec(),
        );

        final k1 = _key();
        await col.put({'_id': k1, 'city': 'London'});

        // Activate the index and wait for the build to complete.
        await db.indexManager.getOrActivate('contacts', 'city');
        await Future.delayed(const Duration(milliseconds: 100));

        // Query the index using the normalised (bare) definition.
        final keys = await IndexReader.lookupByValue(
          store: db.store,
          definition: bareDef,
          value: 'London',
        );
        expect(keys, contains(k1));
      },
    );
  });

  // ── checkInterruptedBuilds ────────────────────────────────────────────────

  group('checkInterruptedBuilds', () {
    test(
      'returns events for each index in building state, empty otherwise',
      () async {
        // Exercises IndexManager.checkInterruptedBuilds() (lines 335-341):
        // simulate an interrupted build by writing `building` status to meta,
        // then verify checkInterruptedBuilds() returns the expected event.
        final db = await KmdbDatabase.open(
          path: '/check_interrupted_builds_test',
          adapter: MemoryStorageAdapter(),
          indexes: [IndexDefinition('contacts', 'city')],
          config: KvStoreConfig.forTesting(),
        );
        addTearDown(db.close);
        addTearDown(MemoryStorageAdapter.releaseAllLocks);

        // No build has been started yet — no interrupted builds.
        expect(await db.indexManager.checkInterruptedBuilds(), isEmpty);

        // Directly write a `building` state for the index to simulate an
        // interrupted build (as if the process crashed mid-build). Written to
        // the local-only $$indexstate namespace (moved from `$meta` by
        // 0.10.01 WI-11/SC-10), using the same key IndexManager._persistState
        // computes (MetaStore.indexKey) and the same EncryptionEnvelope
        // wrapping (unencrypted database here, so a plaintext-flagged wrap).
        final stateBytes = Uint8List.fromList(
          cbor.encode(
            CborMap({
              CborString('path'): CborString('city'),
              CborString('namespace'): CborString('contacts'),
              CborString('status'): CborString('building'),
              CborString('builtThrough'): CborSmallInt(0),
              CborString('builtAt'): CborString(''),
            }),
          ),
        );
        final key = MetaStore.indexKey('contacts', 'city');
        final wrapped = await EncryptionEnvelope.wrap(stateBytes, null);
        await db.store.putRaw(kIndexStateNamespace, key, wrapped);

        // Now checkInterruptedBuilds() must report the interrupted build.
        final events = await db.indexManager.checkInterruptedBuilds();
        expect(events, hasLength(1));
        expect(events.first.namespace, equals('contacts'));
        expect(events.first.path, equals('city'));
      },
    );
  });

  // ── SC-10 regression: index state is device-local, not $meta ──────────────

  group('SC-10 — index state is device-local (\$\$indexstate, not \$meta)', () {
    test(
      'a legacy `current` state left in \$meta (e.g. from a peer that synced '
      'before the WI-11 fix, or a pre-fix on-disk database) is dead: the new '
      'read path never consults it, so the index still reports undefined and '
      'rebuilds — it is not silently trusted',
      () async {
        final db = await KmdbDatabase.open(
          path: '/sc10_legacy_meta_dead_test',
          adapter: MemoryStorageAdapter(),
          indexes: [IndexDefinition('contacts', 'city')],
          config: KvStoreConfig.forTesting(),
        );
        addTearDown(db.close);
        addTearDown(MemoryStorageAdapter.releaseAllLocks);

        // Simulate the pre-fix (or cross-device-inherited) shape: a `current`
        // IndexState written under the OLD `$meta` symbolic name, with NO
        // corresponding entry in the new $$indexstate namespace — exactly
        // what a device that pulled a peer's pre-fix `$meta` (or an old
        // on-disk database not yet reopened by fixed code) would have.
        final legacyBytes = Uint8List.fromList(
          cbor.encode(
            CborMap({
              CborString('path'): CborString('city'),
              CborString('namespace'): CborString('contacts'),
              CborString('status'): CborString('current'),
              CborString('builtThrough'): CborSmallInt(0),
              CborString('builtAt'): CborString(''),
            }),
          ),
        );
        await db.store.meta.putRawByName('index:contacts:city', legacyBytes);

        // The new read path must NOT see this as `current` — it only
        // consults $$indexstate, which is empty for this index.
        final state = await db.indexManager.getState('contacts', 'city');
        expect(
          state.status,
          equals(IndexStatus.undefined),
          reason:
              'a legacy \$meta entry must be dead weight, never re-ingested '
              'as though this device had built the index (SC-10)',
        );

        // getOrActivate must trigger a real build from this undefined state,
        // not trust the stale $meta status.
        await db
            .collection(name: 'contacts', codec: _ContactCodec())
            .insert(_Contact(id: '', city: 'London'));
        final activated = await db.indexManager.getOrActivate(
          'contacts',
          'city',
        );
        expect(
          activated.status,
          anyOf(IndexStatus.building, IndexStatus.current),
          reason: 'a fresh build must actually start, not be skipped',
        );
      },
    );
  });

  // ── IndexState.copyWith ───────────────────────────────────────────────────────

  group('IndexState.copyWith', () {
    // Covers the `status: status ?? this.status` branch (line 78 in
    // index_manager.dart) when copyWith is called without a new status value.
    test('copyWith preserves status when not overridden', () {
      const state = IndexState(
        namespace: 'contacts',
        path: 'city',
        status: IndexStatus.current,
        builtThrough: 42,
        builtAt: '2026-01-01',
      );
      // Pass only builtThrough — status should fall back to this.status.
      final updated = state.copyWith(builtThrough: 99);
      expect(updated.status, equals(IndexStatus.current));
      expect(updated.builtThrough, equals(99));
      expect(updated.namespace, equals('contacts'));
    });
  });

  // ── IndexManager — fallback full-scan while building ─────────────────────────

  group('IndexManager — building-state fallback', () {
    test('query on collection while index is building returns correct results '
        'via full-scan fallback', () async {
      // Pre-populate the collection with documents before any index is built.
      final (db, col) = await _openWithIndexes();
      final k1 = _key();
      final k2 = _key();
      await col.put(_Contact(id: k1, city: 'London'));
      await col.put(_Contact(id: k2, city: 'Paris'));

      // getOrActivate transitions undefined → building (launching a background
      // build) and returns the building-state. The returned state is building
      // because the build has just been kicked off but not yet completed.
      final activatedState = await db.indexManager.getOrActivate(
        'contacts',
        'city',
      );
      // getOrActivate returns `building` when the index was `undefined`
      // (first activation). It may return `current` on subsequent calls if
      // the build completed synchronously — accept both.
      expect(
        activatedState.status,
        anyOf(equals(IndexStatus.building), equals(IndexStatus.current)),
      );

      // A full-scan query on the collection must still return the correct
      // documents regardless of index state — the query layer falls back to
      // a full scan when the index is building.
      final results = await col.all().get();
      expect(results.map((c) => c.id).toSet(), equals({k1, k2}));

      await db.close();
    });
  });

  // ── IndexManager.removeIndex ──────────────────────────────────────────────────

  group('IndexManager.removeIndex', () {
    test(
      'removeIndex on an undefined (never-built) index is a no-op',
      () async {
        // Open a database with a city index, but never trigger a build.
        final (db, _) = await _openWithIndexes();

        // Index is in `undefined` state — no sub-namespaces have been written.
        final before = await db.indexManager.getState('contacts', 'city');
        expect(before.status, equals(IndexStatus.undefined));

        // removeIndex on an undefined index must complete without error.
        await expectLater(
          db.indexManager.removeIndex('contacts', 'city'),
          completes,
        );

        // State should still be undefined (no meta entry to clean up).
        final after = await db.indexManager.getState('contacts', 'city');
        expect(after.status, equals(IndexStatus.undefined));

        await db.close();
      },
    );
  });
}
