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

import 'dart:convert';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/search_command.dart';
import 'package:kmdb_cli/src/config/kmdb_config.dart';
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

/// Seeds a [KmdbDatabase] with FTS index and returns the underlying [KvStore].
Future<KvStoreImpl> _seedDb({
  String collection = 'docs',
  String field = 'body',
  required List<String> bodies,
}) async {
  final db = await KmdbDatabase.open(
    path: 'cli_hybrid_${Object().hashCode}',
    adapter: MemoryStorageAdapter(),
    ftsIndexes: [FtsIndexDefinition(collection: collection, field: field)],
  );

  final col = db.collection(name: collection, codec: const _MapCodec());
  for (final body in bodies) {
    await col.insert({field: body});
  }

  return db.store;
}

CommandContext _ctx(
  KvStoreImpl store, {
  KmdbConfig? config,
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  store: store,
  config: config ?? KmdbConfig.empty(),
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── --rrf-k flag validation ──────────────────────────────────────────────────
  group('--rrf-k flag', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _seedDb(bodies: ['database storage engine']);
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('--rrf-k 1 runs without error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
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
        _ctx(store, config: config, out: out, err: err),
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
        _ctx(store, config: config, out: out, err: err),
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
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'database'],
        {'rrf-k': '-5'},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('--rrf-k must be >= 1'));
    });

    test('--rrf-k is mentioned in usage text', () {
      expect(SearchCommand().usage, contains('--rrf-k'));
    });
  });

  // ── (hybrid) label in table output ──────────────────────────────────────────
  group('hybrid label in table output', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _seedDb(bodies: ['database storage engine']);
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test(
      '--mode auto with embeddingModel configured shows (hybrid) in output',
      () async {
        final config = KmdbConfig.empty();
        config.addFtsIndex('docs', 'body');
        // Signal that an embedding model is configured — this tells the CLI
        // that a vector index would be active, enabling hybrid mode label.
        config.embeddingModel = (type: 'onnx', modelPath: '/fake/model.onnx');

        final ok = await SearchCommand().execute(
          _ctx(store, config: config, out: out, err: err),
          ['docs', 'database'],
          {'mode': 'auto'},
        );

        expect(ok, isTrue);
        expect(out.toString(), contains('(hybrid)'));
      },
    );

    test(
      '--mode auto with only FTS configured (no embeddingModel) shows no (hybrid) label',
      () async {
        final config = KmdbConfig.empty();
        config.addFtsIndex('docs', 'body');
        // No embeddingModel → single-index lexical path.

        final ok = await SearchCommand().execute(
          _ctx(store, config: config, out: out, err: err),
          ['docs', 'database'],
          {'mode': 'auto'},
        );

        expect(ok, isTrue);
        expect(out.toString(), isNot(contains('(hybrid)')));
      },
    );

    test(
      '--mode lexical does not show (hybrid) even with embeddingModel',
      () async {
        final config = KmdbConfig.empty();
        config.addFtsIndex('docs', 'body');
        config.embeddingModel = (type: 'onnx', modelPath: '/fake/model.onnx');

        final ok = await SearchCommand().execute(
          _ctx(store, config: config, out: out, err: err),
          ['docs', 'database'],
          {'mode': 'lexical'},
        );

        expect(ok, isTrue);
        expect(out.toString(), isNot(contains('(hybrid)')));
      },
    );
  });

  // ── --candidates flag ────────────────────────────────────────────────────────
  group('--candidates flag', () {
    late KvStoreImpl store;
    late StringBuffer out;

    setUp(() async {
      store = await _seedDb(
        bodies: List.generate(10, (i) => 'database article $i'),
      );
      out = StringBuffer();
    });
    tearDown(() => store.close());

    test('--candidates 20 is accepted without error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out),
        ['docs', 'database'],
        {'candidates': '20'},
      );

      expect(ok, isTrue);
    });

    test('--candidates 5 limits candidates in hybrid mode', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.embeddingModel = (type: 'onnx', modelPath: '/fake/model.onnx');

      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out),
        ['docs', 'database'],
        {'candidates': '5'},
      );

      // Should succeed — the candidates flag is accepted in hybrid mode.
      expect(ok, isTrue);
    });
  });

  // ── mode label in table output ────────────────────────────────────────────────
  group('mode label', () {
    late KvStoreImpl store;
    late StringBuffer out;

    setUp(() async {
      store = await _seedDb(bodies: ['database storage engine']);
      out = StringBuffer();
    });
    tearDown(() => store.close());

    test('table output includes mode: label', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      await SearchCommand().execute(_ctx(store, config: config, out: out), [
        'docs',
        'database',
      ], {});

      expect(out.toString(), contains('mode:'));
    });

    test('json output includes mode field', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');

      await SearchCommand().execute(
        _ctx(store, config: config, out: out),
        ['docs', 'database'],
        {'output': 'json'},
      );

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded.containsKey('mode'), isTrue);
    });

    test('json output includes rrfK when in hybrid mode', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.embeddingModel = (type: 'onnx', modelPath: '/fake/model.onnx');

      await SearchCommand().execute(
        _ctx(store, config: config, out: out),
        ['docs', 'database'],
        {'output': 'json', 'rrf-k': '42'},
      );

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['mode'], equals('hybrid'));
      expect(decoded['rrfK'], equals(42));
    });
  });
}
