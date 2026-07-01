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

/// Tests for [VaultSearchCommand], [VaultReindexCommand], and
/// [VaultStatusCommand] (WI-3 Step 13).
///
/// These tests focus on:
/// - Error handling (missing vault, missing vault search config, missing args)
/// - Output structure when vault search is configured
/// - Metadata contract (name, description, usage, configureArgParser)
///
/// Note: Full search result rendering requires a real [VaultSearchManager]
/// which indexes blobs asynchronously. The majority of the search path is
/// already covered by VaultSearchManager and VaultSearcher unit tests in the
/// kmdb package. These CLI tests verify the command wiring and error paths.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_reindex_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_search_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_status_command.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// [VaultStore] subclass that overrides [listFilesRecursive] so it works with
/// the flat [MemoryStorageAdapter] key store used in tests.
class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter mem, String dbPath)
    : _mem = mem,
      super(adapter: mem, dbDir: dbPath);

  final MemoryStorageAdapter _mem;

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return [
      for (final path in _mem.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Counter to give each test a unique db path and avoid [LockException].
var _counter = 0;
String _uniquePath() => '/vault_search_cli_${_counter++}';

/// Opens a [KmdbDatabase] with no vault — for testing "vault not configured"
/// error paths.
Future<KmdbDatabase> _openNoVaultDb() => KmdbDatabase.open(
  path: _uniquePath(),
  adapter: MemoryStorageAdapter(),
  config: KvStoreConfig.forTesting(),
);

/// Opens a [KmdbDatabase] with a vault store but no vault search config.
Future<KmdbDatabase> _openVaultNoSearchDb() async {
  final path = _uniquePath();
  final mem = MemoryStorageAdapter();
  final vault = _TestVaultStore(mem, path);
  return KmdbDatabase.open(
    path: path,
    adapter: mem,
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
}

/// Opens a [KmdbDatabase] with vault and vault search configured.
Future<KmdbDatabase> _openVaultSearchDb() async {
  final path = _uniquePath();
  final mem = MemoryStorageAdapter();
  final vault = _TestVaultStore(mem, path);
  return KmdbDatabase.open(
    path: path,
    adapter: mem,
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
    vaultSearch: VaultSearchConfig(),
  );
}

/// Ingests a small text blob into [vault] and returns the sha256.
Future<String> _ingest(VaultStore vault) async {
  final ref = await vault.ingest(
    bytes: Uint8List.fromList(utf8.encode('hello world this is a test')),
    hlcTimestamp: '0000000000000001',
    originalName: 'test.txt',
  );
  return ref.sha256;
}

/// Builds a [CommandContext] backed by [db].
CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── VaultSearchCommand ─────────────────────────────────────────────────────

  group('VaultSearchCommand', () {
    group('metadata', () {
      test(
        'name is search',
        () => expect(const VaultSearchCommand().name, equals('search')),
      );
      test(
        'description is non-empty',
        () => expect(const VaultSearchCommand().description, isNotEmpty),
      );
      test(
        'usage is non-empty',
        () => expect(const VaultSearchCommand().usage, isNotEmpty),
      );
      test('configureArgParser completes normally', () {
        expect(
          () => const VaultSearchCommand().configureArgParser(ArgParser()),
          returnsNormally,
        );
      });
    });

    group('vault not configured', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openNoVaultDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when no vault store', () async {
        final ok = await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {'collection': 'docs'},
        );
        expect(ok, isFalse);
      });

      test('writes error message when no vault store', () async {
        await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {'collection': 'docs'},
        );
        expect(err.toString(), contains('Vault is not available'));
      });
    });

    group('vault search not configured', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultNoSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when no vault search config', () async {
        final ok = await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {'collection': 'docs'},
        );
        expect(ok, isFalse);
      });

      test('reports vault search not configured error', () async {
        await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {'collection': 'docs'},
        );
        expect(err.toString(), contains('Vault search is not configured'));
      });
    });

    group('missing required flags/args', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when --collection not supplied', () async {
        final ok = await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {}, // no --collection
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('--collection'));
      });

      test('returns false when query is empty', () async {
        final ok = await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          [], // no query
          {'collection': 'docs'},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('query argument'));
      });
    });

    group('search against empty collection', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns true with empty results when no blobs indexed', () async {
        final ok = await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {'collection': 'docs'},
        );
        expect(ok, isTrue);
      });

      test('prints no-results message for empty collection', () async {
        await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          ['hello world'],
          {'collection': 'docs'},
        );
        expect(out.toString(), contains('No vault search results'));
      });
    });
  });

  // ── VaultReindexCommand ────────────────────────────────────────────────────

  group('VaultReindexCommand', () {
    group('metadata', () {
      test(
        'name is reindex',
        () => expect(const VaultReindexCommand().name, equals('reindex')),
      );
      test(
        'description is non-empty',
        () => expect(const VaultReindexCommand().description, isNotEmpty),
      );
      test(
        'usage is non-empty',
        () => expect(const VaultReindexCommand().usage, isNotEmpty),
      );
      test('configureArgParser completes normally', () {
        expect(
          () => const VaultReindexCommand().configureArgParser(ArgParser()),
          returnsNormally,
        );
      });
    });

    group('vault not configured', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openNoVaultDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when no vault store', () async {
        final ok = await const VaultReindexCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('Vault is not available'));
      });
    });

    group('vault search not configured', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultNoSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when no vault search config', () async {
        final ok = await const VaultReindexCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('Vault search is not configured'));
      });
    });

    group('empty vault — nothing to reindex', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns true for empty vault', () async {
        final ok = await const VaultReindexCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isTrue);
      });

      test('prints no-blobs message for empty vault', () async {
        await const VaultReindexCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(
          out.toString(),
          anyOf(contains('No vault blobs'), contains('nothing to')),
        );
      });
    });
  });

  // ── VaultStatusCommand ─────────────────────────────────────────────────────

  group('VaultStatusCommand', () {
    group('metadata', () {
      test(
        'name is status',
        () => expect(const VaultStatusCommand().name, equals('status')),
      );
      test(
        'description is non-empty',
        () => expect(const VaultStatusCommand().description, isNotEmpty),
      );
      test(
        'usage is non-empty',
        () => expect(const VaultStatusCommand().usage, isNotEmpty),
      );
      test('configureArgParser completes normally', () {
        expect(
          () => const VaultStatusCommand().configureArgParser(ArgParser()),
          returnsNormally,
        );
      });
    });

    group('vault not configured', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openNoVaultDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when no vault store', () async {
        final ok = await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('Vault is not available'));
      });
    });

    group('vault search not configured', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultNoSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns false when no vault search config', () async {
        final ok = await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('Vault search is not configured'));
      });
    });

    group('empty vault status', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultSearchDb();
        out = StringBuffer();
        err = StringBuffer();
      });
      tearDown(() => db.close());

      test('returns true for empty vault', () async {
        final ok = await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isTrue);
      });

      test('prints status table with all count fields', () async {
        await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        final output = out.toString();
        expect(output, contains('Total blobs:'));
        expect(output, contains('Indexed:'));
        expect(output, contains('Pending:'));
        expect(output, contains('Extracting:'));
        expect(output, contains('Failed:'));
        expect(output, contains('Unsupported type:'));
        expect(output, contains('Stub'));
      });

      test('prints no-blobs status message when vault is empty', () async {
        await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(out.toString(), contains('no vault blobs'));
      });

      test('writes nothing to err when no stubs', () async {
        await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(err.toString(), isEmpty);
      });
    });

    group('status with indexed blob', () {
      late KmdbDatabase db;
      late StringBuffer out;
      late StringBuffer err;

      setUp(() async {
        db = await _openVaultSearchDb();
        out = StringBuffer();
        err = StringBuffer();
        // Ingest a blob to have at least one pending entry in the status.
        await _ingest(db.vaultStore!);
        // Small wait to allow the VaultSearchManager isolate to process the blob.
        // In unit tests, the isolate processes immediately for text/plain blobs.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      tearDown(() => db.close());

      test('returns true when blobs are present', () async {
        final ok = await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        expect(ok, isTrue);
      });

      test('total count is at least 1 when a blob has been ingested', () async {
        await const VaultStatusCommand().execute(
          _ctx(db, out: out, err: err),
          [],
          {},
        );
        // The output must show "Total blobs:" followed by a number > 0.
        // We don't hardcode which lifecycle state the blob is in because
        // the isolate may have completed indexing by the time the status runs.
        final output = out.toString();
        // Check that the Total line is not "0".
        final totalMatch = RegExp(r'Total blobs:\s+(\d+)').firstMatch(output);
        expect(
          totalMatch,
          isNotNull,
          reason: 'Total blobs line must be present',
        );
        final total = int.parse(totalMatch!.group(1)!);
        expect(total, greaterThan(0));
      });
    });
  });
}
