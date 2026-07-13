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

/// Tests for [IndexManager]'s namespace-token format-version migration
/// (Encryption confidentiality reconciliation plan, Gap 2, Q5).
///
/// See `test/search/lexical/fts_token_mode_test.dart`'s doc comment for the
/// full rationale behind testing this via two manager instances over the
/// same [KvStoreImpl] rather than a literal "toggle encryption on an
/// existing database" (architecturally impossible — B5).
library;

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:kmdb/src/query/index/index_manager.dart';
import 'package:test/test.dart';

const _ns = 'contacts';
const _path = 'city';
final _def = IndexDefinition(_ns, _path);

Future<KvStoreImpl> _openStore() async {
  final (store, _) = await KvStoreImpl.open(
    '/db',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return store;
}

Future<void> _putDoc(
  KvStoreImpl store,
  String docKey,
  Map<String, dynamic> doc,
) async {
  final batch = WriteBatch()..put(_ns, docKey, await ValueCodec.encode(doc));
  await store.writeBatchInternal(batch);
}

/// Namespaces belonging to this index's sub-namespace-per-value scheme.
Future<Set<String>> _indexSubNamespaces(KvStoreImpl store) async {
  final prefix = '${_def.indexNamespace}:';
  return (await store.allStoredNamespaces())
      .where((n) => n.startsWith(prefix))
      .toSet();
}

void main() {
  group('IndexManager token-mode migration (Gap 2, Q5)', () {
    test('a database indexed under hex tokens is purged and rebuilt under HMAC '
        'tokens once an EncryptionProvider is configured, and remains '
        'correctly searchable', () async {
      final store = await _openStore();
      addTearDown(store.close);

      await _putDoc(store, '01900000000070008000000000000001', {
        'city': 'London',
      });

      // ── Phase 1: build under an unencrypted IndexManager (hex tokens). ──
      final mgrNoEnc = IndexManager(store: store, definitions: [_def]);
      await mgrNoEnc.checkTokenModeOnOpen(); // no-op: nothing built yet.
      await mgrNoEnc.getOrActivate(_ns, _path);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stateAfterBuild = await mgrNoEnc.getState(_ns, _path);
      expect(stateAfterBuild.status, equals(IndexStatus.current));
      expect(stateAfterBuild.tokenMode, equals(IndexTokenMode.hex));

      final namespacesBeforeMigration = await _indexSubNamespaces(store);
      expect(namespacesBeforeMigration, isNotEmpty);

      // ── Phase 2: "reopen" with an EncryptionProvider configured — a
      // second IndexManager over the same store, exactly as
      // KmdbDatabase.open() would construct after its encryption
      // bootstrap runs. ──────────────────────────────────────────────
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      store.meta.encryption = provider; // Q1 bootstrap-ordering.

      final mgrEnc = IndexManager(
        store: store,
        definitions: [_def],
        encryption: provider,
      );
      await mgrEnc.checkTokenModeOnOpen();

      // The mismatch must purge the stale-mode sub-namespaces and reset
      // the index to undefined — leaving them in place would defeat
      // Gap 2 by keeping plaintext-derivable hex tokens on disk
      // indefinitely.
      final stateAfterCheck = await mgrEnc.getState(_ns, _path);
      expect(stateAfterCheck.status, equals(IndexStatus.undefined));

      final namespacesAfterCheck = await _indexSubNamespaces(store);
      expect(
        namespacesAfterCheck.intersection(namespacesBeforeMigration),
        isEmpty,
        reason:
            'stale hex-mode sub-namespaces must be purged, not left '
            'as orphaned plaintext-derivable entries',
      );

      // ── Phase 3: the index rebuilds lazily (HMAC tokens) and lookup
      // finds the same document correctly. ──────────────────────────
      await mgrEnc.getOrActivate(_ns, _path);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stateAfterRebuild = await mgrEnc.getState(_ns, _path);
      expect(stateAfterRebuild.status, equals(IndexStatus.current));
      expect(stateAfterRebuild.tokenMode, equals(IndexTokenMode.hmac));

      final keys = await mgrEnc.lookupByValue(_def, 'London');
      expect(keys, equals(['01900000000070008000000000000001']));

      final namespacesAfterRebuild = await _indexSubNamespaces(store);
      expect(namespacesAfterRebuild, isNotEmpty);
      expect(
        namespacesAfterRebuild.intersection(namespacesBeforeMigration),
        isEmpty,
      );
    });

    test('an unencrypted database reopened without a provider stays on hex '
        'tokens indefinitely — no spurious purge/rebuild (distinct databases, '
        'not a toggled state, per Q5/B5)', () async {
      final store = await _openStore();
      addTearDown(store.close);

      await _putDoc(store, '01900000000070008000000000000002', {
        'city': 'Paris',
      });

      final mgr1 = IndexManager(store: store, definitions: [_def]);
      await mgr1.getOrActivate(_ns, _path);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final namespacesBefore = await _indexSubNamespaces(store);
      expect(namespacesBefore, isNotEmpty);

      // "Reopen" without any EncryptionProvider — a second IndexManager
      // instance over the same store, still unencrypted.
      final mgr2 = IndexManager(store: store, definitions: [_def]);
      await mgr2.checkTokenModeOnOpen();

      final stateAfterReopen = await mgr2.getState(_ns, _path);
      // Status must remain `current` — checkTokenModeOnOpen must not have
      // reset it to `undefined`.
      expect(stateAfterReopen.status, equals(IndexStatus.current));
      expect(stateAfterReopen.tokenMode, equals(IndexTokenMode.hex));

      final namespacesAfter = await _indexSubNamespaces(store);
      expect(namespacesAfter, equals(namespacesBefore));
    });

    test('write-time and query-time namespace reconstruction match for an '
        'encrypted database (HMAC mode)', () async {
      final store = await _openStore();
      addTearDown(store.close);

      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      store.meta.encryption = provider;

      await _putDoc(store, '01900000000070008000000000000003', {
        'city': 'Berlin',
      });

      final mgr = IndexManager(
        store: store,
        definitions: [_def],
        encryption: provider,
      );
      await mgr.checkTokenModeOnOpen();
      await mgr.getOrActivate(_ns, _path);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // A second manager instance (same store, same provider) must be
      // able to look up what the first wrote — the token derivation is a
      // pure function of (message, DEK), not manager-instance state.
      final mgrReader = IndexManager(
        store: store,
        definitions: [_def],
        encryption: provider,
      );
      final keys = await mgrReader.lookupByValue(_def, 'Berlin');
      expect(keys, equals(['01900000000070008000000000000003']));
    });
  });
}
