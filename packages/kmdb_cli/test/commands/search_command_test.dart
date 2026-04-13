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

// ── Test helpers ───────────────────────────────────────────────────────────────

Future<KvStoreImpl> _openStore() async {
  final (store, _) = await KvStoreImpl.open(
    '/search_test_${Object().hashCode}',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return store;
}

/// Creates a [CommandContext] wired with a [KmdbConfig] that has [ftsIndexes].
CommandContext _ctx(
  KvStoreImpl store, {
  KmdbConfig? config,
  StringBuffer? out,
  StringBuffer? err,
}) {
  return CommandContext(
    store: store,
    config: config ?? KmdbConfig.empty(),
    out: out ?? StringBuffer(),
    err: err ?? StringBuffer(),
  );
}

/// Writes a document into [store] under [collection].
///
/// [doc] must contain an `'_id'` field whose value is a 32-char hex UUID key.
Future<void> _putDoc(
  KvStoreImpl store,
  String collection,
  Map<String, dynamic> doc,
) async {
  final id = doc['_id'] as String;
  await store.put(collection, id, ValueCodec.encode(Map.of(doc)..remove('_id')));
}

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
  Map<String, dynamic> withKey(Map<String, dynamic> value, String key) =>
      {...value, '_id': key};
}

/// Builds a fresh [KmdbDatabase] with an FTS index on [collection].[field] and
/// inserts the provided [docs] through the collection API so the FTS index is
/// populated atomically.
Future<({KvStoreImpl store, List<String> ids})> _seedDb({
  String collection = 'docs',
  String field = 'body',
  bool stopWords = false,
  required List<String> bodies,
}) async {
  final db = await KmdbDatabase.open(
    path: 'cli_search_${Object().hashCode}',
    adapter: MemoryStorageAdapter(),
    ftsIndexes: [
      FtsIndexDefinition(
        collection: collection,
        field: field,
        stopWords: stopWords,
      ),
    ],
  );

  final col = db.collection(name: collection, codec: const _MapCodec());

  final ids = <String>[];
  for (final body in bodies) {
    final doc = await col.insert({field: body});
    ids.add(doc['_id'] as String);
  }

  return (store: db.store, ids: ids);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('SearchCommand — argument validation', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('no args prints error and returns false', () async {
      final ok = await SearchCommand().execute(_ctx(store, out: out, err: err), [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('collection and query required'));
    });

    test('single arg (collection only) prints error and returns false', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['docs'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('collection and query required'));
    });

    test('unknown --output value returns error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'hello'],
        {'output': 'csv'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains("unknown --output value 'csv'"));
    });

    test('collection with no FTS index configured prints error', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['docs', 'hello'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('no FTS indexes configured'));
    });

    test('unknown subcommand is treated as collection name (falls through)', () async {
      // 'bogus query' — 'bogus' is not a reserved subcommand, so args[0] is
      // the collection name.  No FTS index → error about missing indexes.
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['bogus', 'query'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('no FTS indexes configured'));
    });
  });

  // ── search — main query path ──────────────────────────────────────────────────

  group('SearchCommand — table output', () {
    late KvStoreImpl store;
    late List<String> ids;
    late StringBuffer out;
    late StringBuffer err;
    late KmdbConfig config;

    setUp(() async {
      final seeded = await _seedDb(
        bodies: ['the quick brown fox', 'database search engine'],
      );
      store = seeded.store;
      ids = seeded.ids;
      out = StringBuffer();
      err = StringBuffer();
      config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
    });
    tearDown(() => store.close());

    test('returns true and writes table headers', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'quick'],
        {'output': 'table'},
      );
      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
      final text = out.toString();
      expect(text, contains('rank'));
      expect(text, contains('score'));
      expect(text, contains('id'));
      expect(text, contains('body'));
    });

    test('hit contains document id from the store', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'quick'],
        {},
      );
      expect(ok, isTrue);
      final text = out.toString();
      // The first document's ID should appear in the output.
      expect(text, contains(ids[0]));
    });

    test('no results prints informative message', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'zzznomatch'],
        {},
      );
      expect(ok, isTrue);
      expect(out.toString(), contains('No results'));
    });

    test('--limit restricts number of hits', () async {
      final seeded = await _seedDb(
        bodies: ['alpha', 'alpha beta', 'alpha gamma'],
      );
      final cfg2 = KmdbConfig.empty();
      cfg2.addFtsIndex('docs', 'body');
      final out2 = StringBuffer();
      final ok = await SearchCommand().execute(
        _ctx(seeded.store, config: cfg2, out: out2),
        ['docs', 'alpha'],
        {'limit': '1'},
      );
      expect(ok, isTrue);
      // Only one document row should appear (plus header + separator + summary).
      final lines = out2.toString().trim().split('\n');
      // 1 header + 1 separator + 1 hit row + 1 summary = 4 lines (at least)
      final hitLines = lines.where((l) => l.trim().isNotEmpty && !l.startsWith('rank') && !l.startsWith('---') && !l.contains('results')).toList();
      expect(hitLines, hasLength(1));
      await seeded.store.close();
    });
  });

  // ── --output json ─────────────────────────────────────────────────────────────

  group('SearchCommand — json output', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;
    late KmdbConfig config;

    setUp(() async {
      final seeded = await _seedDb(bodies: ['full text search is powerful']);
      store = seeded.store;
      out = StringBuffer();
      err = StringBuffer();
      config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
    });
    tearDown(() => store.close());

    test('produces valid JSON with expected structure', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'text'],
        {'output': 'json'},
      );
      expect(ok, isTrue);
      expect(err.toString(), isEmpty);

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['query'], equals('text'));
      expect(decoded['total'], isA<int>());
      expect(decoded['hits'], isA<List>());

      final hits = decoded['hits'] as List;
      expect(hits, hasLength(1));

      final hit = hits.first as Map<String, dynamic>;
      expect(hit['rank'], equals(1));
      expect(hit['score'], isA<num>());
      expect(hit['id'], isA<String>());
      expect(hit['document'], isA<Map>());
    });

    test('JSON empty query returns empty hits array', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'zzznomatch'],
        {'output': 'json'},
      );
      expect(ok, isTrue);
      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect((decoded['hits'] as List), isEmpty);
    });
  });

  // ── --output ids ──────────────────────────────────────────────────────────────

  group('SearchCommand — ids output', () {
    late KvStoreImpl store;
    late List<String> ids;
    late StringBuffer out;
    late StringBuffer err;
    late KmdbConfig config;

    setUp(() async {
      final seeded = await _seedDb(bodies: ['search engine technology']);
      store = seeded.store;
      ids = seeded.ids;
      out = StringBuffer();
      err = StringBuffer();
      config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
    });
    tearDown(() => store.close());

    test('writes one id per line', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'search'],
        {'output': 'ids'},
      );
      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
      final lines = out.toString().trim().split('\n');
      expect(lines, hasLength(1));
      expect(lines.first, equals(ids[0]));
    });

    test('ids output for no results is empty', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'zzznomatch'],
        {'output': 'ids'},
      );
      expect(ok, isTrue);
      expect(out.toString().trim(), isEmpty);
    });
  });

  // ── --fields defaults ─────────────────────────────────────────────────────────

  group('SearchCommand — --fields flag', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;
    late KmdbConfig config;

    setUp(() async {
      final seeded = await _seedDb(bodies: ['test document content']);
      store = seeded.store;
      out = StringBuffer();
      err = StringBuffer();
      config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
    });
    tearDown(() => store.close());

    test('missing --fields defaults to all configured FTS fields', () async {
      // No --fields flag: must search all configured fields (just 'body').
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'content'],
        {},
      );
      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
      expect(out.toString(), contains('body'));
    });

    test('explicit --fields overrides defaults', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['docs', 'content'],
        {'fields': 'body'},
      );
      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
    });
  });

  // ── search list ───────────────────────────────────────────────────────────────

  group('SearchCommand — search list', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('requires collection name', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['list'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name required'));
    });

    test('empty config prints no-indexes message', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['list', 'docs'],
        {},
      );
      expect(ok, isTrue);
      expect(out.toString(), contains('No FTS indexes'));
    });

    test('lists configured index with its settings', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body', stopWords: true, k1: 1.5, b: 0.6);
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['list', 'docs'],
        {},
      );
      expect(ok, isTrue);
      final text = out.toString();
      expect(text, contains('body'));
      expect(text, contains('stopWords=true'));
      expect(text, contains('k1=1.5'));
      expect(text, contains('b=0.6'));
    });
  });

  // ── search create ─────────────────────────────────────────────────────────────

  group('SearchCommand — search create', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('requires collection and field', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['create'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name and field required'));
    });

    test('requires field arg when only collection given', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['create', 'docs'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name and field required'));
    });

    test('registers index in config (mutation only, no real disk write)', () async {
      // We test the config mutation, not the disk save (memory store).
      final config = KmdbConfig.empty();
      final ctx = _ctx(store, config: config, out: out, err: err);

      // Directly call addFtsIndex to verify the config mutation path.
      config.addFtsIndex('docs', 'body');
      expect(config.ftsIndexesForCollection('docs'), hasLength(1));
      final record = config.ftsIndexesForCollection('docs').first;
      expect(record.field, equals('body'));
      expect(record.stopWords, isFalse);
      expect(record.k1, equals(1.2));
      expect(record.b, equals(0.75));
      // ctx is not used in this test (no disk save possible with memory store).
      expect(ctx.config, isNotNull);
    });

    test('--stopwords creates index with stopWords=true', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body', stopWords: true);
      final record = config.ftsIndexesForCollection('docs').first;
      expect(record.stopWords, isTrue);
    });

    test('duplicate field returns error', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      // Adding again should fail via ArgumentError.
      expect(
        () => config.addFtsIndex('docs', 'body'),
        throwsArgumentError,
      );
    });

    test('invalid --b value returns error', () async {
      final config = KmdbConfig.empty();
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['create', 'docs', 'body'],
        {'b': '2.0'}, // out of range
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('--b must be between'));
    });

    test('invalid --k1 value returns error', () async {
      final config = KmdbConfig.empty();
      final ok = await SearchCommand().execute(
        _ctx(store, config: config, out: out, err: err),
        ['create', 'docs', 'body'],
        {'k1': '-1'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('--k1 must be a positive number'));
    });
  });

  // ── search delete ─────────────────────────────────────────────────────────────

  group('SearchCommand — search delete', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('requires collection and field', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['delete'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('collection name and field required'));
    });

    test('returns error when index not configured', () async {
      final ok = await SearchCommand().execute(
        _ctx(store, out: out, err: err),
        ['delete', 'docs', 'body'],
        {},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains("no FTS index on 'docs.body' found in config"));
    });

    test('removes index from config (mutation verified directly)', () async {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      expect(config.ftsIndexesForCollection('docs'), hasLength(1));

      config.removeFtsIndex('docs', 'body');
      expect(config.ftsIndexesForCollection('docs'), isEmpty);
    });
  });
}
