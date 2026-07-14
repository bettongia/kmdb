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

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/search_command.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A minimal codec for raw map documents.
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

/// A trivial deterministic embedding model — WI-12 Phase B made hybrid mode
/// genuinely depend on a real vector index/model at open time (Q10), so
/// tests that want the mode label to actually resolve to "hybrid" must open
/// the database with a real (if fake) [EmbeddingModel] and matching
/// `vecIndexes:`, not just set `config.embeddingModel` — see
/// `search_semantic_test.dart` for the fuller version of this pattern used
/// for scoring-accuracy tests; this one only needs to make hybrid mode
/// *activate*, not produce a particular ranking.
final class _StubEmbeddingModel implements EmbeddingModel {
  @override
  String get modelId => 'stub-model-v1';

  @override
  int get dimensions => 4;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async => (Float32List(dimensions)..[0] = 1.0, false);

  @override
  void dispose() {}
}

/// Seeds a [KmdbDatabase] with an FTS index and returns the database. When
/// [withVecIndex] is `true`, also configures a real vector index backed by
/// [_StubEmbeddingModel] so hybrid mode genuinely activates (Q10) rather than
/// just being claimed by config.
Future<KmdbDatabase> _seedDb({
  String collection = 'docs',
  String field = 'body',
  required List<String> bodies,
  bool withVecIndex = false,
}) async {
  final db = await KmdbDatabase.open(
    path: 'cli_hybrid_${Object().hashCode}',
    adapter: MemoryStorageAdapter(),
    ftsIndexes: [FtsIndexDefinition(collection: collection, field: field)],
    vecIndexes: withVecIndex
        ? [VecIndexDefinition(collection: collection, field: field)]
        : const [],
    embeddingModel: withVecIndex ? _StubEmbeddingModel() : null,
  );

  final col = db.collection(name: collection, codec: const _MapCodec());
  for (final body in bodies) {
    await col.insert({field: body});
  }

  return db;
}

