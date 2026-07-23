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

/// Tests for [FtsManager]'s namespace-token format-version migration
/// (Encryption confidentiality reconciliation plan, Gap 2, Q5).
///
/// Constructs two [FtsManager] instances against the *same* [KvStoreImpl] —
/// one without an [EncryptionProvider] (hex tokens) and one with (HMAC
/// tokens) — mirroring the pattern [KmdbDatabase.open] uses when it
/// re-constructs collaborators around a late-bound provider, and the same
/// technique `vault_extract_encryption_test.dart` uses for the equivalent
/// vault-FTS migration. A literal "toggle encryption on an existing
/// KmdbDatabase" is architecturally impossible (`cannotProvisionNonEmptyDatabase`
/// — see B5 in the plan's investigation notes); this test instead directly
/// exercises the mechanism ([FtsManager.checkAndTransitionOnOpen]) that a real
/// software-version upgrade of an already-encrypted database would trigger.
library;

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/encryption_envelope.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/search/fts_index_definition.dart';
import 'package:kmdb/src/search/lexical/fts_index_state.dart';
import 'package:kmdb/src/search/lexical/fts_manager.dart';
import 'package:test/test.dart';

const _ns = 'docs';
const _field = 'body';
const _def = FtsIndexDefinition(collection: _ns, field: _field);

/// Reads the persisted [FtsIndexState] directly from the local-only
/// `$$ftsstate` namespace (moved from `$meta` by 0.10.01 WI-11/SC-10 — see
/// [kFtsStateNamespace]'s doc comment), applying the same
/// [EncryptionEnvelope] unwrap [FtsManager]'s private `_loadState` does. Test
/// helper only — production code never reaches into the namespace directly.
Future<FtsIndexState> _readFtsState(
  KvStoreImpl store, [
  EncryptionProvider? encryption,
]) async {
  final key = MetaStore.symbolicKey(FtsIndexState.metaKey(_ns, _field));
  final bytes = await store.get(kFtsStateNamespace, key);
  if (bytes == null) return FtsIndexState.fromBytes(_ns, _field, null);
  final unwrapped = await EncryptionEnvelope.unwrap(bytes, encryption);
  return FtsIndexState.fromBytes(_ns, _field, unwrapped);
}

