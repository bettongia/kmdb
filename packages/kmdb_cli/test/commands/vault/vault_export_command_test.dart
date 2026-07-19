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
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_export_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Counter to generate unique in-memory database paths per test, preventing
/// LockException when multiple [KmdbDatabase] instances are opened concurrently.
var _dbCounter = 0;

/// A [VaultStore] subclass that overrides [listFilesRecursive] so it works
/// with the flat [MemoryStorageAdapter] key store used in tests.
class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter memAdapter, String dbPath)
    : _mem = memAdapter,
      super(adapter: memAdapter, dbDir: dbPath);

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

/// Opens an in-memory [KmdbDatabase] for tests, optionally wired with [vault].
Future<KmdbDatabase> _openStore({String? path, _TestVaultStore? vault}) async {
  final dbPath = path ?? '/testdb_vault_export_${_dbCounter++}';
  return KmdbDatabase.open(
    path: dbPath,
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
}

/// Builds a [CommandContext] backed by [db].
CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

/// Content bytes short enough that VaultStore never invokes Zstd compression.
final _kBytes = Uint8List.fromList(utf8.encode('vault-export-test'));

/// Ingests [bytes] into [vault] and returns the `kmdb-vault://` URI string.
Future<String> _ingest(
  _TestVaultStore vault,
  Uint8List bytes, {
  String name = 'test.txt',
}) async {
  final ref = await vault.ingest(
    bytes: bytes,
    hlcTimestamp: '0000000000000001',
    originalName: name,
  );
  return ref.toString();
}

/// Creates a fresh temp directory for a single test, torn down afterward.
io.Directory _tempDir(String prefix) {
  final dir = io.Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

/// A [_TestVaultStore] that can be toggled to throw from [getManifest] or
/// [getBytes], for exercising the command's read-failure branches.
///
/// A second, freshly-opened [KmdbDatabase] cannot be used for this purpose:
/// its empty document store has no reference to the already-ingested blob,
/// so vault ref-count GC on open reclaims it as an orphan before the test
/// even runs. Toggling failure on the same store used at `setUp` time avoids
/// that entirely.
class _ToggleableVaultStore extends _TestVaultStore {
  _ToggleableVaultStore(super.memAdapter, super.dbPath);

  bool throwOnGetManifest = false;
  bool throwOnGetBytes = false;

  @override
  Future<VaultManifest> getManifest(String sha256) async {
    if (throwOnGetManifest) throw Exception('boom');
    return super.getManifest(sha256);
  }

  @override
  Future<Uint8List> getBytes(String sha256) async {
    if (throwOnGetBytes) throw Exception('boom');
    return super.getBytes(sha256);
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('VaultExportCommand', () {
    late KmdbDatabase db;
    late String dbPath;
    late MemoryStorageAdapter memAdapter;
    late _ToggleableVaultStore vault;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      dbPath = '/testdb_vault_export_${_dbCounter++}';
      memAdapter = MemoryStorageAdapter();
      vault = _ToggleableVaultStore(memAdapter, dbPath);
      db = await _openStore(path: dbPath, vault: vault);
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    // ── Vault store not configured ────────────────────────────────────────

    test('returns false when vault store is null', () async {
      final dbNoVault = await _openStore();
      addTearDown(() => dbNoVault.close());
      final ctx = _ctx(dbNoVault, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        ['kmdb-vault://sha256/${'a' * 64}'],
        {'output': '/tmp/whatever'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('not configured'));
    });

    // ── URI argument validation ────────────────────────────────────────────

    test('returns false when no URI argument is given', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(ctx, [], {
        'output': '/tmp/whatever',
      });
      expect(ok, isFalse);
      expect(err.toString(), contains('requires a URI argument'));
    });

    test('returns false for a non-vault URI scheme', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        ['https://example.com/file'],
        {'output': '/tmp/whatever'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid vault URI'));
    });

    // ── --output required ───────────────────────────────────────────────────

    test('returns false when --output is missing', () async {
      final uri = await _ingest(vault, _kBytes);
      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(ctx, [uri], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires --output'));
    });

    test('returns false when --output is blank', () async {
      final uri = await _ingest(vault, _kBytes);
      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        [uri],
        {'output': '   '},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('requires --output'));
    });

    // ── Object not found ──────────────────────────────────────────────────

    test('returns false when the vault object does not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        ['kmdb-vault://sha256/${'b' * 64}'],
        {'output': '/tmp/whatever'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    // ── Stub (manifest present, blob absent) ──────────────────────────────

    test('returns false for a stub object', () async {
      final sha256 = VaultStore.computeSha256(_kBytes);
      final crc32c = VaultStore.computeCrc32cForTest(_kBytes);
      final dir = vault.hashDir(sha256);
      await vault.adapter.createDirectory(dir);
      await vault.adapter.writeFile(
        vault.manifestPath(sha256),
        Uint8List.fromList(
          utf8.encode(
            '{"schemaVersion":1,"sha256":"$sha256","size":${_kBytes.length},'
            '"crc32c":"$crc32c","mediaType":"text/plain","originalName":"f.txt",'
            '"createdAt":"0000000000000001"}',
          ),
        ),
      );
      // Blob is deliberately absent to simulate a stub.

      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        ['kmdb-vault://sha256/$sha256'],
        {'output': '/tmp/whatever'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('stub'));
    });

    // ── File-path target ────────────────────────────────────────────────────

    test('writes blob to an exact --output file path', () async {
      final uri = await _ingest(vault, _kBytes);
      final sha256 = VaultStore.computeSha256(_kBytes);
      final dir = _tempDir('kmdb_vault_export_file_');
      final targetPath = '${dir.path}/out.bin';

      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        [uri],
        {'output': targetPath},
      );

      expect(ok, isTrue);
      expect(io.File(targetPath).readAsBytesSync(), equals(_kBytes));
      final summary = out.toString();
      expect(summary, contains(sha256));
      expect(summary, contains(uri));
      // Decode rather than substring-match: on Windows, targetPath contains
      // backslashes, which JsonEncoder escapes (`\\`) — a raw `contains`
      // check would never match the doubled-up escaped form.
      final decoded = jsonDecode(summary) as Map<String, dynamic>;
      expect(decoded['output'], targetPath);
    });

    test('overwrites an existing file at the exact --output path', () async {
      final uri = await _ingest(vault, _kBytes);
      final dir = _tempDir('kmdb_vault_export_overwrite_');
      final targetPath = '${dir.path}/out.bin';
      io.File(targetPath).writeAsBytesSync([1, 2, 3]);

      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        [uri],
        {'output': targetPath},
      );

      expect(ok, isTrue);
      expect(io.File(targetPath).readAsBytesSync(), equals(_kBytes));
    });

    test(
      'returns false when the exact --output path parent does not exist',
      () async {
        final uri = await _ingest(vault, _kBytes);
        final ctx = _ctx(db, out: out, err: err);
        final ok = await VaultExportCommand().execute(
          ctx,
          [uri],
          {'output': '/nonexistent/dir/file.bin'},
        );

        expect(ok, isFalse);
        expect(err.toString(), contains('parent directory does not exist'));
      },
    );

    // ── Directory target ────────────────────────────────────────────────────

    test(
      'writes blob into an --output directory using a derived filename',
      () async {
        final dir = _tempDir('kmdb_vault_export_dir_');
        final uri = await _ingest(vault, _kBytes, name: 'photo.jpg');
        final sha256 = VaultStore.computeSha256(_kBytes);

        final ctx = _ctx(db, out: out, err: err);
        final ok = await VaultExportCommand().execute(
          ctx,
          [uri],
          {'output': dir.path},
        );

        expect(ok, isTrue);
        final expectedPath = p.join(dir.path, 'photo.jpg');
        expect(io.File(expectedPath).readAsBytesSync(), equals(_kBytes));
        final summary = out.toString();
        expect(summary, contains(sha256));
        // Decode rather than substring-match: on Windows, expectedPath
        // contains backslashes, which JsonEncoder escapes (`\\`) — a raw
        // `contains` check would never match the doubled-up escaped form.
        final decoded = jsonDecode(summary) as Map<String, dynamic>;
        expect(decoded['output'], expectedPath);
      },
    );

    test(
      'sanitises an absolute originalName to its basename under an --output directory',
      () async {
        final dir = _tempDir('kmdb_vault_export_absolute_');
        // '/etc/passwd' is a POSIX absolute path; on Windows it is merely a
        // relative-looking name rooted at '\', so p.basename still isolates
        // 'passwd' — the sanitisation logic under test is platform-agnostic.
        final uri = await _ingest(vault, _kBytes, name: '/etc/passwd');

        final ctx = _ctx(db, out: out, err: err);
        final ok = await VaultExportCommand().execute(
          ctx,
          [uri],
          {'output': dir.path},
        );

        expect(ok, isTrue);
        // Must be contained within dir.path, never write outside it.
        final expectedPath = p.join(dir.path, 'passwd');
        expect(io.File(expectedPath).readAsBytesSync(), equals(_kBytes));
        // Confirm nothing was written to the real absolute path — only
        // meaningful where '/etc/passwd' actually exists (POSIX systems);
        // Windows has no such file to accidentally clobber.
        if (!io.Platform.isWindows) {
          expect(io.File('/etc/passwd').readAsBytesSync(), isNot(_kBytes));
        }
      },
    );

    test(
      'sanitises a path-traversal originalName to its basename under an --output directory',
      () async {
        final dir = _tempDir('kmdb_vault_export_traversal_');
        final uri = await _ingest(vault, _kBytes, name: '../../evil');

        final ctx = _ctx(db, out: out, err: err);
        final ok = await VaultExportCommand().execute(
          ctx,
          [uri],
          {'output': dir.path},
        );

        expect(ok, isTrue);
        final expectedPath = '${dir.path}/evil';
        expect(io.File(expectedPath).readAsBytesSync(), equals(_kBytes));
      },
    );

    test(
      'falls back to "blob" when originalName is empty or whitespace',
      () async {
        final dir = _tempDir('kmdb_vault_export_blank_name_');
        final uri = await _ingest(vault, _kBytes, name: '   ');

        final ctx = _ctx(db, out: out, err: err);
        final ok = await VaultExportCommand().execute(
          ctx,
          [uri],
          {'output': dir.path},
        );

        expect(ok, isTrue);
        final expectedPath = '${dir.path}/blob';
        expect(io.File(expectedPath).readAsBytesSync(), equals(_kBytes));
      },
    );

    // ── Manifest / blob read failures ───────────────────────────────────

    test('returns false when the manifest cannot be read', () async {
      final uri = await _ingest(vault, _kBytes);
      vault.throwOnGetManifest = true;

      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        [uri],
        {'output': '/tmp/whatever'},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('Failed to read vault manifest'));
    });

    test('returns false when the blob bytes cannot be read', () async {
      final uri = await _ingest(vault, _kBytes);
      vault.throwOnGetBytes = true;

      final ctx = _ctx(db, out: out, err: err);
      final ok = await VaultExportCommand().execute(
        ctx,
        [uri],
        {'output': '/tmp/whatever'},
      );

      expect(ok, isFalse);
      expect(err.toString(), contains('Failed to read vault object'));
    });

    // ── Write failure ────────────────────────────────────────────────────

    test(
      'returns false when writeAsBytes fails despite an existing parent',
      () async {
        // Force an IOException at the final write step (rather than the
        // earlier parent-existence guard) by making the derived target name
        // collide with an existing sub-directory of the same name.
        final dir = _tempDir('kmdb_vault_export_collision_');
        io.Directory('${dir.path}/blob').createSync();
        final uri = await _ingest(vault, _kBytes, name: '   ');

        final ctx = _ctx(db, out: out, err: err);
        final ok = await VaultExportCommand().execute(
          ctx,
          [uri],
          {'output': dir.path},
        );

        expect(ok, isFalse);
        expect(err.toString(), contains('Cannot write'));
      },
    );

    // ── Command metadata ─────────────────────────────────────────────────

    test('exposes name, description, usage, and the --output option', () {
      const cmd = VaultExportCommand();
      expect(cmd.name, 'export');
      expect(cmd.description, contains('kmdb-vault://'));
      expect(cmd.usage, contains('--output'));

      final parser = ArgParser();
      cmd.configureArgParser(parser);
      expect(parser.options.containsKey('output'), isTrue);
    });
  });
}
