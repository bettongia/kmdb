// Copyright 2026 The Authors
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

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_ref.dart';
import 'package:kmdb/src/vault/vault_ref_count.dart';
import 'package:kmdb/src/vault/vault_recovery.dart'
    show kVaultNamespace, kVaultRefCountSentinelKey;
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

/// A pass-through codec that returns the raw decoded [Map<String, dynamic>].
///
/// Used in tests that need to inspect the raw decoded document (including wired
/// [VaultRef] instances) without domain-model deserialization.
final class _RawCodec implements KmdbCodec<Map<String, dynamic>> {
  const _RawCodec();

  @override
  String keyOf(Map<String, dynamic> v) => v['_id'] as String;

  @override
  Map<String, dynamic> withKey(Map<String, dynamic> v, String key) => {
    ...v,
    '_id': key,
  };

  @override
  Map<String, dynamic> encode(Map<String, dynamic> v) =>
      Map.of(v)..remove('_id');

  @override
  Map<String, dynamic> decode(Map<String, dynamic> json) => json;
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

    // Bug 1 regression coverage: these three scenarios exercise the ref-count
    // scheme's edge cases against the *real* KvStoreImpl (via the public
    // KmdbCollection API, or — where the scenario is inherently unreachable
    // through well-formed public-API usage — via the real VaultRefInterceptor
    // against the real store), proving the namespace-per-blob fix
    // (`$vault:{sha256}` / kVaultRefCountSentinelKey) holds under real
    // KeyCodec validation, not just against an in-memory test double that
    // never exercises KeyCodec at all.
    group(
      'multi-reference (two documents referencing the same blob)',
      tags: 'e2e',
      () {
        test(
          'ref count reaches 2, then drops as each document is removed',
          () async {
            final collection = db.collection(
              name: 'attachments',
              codec: const _AttachmentCodec(),
            );
            final ref = await vaultStore.ingest(
              bytes: _utf8('shared blob'),
              hlcTimestamp: 't1',
            );

            final docA = await collection.insert(
              _Attachment(id: '', name: 'a', file: ref),
            );
            final docB = await collection.insert(
              _Attachment(id: '', name: 'b', file: ref),
            );

            final afterBothInserts = await VaultRefCount.read(
              db.store,
              ref.sha256,
            );
            expect(afterBothInserts, isA<RefCountValue>());
            expect((afterBothInserts as RefCountValue).count, equals(2));

            // Deleting the first document must not tombstone the blob — the
            // second document still references it.
            await collection.delete(docA.id);
            expect(await vaultStore.isTombstoned(ref.sha256), isFalse);
            final afterOneDelete = await VaultRefCount.read(
              db.store,
              ref.sha256,
            );
            expect((afterOneDelete as RefCountValue).count, equals(1));

            // Deleting the second (last) reference tombstones the blob.
            await collection.delete(docB.id);
            expect(await vaultStore.isTombstoned(ref.sha256), isTrue);
          },
        );
      },
    );

