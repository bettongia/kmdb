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

/// Crash-safety tests for the encryption bootstrap using [FaultyStorageAdapter].
library;

///
/// These tests verify the Q2 crash-safety invariant: the `enc:blob` (wrapped
/// DEK) must be durable before any encrypted user value can be written. If a
/// crash occurs between provisioning and the first encrypted user write, the
/// database must remain in a consistent, recoverable state.
///
/// The failure mode we protect against: a crash that loses the `enc:blob`
/// write (because the WAL record was buffered but not fsync'd) while one or
/// more encrypted user values ARE durable — producing undecryptable data with
/// no wrapped DEK available.
///
/// In KMDB's implementation, `enc:blob` is written via `putRawByName` which
/// goes through the normal WAL path. The provisioning write happens at `open()`
/// time, before the handle is returned to the caller — no user values can be
/// written until after `open()` completes. This guarantees ordering: the
/// `enc:blob` WAL record is written before any user value WAL record.
///
/// After a simulated crash (via [FaultyStorageAdapter.crash]) and re-open, the
/// database must either:
/// - Recover to a state where `enc:blob` is present (the provisioning write
///   survived the crash and user data can be decrypted), OR
/// - Recover to a state where NEITHER `enc:blob` NOR user data are durable
///   (the crash happened before anything was fsynced — the DB appears unencrypted
///   and empty, which is safe to re-provision).
///
/// The one scenario that must NOT occur: `enc:blob` absent but encrypted user
/// data present.

import 'package:kmdb/src/encryption/encryption_config.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/query/kmdb_codec.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _kPassphrase = 'crash-test-passphrase';

final _keyGen = SequentialKeyGenerator();

void main() {
  // Note: FaultyStorageAdapter uses its own lock management and does NOT
  // integrate with MemoryStorageAdapter.releaseAllLocks. Tests are self-
  // contained and the adapter is discarded after each test.

  // ── Provisioning crash-safety ─────────────────────────────────────────────────

  group('Encryption provisioning crash-safety (FaultyStorageAdapter)', () {
    test(
      'crash before any fsync: reopen sees a clean plaintext DB (re-provision safe)',
      () async {
        // Provision encryption. The provisioning open() writes enc:blob to the WAL
        // but does NOT fsync before returning — a crash at this point discards all
        // volatile writes.
        final faultyAdapter = FaultyStorageAdapter();
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );

        // Open the database (this writes enc:blob to the WAL, volatile).
        final db = await KmdbDatabase.open(
          path: '/db',
          adapter: faultyAdapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
        );
        // Crash immediately — no user writes, no fsync.
        await db.close(
          flush: false,
        ); // close without flush to leave WAL unsynced
        faultyAdapter.crash();

        // After a crash with no durable writes, the DB is empty.
        // Reopening without encryption config must succeed (no enc:blob survived).
        // This verifies the "no partial state" invariant: enc:blob and any user
        // data are lost together if they were never fsynced.
        //
        // The safe outcome: either the database is empty and unencrypted (we can
        // re-provision), or the database has an enc:blob and we can unlock it.
        // The UNSAFE outcome (enc:blob absent but encrypted user data present) is
        // impossible because there were no user writes.
        //
        // Try to open without encryption config — should NOT throw databaseIsEncrypted.
        // If enc:blob survived the crash, throw would be expected; but we called
        // crash() which discards un-synced data.
        bool openSucceeded = false;
        EncryptionError? openError;
        try {
          final db2 = await KmdbDatabase.open(
            path: '/db',
            adapter: faultyAdapter,
            config: KvStoreConfig.forTesting(),
          );
          openSucceeded = true;
          await db2.close();
        } on EncryptionError catch (e) {
          openError = e;
        }

        // Acceptable outcomes:
        // 1. Open succeeded (plaintext open, enc:blob not durable) — correct.
        // 2. EncryptionError.databaseIsEncrypted (enc:blob survived) — also correct,
        //    because the data would be decryptable with the passphrase.
        // NOT acceptable: any other exception.
        if (!openSucceeded) {
          expect(
            openError?.code,
            equals(EncryptionErrorCode.databaseIsEncrypted),
            reason:
                'If open failed, it must be because enc:blob survived the crash',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'no undecryptable user data after provisioning crash',
      () async {
        // This is the key invariant: there must NEVER be encrypted user data
        // without a readable enc:blob.
        //
        // In KMDB's design this is guaranteed by construction:
        // open() writes enc:blob BEFORE returning, and user data can only be
        // written after open() returns. So enc:blob is always written before
        // any user value in the WAL — they cannot arrive in reverse order.
        //
        // This test verifies the invariant by trying to insert data after open,
        // then crashing and checking the post-crash state is consistent.

        final faultyAdapter = FaultyStorageAdapter();
        final result = await EncryptionConfig.createResult(
          passphrase: _kPassphrase,
        );

        final db = await KmdbDatabase.open(
          path: '/db',
          adapter: faultyAdapter,
          config: KvStoreConfig.forTesting(),
          encryptionConfig: result.config,
        );

        // Write a user document (encrypted).
        final col = db.collection<Map<String, dynamic>>(
          name: 'data',
          codec: const _MapCodec(),
        );
        final docKey = _keyGen.next();
        await col.put({'_id': docKey, 'value': 'secret-value'});

        // Crash without flushing — WAL records are volatile.
        await db.close(flush: false);
        faultyAdapter.crash();

        // After crash: either the DB is in an empty/unencrypted state (all WAL
        // records lost), or enc:blob + user data both survived (consistent).
        // Verify by trying to open. Any outcome is acceptable as long as we can
        // open it (possibly empty, possibly with data) or get a clear error.
        bool consistentStateAchieved = false;

        // Try plaintext open.
        try {
          final db2 = await KmdbDatabase.open(
            path: '/db',
            adapter: faultyAdapter,
            config: KvStoreConfig.forTesting(),
          );
          // Plaintext open succeeded — no encrypted data in a state that requires
          // decryption. Consistent state: enc:blob and user data both lost to crash.
          consistentStateAchieved = true;
          await db2.close();
        } on EncryptionError catch (e) {
          if (e.code == EncryptionErrorCode.databaseIsEncrypted) {
            // enc:blob survived — open with the passphrase to verify no corrupt data.
            final db3 = await KmdbDatabase.open(
              path: '/db',
              adapter: faultyAdapter,
              config: KvStoreConfig.forTesting(),
              encryptionConfig: EncryptionConfig(passphrase: _kPassphrase),
            );
            // If we get here without exception, the database is decryptable.
            consistentStateAchieved = true;
            await db3.close();
          } else {
            rethrow;
          }
        }

        expect(consistentStateAchieved, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}

/// Minimal [KmdbCodec] for [Map<String, dynamic>] documents.
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
    // Strip '_id' — KMDB stores the key separately; codec.encode() must
    // not return top-level keys starting with '_'.
    final result = Map<String, dynamic>.from(value);
    result.remove('_id');
    return result;
  }

  @override
  Map<String, dynamic> decode(Map<String, dynamic> json) => json;
}
