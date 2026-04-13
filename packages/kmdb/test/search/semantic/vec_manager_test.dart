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

  @override
  Future<(Float32List, bool)> embed(String text) async {
    embedCalled = true;
    if (shouldThrow) throw Exception('inference failure');
    if (text.isEmpty) {
      return (Float32List(384), false);
    }
    final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
    final rng = math.Random(seed);
    final v = Float32List.fromList(
      List.generate(384, (_) => rng.nextDouble() * 2 - 1),
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
        final db = await _openDb();
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
        expect(bytes!.length, equals(384));

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
        final db = await _openDb();
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
        equals(r'$vec:articles:body'),
      );
    });

    test('corpusNamespace returns expected format', () {
      expect(
        VecIndexState.corpusNamespace('articles', 'body'),
        equals(r'$vec:corpus:articles:body'),
      );
    });

    test('truncatedNamespace returns expected format', () {
      expect(
        VecIndexState.truncatedNamespace('articles', 'body'),
        equals(r'$vec:truncated:articles:body'),
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
}

// ── Tracking model for dispose test ───────────────────────────────────────────

final class _TrackingEmbeddingModel implements EmbeddingModel {
  _TrackingEmbeddingModel(this._onDispose);
  final void Function() _onDispose;

  @override
  Future<(Float32List, bool)> embed(String text) async =>
      (Float32List(384), false);

  @override
  void dispose() => _onDispose();
}
