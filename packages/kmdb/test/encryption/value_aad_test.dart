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

/// Behavioural tests for the AES-GCM associated-data binding introduced by
/// 0.10.01 WI-3 (finding E-2): [ValueContext] (`(namespace, key)`) is folded
/// into every encrypted value's AAD, so a ciphertext authenticates only at
/// the coordinates it was written to.
///
/// **Every test here uses the real [AesGcmEncryptionProvider]** — never a
/// toy/no-op provider — because only the real provider's GCM tag actually
/// covers the AAD. A test built on a provider that ignores its `aad`
/// parameter would pass vacuously and prove nothing (the reviewer's
/// specific warning during plan review).
///
/// Covers:
/// - Relocation (same namespace, different key) and cross-namespace
///   transplant — the core fix.
/// - `$ver:` isolation — a version-history ciphertext cannot be transplanted
///   into the live document slot at the same key.
/// - The documented scope boundary: AAD binds *location*, not *freshness* —
///   a rollback (older ciphertext replayed at the same key) still
///   authenticates. This is intentional (deferred to WI-4) and this test
///   pins that boundary so it is not later mistaken for a regression.
/// - `version:config`'s double-encryption (outer [EncryptionEnvelope] +
///   inner [ValueCodec]).
/// - A round-trip for every [ValueContext] named constructor.
/// - Old-format database rejection (`formatVersion` marker < current).
/// - Fault injection via [FaultyStorageAdapter] (CLAUDE.md requirement).
/// - The compaction `$ver:`-drop deviation ([DroppedVersionEntry]).
///
/// Unit tests for [ValueContext]'s own byte composition (not behavioural)
/// live in `value_context_test.dart`. Vault-blob/extract/manifest-name
/// relocation tests live alongside their existing encryption test files
/// (`vault_encryption_test.dart`, `vault_extract_encryption_test.dart`) since
/// they need the full [VaultStore]/[VaultSearchManager] machinery.
library;

import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/encryption_envelope.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/encryption/value_context.dart';
import 'package:kmdb/src/engine/compaction/reclamation_policy.dart';
import 'package:kmdb/src/engine/kvstore/crash_recovery.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/versioning/version_config.dart';
import 'package:kmdb/src/versioning/version_entry.dart';
import 'package:kmdb/src/versioning/version_manager.dart';
import 'package:kmdb/src/versioning/version_retention_policy.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

/// Matches an [EncryptionError] whose [EncryptionError.code] is
/// [EncryptionErrorCode.badCredentials] — the code AES-GCM authentication
/// failure surfaces as, regardless of whether the cause was a wrong key, a
/// tampered ciphertext, or (as in every test in this file) an AAD mismatch
/// from a relocated/transplanted value.
final _authFails = throwsA(
  isA<EncryptionError>().having(
    (e) => e.code,
    'code',
    EncryptionErrorCode.badCredentials,
  ),
);

const _kPassphrase = 'value-aad-test-passphrase';
final _keyGen = SequentialKeyGenerator();

/// Minimal [KmdbCodec] for `Map<String, dynamic>` documents, mirroring the
/// one in `encryption_crash_test.dart`.
final class _MapCodec implements KmdbCodec<Map<String, dynamic>> {
  const _MapCodec();

  @override
  String keyOf(Map<String, dynamic> value) =>
      (value['_id'] ?? 'unknown') as String;

  @override
  Map<String, dynamic> withKey(Map<String, dynamic> value, String key) => {
    ...value,
    '_id': key,
  };

  @override
  Map<String, dynamic> encode(Map<String, dynamic> value) {
    final result = Map<String, dynamic>.from(value);
    result.remove('_id');
    return result;
  }

  @override
  Map<String, dynamic> decode(Map<String, dynamic> json) => json;
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  late Uint8List dek;
  late AesGcmEncryptionProvider provider;

  setUpAll(() async {
    dek = await KeyDerivation.generateDek();
  });

  setUp(() {
    provider = AesGcmEncryptionProvider(dek);
  });

  // ── Relocation and transplant (the core fix) ──────────────────────────────