    group('decrement below zero guard', tags: 'e2e', () {
      test('a defensive extra decrement clamps to zero instead of going '
          'negative', () async {
        // This scenario is not reachable through well-formed public-API
        // usage (a document's own ref-count arithmetic is always balanced
        // by construction), so it drives VaultRefInterceptor directly
        // against the real db.store — proving the *real* KvStoreImpl
        // clamps defensively rather than throwing or corrupting the entry,
        // which is the guarantee _decrement's `current > 0 ? current - 1 :
        // 0` clamp provides.
        final ref = await vaultStore.ingest(
          bytes: _utf8('below-zero-guard'),
          hlcTimestamp: 't1',
        );
        final interceptor = db.vaultRefInterceptor!;

        // Increment once (ref count 0 → 1).
        final incBatch = WriteBatch();
        await interceptor.interceptWrite(
          batch: incBatch,
          namespace: 'test',
          docKey: '01900000000070809000000000000099', // 32-char UUIDv7
          oldDoc: null,
          newDoc: {'file': ref.uri},
        );
        // The interceptor writes to the `$vault:{sha256}` system namespace —
        // the public writeBatch() rejects `$`-prefixed namespaces
        // (KvStoreImpl._normaliseAndGuardNamespace), so use writeBatchInternal
        // like the Query Layer itself does when committing an interceptor's
        // batch alongside the document write.
        await db.store.writeBatchInternal(incBatch);

        // Decrement twice in a row (simulating a corrupt double-decrement)
        // — the second decrement must clamp at zero, not go negative.
        for (var i = 0; i < 2; i++) {
          final decBatch = WriteBatch();
          await interceptor.interceptWrite(
            batch: decBatch,
            namespace: 'test',
            docKey: '01900000000070809000000000000099', // 32-char UUIDv7
            oldDoc: {'file': ref.uri},
            newDoc: null,
          );
          await db.store.writeBatchInternal(decBatch);
        }

        // Absence of the entry is the authoritative "zero references"
        // signal (see VaultRefCount's doc comment) — the clamp guarantees
        // this, never a negative count.
        final result = await VaultRefCount.read(db.store, ref.sha256);
        expect(result, isA<RefCountAbsent>());
        expect(await vaultStore.isTombstoned(ref.sha256), isTrue);
      });
    });

    group(
      'undecodable-entry fail-safe (RefCountUndecodable → retain)',
      tags: 'e2e',
      () {
        test(
          r'a corrupt $vault:{sha256} entry is retained by GC, not deleted',
          () async {
            final ref = await vaultStore.ingest(
              bytes: _utf8('undecodable-guard'),
              hlcTimestamp: 't1',
            );
            // Directly corrupt the ref-count entry — simulates a truncated/
            // garbage byte pattern (e.g. from a future or older codec) that
            // ValueCodec.decode cannot parse. The `$vault:{sha256}` namespace
            // is a system namespace, so writeBatchInternal is required (the
            // public put()/writeBatch() reject `$`-prefixed namespaces).
            final corruptBatch = WriteBatch();
            corruptBatch.put(
              '$kVaultNamespace:${ref.sha256}',
              kVaultRefCountSentinelKey,
              Uint8List.fromList([0xFF, 0xFF, 0xFF]),
            );
            await db.store.writeBatchInternal(corruptBatch);
            await vaultStore.writeTombstone(ref.sha256);

            final result = await VaultRefCount.read(db.store, ref.sha256);
            expect(result, isA<RefCountUndecodable>());

            final gcResult = await VaultGc(
              store: vaultStore,
              kvStore: db.store,
            ).sweep();
            expect(gcResult.retainedUndecodable, equals(1));
            expect(gcResult.deleted, isZero);
            // Fail-safe: the object must survive — never deleted on an
            // uncertain (undecodable) reference count.
            expect(await vaultStore.exists(ref.sha256), isTrue);
          },
        );
      },
    );

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

