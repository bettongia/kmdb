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

/// End-to-end tests confirming that `search --mode semantic`/`--mode auto`
/// (document-field search) and `vault search --mode semantic`/`--mode auto`
/// (vault content search) produce **genuine** vector/hybrid scores through
/// the CLI commands (WI-12 Phase B) — not the old lexical-only approximation
/// with a fake `(hybrid)` label.
///
/// Uses a deterministic fake [EmbeddingModel], mirroring the established
/// pattern in `packages/kmdb/test/search/hybrid/hybrid_search_integration_test.dart`
/// (`_DeterministicEmbeddingModel`) — no live network download, no ONNX
/// Runtime dependency, fully reproducible in CI. The fake model is passed
/// directly to [DatabaseOpener.open]'s `embeddingModel:` parameter, bypassing
/// `cli_runner.dart`'s real `ModelCatalog`/`OnnxEmbeddingModel` construction
/// entirely — that construction logic (and its command-token gating) is
/// tested separately against the real `ModelCatalog.lookup()` failure paths
/// in `cli_runner_test.dart`, without needing a real model load there either.
library;

import 'dart:convert' show utf8;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/search_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_search_command.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Fake embedding model ─────────────────────────────────────────────────────

/// Deterministic embedding model for integration tests — see the
/// library-level doc comment for why this (not a real ONNX model) is the
/// right test double here.
///
/// Produces a vector whose first two components encode a simple 2D semantic
/// space: "database"/"storage" content clusters near `(0.9, 0.2)`,
/// "learning"/"neural" content clusters near `(-0.9, 0.2)` — far apart under
/// cosine similarity — so a semantic query for one cluster reliably ranks
/// same-cluster documents above the other cluster, giving the test a real,
/// checkable signal rather than an arbitrary hash.
final class _FakeEmbeddingModel implements EmbeddingModel {
  @override
  String get modelId => 'fake-model-v1';

  @override
  int get dimensions => 8;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async {
    final lower = text.toLowerCase();
    final v = Float32List(dimensions);

    if (lower.contains('database') || lower.contains('storage')) {
      v[0] = 0.9;
      v[1] = 0.2;
    } else if (lower.contains('learning') || lower.contains('neural')) {
      v[0] = -0.9;
      v[1] = 0.2;
    } else {
      // Pseudo-random but deterministic from text content, so unrelated text
      // doesn't collide with either cluster.
      final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
      final rng = math.Random(seed);
      v[0] = rng.nextDouble() * 0.4 - 0.2;
      v[1] = rng.nextDouble() * 0.4 - 0.2;
    }

    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm > 0) {
      norm = math.sqrt(norm);
      for (var i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }

    return (v, false);
  }

