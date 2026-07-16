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

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

// ── Fake embedding model ───────────────────────────────────────────────────────

/// A deterministic fake embedding model for unit testing.
///
/// Returns a unit vector in a direction derived from the input text's hash.
/// Simulates truncation for text longer than 1000 characters.
final class _FakeEmbeddingModel implements EmbeddingModel {
  bool embedCalled = false;
  bool shouldThrow = false;

  /// The [EmbeddingKind] passed to the most recent [embed] call, or `null` if
  /// [embed] has not been called yet. Lets tests assert that [VecManager]
  /// passes `document` at index time and `query` at query time.
  EmbeddingKind? lastKind;

  @override
  String get modelId => 'fake-model-v1';

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async {
    embedCalled = true;
    lastKind = kind;
    if (shouldThrow) throw Exception('inference failure');
    if (text.isEmpty) {
      return (Float32List(dimensions), false);
    }
    final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
    final rng = math.Random(seed);
    final v = Float32List.fromList(
      List.generate(dimensions, (_) => rng.nextDouble() * 2 - 1),
    );
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    for (var i = 0; i < v.length; i++) {
      v[i] /= norm;
    }
    final truncated = text.length > 1000;
    return (v, truncated);
  }

  @override
  void dispose() {}
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/// Opens a fresh in-memory database with a single [VecIndexDefinition].
Future<KmdbDatabase> _openDb({
  String collection = 'docs',
  String field = 'body',
  _FakeEmbeddingModel? model,
}) {
  final m = model ?? _FakeEmbeddingModel();
  return KmdbDatabase.open(
    path: 'vec_mgr_${Object().hashCode}',
    adapter: MemoryStorageAdapter(),
    vecIndexes: [VecIndexDefinition(collection: collection, field: field)],
    embeddingModel: m,
  );
}

/// A minimal codec for [Map<String, dynamic>] documents.
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

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  // ── interceptWrite — insert ─────────────────────────────────────────────────
  //
  // Vector interception only fires when the index is 'current'. The pattern
  // is: call ensureBuilt() on an empty namespace to transition the index to
  // 'current', then insert documents — each insert is intercepted.

  group('interceptWrite — insert', () {
    test(
      'stores a 384-byte quantised vector under the correct namespace',
      () async {
        final model = _FakeEmbeddingModel();
        final db = await _openDb(model: model);
        final store = db.store;
        final col = db.collection(name: 'docs', codec: _codec);

        // Bring index to 'current' before writing.
        await db.vecManager!.ensureBuilt('docs', 'body');

        final doc = await col.insert({'body': 'semantic search engine'});
        final id = doc['_id'] as String;

        final bytes = await store.get(
          VecIndexState.vecNamespace('docs', 'body'),
          id,
        );
        expect(bytes, isNotNull);
        // 384 quantised SQ8 bytes + a 1-byte EncryptionFlag prefix
        // (Encryption confidentiality reconciliation plan, Phase 1 — every
        // stored value is now flag-prefixed, even in an unencrypted database;
        // see EncryptionEnvelope). This is a deliberate on-disk format
        // change, not "byte-for-byte unchanged" from the pre-plan format.
        expect(bytes!.length, equals(384 + 1));
        // Index-time embedding must pass EmbeddingKind.document.
        expect(model.lastKind, equals(EmbeddingKind.document));

        await db.close();
      },
    );

    test('increments corpus n on insert', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      await col.insert({'body': 'document one'});
      await col.insert({'body': 'document two'});

      final corpusBytes = await store.get(
        VecIndexState.corpusNamespace('docs', 'body'),
        VecIndexState.corpusSentinelKey,
      );
      expect(corpusBytes, isNotNull);

      await db.close();
    });

    test('does not store a vector when field is absent', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'title': 'no body field'});
      final id = doc['_id'] as String;

      final bytes = await store.get(
        VecIndexState.vecNamespace('docs', 'body'),
        id,
      );
      expect(bytes, isNull);

