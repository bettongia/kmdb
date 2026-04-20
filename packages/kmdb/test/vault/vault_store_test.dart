// Copyright 2026 The KMDB Authors
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

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_ref.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [VaultStore] subclass that overrides [listFilesRecursive] to enumerate
/// all paths in the underlying [MemoryStorageAdapter].
class TestVaultStore extends VaultStore {
  TestVaultStore(MemoryStorageAdapter adapter, {super.dbDir = '/db'})
    : _memAdapter = adapter,
      super(
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _counter,
      );

  final MemoryStorageAdapter _memAdapter;

  static int _seq = 0;
  static String _counter() => 'staging-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final results = <String>[];
    for (final path in _memAdapter.files.keys) {
      if (path.startsWith(prefix)) {
        results.add(path.substring(prefix.length));
      }
    }
    return results;
  }
}

/// A [MediaTypeDetector] that always returns an empty [MatchList].
final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => []; // empty match list
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _bytes(String content) => Uint8List.fromList(content.codeUnits);

/// Returns a 64-char lower-case hex hash of [data] using VaultStore.
String _sha256Of(Uint8List data) => VaultStore.computeSha256ForTest(data);

/// Returns the 8-char CRC32C of [data].
String _crc32cOf(Uint8List data) => VaultStore.computeCrc32cForTest(data);

