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

// End-to-end regression test exercising *both* fixes from this plan together:
//
// - Bug 1 (`$vault` ref-count key-length mismatch): a document containing a
//   `kmdb-vault://` URI field can be written through the public
//   `KmdbCollection.insert`/`delete` API without throwing.
// - Bug 2 (`VaultStore.listFilesRecursive` stopgap): `VaultGc.sweep()`
//   correctly enumerates and deletes the blob once unreferenced — using a
//   *bare* `VaultStore` with no subclass override, so the real
//   `StorageAdapter.listFilesRecursive` delegation is what makes GC see the
//   blob at all.
//
// Every other vault_integration_test.dart test uses `_TestVaultStore`, which
// overrides `listFilesRecursive` — so this file deliberately avoids that
// override to prove the two fixes compose correctly on a real, unmodified
// `VaultStore` (the configuration every real application actually uses).

import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_ref.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => const [];
}

/// A document model with a vault attachment, matching the shape used
/// elsewhere in the vault test suite.
final class _Attachment {
  const _Attachment({required this.id, required this.name, this.file});

  final String id;
  final String name;
  final VaultRef? file;
}

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
    if (f != null) map['file'] = f.uri;
    return map;
  }

  @override
  _Attachment decode(Map<String, dynamic> json) => _Attachment(
    id: json['_id'] as String,
    name: json['name'] as String,
    file: switch (json['file']) {
      final VaultRef r => r,
      final String s when VaultRef.isVaultUri(s) => VaultRef(s),
      _ => null,
    },
  );
}

Uint8List _utf8(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  test('a public-API-written vault document survives GC while referenced and '
      'is GC-d once unreferenced (Bug 1 + Bug 2 composed)', () async {
    final dbAdapter = MemoryStorageAdapter();
    final vaultAdapter = MemoryStorageAdapter();
    // Deliberately a bare VaultStore — no listFilesRecursive override — so
    // VaultGc.sweep() must go through the real
    // StorageAdapter.listFilesRecursive delegation (Bug 2's fix) to find
    // anything at all.
    final vaultStore = VaultStore(
      dbDir: '/db',
      adapter: vaultAdapter,
      detector: const _NoOpDetector(),
    );

    final db = await KmdbDatabase.open(
      path: '/db',
      adapter: dbAdapter,
      vaultStore: vaultStore,
    );
    addTearDown(() => db.close(flush: false));

    final collection = db.collection(
      name: 'attachments',
      codec: const _AttachmentCodec(),
    );

    // Step 1 (Bug 1): ingest a blob and write a document referencing it
    // through the *public* insert() API. Before the fix, the ref-count
    // WriteBatch entry (namespace='$vault', key=sha256) would throw
    // FormatException inside KeyCodec.keyToBytes on commit.
    final ref = await vaultStore.ingest(
      bytes: _utf8('end-to-end payload'),
      hlcTimestamp: 't1',
    );
    final inserted = await collection.insert(
      _Attachment(id: '', name: 'e2e.txt', file: ref),
    );

    // Step 2 (Bug 2): while still referenced, a GC sweep must not delete
    // the blob — and, critically, must be able to *enumerate* it in the
    // first place via the real listFilesRecursive delegation.
    final gc = VaultGc(store: vaultStore, kvStore: db.store);
    final sweepWhileReferenced = await gc.sweep();
    expect(sweepWhileReferenced.deleted, isZero);
    expect(await vaultStore.exists(ref.sha256), isTrue);

    // Step 3 (Bug 1): delete the referencing document through the public
    // API — the ref count drops to zero and a tombstone is written.
    await collection.delete(inserted.id);
    expect(await vaultStore.isTombstoned(ref.sha256), isTrue);

    // Step 4 (Bug 2): a second GC sweep must now find and delete the
    // tombstoned, unreferenced blob — this is the exact scenario that a
    // leading-slash regression (or the old always-[] stopgap) would make
    // silently invisible: `listAllHashes()` would return [], `examined`
    // would stay 0, and the blob would leak forever.
    final sweepAfterDelete = await gc.sweep();
    expect(sweepAfterDelete.examined, equals(1));
    expect(sweepAfterDelete.deleted, equals(1));
    expect(await vaultStore.exists(ref.sha256), isFalse);
  });
}
