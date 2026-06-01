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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/versions_command.dart';
import 'package:kmdb_cli/src/commands/promote_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<(KmdbDatabase, StringBuffer, StringBuffer)> _openDb() async {
  final db = await KmdbDatabase.open(
    path: '/testdb',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    versionConfigs: {'notes': VersionConfig.defaults},
  );
  final out = StringBuffer();
  final err = StringBuffer();
  return (db, out, err);
}

CommandContext _ctx(
  KmdbDatabase db, {
  required StringBuffer out,
  required StringBuffer err,
}) => CommandContext(db: db, out: out, err: err);

const _versionsCmd = VersionsCommand();
const _promoteCmd = PromoteCommand();

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── versions command ─────────────────────────────────────────────────────────

  group('versions command', () {
    test('requires at least 2 args', () async {
      final (db, out, err) = await _openDb();
      final ctx = _ctx(db, out: out, err: err);
      final ok = await _versionsCmd.execute(ctx, ['notes'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
      await db.close();
    });

    test('returns false and error when no versions exist', () async {
      final (db, out, err) = await _openDb();
      final ctx = _ctx(db, out: out, err: err);
      // Use a key that was never written.
      final fakeKey = UuidV7KeyGenerator().next();
      final ok = await _versionsCmd.execute(ctx, ['notes', fakeKey], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('No version history'));
      await db.close();
    });

    test('returns JSON with version metadata when versions exist', () async {
      final (db, out, err) = await _openDb();
      final col = db.rawCollection('notes');
      final key = UuidV7KeyGenerator().next();
      await col.insert({'body': 'v1', '_id': key});
      await col.put({'body': 'v2', '_id': key});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await _versionsCmd.execute(ctx, ['notes', key], {});
      expect(ok, isTrue);
      final output = out.toString();
      expect(output, contains('version'));
      expect(output, contains('timestamp'));
      expect(output, contains('is_delete'));
      await db.close();
    });
  });

  // ── promote command ──────────────────────────────────────────────────────────

  group('promote command', () {
    test('requires at least 3 args', () async {
      final (db, out, err) = await _openDb();
      final ctx = _ctx(db, out: out, err: err);
      final ok = await _promoteCmd.execute(ctx, ['notes', 'somekey'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
      await db.close();
    });

    test('returns false for invalid HLC hex', () async {
      final (db, out, err) = await _openDb();
      final ctx = _ctx(db, out: out, err: err);
      final ok = await _promoteCmd.execute(ctx, [
        'notes',
        'somekey',
        'not_a_valid_hlc',
      ], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid version HLC'));
      await db.close();
    });

    test('returns false when version not found', () async {
      final (db, out, err) = await _openDb();
      final col = db.rawCollection('notes');
      final key = UuidV7KeyGenerator().next();
      await col.insert({'body': 'v1', '_id': key});

      final ctx = _ctx(db, out: out, err: err);
      // Use a valid-format HLC that doesn't exist in version history.
      final fakeHlcHex = const Hlc(1, 0).toHex();
      final ok = await _promoteCmd.execute(ctx, ['notes', key, fakeHlcHex], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
      await db.close();
    });

    test('promote a known version succeeds', () async {
      final (db, out, err) = await _openDb();
      final col = db.rawCollection('notes');
      final key = UuidV7KeyGenerator().next();
      // Use put (not insert) so the explicit _id field is preserved as the key.
      await col.put({'body': 'original', '_id': key});
      await col.put({'body': 'updated', '_id': key});

      // Get v1's HLC.
      final verCol = db.collection(name: 'notes', codec: RawDocumentCodec());
      final versions = await verCol.getVersions(key);
      final v1Hlc = versions.last.hlc; // oldest = v1

      final ctx = _ctx(db, out: out, err: err);
      final ok = await _promoteCmd.execute(ctx, [
        'notes',
        key,
        v1Hlc.toHex(),
      ], {});
      expect(ok, isTrue);
      expect(out.toString(), contains('Promoted'));

      // Verify value was restored.
      final current = await col.get(key);
      expect(current?['body'], equals('original'));
      await db.close();
    });
  });
}