      await db.close();
    });

    test(
      'writes truncation marker for field value > 1000 chars (simulated)',
      () async {
        final db = await _openDb();
        final store = db.store;
        final col = db.collection(name: 'docs', codec: _codec);

        await db.vecManager!.ensureBuilt('docs', 'body');

        // _FakeEmbeddingModel returns truncated=true for text.length > 1000.
        final doc = await col.insert({'body': 'a' * 1001});
        final id = doc['_id'] as String;

        final truncatedBytes = await store.get(
          VecIndexState.truncatedNamespace('docs', 'body'),
          id,
        );
        expect(truncatedBytes, isNotNull);

        await db.close();
      },
    );

    test('does not write truncation marker for short field values', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'body': 'short text'});
      final id = doc['_id'] as String;

      final truncatedBytes = await store.get(
        VecIndexState.truncatedNamespace('docs', 'body'),
        id,
      );
      expect(truncatedBytes, isNull);

      await db.close();
    });
  });

  // ── interceptDelete ─────────────────────────────────────────────────────────

  group('interceptDelete', () {
    test('removes vector entry on delete', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'body': 'to be deleted'});
      final id = doc['_id'] as String;

      final before = await store.get(
        VecIndexState.vecNamespace('docs', 'body'),
        id,
      );
      expect(before, isNotNull);

      await col.delete(id);

      final after = await store.get(
        VecIndexState.vecNamespace('docs', 'body'),
        id,
      );
      expect(after, isNull);

      await db.close();
    });

    test('removes truncation marker on delete', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'body': 'a' * 1001});
      final id = doc['_id'] as String;

      expect(
        await store.get(VecIndexState.truncatedNamespace('docs', 'body'), id),
        isNotNull,
      );

      await col.delete(id);

      expect(
        await store.get(VecIndexState.truncatedNamespace('docs', 'body'), id),
        isNull,
      );

      await db.close();
    });

    test('delete of document with no vector entry is a no-op', () async {
      final db = await _openDb();
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      // Insert a document with no indexed field — no vector written.
      final doc = await col.insert({'title': 'no body'});
      final id = doc['_id'] as String;

      // Delete should not throw even though there is no vector entry.
      await expectLater(col.delete(id), completes);

      await db.close();
    });
  });

  // ── interceptUpdate ─────────────────────────────────────────────────────────

  group('interceptUpdate', () {
    test(
      'overwrites vector on update — new bytes differ from original',
      () async {
        final model = _FakeEmbeddingModel();
        final db = await _openDb(model: model);
        final store = db.store;
        final col = db.collection(name: 'docs', codec: _codec);

        await db.vecManager!.ensureBuilt('docs', 'body');

        final doc = await col.insert({'body': 'original text'});
        final id = doc['_id'] as String;

        final before = Uint8List.fromList(
          (await store.get(VecIndexState.vecNamespace('docs', 'body'), id))!,
        );

        await col.put({...doc, 'body': 'completely different text'});

        final after = await store.get(
          VecIndexState.vecNamespace('docs', 'body'),
          id,
        );

        expect(after, isNotNull);
        expect(after, isNot(equals(before)));
        // Update-time re-embedding must also pass EmbeddingKind.document.
        expect(model.lastKind, equals(EmbeddingKind.document));

        await db.close();
      },
    );

    test('adds truncation marker when update makes field long', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'body': 'short'});
      final id = doc['_id'] as String;

      expect(
        await store.get(VecIndexState.truncatedNamespace('docs', 'body'), id),
        isNull,
      );

      await col.put({...doc, 'body': 'a' * 1001});

      expect(
        await store.get(VecIndexState.truncatedNamespace('docs', 'body'), id),
        isNotNull,
      );

      await db.close();
    });

    test('removes truncation marker when update makes field short', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'body': 'a' * 1001});
      final id = doc['_id'] as String;

      expect(
        await store.get(VecIndexState.truncatedNamespace('docs', 'body'), id),
        isNotNull,
      );

      await col.put({...doc, 'body': 'now short'});

      expect(
        await store.get(VecIndexState.truncatedNamespace('docs', 'body'), id),
        isNull,
      );

      await db.close();
    });

    test('corpus n is unchanged on update', () async {
      final db = await _openDb();
      final store = db.store;
      final col = db.collection(name: 'docs', codec: _codec);

      await db.vecManager!.ensureBuilt('docs', 'body');

      final doc = await col.insert({'body': 'document one'});

      // Record corpus bytes after insert.
      final corpusBefore = await store.get(
        VecIndexState.corpusNamespace('docs', 'body'),
        VecIndexState.corpusSentinelKey,
      );
      expect(corpusBefore, isNotNull);

      // Update the document body.
      await col.put({...doc, 'body': 'updated body text'});

      final corpusAfter = await store.get(
        VecIndexState.corpusNamespace('docs', 'body'),
        VecIndexState.corpusSentinelKey,
      );

      // Corpus bytes are identical — n unchanged by update.
      expect(corpusAfter, equals(corpusBefore));

      await db.close();
    });
  });

  // ── VecIndexState CBOR round-trip ───────────────────────────────────────────

  group('VecIndexState serialisation', () {
    test('round-trip through CBOR bytes preserves all fields', () {
      const original = VecIndexState(
        namespace: 'articles',
        field: 'body',
        status: VecIndexStatus.current,
        builtThrough: 'abc123',
        builtAt: '2026-04-14T00:00:00.000Z',
      );
      final bytes = original.toBytes();
      final restored = VecIndexState.fromBytes('articles', 'body', bytes);

      expect(restored.namespace, equals('articles'));
      expect(restored.field, equals('body'));
      expect(restored.status, equals(VecIndexStatus.current));
      expect(restored.builtThrough, equals('abc123'));
      expect(restored.builtAt, equals('2026-04-14T00:00:00.000Z'));
    });

    test('fromBytes with null returns undefined state', () {
      final state = VecIndexState.fromBytes('ns', 'field', null);
      expect(state.status, equals(VecIndexStatus.undefined));
    });

    test('fromBytes with empty bytes returns undefined state', () {
      final state = VecIndexState.fromBytes('ns', 'field', Uint8List(0));
      expect(state.status, equals(VecIndexStatus.undefined));
    });

    test('fromBytes with corrupt bytes returns undefined state', () {
      final state = VecIndexState.fromBytes(
        'ns',
        'field',
        Uint8List.fromList([0, 1, 2]),
      );
      expect(state.status, equals(VecIndexStatus.undefined));
    });

    test('all VecIndexStatus values survive CBOR round-trip', () {
      for (final status in VecIndexStatus.values) {
        final state = VecIndexState(
          namespace: 'ns',
          field: 'f',
          status: status,
        );
        final restored = VecIndexState.fromBytes('ns', 'f', state.toBytes());
        expect(restored.status, equals(status));
      }
    });
  });

  // ── Key helpers ────────────────────────────────────────────────────────────

  group('VecIndexState key helpers', () {
    test('vecNamespace returns expected format', () {
      expect(
        VecIndexState.vecNamespace('articles', 'body'),
        equals(r'$$vec:articles:body'),
      );
    });

    test('corpusNamespace returns expected format', () {
      expect(
        VecIndexState.corpusNamespace('articles', 'body'),
        equals(r'$$vec:corpus:articles:body'),
      );
    });

    test('truncatedNamespace returns expected format', () {
      expect(
        VecIndexState.truncatedNamespace('articles', 'body'),
        equals(r'$$vec:truncated:articles:body'),
      );
    });

    test('metaKey returns expected format (no dollar prefix)', () {
      expect(
        VecIndexState.metaKey('articles', 'body'),
        equals('vec:articles:body'),
      );
    });
  });

  // ── Inference failure ──────────────────────────────────────────────────────

  group('inference failure handling', () {
    test('throws StateError when embed throws during insert', () async {
      final model = _FakeEmbeddingModel();
      final db = await KmdbDatabase.open(
        path: 'vec_err_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        embeddingModel: model,
      );
      final col = db.collection(name: 'docs', codec: _codec);

      // Bring index to 'current' before writing.
      await db.vecManager!.ensureBuilt('docs', 'body');

      // Now make embed throw on the next call.
      model.shouldThrow = true;

      await expectLater(
        () => col.insert({'body': 'will fail'}),
        throwsA(isA<StateError>()),
      );

      await db.close();
    });
  });

  // ── Model identity — mismatch detection ────────────────────────────────────

  group('model identity', () {
    test('reopening with a different model id marks the index stale', () async {
      // Step 1: build the index with model-A.
      final path = 'vec_identity_${Object().hashCode}';
      final adapterA = MemoryStorageAdapter();
      final modelA = _ConfigurableIdEmbeddingModel('model-a');
      final dbA = await KmdbDatabase.open(
        path: path,
        adapter: adapterA,
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        embeddingModel: modelA,
      );
      final colA = dbA.collection(name: 'docs', codec: _codec);
      await dbA.vecManager!.ensureBuilt('docs', 'body');
      await colA.insert({'body': 'hello world'});
      await dbA.close();

      // Step 2: reopen the same adapter (same data) with model-B.
      // checkAndTransitionOnOpen should detect the modelId mismatch.
      final modelB = _ConfigurableIdEmbeddingModel('model-b');
      final dbB = await KmdbDatabase.open(
        path: path, // same path so memory adapter reuses the same lock key
        adapter: adapterA, // reuse the same in-memory store
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        embeddingModel: modelB,
      );

      // The index should be stale because model-b != model-a.
      final state = await _loadVecState(dbB, 'docs', 'body');
      expect(state.status, equals(VecIndexStatus.stale));

      await dbB.close();
    });

    test(
      'reopening with the same model id does not mark the index stale',
      () async {
        final path = 'vec_same_model_${Object().hashCode}';
        final adapter = MemoryStorageAdapter();
        final modelFirst = _ConfigurableIdEmbeddingModel('same-model');
        final dbFirst = await KmdbDatabase.open(
          path: path,
          adapter: adapter,
          vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
          embeddingModel: modelFirst,
        );
        await dbFirst.vecManager!.ensureBuilt('docs', 'body');
        await dbFirst.close();

        // Reopen with the identical model id — index should stay current.
        final modelSecond = _ConfigurableIdEmbeddingModel('same-model');
        final dbSecond = await KmdbDatabase.open(
          path: path,
          adapter: adapter,
          vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
          embeddingModel: modelSecond,
        );

        final state = await _loadVecState(dbSecond, 'docs', 'body');
        expect(state.status, equals(VecIndexStatus.current));

        await dbSecond.close();
      },
    );

    test(
      'index with empty stored modelId is treated as a match (pre-identity)',
      () async {
        final pathA = 'vec_empty_id_${Object().hashCode}';
        final adapter = MemoryStorageAdapter();

        // Open without building — state is undefined (empty modelId).
        final modelA = _ConfigurableIdEmbeddingModel('any-model');
        final dbA = await KmdbDatabase.open(
          path: pathA,
          adapter: adapter,
          vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
          embeddingModel: modelA,
        );
        // Do NOT call ensureBuilt — state stays undefined with empty modelId.

        // The undefined index must not be marked stale (empty id = no mismatch).
        var state = await _loadVecState(dbA, 'docs', 'body');
        expect(state.status, equals(VecIndexStatus.undefined));
        expect(state.modelId, isEmpty);

        await dbA.close();

        // Reopen — checkAndTransitionOnOpen sees empty modelId → no stale mark.
        final dbB = await KmdbDatabase.open(
          path: pathA,
          adapter: adapter,
          vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
          embeddingModel: modelA,
        );
        state = await _loadVecState(dbB, 'docs', 'body');
        // Still undefined, not stale — empty id is a match.
        expect(state.status, equals(VecIndexStatus.undefined));

        await dbB.close();
      },
    );

    test('ensureBuilt stamps modelId on first build', () async {
      final adapter = MemoryStorageAdapter();
      const modelId = 'stamp-test-model';
      final model = _ConfigurableIdEmbeddingModel(modelId);

      final db = await KmdbDatabase.open(
        path: 'vec_stamp_${Object().hashCode}',
        adapter: adapter,
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        embeddingModel: model,
      );

      // Before build: modelId is empty.
      var state = await _loadVecState(db, 'docs', 'body');
      expect(state.modelId, isEmpty);

      await db.vecManager!.ensureBuilt('docs', 'body');

      // After build: modelId is stamped.
      state = await _loadVecState(db, 'docs', 'body');
      expect(state.modelId, equals(modelId));
      expect(state.status, equals(VecIndexStatus.current));

      await db.close();
    });
  });

  // ── reindex() ──────────────────────────────────────────────────────────────

  group('reindex()', () {
    test('returns count of rebuilt indexes', () async {
      final path = 'vec_reindex_${Object().hashCode}';
      final adapter = MemoryStorageAdapter();
      final modelA = _ConfigurableIdEmbeddingModel('model-a');
      final dbA = await KmdbDatabase.open(
        path: path,
        adapter: adapter,
        vecIndexes: [
          VecIndexDefinition(collection: 'docs', field: 'body'),
          VecIndexDefinition(collection: 'docs', field: 'title'),
        ],
        embeddingModel: modelA,
      );
      // Build first index, leave second undefined.
      await dbA.vecManager!.ensureBuilt('docs', 'body');
      await dbA.close();

      // Reopen with a different model — body should be stale, title undefined.
      final modelB = _ConfigurableIdEmbeddingModel('model-b');
      final dbB = await KmdbDatabase.open(
        path: path,
        adapter: adapter,
        vecIndexes: [
          VecIndexDefinition(collection: 'docs', field: 'body'),
          VecIndexDefinition(collection: 'docs', field: 'title'),
        ],
        embeddingModel: modelB,
      );

      // Both stale (body) and undefined (title) are rebuilt by reindex().
      final count = await dbB.reindex();
      expect(count, equals(2));

      // Both fields should now be current.
      final bodyState = await _loadVecState(dbB, 'docs', 'body');
      final titleState = await _loadVecState(dbB, 'docs', 'title');
      expect(bodyState.status, equals(VecIndexStatus.current));
      expect(titleState.status, equals(VecIndexStatus.current));

      await dbB.close();
    });

    test('returns 0 when all indexes are already current', () async {
      final db = await _openDb();
      await db.vecManager!.ensureBuilt('docs', 'body');

      final count = await db.reindex();
      expect(count, equals(0));

      await db.close();
    });

    test('KmdbDatabase.reindex() returns 0 when no vecManager', () async {
      // Open a database with no vector indexes — vecManager is null.
      final db = await KmdbDatabase.open(
        path: 'no_vec_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
      );
      final count = await db.reindex();
      expect(count, equals(0));
      await db.close();
    });
  });

  // ── close() disposes model ─────────────────────────────────────────────────

  group('KmdbDatabase.close()', () {
    test('close() calls dispose on embedding model', () async {
      var disposeCalled = false;
      final model = _TrackingEmbeddingModel(() => disposeCalled = true);
      final db = await KmdbDatabase.open(
        path: 'vec_close_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        embeddingModel: model,
      );

      expect(disposeCalled, isFalse);
      await db.close();
      expect(disposeCalled, isTrue);
    });
  });

  // ── Corrupted encrypted SQ8 entry at query time (docs/roadmap/0_09.md) ────
  //
  // The corruption guard (`unwrapped.length != expectedByteLen` in
  // `VecManager._scoreField`) is unit-tested against `EncryptionEnvelope`
  // directly elsewhere, but nothing seeds a genuinely-corrupted *encrypted*
  // SQ8 entry into a real index and exercises the full integration path —
  // encrypted-index query -> corrupted entry -> skip, not crash -- end to
  // end. This closes that gap.
  group('corrupted encrypted SQ8 entry at query time', () {
    test('search skips a corrupted encrypted vector entry without throwing, '
        'and still returns the valid one', () async {
      final result = await EncryptionConfig.createResult(
        passphrase: 'test-passphrase-123',
      );
      final db = await KmdbDatabase.open(
        path: 'vec_corrupt_enc_${Object().hashCode}',
        adapter: MemoryStorageAdapter(),
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        embeddingModel: _FakeEmbeddingModel(),
        encryptionConfig: result.config,
      );
      final col = db.collection(name: 'docs', codec: _codec);

      final validDoc = await col.insert({
        'body': 'a valid searchable document',
      });
      final validId = validDoc['_id'] as String;
      final corruptDoc = await col.insert({'body': 'a document to corrupt'});
      final corruptId = corruptDoc['_id'] as String;

      // Build the index for real first — corrupting before the build would
      // just be overwritten by it. Only then overwrite the corrupt
      // document's real (encrypted) vector entry with garbage bytes that
      // are undecodable by EncryptionEnvelope.unwrap, simulating on-disk
      // corruption of an already-encrypted entry.
      await db.reindex();
      final vecNamespace = VecIndexState.vecNamespace('docs', 'body');
      // KvStoreImpl.put() rejects writes to `$`-prefixed system namespaces;
      // writeBatchInternal() is the same internal escape hatch the Query
      // Layer itself uses for index writes (and other corruption tests in
      // this suite, e.g. fts_manager_test.dart, already rely on).
      await db.store.writeBatchInternal(
        WriteBatch()
          ..put(vecNamespace, corruptId, Uint8List.fromList([1, 2, 3, 4, 5])),
      );

      final searchResult = await col.search(
        'valid searchable document',
        fields: ['body'],
        mode: SearchMode.semantic,
      );

      final ids = searchResult.hits.map((h) => h.id).toList();
      expect(ids, contains(validId));
      expect(ids, isNot(contains(corruptId)));

      await db.close();
    });
  });
}