  group('Relocation and cross-namespace transplant', () {
    test('a ciphertext relocated to a different key in the SAME namespace '
        'fails GCM authentication', () async {
      final encoded = await ValueCodec.encode(
        {'secret': 'value'},
        context: const ValueContext('tasks', 'key-A'),
        encryption: provider,
      );

      // "Attacker" places the valid ciphertext at a different key.
      await expectLater(
        ValueCodec.decode(
          encoded,
          context: const ValueContext('tasks', 'key-B'),
          encryption: provider,
        ),
        _authFails,
      );
    });

    test('a ciphertext transplanted into a DIFFERENT namespace at the same key '
        'fails GCM authentication', () async {
      final encoded = await ValueCodec.encode(
        {'secret': 'value'},
        context: const ValueContext('tasks', 'shared-key'),
        encryption: provider,
      );

      await expectLater(
        ValueCodec.decode(
          encoded,
          context: const ValueContext('notes', 'shared-key'),
          encryption: provider,
        ),
        _authFails,
      );
    });

    test('the same relocation/transplant failure applies at the '
        'EncryptionEnvelope layer (not just ValueCodec)', () async {
      final wrapped = await EncryptionEnvelope.wrap(
        Uint8List.fromList([1, 2, 3, 4]),
        provider,
        context: const ValueContext(r'$meta', 'name-A'),
      );

      await expectLater(
        EncryptionEnvelope.unwrap(
          wrapped,
          provider,
          context: const ValueContext(r'$meta', 'name-B'),
        ),
        _authFails,
      );
    });

    test('the correct (namespace, key) round-trips cleanly — sanity check that '
        'the relocation tests above fail for the right reason', () async {
      const ctx = ValueContext('tasks', 'key-A');
      final encoded = await ValueCodec.encode(
        {'secret': 'value'},
        context: ctx,
        encryption: provider,
      );
      final decoded = await ValueCodec.decode(
        encoded,
        context: ctx,
        encryption: provider,
      );
      expect(decoded['secret'], equals('value'));
    });
  });

  // ── `$ver:` isolation ──────────────────────────────────────────────────────

  group(r'$ver: isolation', () {
    test(r'a $ver:{ns} ciphertext transplanted into the live {ns} slot at the '
        'same key fails authentication (namespace differs)', () async {
      final verNs = versionNamespace('tasks');
      final encoded = await ValueCodec.encode(
        {'body': 'historical snapshot'},
        context: ValueContext(verNs, 'doc-1'),
        encryption: provider,
      );

      await expectLater(
        ValueCodec.decode(
          encoded,
          context: const ValueContext('tasks', 'doc-1'),
          encryption: provider,
        ),
        _authFails,
      );
    });

    test('the reverse direction also fails: a live-namespace ciphertext placed '
        r'in the $ver: slot at the same key', () async {
      final encoded = await ValueCodec.encode(
        {'body': 'live value'},
        context: const ValueContext('tasks', 'doc-1'),
        encryption: provider,
      );
      final verNs = versionNamespace('tasks');

      await expectLater(
        ValueCodec.decode(
          encoded,
          context: ValueContext(verNs, 'doc-1'),
          encryption: provider,
        ),
        _authFails,
      );
    });

    test(r'VersionEntry.encode/decode round-trips using its real $ver:{ns} '
        'context', () async {
      final verNs = versionNamespace('tasks');
      final context = ValueContext(verNs, 'doc-1');
      final innerDoc = await ValueCodec.encode(
        {'title': 'hello'},
        context: const ValueContext('tasks', 'doc-1'),
        encryption: provider,
      );
      final entry = VersionEntry(hlc: const Hlc(0, 0), encodedValue: innerDoc);

      final bytes = await entry.encode(context: context, encryption: provider);
      final decoded = await VersionEntry.decode(
        bytes,
        context: context,
        encryption: provider,
      );
      expect(decoded.encodedValue, equals(innerDoc));
    });
  });

  // ── Scope boundary: location, not freshness ───────────────────────────────

  group('Scope boundary — AAD binds location, not freshness', () {
    test('replacing a value with an OLDER ciphertext at the SAME (namespace, '
        'key) still authenticates — E-2 does not detect rollback/replay '
        '(intentional; deferred to WI-4). This test pins the boundary so it '
        'is not mistaken for a regression later.', () async {
      const ctx = ValueContext('tasks', 'doc-1');
      final v1 = await ValueCodec.encode(
        {'body': 'v1 — original'},
        context: ctx,
        encryption: provider,
      );
      final v2 = await ValueCodec.encode(
        {'body': 'v2 — newer'},
        context: ctx,
        encryption: provider,
      );
      expect(v1, isNot(equals(v2)));

      // An "attacker" (or a buggy sync peer) re-places the OLDER
      // ciphertext (v1) at the same (namespace, key) that currently holds
      // v2 — a textbook rollback/replay. Because the AAD is unchanged
      // (same namespace + key), this authenticates cleanly.
      final decoded = await ValueCodec.decode(
        v1,
        context: ctx,
        encryption: provider,
      );
      expect(
        decoded['body'],
        equals('v1 — original'),
        reason:
            'The stale value decrypts and authenticates — E-2 fixes '
            'relocation/transplant, not rollback. Freshness binding '
            'requires the write-HLC, which is not available at encrypt '
            'time (see the plan\'s "Resolved scope decision").',
      );
    });
  });