CommandContext _ctx(
  KmdbDatabase db, {
  KmdbConfig? config,
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  db: db,
  config: config ?? KmdbConfig.empty(),
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── --rrf-k flag validation ──────────────────────────────────────────────────
  group('--rrf-k flag', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _seedDb(bodies: ['database storage engine']);
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('--rrf-k 1 runs without error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'rrf-k': '1'},
      );

      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
    });

    test('--rrf-k 60 (default) runs without error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'rrf-k': '60'},
      );

      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
    });

    test('--rrf-k 0 returns error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'rrf-k': '0'},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('--rrf-k must be >= 1'));
    });

    test('--rrf-k negative value returns error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'rrf-k': '-5'},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('--rrf-k must be >= 1'));
    });

    test('--rrf-k is registered in the arg parser', () {
      final parser = ArgParser();
      SearchCommand().configureArgParser(parser);
      expect(parser.usage, contains('--rrf-k'));
    });
  });

  // ── hybrid mode label in table output (config-derived, Q10) ───────────────
  //
  // Per Q10's decision, the mode label is computed deterministically from
  // config presence — both an FTS index AND a vector index registered for
  // the collection — not from `embeddingModel` alone (that was the old,
  // pre-Phase-B "fake hybrid" heuristic this plan explicitly removed). These
  // tests therefore open the database with a real (if stub) vector index/
  // model via `_seedDb(withVecIndex: true)` so hybrid mode genuinely
  // activates, matching what `DatabaseOpener.open()` does in production
  // (both `ftsIndexes`/`vecIndexes` are built from the same `config`).
  group('hybrid label in table output', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    test('--mode auto with both an FTS and a vector index configured shows '
        'the "hybrid" mode label', () async {
      final db = await _seedDb(
        bodies: ['database storage engine'],
        withVecIndex: true,
      );
      addTearDown(db.close);

      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.addVecIndex('docs', 'body');
      config.embeddingModel = (type: 'onnx', modelId: 'stub-model-v1');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'mode': 'auto'},
      );

      expect(ok, isTrue, reason: err.toString());
      expect(out.toString(), contains('mode: hybrid'));
    });

    test('--mode auto with only FTS configured (no vector index) shows the '
        '"lexical" mode label, not "hybrid"', () async {
      final db = await _seedDb(bodies: ['database storage engine']);
      addTearDown(db.close);

      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      // No vecIndex → lexical-only per Q10's three-way rule, even though
      // this was previously enough (with embeddingModel alone) to trigger
      // the old fake-hybrid heuristic.

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'mode': 'auto'},
      );

      expect(ok, isTrue, reason: err.toString());
      expect(out.toString(), contains('mode: lexical'));
      expect(out.toString(), isNot(contains('hybrid')));
    });

    test('--mode lexical shows "lexical" directly even with both FTS and '
        'vector indexes configured (explicit mode is not computed)', () async {
      final db = await _seedDb(
        bodies: ['database storage engine'],
        withVecIndex: true,
      );
      addTearDown(db.close);

      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.addVecIndex('docs', 'body');
      config.embeddingModel = (type: 'onnx', modelId: 'stub-model-v1');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out, err: err),
        ['docs', 'database'],
        {'mode': 'lexical'},
      );

      expect(ok, isTrue, reason: err.toString());
      expect(out.toString(), contains('mode: lexical'));
      expect(out.toString(), isNot(contains('hybrid')));
    });
  });

  // ── --candidates flag ────────────────────────────────────────────────────────
  group('--candidates flag', () {
    late KmdbDatabase db;
    late StringBuffer out;

    setUp(() async {
      db = await _seedDb(
        bodies: List.generate(10, (i) => 'database article $i'),
      );
      out = StringBuffer();
    });
    tearDown(() => db.close());

    test('--candidates 20 is accepted without error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(db, config: config, out: out),
        ['docs', 'database'],
        {'candidates': '20'},
      );

      expect(ok, isTrue);
    });

    test('--candidates 5 limits candidates in hybrid mode', () async {
      // A separate db (not the shared FTS-only one from setUp) with a real
      // vector index/model so hybrid mode genuinely activates (Q10).
      final hybridDb = await _seedDb(
        bodies: List.generate(10, (i) => 'database article $i'),
        withVecIndex: true,
      );
      addTearDown(hybridDb.close);

      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.addVecIndex('docs', 'body');
      config.embeddingModel = (type: 'onnx', modelId: 'stub-model-v1');

      final err = StringBuffer();
      final ok = await SearchCommand().execute(
        _ctx(hybridDb, config: config, out: out, err: err),
        ['docs', 'database'],
        {'candidates': '5'},
      );

      // Should succeed — the candidates flag is accepted in hybrid mode.
      expect(ok, isTrue, reason: err.toString());
      expect(out.toString(), contains('mode: hybrid'));
    });
  });

  // ── mode label in table output ────────────────────────────────────────────────
  group('mode label', () {
    late KmdbDatabase db;
    late StringBuffer out;

    setUp(() async {
      db = await _seedDb(bodies: ['database storage engine']);
      out = StringBuffer();
    });
    tearDown(() => db.close());

    test('table output includes mode: label', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      await SearchCommand().execute(_ctx(db, config: config, out: out), [
        'docs',
        'database',
      ], {});

      expect(out.toString(), contains('mode:'));
    });

    test('json output includes mode field', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      await SearchCommand().execute(
        _ctx(db, config: config, out: out),
        ['docs', 'database'],
        {'output': 'json'},
      );

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded.containsKey('mode'), isTrue);
    });

    test('json output includes rrfK when in hybrid mode', () async {
      // A separate db (not the shared FTS-only one from setUp) with a real
      // vector index/model so hybrid mode genuinely activates (Q10).
      final hybridDb = await _seedDb(
        bodies: ['database storage engine'],
        withVecIndex: true,
      );
      addTearDown(hybridDb.close);

      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.addVecIndex('docs', 'body');
      config.embeddingModel = (type: 'onnx', modelId: 'stub-model-v1');

      await SearchCommand().execute(
        _ctx(hybridDb, config: config, out: out),
        ['docs', 'database'],
        {'output': 'json', 'rrf-k': '42'},
      );

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['mode'], equals('hybrid'));
      expect(decoded['rrfK'], equals(42));
    });
  });
}
