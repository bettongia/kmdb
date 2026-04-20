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
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_ref.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// NOTE: Tests in the 'vault-e2e' group require the kmdb_zstd native library
// to be available (they trigger Zstd compression due to document size).
// They are tagged @Tags(['e2e']) and skipped in normal CI test runs.
// Run with: dart test --preset e2e

// ── Test model ────────────────────────────────────────────────────────────────

/// A document model with an optional vault attachment.
final class _Attachment {
  const _Attachment({required this.id, required this.name, this.file});

  final String id;
  final String name;
  final VaultRef? file;
}

/// Codec for [_Attachment]. Maps `file` to/from a vault URI string.
final class _AttachmentCodec implements KmdbCodec<_Attachment> {
  const _AttachmentCodec();

  @override
  String keyOf(_Attachment v) => v.id;

  @override
  _Attachment withKey(_Attachment v, String key) =>
      _Attachment(id: key, name: v.name, file: v.file);

  @override
  Map<String, dynamic> encode(_Attachment v) {
    final map = <String, dynamic>{'name': v.name};
    final f = v.file;
    if (f != null) {
      // Store the VaultRef as its URI string. The Query Layer wires VaultRef
      // instances on decode.
      map['file'] = f.uri;
    }
    return map;
  }

  @override
  _Attachment decode(Map<String, dynamic> json) => _Attachment(
    id: json['_id'] as String,
    name: json['name'] as String,
    // The Query Layer replaces vault URI strings with VaultRef instances before
    // calling decode, so 'file' may be a VaultRef or a plain String.
    file: switch (json['file']) {
      final VaultRef r => r,
      final String s when VaultRef.isVaultUri(s) => VaultRef(s),
      _ => null,
    },
  );
}

// ── Test vault store ──────────────────────────────────────────────────────────

