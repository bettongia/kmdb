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

import 'package:kmdb/src/encryption/dek_cache.dart';
import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_collection.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

// ── Test model ────────────────────────────────────────────────────────────────

final class _Note {
  const _Note({required this.id, required this.text});
  final String id;
  final String text;
}

final class _NoteCodec implements KmdbCodec<_Note> {
  const _NoteCodec();

  @override
  String keyOf(_Note value) => value.id;

  @override
  _Note withKey(_Note value, String key) => _Note(id: key, text: value.text);

  @override
  Map<String, dynamic> encode(_Note value) => {'text': value.text};

  @override
  _Note decode(Map<String, dynamic> json) =>
      _Note(id: json['_id'] as String, text: json['text'] as String);
}

const _codec = _NoteCodec();
const _kPassphrase = 'test-passphrase-123';

// Sequential key generator for creating valid UUIDv7-format keys.
final _keyGen = SequentialKeyGenerator();

String _key() => _keyGen.next();

/// Opens a fresh in-memory database with the given [encryptionConfig].
Future<(KmdbDatabase, KmdbCollection<_Note>, MemoryStorageAdapter)> _openFresh({
  EncryptionConfig? encryptionConfig,
}) async {
  final adapter = MemoryStorageAdapter();
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    config: KvStoreConfig.forTesting(),
    encryptionConfig: encryptionConfig,
  );
  final col = db.collection(name: 'notes', codec: _codec);
  return (db, col, adapter);
}