// ── Configurable-id model for identity tests ──────────────────────────────────

/// An embedding model whose [modelId] is set at construction time.
///
/// Used by model-identity tests to simulate reopening with a different model.
final class _ConfigurableIdEmbeddingModel implements EmbeddingModel {
  _ConfigurableIdEmbeddingModel(this._modelId);

  final String _modelId;

  @override
  String get modelId => _modelId;

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async => (Float32List(dimensions), false);

  @override
  void dispose() {}
}

// ── Helper: read VecIndexState from $meta ─────────────────────────────────────

/// Loads the stored [VecIndexState] for [namespace]/[field] from [db]'s
/// `$meta` namespace via the [MetaStore] API.
///
/// Returns the `undefined` sentinel when no state has been persisted yet.
Future<VecIndexState> _loadVecState(
  KmdbDatabase db,
  String namespace,
  String field,
) async {
  // VecManager stores state via MetaStore.getRawByName / putRawByName.
  // Use the same API here to read without going through the UUID-keyed path.
  final bytes = await db.store.meta.getRawByName(
    VecIndexState.metaKey(namespace, field),
  );
  return VecIndexState.fromBytes(namespace, field, bytes);
}

// ── Tracking model for dispose test ───────────────────────────────────────────

final class _TrackingEmbeddingModel implements EmbeddingModel {
  _TrackingEmbeddingModel(this._onDispose);
  final void Function() _onDispose;

  @override
  String get modelId => 'tracking-model-v1';

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async => (Float32List(dimensions), false);

  @override
  void dispose() => _onDispose();
}