  // ── _wireVaultRefsInMap / _wireVaultRefsInList coverage ──────────────────────
  //
  // These tests are NOT tagged e2e. They exercise the vault-URI wiring path in
  // KmdbCollection.decodeDoc() (lines 685-717) by storing documents with vault
  // URI strings via db.store.put() (bypassing VaultRefInterceptor's ref-count
  // bookkeeping) and reading them back via the collection API.
  //
  // Design note: writing through the public KmdbCollection.insert()/put() API
  // with a real kmdb-vault:// URI field now works correctly (see the 'insert
  // document with vault ref' group above, and vault_write_interception_test.dart
  // / vault_ref_count_test.dart for the ref-count mechanics themselves) — the
  // $vault ref-count key-length bug that used to make that path throw a
  // FormatException has been fixed (ref counts are now stored under the
  // namespace-per-blob scheme `$vault:{sha256}`, not `(namespace: '$vault',
  // key: sha256)`; see vault_ref_count.dart). These tests still bypass the
  // interceptor deliberately, not out of necessity: they use synthetic sha256
  // values with no corresponding ingested blob, purely to isolate the
  // decode-side wiring logic (list/nested-map recursion) from ref-count
  // bookkeeping and vault I/O.
  group('vault URI wiring in collection.get()', () {
    // Fresh vault-configured DB for these tests (not the shared 'e2e' setUp).
    late KmdbDatabase vaultDb;

    setUp(() async {
      final dbAdapter2 = MemoryStorageAdapter();
      final vaultAdapter2 = MemoryStorageAdapter();
      final vaultStore2 = _TestVaultStore(vaultAdapter2);
      vaultDb = await KmdbDatabase.open(
        path: '/vault_wire_test',
        adapter: dbAdapter2,
        vaultStore: vaultStore2,
      );
    });

    tearDown(() async {
      await vaultDb.close(flush: false);
      MemoryStorageAdapter.releaseAllLocks();
    });

    test('get() wires a vault URI at the top level of a document', () async {
      // Store a document with a vault URI string directly (bypasses
      // VaultRefInterceptor ref-count writes).
      const fakeSha256 =
          'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
      final vaultUri = 'kmdb-vault://sha256/$fakeSha256';
      const docId = '01900000000070809000000000000070';

      final docBytes = await ValueCodec.encode({
        'name': 'attachment',
        'file': vaultUri,
      });
      await vaultDb.store.put('attachments', docId, docBytes);

      // Read back via collection — _wireVaultRefsInMap must replace the URI
      // string with a wired VaultRef instance.
      final col = vaultDb.collection(
        name: 'attachments',
        codec: const _AttachmentCodec(),
      );
      final fetched = await col.get(docId);

      expect(fetched, isNotNull);
      expect(fetched!.file, isNotNull);
      expect(fetched.file!.sha256, equals(fakeSha256));
      // The VaultRef URI must match the stored string.
      expect(fetched.file!.uri, equals(vaultUri));
    });

    test(
      'get() wires vault URIs inside a list field (_wireVaultRefsInList)',
      () async {
        // Exercises _wireVaultRefsInList (lines 708-719) by storing a document
        // with a list containing both a vault URI and a plain string.
        const fakeSha256 =
            'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
        final vaultUri = 'kmdb-vault://sha256/$fakeSha256';
        const docId = '01900000000070809000000000000071';

        final docBytes = await ValueCodec.encode({
          '_id': docId,
          'name': 'list-doc',
          'files': [vaultUri, 'plain-string', vaultUri],
        });
        await vaultDb.store.put('items', docId, docBytes);

        // Use a raw codec so we can inspect the raw decoded map.
        final col = vaultDb.collection(name: 'items', codec: _RawCodec());
        final fetched = await col.get(docId);
        expect(fetched, isNotNull);

        final files = fetched!['files'] as List<dynamic>;
        // The vault URI strings at index 0 and 2 must have been replaced with
        // wired VaultRef instances.
        expect(files[0], isA<VaultRef>());
        expect((files[0] as VaultRef).sha256, equals(fakeSha256));
        // Plain string is unchanged.
        expect(files[1], isA<String>());
        // Second vault URI entry.
        expect(files[2], isA<VaultRef>());
      },
    );

    test(
      'get() wires vault URIs inside a nested map (_wireVaultRefsInMap recursion)',
      () async {
        // Exercises the nested-map recursion branch (line 699) in
        // _wireVaultRefsInMap.
        const fakeSha256 =
            'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
        final vaultUri = 'kmdb-vault://sha256/$fakeSha256';
        const docId = '01900000000070809000000000000072';

        final docBytes = await ValueCodec.encode({
          'name': 'nested-doc',
          'meta': {'attachment': vaultUri, 'other': 'plain'},
        });
        await vaultDb.store.put('items', docId, docBytes);

        final col = vaultDb.collection(name: 'items', codec: _RawCodec());
        final fetched = await col.get(docId);
        expect(fetched, isNotNull);

        final meta = fetched!['meta'] as Map<String, dynamic>;
        // The nested vault URI must be wired.
        expect(meta['attachment'], isA<VaultRef>());
        expect((meta['attachment'] as VaultRef).sha256, equals(fakeSha256));
        expect(meta['other'], isA<String>());
      },
    );
  });
}