void main() {
  late MemoryStorageAdapter adapter;
  late TestVaultStore store;

  setUp(() {
    TestVaultStore._seq = 0;
    adapter = MemoryStorageAdapter();
    store = TestVaultStore(adapter);
  });

  group('VaultStore', () {
    group('path helpers', () {
      test('hashDir uses two-level shard', () {
        const sha256 =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        expect(
          store.hashDir(sha256),
          equals(
            '/db/vault/blobs/sha256/ab/cdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
          ),
        );
      });

      test('blobPath is inside hashDir', () {
        const sha256 =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        expect(store.blobPath(sha256), endsWith('/blob'));
        expect(store.blobPath(sha256), startsWith(store.hashDir(sha256)));
      });

      test('manifestPath ends with manifest.json', () {
        const sha256 =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        expect(store.manifestPath(sha256), endsWith('/manifest.json'));
      });

      test('tombstonePath ends with tombstone.json', () {
        const sha256 =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        expect(store.tombstonePath(sha256), endsWith('/tombstone.json'));
      });

      test('stagingPath is inside stagingDir', () {
        expect(store.stagingPath('abc'), equals('/db/vault/staging/abc'));
      });
    });

    group('exists / isHydrated', () {
      test('exists returns false when no manifest', () async {
        final sha256 = 'a' * 64;
        expect(await store.exists(sha256), isFalse);
      });

      test('isHydrated returns false when no blob', () async {
        final sha256 = 'a' * 64;
        expect(await store.isHydrated(sha256), isFalse);
      });

      test('exists returns true after ingest', () async {
        final bytes = _bytes('hello');
        final ref = await store.ingest(
          bytes: bytes,
          hlcTimestamp: '2026-01-01',
          originalName: 'hello.txt',
        );
        expect(await store.exists(ref.sha256), isTrue);
      });

      test('isHydrated returns true after ingest', () async {
        final bytes = _bytes('hello');
        final ref = await store.ingest(
          bytes: bytes,
          hlcTimestamp: '2026-01-01',
          originalName: 'hello.txt',
        );
        expect(await store.isHydrated(ref.sha256), isTrue);
      });
    });

    group('ingest — new file', () {
      test('returns a VaultRef with correct uri', () async {
        final bytes = _bytes('test content');
        final ref = await store.ingest(
          bytes: bytes,
          hlcTimestamp: '2026-01-01T00:00:00Z',
        );
        expect(ref, isA<VaultRef>());
        expect(ref.uri, startsWith('kmdb-vault://sha256/'));
        expect(ref.sha256.length, equals(64));
      });

      test('ref is wired to store (getBlob works)', () async {
        final bytes = _bytes('wired test');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        // getBlob should work because ref is wired at ingest time.
        final got = await ref.getBlob();
        expect(got, equals(bytes));
      });

      test('manifest is written to correct path', () async {
        final bytes = _bytes('manifest test');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        expect(
          adapter.files.containsKey(store.manifestPath(ref.sha256)),
          isTrue,
        );
      });

      test('blob is written to correct path', () async {
        final bytes = _bytes('blob test');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        expect(adapter.files.containsKey(store.blobPath(ref.sha256)), isTrue);
      });

      test('staging file is cleaned up after ingest', () async {
        final bytes = _bytes('staging cleanup');
        await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        // No files should remain under staging/ after a successful ingest.
        final stagingFiles = adapter.files.keys
            .where((k) => k.startsWith(store.stagingDir))
            .toList();
        expect(stagingFiles, isEmpty);
      });

      test('sha256 matches content', () async {
        final bytes = _bytes('sha256 check');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        expect(ref.sha256, equals(_sha256Of(bytes)));
      });

      test('manifest has correct fields', () async {
        final bytes = _bytes('manifest fields test');
        final ref = await store.ingest(
          bytes: bytes,
          hlcTimestamp: '2026-04-01T00:00:00Z',
          originalName: 'test.txt',
        );
        final manifest = await store.getManifest(ref.sha256);
        expect(manifest.sha256, equals(ref.sha256));
        expect(manifest.size, equals(bytes.length));
        expect(manifest.crc32c, equals(_crc32cOf(bytes)));
        expect(manifest.originalName, equals('test.txt'));
        expect(manifest.createdAt, equals('2026-04-01T00:00:00Z'));
      });

      test('media type falls back to octet-stream when no detection', () async {
        final bytes = _bytes('no media type');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        final manifest = await store.getManifest(ref.sha256);
        expect(
          manifest.mediaType,
          equals(FreedesktopMediaTypeDetector.kFallbackType),
        );
      });

      test(
        'explicit media type is accepted when candidates are empty',
        () async {
          final bytes = _bytes('explicit type');
          final ref = await store.ingest(
            bytes: bytes,
            hlcTimestamp: 't1',
            explicitMediaType: 'text/plain',
          );
          final manifest = await store.getManifest(ref.sha256);
          expect(manifest.mediaType, equals('text/plain'));
        },
      );
    });

    group('ingest — deduplication', () {
      test('returns same ref for duplicate content', () async {
        final bytes = _bytes('duplicate test');
        final ref1 = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        final ref2 = await store.ingest(bytes: bytes, hlcTimestamp: 't2');
        expect(ref1, equals(ref2));
      });

      test('no extra files are created on duplicate', () async {
        final bytes = _bytes('duplicate files');
        await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        final countBefore = adapter.files.length;

        await store.ingest(bytes: bytes, hlcTimestamp: 't2');
        final countAfter = adapter.files.length;
        expect(countAfter, equals(countBefore));
      });

      test('manifest from first ingest is preserved', () async {
        final bytes = _bytes('manifest preserved');
        final ref1 = await store.ingest(
          bytes: bytes,
          hlcTimestamp: 't1',
          originalName: 'first.bin',
        );
        await store.ingest(
          bytes: bytes,
          hlcTimestamp: 't2',
          originalName: 'second.bin',
        );
        final manifest = await store.getManifest(ref1.sha256);
        // First ingest's originalName is preserved.
        expect(manifest.originalName, equals('first.bin'));
        expect(manifest.createdAt, equals('t1'));
      });
    });

    group('ingest — CRC32C mismatch (ISS collision)', () {
      test('throws VaultCrcMismatchException', () async {
        // Create a file and ingest it.
        final bytes1 = _bytes('original content');
        final sha256 = _sha256Of(bytes1);
        await store.ingest(bytes: bytes1, hlcTimestamp: 't1');

        // Now inject a manifest with a different CRC32C to simulate a collision.
        // Overwrite the manifest with a different crc32c value.
        final fakeManifest = VaultManifest(
          sha256: sha256,
          size: bytes1.length,
          crc32c: 'ffffffff', // different from real
          mediaType: 'application/octet-stream',
          originalName: 'hack.bin',
          createdAt: 't0',
        );
        final manifestBytes = fakeManifest.toJsonString().codeUnits;
        adapter.files[store.manifestPath(sha256)] = Uint8List.fromList(
          manifestBytes,
        );

        // Ingest the same bytes again — the stored CRC32C is now different.
        expect(
          () => store.ingest(bytes: bytes1, hlcTimestamp: 't2'),
          throwsA(isA<VaultCrcMismatchException>()),
        );
      });

      test('VaultCrcMismatchException has correct fields', () async {
        final bytes = _bytes('crc mismatch test');
        final sha256 = _sha256Of(bytes);
        await store.ingest(bytes: bytes, hlcTimestamp: 't1');

        // Overwrite manifest with a different crc32c.
        final fakeManifest = VaultManifest(
          sha256: sha256,
          size: bytes.length,
          crc32c: '00000000',
          mediaType: 'application/octet-stream',
          originalName: 'fake.bin',
          createdAt: 't0',
        );
        adapter.files[store.manifestPath(sha256)] = Uint8List.fromList(
          fakeManifest.toJsonString().codeUnits,
        );

        try {
          await store.ingest(bytes: bytes, hlcTimestamp: 't2');
          fail('Expected VaultCrcMismatchException');
        } on VaultCrcMismatchException catch (e) {
          expect(e.sha256, equals(sha256));
          expect(e.existingCrc32c, equals('00000000'));
          expect(e.incomingCrc32c, equals(_crc32cOf(bytes)));
        }
      });
    });

    group('getBytes', () {
      test('returns blob bytes after ingest', () async {
        final bytes = _bytes('get bytes test');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        final got = await store.getBytes(ref.sha256);
        expect(got, equals(bytes));
      });

      test('throws VaultObjectNotFoundException for unknown hash', () async {
        expect(
          () => store.getBytes('a' * 64), // ignore: avoid_dynamic_calls
          throwsA(isA<VaultObjectNotFoundException>()),
        );
      });

      test('throws StateError for stub without sync adapter', () async {
        // Create a stub manually (manifest without blob).
        final sha256 = 'a' * 64;
        await store.createStub(
          VaultManifest(
            sha256: sha256,
            size: 10,
            crc32c: '00000000',
            mediaType: 'application/octet-stream',
            originalName: 'stub.bin',
            createdAt: 't1',
          ),
        );
        expect(() => store.getBytes(sha256), throwsA(isA<StateError>()));
      });
    });

    group('getManifest', () {
      test('returns manifest after ingest', () async {
        final bytes = _bytes('manifest retrieval');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        final manifest = await store.getManifest(ref.sha256);
        expect(manifest.sha256, equals(ref.sha256));
      });

      test('throws VaultObjectNotFoundException for unknown hash', () async {
        expect(
          () => store.getManifest('b' * 64),
          throwsA(isA<VaultObjectNotFoundException>()),
        );
      });
    });

    group('tombstone', () {
      test('isTombstoned returns false before tombstone written', () async {
        final bytes = _bytes('not tombstoned');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        expect(await store.isTombstoned(ref.sha256), isFalse);
      });

      test('isTombstoned returns true after writeTombstone', () async {
        final bytes = _bytes('tombstoned');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        await store.writeTombstone(ref.sha256);
        expect(await store.isTombstoned(ref.sha256), isTrue);
      });

      test('deleteTombstone removes tombstone', () async {
        final bytes = _bytes('un-tombstone');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        await store.writeTombstone(ref.sha256);
        await store.deleteTombstone(ref.sha256);
        expect(await store.isTombstoned(ref.sha256), isFalse);
      });
    });

    group('deleteHashDir', () {
      test('removes blob, manifest, tombstone', () async {
        final bytes = _bytes('delete hash dir');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        await store.writeTombstone(ref.sha256);

        await store.deleteHashDir(ref.sha256);

        expect(await store.exists(ref.sha256), isFalse);
        expect(await store.isHydrated(ref.sha256), isFalse);
        expect(await store.isTombstoned(ref.sha256), isFalse);
      });

      test('removes corresponding VAULT_OFFLINE entry', () async {
        final bytes = _bytes('vault offline test');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');

        // Write a VAULT_OFFLINE file with the hash entry.
        final line = VaultStore.vaultOfflineLine(ref.sha256);
        adapter.files[store.vaultOfflinePath] = Uint8List.fromList(
          '$line\n'.codeUnits,
        );

        await store.deleteHashDir(ref.sha256);

        // VAULT_OFFLINE should no longer contain the entry.
        if (adapter.files.containsKey(store.vaultOfflinePath)) {
          final content = String.fromCharCodes(
            adapter.files[store.vaultOfflinePath]!,
          );
          expect(content, isNot(contains(line)));
        }
      });
    });

    group('createStub', () {
      test('creates manifest without blob', () async {
        final sha256 = 'c' * 64;
        final manifest = VaultManifest(
          sha256: sha256,
          size: 100,
          crc32c: '12345678',
          mediaType: 'image/png',
          originalName: 'stub.png',
          createdAt: 't1',
        );
        await store.createStub(manifest);

        expect(await store.exists(sha256), isTrue);
        expect(await store.isHydrated(sha256), isFalse);
      });
    });

    group('listAllHashes', () {
      test('returns empty list when no hashes exist', () async {
        expect(await store.listAllHashes(), isEmpty);
      });

      test('returns ingested hashes', () async {
        final bytes1 = _bytes('hash 1');
        final bytes2 = _bytes('hash 2');
        final ref1 = await store.ingest(bytes: bytes1, hlcTimestamp: 't1');
        final ref2 = await store.ingest(bytes: bytes2, hlcTimestamp: 't2');
        final hashes = await store.listAllHashes();
        expect(hashes, containsAll([ref1.sha256, ref2.sha256]));
      });
    });

    group('sha256 and crc32c correctness', () {
      test('SHA-256 of empty bytes', () {
        final hash = _sha256Of(Uint8List(0));
        // Known SHA-256 of empty input
        expect(
          hash,
          equals(
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          ),
        );
      });

      test('CRC32C of known input', () {
        // CRC32C of "123456789" = 0xe3069283
        final bytes = Uint8List.fromList('123456789'.codeUnits);
        final result = _crc32cOf(bytes);
        expect(result, equals('e3069283'));
      });

      test('two different inputs produce different sha256', () {
        final h1 = _sha256Of(_bytes('content A'));
        final h2 = _sha256Of(_bytes('content B'));
        expect(h1, isNot(equals(h2)));
      });

      test('same input produces the same sha256', () {
        final bytes = _bytes('consistent input');
        expect(_sha256Of(bytes), equals(_sha256Of(bytes)));
      });
    });
  });
}
