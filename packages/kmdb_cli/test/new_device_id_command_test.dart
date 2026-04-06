// Copyright 2026 The KMDB Authors.
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

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/new_device_id_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

int _dbCounter = 0;

/// Opens a fresh in-memory store for testing with the given [deviceId].
Future<KvStoreImpl> _openStore({String deviceId = 'aaaaaaaa'}) async {
  final (store, _) = await KvStoreImpl.open(
    '/testdb${_dbCounter++}',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    deviceId: deviceId,
  );
  return store;
}

/// Creates a [CommandContext] for testing.
CommandContext _ctx(
  KvStoreImpl store, {
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  store: store,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('NewDeviceIdCommand', () {
    // ── Happy path ──────────────────────────────────────────────────────────

    test(
      'returns true and outputs valid JSON with old and new device IDs',
      () async {
        final store = await _openStore(deviceId: 'aaaaaaaa');
        final out = StringBuffer();
        final err = StringBuffer();
        addTearDown(() => store.close());

        final ok = await NewDeviceIdCommand().execute(
          _ctx(store, out: out, err: err),
          [],
          {},
        );

        expect(ok, isTrue);

        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result['oldDeviceId'], 'aaaaaaaa');
        expect(result['newDeviceId'], isA<String>());
        // The new ID must be different from the old one.
        expect(result['newDeviceId'], isNot('aaaaaaaa'));
        // The new ID must be 8 lowercase hex characters.
        expect(
          result['newDeviceId'] as String,
          matches(RegExp(r'^[0-9a-f]{8}$')),
        );
      },
    );

    test('store reflects new device ID after command executes', () async {
      final store = await _openStore(deviceId: 'aaaaaaaa');
      final out = StringBuffer();
      addTearDown(() => store.close());

      final ok = await NewDeviceIdCommand().execute(
        _ctx(store, out: out),
        [],
        {},
      );
      expect(ok, isTrue);

      final result = json.decode(out.toString()) as Map<String, dynamic>;
      final newId = result['newDeviceId'] as String;

      final info = await store.storeInfo();
      expect(info.deviceId, newId);
    });

    test(
      'outputs oldDeviceId from storeInfo, not a hard-coded value',
      () async {
        // Use a non-default device ID so we can verify the command reads the
        // actual current ID rather than assuming a default.
        final store = await _openStore(deviceId: 'deadbeef');
        final out = StringBuffer();
        addTearDown(() => store.close());

        final ok = await NewDeviceIdCommand().execute(
          _ctx(store, out: out),
          [],
          {},
        );
        expect(ok, isTrue);

        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result['oldDeviceId'], 'deadbeef');
      },
    );

    // ── Remote warning ──────────────────────────────────────────────────────

    test('emits no warning when no remotes are configured', () async {
      final store = await _openStore();
      final err = StringBuffer();
      addTearDown(() => store.close());

      await NewDeviceIdCommand().execute(_ctx(store, err: err), [], {});

      expect(err.toString(), isEmpty);
    });

    test('emits warning to stderr when remotes are configured', () async {
      // Write a config.json with a fake remote so the command detects it.
      // We use a real temp directory since KmdbConfig.load reads from disk.
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      // Create the local/config.json file manually.
      final localDir = io.Directory('${tmpDir.path}/local');
      await localDir.create();
      final configFile = io.File('${tmpDir.path}/local/config.json');
      await configFile.writeAsString(
        json.encode({
          'remotes': {
            'origin': {'type': 'local', 'path': '/some/sync/dir'},
          },
        }),
      );

      // Open the store at the temp directory using the native adapter so the
      // CLI command can read the config.json file.
      final adapter = StorageAdapterNative();
      final (store, _) = await KvStoreImpl.open(
        tmpDir.path,
        adapter,
        config: KvStoreConfig.forTesting(),
        deviceId: 'aaaaaaaa',
      );
      addTearDown(() => store.close());

      final out = StringBuffer();
      final err = StringBuffer();
      final ok = await NewDeviceIdCommand().execute(
        _ctx(store, out: out, err: err),
        [],
        {},
      );

      expect(ok, isTrue);
      // The warning must mention the old device ID so the user knows which
      // highwater file to delete from the remote.
      expect(err.toString(), contains('aaaaaaaa'));
      expect(err.toString(), contains('highwater'));
    });
  });
}