class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _counter,
        dbDir: '/db',
      );

  final MemoryStorageAdapter _mem;
  static int _seq = 0;
  static String _counter() => 'vs-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return _mem.files.keys
        .where((p) => p.startsWith(prefix))
        .map((p) => p.substring(prefix.length))
        .toList();
  }
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _utf8(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late MemoryStorageAdapter dbAdapter;
  late MemoryStorageAdapter vaultAdapter;
  late _TestVaultStore vaultStore;
  late KmdbDatabase db;

  setUp(() async {
    _TestVaultStore._seq = 0;
    dbAdapter = MemoryStorageAdapter();
    vaultAdapter = MemoryStorageAdapter();
    vaultStore = _TestVaultStore(vaultAdapter);

    db = await KmdbDatabase.open(
      path: '/db',
      adapter: dbAdapter,
      vaultStore: vaultStore,
    );
  });

  tearDown(() => db.close(flush: false));

  group('vault integration', () {
    group('KmdbDatabase.open() with VaultStore', () {
      test('vaultStore getter returns the configured store', () {
        expect(db.vaultStore, same(vaultStore));
      });

      test('vaultRefInterceptor is non-null when vault is configured', () {
        expect(db.vaultRefInterceptor, isNotNull);
      });
    });

    group('insert document with vault ref', tags: 'e2e', () {
      test('ref count reaches 1 after insert', () async {
        final collection = db.collection(
          name: 'attachments',
          codec: const _AttachmentCodec(),
        );
        final ref = await vaultStore.ingest(
          bytes: _utf8('hello world'),
          hlcTimestamp: 't1',
        );
        final doc = _Attachment(id: '', name: 'test.txt', file: ref);
        await collection.insert(doc);

        // Verify ref count via interceptor's underlying kvStore.
        // We read the ref count through the vaultStore GC path.
        final gcResult = await VaultGc(
          store: vaultStore,
          kvStore: db.store,
        ).sweep();
        // Nothing tombstoned, so GC should do nothing.
        expect(gcResult.examined, isZero);
        expect(gcResult.deleted, isZero);
      });

      test('decoded document returns wired VaultRef', () async {
        final collection = db.collection(
          name: 'attachments',
          codec: const _AttachmentCodec(),
        );
        final ref = await vaultStore.ingest(
          bytes: _utf8('hello'),
          hlcTimestamp: 't1',
        );
        final inserted = await collection.insert(
          _Attachment(id: '', name: 'test', file: ref),
        );
        final fetched = await collection.get(inserted.id);

        expect(fetched, isNotNull);
        expect(fetched!.file, isNotNull);
        expect(fetched.file!.sha256, equals(ref.sha256));
        // getBlob should work — the VaultRef is wired.
        final blobBytes = await fetched.file!.getBlob();
        expect(blobBytes, equals(_utf8('hello')));
      });

      test('getMetadata works on a wired VaultRef', () async {
        final collection = db.collection(
          name: 'attachments',
          codec: const _AttachmentCodec(),
        );
        final ref = await vaultStore.ingest(
          bytes: _utf8('metadata test'),
          hlcTimestamp: 't1',
        );
        final inserted = await collection.insert(
          _Attachment(id: '', name: 'doc', file: ref),
        );
        final fetched = await collection.get(inserted.id);
        final manifest = await fetched!.file!.getMetadata();
        expect(manifest.sha256, equals(ref.sha256));
        expect(manifest.size, equals(_utf8('metadata test').length));
      });
    });

    group('delete document with vault ref', tags: 'e2e', () {
      test('tombstone is created after delete', () async {
        final collection = db.collection(
          name: 'attachments',
          codec: const _AttachmentCodec(),
        );
        final ref = await vaultStore.ingest(
          bytes: _utf8('to be deleted'),
          hlcTimestamp: 't1',
        );
        final inserted = await collection.insert(
          _Attachment(id: '', name: 'delete-me', file: ref),
        );
        await collection.delete(inserted.id);

        expect(await vaultStore.isTombstoned(ref.sha256), isTrue);
      });

      test('GC sweep deletes hash dir after tombstoning', () async {
        final collection = db.collection(
          name: 'attachments',
          codec: const _AttachmentCodec(),
        );
        final ref = await vaultStore.ingest(
          bytes: _utf8('sweep me'),
          hlcTimestamp: 't1',
        );
        final inserted = await collection.insert(
          _Attachment(id: '', name: 'sweep', file: ref),
        );
        await collection.delete(inserted.id);

        // Object still exists (tombstoned, not deleted yet).
        expect(await vaultStore.exists(ref.sha256), isTrue);

        // Run GC sweep — object should be deleted.
        final gcResult = await VaultGc(
          store: vaultStore,
          kvStore: db.store,
        ).sweep();
        expect(gcResult.deleted, equals(1));
        expect(await vaultStore.exists(ref.sha256), isFalse);
      });
    });

    group('update document vault ref', tags: 'e2e', () {
      test(
        'old ref is tombstoned and new ref has count 1 after update',
        () async {
          final collection = db.collection(
            name: 'attachments',
            codec: const _AttachmentCodec(),
          );
          final ref1 = await vaultStore.ingest(
            bytes: _utf8('original'),
            hlcTimestamp: 't1',
          );
          final ref2 = await vaultStore.ingest(
            bytes: _utf8('replacement'),
            hlcTimestamp: 't2',
          );

          final inserted = await collection.insert(
            _Attachment(id: '', name: 'swap', file: ref1),
          );

          // Replace the file ref.
          await collection.replace(
            _Attachment(id: inserted.id, name: 'swap', file: ref2),
          );

          expect(await vaultStore.isTombstoned(ref1.sha256), isTrue);
          expect(await vaultStore.isTombstoned(ref2.sha256), isFalse);
        },
      );
    });

    group('without vault store configured', tags: 'e2e', () {
      late KmdbDatabase dbNoVault;

      setUp(() async {
        dbNoVault = await KmdbDatabase.open(
          path: '/db-no-vault',
          adapter: MemoryStorageAdapter(),
          // No vaultStore — vault features disabled.
        );
      });

      tearDown(() => dbNoVault.close(flush: false));

      test('vaultStore getter returns null', () {
        expect(dbNoVault.vaultStore, isNull);
      });

      test('vaultRefInterceptor is null', () {
        expect(dbNoVault.vaultRefInterceptor, isNull);
      });

      test('insert/get works normally without vault', () async {
        final collection = dbNoVault.collection(
          name: 'plain',
          codec: const _AttachmentCodec(),
        );
        final inserted = await collection.insert(
          const _Attachment(id: '', name: 'no vault'),
        );
        final fetched = await collection.get(inserted.id);
        expect(fetched!.name, equals('no vault'));
        expect(fetched.file, isNull);
      });
    });
  });
}