/// Re-opens the same [adapter] with a new [KmdbDatabase].
Future<(KmdbDatabase, KmdbCollection<_Note>)> _reopen(
  MemoryStorageAdapter adapter, {
  EncryptionConfig? encryptionConfig,
}) async {
  final db = await KmdbDatabase.open(
    path: '/db',
    adapter: adapter,
    config: KvStoreConfig.forTesting(),
    encryptionConfig: encryptionConfig,
  );
  final col = db.collection(name: 'notes', codec: _codec);
  return (db, col);
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── State 1: plaintext open (no blob, no config) ─────────────────────────────

  group('Unencrypted database (State 1)', () {
    test('opens normally without an EncryptionConfig', () async {
      final (db, col, adapter) = await _openFresh();
      // Verify we can close without errors (col and adapter are unused but
      // destructured to satisfy the record type).
      await db.close();
      expect(col, isNotNull);
      expect(adapter, isNotNull);
    });

    test('put and get round-trips in a plaintext database', () async {
      final (db, col, _) = await _openFresh();
      final id = _key();
      await col.put(_Note(id: id, text: 'hello'));
      final note = await col.get(id);
      expect(note?.text, equals('hello'));
      await db.close();
    });
  });

  // ── State 4: provisioning (no blob, create config) ────────────────────────────

  group(
    'Encrypted database provisioning (State 4)',
    () {
      test(
        'createResult returns a config and a 16-word recovery code',
        () async {
          final result = await EncryptionConfig.createResult(
            passphrase: _kPassphrase,
          );
          expect(result.recoveryCode.split(' '), hasLength(16));
          expect(result.config.isProvisioning, isTrue);
        },
      );

      test('provisioned database opens successfully', () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db, col, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        await db.close();
        expect(col, isNotNull);
        expect(adapter, isNotNull);
      });

      test('put and get round-trips in an encrypted database', () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db, col, _) = await _openFresh(encryptionConfig: result.config);
        final id = _key();
        await col.put(_Note(id: id, text: 'secret'));
        final note = await col.get(id);
        expect(note?.text, equals('secret'));
        await db.close();
      });

      test(
        'provisioning on a non-empty database throws cannotProvisionNonEmptyDatabase',
        () async {
          // Open plaintext, insert data, close.
          final (db1, col1, adapter) = await _openFresh();
          await col1.put(_Note(id: _key(), text: 'data'));
          await db1.close();

          // Now try to provision encryption — must fail.
          final result = await EncryptionConfig.createResult(
            passphrase: _kPassphrase,
          );
          expect(
            () async => _reopen(adapter, encryptionConfig: result.config),
            throwsA(
              isA<EncryptionError>().having(
                (e) => e.code,
                'code',
                EncryptionErrorCode.cannotProvisionNonEmptyDatabase,
              ),
            ),
          );
        },
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  // ── State 5: unlock (blob present, config supplied) ───────────────────────────

  group('Encrypted database unlock (State 5)', () {
    test(
      'write encrypted → close → reopen with correct passphrase → read back',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db1, col1, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        final id = _key();
        await col1.put(_Note(id: id, text: 'secret note'));
        await db1.close();

        // Reopen with passphrase.
        final unlockConfig = EncryptionConfig(passphrase: _kPassphrase);
        final (db2, col2) = await _reopen(
          adapter,
          encryptionConfig: unlockConfig,
        );
        final note = await col2.get(id);
        expect(note?.text, equals('secret note'));
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'write encrypted → close → reopen with recovery code → read back',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final recoveryCode = result.recoveryCode;

        final (db1, col1, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        final id = _key();
        await col1.put(_Note(id: id, text: 'recovery note'));
        await db1.close();

        // Reopen with the recovery code.
        final rcConfig = EncryptionConfig(recoveryCode: recoveryCode);
        final (db2, col2) = await _reopen(adapter, encryptionConfig: rcConfig);
        final note = await col2.get(id);
        expect(note?.text, equals('recovery note'));
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'wrong passphrase throws EncryptionError.badCredentials',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db1, _, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        await db1.close();

        final wrongConfig = EncryptionConfig(passphrase: 'wrong-passphrase');
        expect(
          () async => _reopen(adapter, encryptionConfig: wrongConfig),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.badCredentials,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'multiple documents are stored encrypted and readable after reopen',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db1, col1, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );

        final keys = List.generate(10, (_) => _key());
        for (var i = 0; i < 10; i++) {
          await col1.put(_Note(id: keys[i], text: 'note number $i'));
        }
        await db1.close();

        final unlockConfig = EncryptionConfig(passphrase: _kPassphrase);
        final (db2, col2) = await _reopen(
          adapter,
          encryptionConfig: unlockConfig,
        );

        for (var i = 0; i < 10; i++) {
          final note = await col2.get(keys[i]);
          expect(note?.text, equals('note number $i'), reason: 'note index $i');
        }
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ── State 2: encrypted DB opened without config ──────────────────────────────

  group('Encrypted database opened without config (State 2)', () {
    test(
      'throws EncryptionError.databaseIsEncrypted',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db1, _, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        await db1.close();

        // Open without supplying any encryption config.
        expect(
          () async => _reopen(adapter),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.databaseIsEncrypted,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ── State 3: unlock config on plaintext DB ────────────────────────────────────

  group('Unlock config on plaintext database (State 3)', () {
    test('throws EncryptionError.databaseIsNotEncrypted', () async {
      // Open and close a plaintext database.
      final (db1, _, adapter) = await _openFresh();
      await db1.close();

      // Supply an unlock config to a plaintext database — must fail.
      final unlockConfig = EncryptionConfig(passphrase: _kPassphrase);
      expect(
        () async => _reopen(adapter, encryptionConfig: unlockConfig),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.databaseIsNotEncrypted,
          ),
        ),
      );
    });
  });

  // ── SSTable ciphertext verification ──────────────────────────────────────────

  group('Encrypted SSTable contents are opaque', () {
    test(
      'stored SSTable bytes do not contain plaintext document text',
      () async {
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db, col, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );

        const secretText = 'my-top-secret-data-UNIQUESTRING';
        await col.put(_Note(id: _key(), text: secretText));
        // close() with flush=true (default) flushes the memtable to SSTable.
        await db.close();

        // Inspect every file in the adapter for the plaintext string.
        final secretBytes = secretText.codeUnits;
        bool foundPlaintext = false;
        outer:
        for (final fileBytes in adapter.files.values) {
          // Simple byte-search for the ASCII bytes of the secret string.
          for (var i = 0; i <= fileBytes.length - secretBytes.length; i++) {
            bool match = true;
            for (var j = 0; j < secretBytes.length; j++) {
              if (fileBytes[i + j] != secretBytes[j]) {
                match = false;
                break;
              }
            }
            if (match) {
              foundPlaintext = true;
              break outer;
            }
          }
        }

        expect(
          foundPlaintext,
          isFalse,
          reason:
              'Plaintext "$secretText" was found in the storage adapter — '
              'values are not encrypted correctly.',
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ── DEK cache integration ────────────────────────────────────────────────────

  group('DEK cache integration', () {
    test(
      'InMemoryDekCache allows reopen without re-deriving from passphrase',
      () async {
        // Use the same DekCache instance across both open() calls.
        // The second open() reads from InMemoryDekCache and skips Argon2id.
        final cache = InMemoryDekCache();
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
          dekCache: cache,
        );

        final (db1, col1, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        final id = _key();
        await col1.put(_Note(id: id, text: 'cached-value'));
        await db1.close();

        // Second open — uses the same cache (DEK already stored, no Argon2id).
        final unlockConfig = EncryptionConfig(
          passphrase: _kPassphrase,
          dekCache: cache,
        );
        final (db2, col2) = await _reopen(
          adapter,
          encryptionConfig: unlockConfig,
        );
        final note = await col2.get(id);
        expect(note?.text, equals('cached-value'));
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ── Passphrase change ────────────────────────────────────────────────────────

  group('Passphrase change', () {
    test(
      'data is accessible after changing the passphrase',
      () async {
        const newPassphrase = 'new-passphrase-456';

        // Provision with the initial passphrase and write some data.
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db1, col1, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        final id = _key();
        await col1.put(_Note(id: id, text: 'before-passphrase-change'));

        // Change the passphrase while the database is still open.
        await db1.changePassphrase(
          currentConfig: EncryptionConfig(passphrase: _kPassphrase),
          newPassphrase: newPassphrase,
        );
        await db1.close();

        // Open with the NEW passphrase — data must be readable.
        final (db2, col2) = await _reopen(
          adapter,
          encryptionConfig: EncryptionConfig(passphrase: newPassphrase),
        );
        final note = await col2.get(id);
        expect(note?.text, equals('before-passphrase-change'));
        await db2.close();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'old passphrase is rejected after change',
      () async {
        const newPassphrase = 'another-passphrase';
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );
        final (db1, _, adapter) = await _openFresh(
          encryptionConfig: result.config,
        );
        await db1.changePassphrase(
          currentConfig: EncryptionConfig(passphrase: _kPassphrase),
          newPassphrase: newPassphrase,
        );
        await db1.close();

        // Old passphrase must fail.
        expect(
          () async => _reopen(
            adapter,
            encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
          ),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.badCredentials,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