  // ── version:config double-encryption ──────────────────────────────────────

  group('version:config double-encryption round-trip', () {
    test('VersionConfigStore.put/get round-trips correctly through BOTH '
        'encryption layers (outer EncryptionEnvelope via MetaStore, inner '
        'ValueCodec), each bound with ValueContext.meta for the same config '
        'key', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await KvStoreImpl.open(
        '/db',
        adapter,
        config: KvStoreConfig.forTesting(),
      );
      store.meta.encryption = provider;
      final configStore = VersionConfigStore(store.meta);

      const cfg = VersionConfig(maxVersions: 7, retentionDays: 42);
      await configStore.put('tasks', cfg, encryption: provider);

      // The outer EncryptionEnvelope layer must be genuinely active: the
      // raw bytes under $meta must start with EncryptionFlag.aesGcm, not
      // be plaintext-inspectable.
      final rawKey = MetaStore.symbolicKey('version:config:tasks');
      final raw = await store.get(MetaStore.kNamespace, rawKey);
      expect(raw, isNotNull);
      expect(raw![0], equals(1)); // EncryptionFlag.aesGcm.byte

      final readBack = await configStore.get('tasks', encryption: provider);
      expect(readBack, equals(cfg));

      // A wrong provider must fail at (at least) the outer layer.
      final wrongDek = await KeyDerivation.generateDek();
      final wrongProvider = AesGcmEncryptionProvider(wrongDek);
      await expectLater(
        configStore.get('tasks', encryption: wrongProvider),
        // VersionConfigStore.get catches decode failures and falls back to
        // VersionConfig.defaults (defensive posture) — so the observable
        // effect of a wrong key is "silently returns defaults", not a
        // thrown exception. Assert that fallback explicitly, since a
        // raw exception assertion would be wrong here.
        completion(equals(VersionConfig.defaults)),
      );

      await store.close();
    });
  });

  // ── Round-trip per ValueContext constructor / value class ─────────────────

  group('Round-trip per ValueContext constructor', () {
    test('base ValueContext(namespace, key) — collection documents', () async {
      const ctx = ValueContext('tasks', 'doc-1');
      final encoded = await ValueCodec.encode(
        {'a': 1},
        context: ctx,
        encryption: provider,
      );
      final decoded = await ValueCodec.decode(
        encoded,
        context: ctx,
        encryption: provider,
      );
      expect(decoded['a'], equals(1));
    });

    test(r'ValueContext.meta — $meta / $$…state symbolic names', () async {
      final ctx = ValueContext.meta('gen:tasks');
      final wrapped = await EncryptionEnvelope.wrap(
        Uint8List.fromList([9, 8, 7]),
        provider,
        context: ctx,
      );
      final unwrapped = await EncryptionEnvelope.unwrap(
        wrapped,
        provider,
        context: ctx,
      );
      expect(unwrapped, equals(Uint8List.fromList([9, 8, 7])));
    });

    test('ValueContext.vaultBlob — vault blob bytes keyed by sha256', () async {
      final ctx = ValueContext.vaultBlob('a' * 64);
      final wrapped = await EncryptionEnvelope.wrap(
        Uint8List.fromList([1, 2, 3]),
        provider,
        context: ctx,
      );
      final unwrapped = await EncryptionEnvelope.unwrap(
        wrapped,
        provider,
        context: ctx,
      );
      expect(unwrapped, equals(Uint8List.fromList([1, 2, 3])));
    });

    test(
      'ValueContext.vaultExtract — extract/ artifact files keyed by path',
      () async {
        final ctx = ValueContext.vaultExtract('extract/text.txt');
        final wrapped = await EncryptionEnvelope.wrap(
          Uint8List.fromList([4, 5, 6]),
          provider,
          context: ctx,
        );
        final unwrapped = await EncryptionEnvelope.unwrap(
          wrapped,
          provider,
          context: ctx,
        );
        expect(unwrapped, equals(Uint8List.fromList([4, 5, 6])));
      },
    );

    test('ValueContext.vaultManifestName — manifest originalName keyed by '
        'sha256', () async {
      final ctx = ValueContext.vaultManifestName('b' * 64);
      final wrapped = await EncryptionEnvelope.wrap(
        Uint8List.fromList([7, 8, 9]),
        provider,
        context: ctx,
      );
      final unwrapped = await EncryptionEnvelope.unwrap(
        wrapped,
        provider,
        context: ctx,
      );
      expect(unwrapped, equals(Uint8List.fromList([7, 8, 9])));
    });

    test('ValueContext.vaultCorpus — corpus sentinel entry', () async {
      final ctx = ValueContext.vaultCorpus(
        r'$$vault:fts:' + ('c' * 64),
        'sentinel',
      );
      final wrapped = await EncryptionEnvelope.wrap(
        Uint8List.fromList([1, 1, 1]),
        provider,
        context: ctx,
      );
      final unwrapped = await EncryptionEnvelope.unwrap(
        wrapped,
        provider,
        context: ctx,
      );
      expect(unwrapped, equals(Uint8List.fromList([1, 1, 1])));
    });
  });

  // ── Old-format database rejection ─────────────────────────────────────────

  group('Old-format database rejection', () {
    test('a database whose formatVersion marker is 1 (predating this plan) '
        'fails to open via the NEW `< kCurrentFormatVersion` branch — not '
        'merely the pre-existing null-marker branch', () async {
      final adapter = MemoryStorageAdapter();

      // Seed a database directly at the engine level whose ONLY $meta
      // content is a formatVersion marker of 1 — modelling a real
      // pre-WI-3 database (format version 1) that predates the AAD
      // binding, bypassing KvStoreImpl.open's gate so a genuinely "raw"
      // v1 marker can be written (mirrors meta_store_encryption_test.dart's
      // _seedLegacyDatabase pattern).
      final recovery = CrashRecovery(
        adapter: adapter,
        config: KvStoreConfig.forTesting(),
      );
      final (engine, _) = await recovery.open('/db', deviceId: 'testdev1');
      final meta = MetaStore(engine);
      engine.setMetaStore(meta);
      await engine.put(
        MetaStore.kNamespace,
        MetaStore.symbolicKey(MetaStore.kFormatVersionMarkerName),
        Uint8List.fromList([1]),
      );
      final seedStore = KvStoreImpl.forTesting(
        engine,
        meta,
        KvStoreConfig.forTesting(),
        dirtyFlagPresent: false,
      );
      await seedStore.close();

      // Reopening through the normal gate must throw
      // LegacyDatabaseFormatException with foundVersion=1 and
      // currentVersion=MetaStore.kCurrentFormatVersion (2) — proving the
      // `else if (formatVersion < kCurrentFormatVersion)` branch fired,
      // not merely the pre-existing `formatVersion == null` branch (which
      // would NOT have caught this case, since the marker IS present).
      await expectLater(
        KvStoreImpl.open(
          '/db',
          adapter,
          config: KvStoreConfig.forTesting(),
          deviceId: 'testdev1',
        ),
        throwsA(
          isA<LegacyDatabaseFormatException>()
              .having((e) => e.foundVersion, 'foundVersion', equals(1))
              .having(
                (e) => e.currentVersion,
                'currentVersion',
                equals(MetaStore.kCurrentFormatVersion),
              ),
        ),
      );
    });

    test('a brand-new database is stamped with kCurrentFormatVersion (2), not '
        'the old value 1', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await KvStoreImpl.open(
        '/db',
        adapter,
        config: KvStoreConfig.forTesting(),
      );
      expect(
        await store.meta.getFormatVersionMarker(),
        equals(MetaStore.kCurrentFormatVersion),
      );
      expect(MetaStore.kCurrentFormatVersion, equals(2));
      await store.close();
    });
  });

  // ── Fault injection (CLAUDE.md requirement) ───────────────────────────────

  group('Fault injection (FaultyStorageAdapter)', () {
    test('an AAD-bound encrypted value (and its companion \$ver: entry), '
        'written and then recovered via WAL replay after a simulated crash, '
        'still authenticates on reopen', () async {
      final faultyAdapter = FaultyStorageAdapter();
      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );

      // fsyncOnWrite: true so the write below is durable (in the WAL) but
      // NOT yet flushed into an SSTable — reopening must go through WAL
      // replay, not merely re-read an already-flushed SSTable.
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: faultyAdapter,
        config: const KvStoreConfig(fsyncOnWrite: true),
        encryptionConfig: result.config,
      );
      final col = db.collection<Map<String, dynamic>>(
        name: 'notes',
        codec: const _MapCodec(),
      );
      final key = _keyGen.next();
      await col.put({'_id': key, 'value': 'aad-protected-secret'});

      // Crash WITHOUT an explicit flush — the write survives only because
      // it was fsync'd to the WAL; recovery must replay it.
      await db.close(flush: false);
      faultyAdapter.crash();

      final db2 = await KmdbDatabase.open(
        path: '/db',
        adapter: faultyAdapter,
        config: const KvStoreConfig(fsyncOnWrite: true),
        encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
      );
      final col2 = db2.collection<Map<String, dynamic>>(
        name: 'notes',
        codec: const _MapCodec(),
      );

      // The live document authenticates and decrypts correctly.
      final recovered = await col2.get(key);
      expect(recovered, isNotNull);
      expect(recovered!['value'], equals('aad-protected-secret'));

      // Its companion $ver: entry (versioning defaults to enabled) also
      // authenticates and decrypts correctly through the same recovered
      // encryption context.
      final versions = await col2.getVersions(key);
      expect(versions, isNotEmpty);
      expect(versions.first.value?['value'], equals('aad-protected-secret'));

      await db2.close();
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a crash between the format-version marker/enc:blob write and the '
        'first encrypted user value leaves the database safely reopenable — '
        'the un-synced user value is simply lost, never partially/incorrectly '
        'decodable', () async {
      final faultyAdapter = FaultyStorageAdapter();
      final result = await EncryptionConfig.createResult(
        passphrase: _kPassphrase,
      );

      // Opening durably writes the format marker + enc:blob during
      // open(), strictly before any user value can be written (open() has
      // not yet returned to the caller).
      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: faultyAdapter,
        config: KvStoreConfig.forTesting(), // fsyncOnWrite: false
        encryptionConfig: result.config,
      );

      final col = db.collection<Map<String, dynamic>>(
        name: 'notes',
        codec: const _MapCodec(),
      );
      final key = _keyGen.next();
      await col.put({'_id': key, 'value': 'may-or-may-not-survive'});

      // Crash before this write (or even the marker itself) is fsync'd —
      // with fsyncOnWrite: false, the ENTIRE un-synced session (marker,
      // enc:blob, and the user write) can be lost together, or all of it
      // can survive together (each is written via the same underlying WAL
      // append path) — never a partial mix of the two.
      await db.close(flush: false);
      faultyAdapter.crash();

      // Two safe outcomes are possible; the UNSAFE one this plan's format
      // gate exists to prevent — a marker/enc:blob durably present while
      // the format is otherwise inconsistent — must never occur.
      bool consistentStateAchieved = false;
      try {
        // Outcome (b): the marker + enc:blob (+ possibly the user write)
        // survived the crash — unlocking with the passphrase must succeed.
        final db2 = await KmdbDatabase.open(
          path: '/db',
          adapter: faultyAdapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
        );
        final col2 = db2.collection<Map<String, dynamic>>(
          name: 'notes',
          codec: const _MapCodec(),
        );
        // Either the value survived and authenticates correctly, or it
        // was lost entirely to the crash — never a corrupt/partial read.
        final recovered = await col2.get(key);
        if (recovered != null) {
          expect(recovered['value'], equals('may-or-may-not-survive'));
        }
        await db2.close();
        consistentStateAchieved = true;
      } on EncryptionError catch (e) {
        // Outcome (a): nothing survived the crash — the database looks
        // like a fresh, unencrypted database again, so unlocking with a
        // passphrase correctly fails with databaseIsNotEncrypted (there is
        // nothing to unlock).
        expect(e.code, equals(EncryptionErrorCode.databaseIsNotEncrypted));

        // Confirm outcome (a) fully: a plain (no unlock config) open must
        // now succeed, and the partially-written user value is simply
        // absent — never corrupt or partially decodable.
        final db3 = await KmdbDatabase.open(
          path: '/db',
          adapter: faultyAdapter,
          config: KvStoreConfig.forTesting(),
        );
        final col3 = db3.collection<Map<String, dynamic>>(
          name: 'notes',
          codec: const _MapCodec(),
        );
        expect(await col3.get(key), isNull);
        await db3.close();
        consistentStateAchieved = true;
      }

      expect(consistentStateAchieved, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ── Compaction $ver:-drop deviation (DroppedVersionEntry) ─────────────────

  group('Compaction \$ver:-drop deviation (DroppedVersionEntry)', () {
    test('the version-drop callback receives the correct (namespace, docKey) '
        'for each trimmed \$ver: entry, and the entries it decodes actually '
        'authenticate under real AES-GCM encryption (0.10.01 WI-3 deviation — '
        'not in the reviewer\'s original census)', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await KvStoreImpl.open(
        '/db',
        adapter,
        config: KvStoreConfig.forTesting(),
      );
      store.meta.encryption = provider;

      const ns = 'files';
      final verNs = versionNamespace(ns);
      const docKey = '01900000000070008000000000000009';

      // Trim $ver:files down to the newest 1 entry at compaction time.
      store.setVersionRegistryProvider(
        () async => ReclamationPolicyRegistry.withVersionPolicies({
          verNs: const VersionRetentionPolicy(VersionConfig(maxVersions: 1)),
        }),
      );

      final captured = <DroppedVersionEntry>[];
      store.setVersionDropCallback((dropped) async {
        captured.addAll(dropped);
      });

      // Write 3 successive live-document + $ver: entry pairs, all
      // encrypted with the real provider — mirroring what
      // VaultRefInterceptor + VersionWriteAugmentor produce together in
      // production (kmdb_database.dart's real callback).
      for (var i = 1; i <= 3; i++) {
        final liveCtx = ValueContext(ns, docKey);
        final docBytes = await ValueCodec.encode(
          {'body': 'v$i'},
          context: liveCtx,
          encryption: provider,
        );
        final verCtx = ValueContext(verNs, docKey);
        final entry = VersionEntry(
          hlc: const Hlc(0, 0),
          encodedValue: docBytes,
        );
        final verBytes = await entry.encode(
          context: verCtx,
          encryption: provider,
        );

        final batch = WriteBatch()
          ..put(ns, docKey, docBytes)
          ..put(verNs, docKey, verBytes);
        // writeBatchInternal (not the public writeBatch) is used because
        // $ver:* is a reserved system namespace that the public API
        // rejects — this mirrors how VersionWriteAugmentor's $ver: writes
        // reach the engine (via the internal path), not a workaround.
        await store.writeBatchInternal(batch);
      }

      await store.flush();
      await store.compactAll();

      expect(
        captured,
        isNotEmpty,
        reason: 'maxVersions=1 with 3 writes must trim at least one entry',
      );

      for (final dropped in captured) {
        expect(dropped.namespace, equals(verNs));
        expect(dropped.docKey, equals(docKey));

        // The critical assertion: VersionEntry.decode succeeds using the
        // context RECONSTRUCTED from DroppedVersionEntry's namespace/docKey
        // — exactly what KmdbDatabase's real callback does — under real
        // AES-GCM encryption.
        final decodedEntry = await VersionEntry.decode(
          dropped.value,
          context: ValueContext(dropped.namespace, dropped.docKey),
          encryption: provider,
        );
        expect(decodedEntry.encodedValue, isNotNull);

        // The nested encodedValue was encrypted under the LIVE namespace,
        // not $ver: — strip the fixed prefix, exactly as
        // KmdbDatabase's real callback does.
        final liveNamespace = dropped.namespace.substring(
          kVersionNamespacePrefix.length,
        );
        final decodedDoc = await ValueCodec.decode(
          decodedEntry.encodedValue!,
          context: ValueContext(liveNamespace, dropped.docKey),
          encryption: provider,
        );
        expect(decodedDoc['body'], isNotNull);

        // Regression guard: a WRONG context (mismatched docKey) must fail
        // GCM authentication — proving this binding is load-bearing, not
        // vacuous. If DroppedVersionEntry ever stopped carrying the real
        // docKey, this is the assertion that would catch it (the decode
        // above would then also fail, silently, inside the production
        // callback's catch-and-skip).
        await expectLater(
          VersionEntry.decode(
            dropped.value,
            context: const ValueContext(
              r'$ver:files',
              'wrong-key-does-not-match',
            ),
            encryption: provider,
          ),
          _authFails,
        );
      }

      await store.close();
    });
  });
}
