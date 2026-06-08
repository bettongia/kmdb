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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/reindex_command.dart';
import 'package:test/test.dart';

// ── Fake embedding model ───────────────────────────────────────────────────────

/// A trivial embedding model for CLI unit tests.
///
/// Returns a zero-vector — no real inference; sufficient to populate an index
/// and verify reindex() behaviour without depending on ONNX.
final class _FakeEmbeddingModel implements EmbeddingModel {
  @override
  String get modelId => 'fake-cli-model-v1';

  @override
  int get dimensions => 384;

  @override
  Future<(Float32List, bool)> embed(String text) async =>
      (Float32List(dimensions), false);

  @override
  void dispose() {}
}

// ── Test helpers ───────────────────────────────────────────────────────────────

/// Opens a fresh in-memory database with an optional vector index.
Future<KmdbDatabase> _openVecDb({EmbeddingModel? model}) {
  final m = model ?? _FakeEmbeddingModel();
  return KmdbDatabase.open(
    path: 'reindex_cli_${Object().hashCode}',
    adapter: MemoryStorageAdapter(),
    vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
    embeddingModel: m,
  );
}

/// Opens a fresh in-memory database with NO vector indexes.
Future<KmdbDatabase> _openPlainDb() => KmdbDatabase.open(
  path: 'reindex_plain_${Object().hashCode}',
  adapter: MemoryStorageAdapter(),
);

/// Builds a [CommandContext] with optionally configured embedding model.
CommandContext _ctx(
  KmdbDatabase db, {
  bool withEmbeddingModel = true,
  StringBuffer? out,
  StringBuffer? err,
}) {
  final config = KmdbConfig.empty();
  if (withEmbeddingModel) {
    config.embeddingModel = (type: 'onnx', modelId: 'fake-cli-model-v1');
  }
  return CommandContext(
    db: db,
    config: config,
    out: out ?? StringBuffer(),
    err: err ?? StringBuffer(),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('ReindexCommand — metadata', () {
    test('name is reindex', () {
      expect(const ReindexCommand().name, equals('reindex'));
    });

    test('description is non-empty', () {
      expect(const ReindexCommand().description, isNotEmpty);
    });
  });

  group('ReindexCommand — no embedding model configured', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openPlainDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('returns true when no embeddingModel in config', () async {
      final ok = await const ReindexCommand().execute(
        _ctx(db, withEmbeddingModel: false, out: out, err: err),
        [],
        {},
      );
      expect(ok, isTrue);
    });

    test('prints informational message when no embeddingModel', () async {
      await const ReindexCommand().execute(
        _ctx(db, withEmbeddingModel: false, out: out, err: err),
        [],
        {},
      );
      expect(out.toString(), contains('No embedding model configured'));
    });

    test('writes nothing to err when no embeddingModel', () async {
      await const ReindexCommand().execute(
        _ctx(db, withEmbeddingModel: false, out: out, err: err),
        [],
        {},
      );
      expect(err.toString(), isEmpty);
    });
  });

  group('ReindexCommand — no stale indexes', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openVecDb();
      out = StringBuffer();
      err = StringBuffer();
      // Ensure the index is already current so reindex() is a no-op.
      await db.vecManager!.ensureBuilt('docs', 'body');
    });
    tearDown(() => db.close());

    test('returns true when all indexes are current', () async {
      final ok = await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      expect(ok, isTrue);
    });

    test(
      'reports "No stale vector indexes found" when nothing rebuilt',
      () async {
        await const ReindexCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(out.toString(), contains('No stale vector indexes found'));
      },
    );

    test('writes nothing to err when nothing rebuilt', () async {
      await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      expect(err.toString(), isEmpty);
    });
  });

  group('ReindexCommand — rebuilds stale indexes', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      // Open with undefined indexes (not yet built) — reindex() should rebuild.
      db = await _openVecDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('returns true after rebuilding', () async {
      final ok = await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      expect(ok, isTrue);
    });

    test('reports rebuilt count in output', () async {
      await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      // The undefined 'body' index should have been rebuilt.
      expect(out.toString(), contains('Rebuilt 1 vector index'));
    });

    test('uses correct singular/plural for count=1', () async {
      await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      // "Rebuilt 1 vector index." — not "indexes"
      final output = out.toString();
      expect(output, contains('1 vector index'));
      expect(output, isNot(contains('1 vector indexes')));
    });

    test('writes nothing to err on success', () async {
      await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      expect(err.toString(), isEmpty);
    });
  });

  group('ReindexCommand — database has no vec manager', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      // Plain database: no vecIndexes configured, vecManager is null.
      db = await _openPlainDb();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('returns true even when vecManager is absent', () async {
      // Config has embeddingModel set but db was opened with no vec indexes.
      // KmdbDatabase.reindex() should return 0 safely.
      final ok = await const ReindexCommand().execute(
        _ctx(db, out: out, err: err),
        [],
        {},
      );
      expect(ok, isTrue);
    });

    test(
      'reports "No stale vector indexes found" when vecManager absent',
      () async {
        await const ReindexCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(out.toString(), contains('No stale vector indexes found'));
      },
    );
  });
}