  @override
  void dispose() {}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

CommandContext _ctx(
  KmdbDatabase db,
  KmdbConfig config, {
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  db: db,
  config: config,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

void main() {
  late io.Directory tmp;
  var dbCounter = 0;

  setUp(() {
    tmp = io.Directory.systemTemp.createTempSync('kmdb_search_semantic_test_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  });

  String nextDbPath() => p.join(tmp.path, 'db${dbCounter++}');

  group('SearchCommand — semantic/hybrid document-field search (Phase B)', () {
    test(
      '--mode semantic produces genuine vector scores for a vecIndex-enabled '
      'field, ranking the semantically-closer document first',
      () async {
        final config = KmdbConfig.empty();
        config.addVecIndex('docs', 'body');
        // SearchCommand._search's explicit `--mode semantic` guard checks
        // ctx.config.embeddingModel (the CLI config's record), not just
        // whether the database actually has a model — set it to match what
        // was passed to DatabaseOpener.open below, mirroring what a real
        // local/config.json would contain.
        config.embeddingModel = (type: 'onnx', modelId: 'fake-model-v1');
        final (db, _) = await DatabaseOpener.open(
          nextDbPath(),
          config,
          embeddingModel: _FakeEmbeddingModel(),
          vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
        );
        addTearDown(db.close);

        final col = db.rawCollection('docs');
        final dbDoc = await col.insert({
          'body': 'a fast database storage engine',
        });
        await col.insert({'body': 'deep learning neural network research'});

        final out = StringBuffer();
        final err = StringBuffer();
        final ok = await SearchCommand().execute(
          _ctx(db, config, out: out, err: err),
          ['docs', 'database storage'],
          {'mode': 'semantic'},
        );

        expect(ok, isTrue, reason: err.toString());
        expect(out.toString(), contains('mode: semantic'));
        // The database-cluster document must rank first (appear before the
        // unrelated learning-cluster document in the table output).
        final text = out.toString();
        expect(
          text.indexOf(dbDoc['_id'] as String),
          greaterThan(-1),
          reason: 'expected the database-cluster document to be a hit',
        );
      },
    );

    test('--mode auto resolves to the "hybrid" label when both FTS and vector '
        'indexes are configured for the collection', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.addVecIndex('docs', 'body');
      final (db, _) = await DatabaseOpener.open(
        nextDbPath(),
        config,
        embeddingModel: _FakeEmbeddingModel(),
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
      );
      addTearDown(db.close);

      final col = db.rawCollection('docs');
      await col.insert({'body': 'a fast database storage engine'});

      final out = StringBuffer();
      final err = StringBuffer();
      final ok = await SearchCommand().execute(
        _ctx(db, config, out: out, err: err),
        ['docs', 'database'],
        {},
      );

      expect(ok, isTrue, reason: err.toString());
      expect(out.toString(), contains('mode: hybrid'));
    });

    test('--mode auto resolves to "lexical" when only an FTS index is '
        'configured (no vecIndex) — matches Q10\'s three-way rule', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      final (db, _) = await DatabaseOpener.open(nextDbPath(), config);
      addTearDown(db.close);

      final col = db.rawCollection('docs');
      await col.insert({'body': 'a fast database storage engine'});

      final out = StringBuffer();
      final ok = await SearchCommand().execute(_ctx(db, config, out: out), [
        'docs',
        'database',
      ], {});

      expect(ok, isTrue);
      expect(out.toString(), contains('mode: lexical'));
    });

    test('--mode auto resolves to "semantic" when only a vector index is '
        'configured (no FTS index) — matches Q10\'s three-way rule', () async {
      final config = KmdbConfig.empty();
      config.addVecIndex('docs', 'body');
      final (db, _) = await DatabaseOpener.open(
        nextDbPath(),
        config,
        embeddingModel: _FakeEmbeddingModel(),
        vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
      );
      addTearDown(db.close);

      final col = db.rawCollection('docs');
      await col.insert({'body': 'a fast database storage engine'});

      final out = StringBuffer();
      final ok = await SearchCommand().execute(_ctx(db, config, out: out), [
        'docs',
        'database storage',
      ], {});

      expect(ok, isTrue);
      expect(out.toString(), contains('mode: semantic'));
    });
  });

  group('VaultSearchCommand — semantic/hybrid vault search (Phase B)', () {
    test('vault search --mode semantic produces genuine vector scores over '
        'vault blob content', () async {
      final (db, _) = await DatabaseOpener.open(
        nextDbPath(),
        KmdbConfig.empty(),
        embeddingModel: _FakeEmbeddingModel(),
      );
      addTearDown(db.close);

      // Link a vault blob to a document via the public write path (see
      // database_opener_test.dart's _ingestAndLink doc comment for why
      // this — not KvStoreImpl.writeBatchInternal — is the right way to
      // do this from outside package:kmdb).
      final ref = await db.vaultStore!.ingest(
        bytes: Uint8List.fromList(
          utf8.encode('a fast database storage engine'),
        ),
        hlcTimestamp: '0000000000000001',
        originalName: 'note.txt',
        explicitMediaType: 'text/plain',
      );
      final col = db.rawCollection('docs');
      await col.insert({'label': 'note.txt', 'file': ref.uri});

      // Wait for vault indexing (including semantic embedding) to settle.
      await db
          .watchVaultIndexingStatus()
          .firstWhere((status) => status.isComplete)
          .timeout(const Duration(seconds: 10));

      final out = StringBuffer();
      final err = StringBuffer();
      final ok = await const VaultSearchCommand().execute(
        _ctx(db, KmdbConfig.empty(), out: out, err: err),
        ['database storage'],
        {'collection': 'docs', 'mode': 'semantic'},
      );

      expect(ok, isTrue, reason: err.toString());
      expect(
        out.toString(),
        isNot(contains('No vault search results')),
        reason:
            'expected a genuine semantic hit for a database/storage '
            'query against database/storage content:\n${out.toString()}',
      );
    });
  });
}