Future<KvStoreImpl> _openStore() async {
  final (store, _) = await KvStoreImpl.open(
    '/db',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return store;
}

/// Writes a document directly into the `docs` namespace (bypassing the
/// public collection API, which this low-level test does not use).
Future<void> _putDoc(
  KvStoreImpl store,
  String docKey,
  Map<String, dynamic> doc,
) async {
  final batch = WriteBatch()..put(_ns, docKey, await ValueCodec.encode(doc));
  await store.writeBatchInternal(batch);
}

void main() {
  group('FtsManager token-mode migration (Gap 2, Q5)', () {
    test('a database indexed under hex tokens is purged and rebuilt under HMAC '
        'tokens once an EncryptionProvider is configured, and remains '
        'correctly searchable', () async {
      final store = await _openStore();
      addTearDown(store.close);

      await _putDoc(store, '01900000000070008000000000000001', {
        'body': 'the quick brown fox',
      });

      // ── Phase 1: index under an unencrypted FtsManager (hex tokens). ──
      final ftsNoEnc = FtsManager(store, const [_def]);
      await ftsNoEnc.checkAndTransitionOnOpen();
      await ftsNoEnc.ensureBuilt(_ns, _field);

      final decodedState = await _readFtsState(store);
      expect(decodedState.status, equals(FtsIndexStatus.current));
      expect(decodedState.tokenMode, equals(FtsTokenMode.hex));

      // Snapshot the hex-mode base-term namespaces before migration.
      final namespacesBeforeMigration = (await store.allStoredNamespaces())
          .where((n) => n.startsWith(r'$$fts:docs:body:'))
          .toSet();
      expect(namespacesBeforeMigration, isNotEmpty);

      // ── Phase 2: "reopen" with an EncryptionProvider configured — a
      // second FtsManager over the same store, exactly as
      // KmdbDatabase.open() would construct after its encryption
      // bootstrap runs. ──────────────────────────────────────────────
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      store.meta.encryption = provider; // Q1 bootstrap-ordering.

      final ftsEnc = FtsManager(store, const [_def], encryption: provider);
      await ftsEnc.checkAndTransitionOnOpen();

      // The mismatch must reset the index to undefined immediately (not
      // merely `stale`) and purge the stale-mode base entries — leaving
      // them in place would defeat Gap 2 by keeping the plaintext-
      // derivable hex tokens on disk indefinitely.
      final namespacesAfterCheck = (await store.allStoredNamespaces())
          .where((n) => n.startsWith(r'$$fts:docs:body:'))
          .toSet();
      expect(
        namespacesAfterCheck.intersection(namespacesBeforeMigration),
        isEmpty,
        reason:
            'stale hex-mode base namespaces must be purged, not left '
            'as orphaned plaintext-derivable entries',
      );

      // ── Phase 3: the index rebuilds lazily (HMAC tokens) and search
      // finds the same document correctly. ──────────────────────────
      final result = await ftsEnc.search<Map<String, dynamic>>(
        namespace: _ns,
        query: 'quick',
        fields: [_field],
        fetchDoc: (id) async {
          final bytes = await store.get(_ns, id);
          if (bytes == null) return null;
          return ValueCodec.decode(bytes, encryption: provider);
        },
      );
      expect(result.hits, hasLength(1));
      expect(result.hits.first.id, equals('01900000000070008000000000000001'));

      final stateAfterRebuild = await _readFtsState(store, provider);
      expect(stateAfterRebuild.status, equals(FtsIndexStatus.current));
      expect(stateAfterRebuild.tokenMode, equals(FtsTokenMode.hmac));

      // The rebuilt base namespaces are new HMAC-mode namespaces, entirely
      // disjoint from the purged hex-mode set.
      final namespacesAfterRebuild = (await store.allStoredNamespaces())
          .where((n) => n.startsWith(r'$$fts:docs:body:'))
          .toSet();
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
        'body': 'a second unencrypted document',
      });

      final fts1 = FtsManager(store, const [_def]);
      await fts1.checkAndTransitionOnOpen();
      await fts1.ensureBuilt(_ns, _field);

      final namespacesBefore = (await store.allStoredNamespaces())
          .where((n) => n.startsWith(r'$$fts:docs:body:'))
          .toSet();
      expect(namespacesBefore, isNotEmpty);

      // "Reopen" without any EncryptionProvider — a second FtsManager
      // instance over the same store, still unencrypted.
      final fts2 = FtsManager(store, const [_def]);
      await fts2.checkAndTransitionOnOpen();

      final stateAfterReopen = await _readFtsState(store);
      // Status must remain `current` — checkAndTransitionOnOpen must not
      // have reset it to `undefined`.
      expect(stateAfterReopen.status, equals(FtsIndexStatus.current));
      expect(stateAfterReopen.tokenMode, equals(FtsTokenMode.hex));

      final namespacesAfter = (await store.allStoredNamespaces())
          .where((n) => n.startsWith(r'$$fts:docs:body:'))
          .toSet();
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
        'body': 'searchable encrypted content here',
      });

      final fts = FtsManager(store, const [_def], encryption: provider);
      await fts.checkAndTransitionOnOpen();
      await fts.ensureBuilt(_ns, _field);

      // A second manager instance (same store, same provider) must be
      // able to read what the first wrote — the token derivation is a
      // pure function of (message, DEK), not manager-instance state.
      final ftsReader = FtsManager(store, const [_def], encryption: provider);
      await ftsReader.checkAndTransitionOnOpen(); // no mismatch expected

      final result = await ftsReader.search<Map<String, dynamic>>(
        namespace: _ns,
        query: 'searchable',
        fields: [_field],
        fetchDoc: (id) async {
          final bytes = await store.get(_ns, id);
          if (bytes == null) return null;
          return ValueCodec.decode(bytes, encryption: provider);
        },
      );
      expect(result.hits, hasLength(1));
    });
  });
}
