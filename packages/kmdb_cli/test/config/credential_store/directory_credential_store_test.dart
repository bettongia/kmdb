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

import 'dart:io';

import 'package:kmdb_cli/src/config/credential_store.dart';
import 'package:kmdb_cli/src/config/credential_store/directory_credential_store.dart';
import 'package:test/test.dart';

/// Reason string used to skip POSIX-only tests when running on Windows,
/// where `DirectoryCredentialStore` performs no chmod/stat checks at all
/// (see the "Windows (no permission enforcement)" group below for the
/// Windows-specific behaviour, and RC-24 in `docs/spec/28_release_checklist.md`
/// for the manual verification these automated tests cannot perform).
const _posixOnly =
    'POSIX-only: DirectoryCredentialStore performs no '
    'chmod/stat checks on Windows.';

/// Reason string for tests that only meaningfully assert on Windows.
const _windowsOnly =
    'Windows-only: exercises the no-permission-enforcement '
    'branch, which only exists off the POSIX path. Run on a Windows CI '
    'runner or dev machine.';

/// Returns the low-9-bit POSIX permission mode of [entity].
Future<int> _modeOf(FileSystemEntity entity) async {
  final stat = await entity.stat();
  return stat.mode & 0x1FF;
}

void main() {
  late Directory tmpDir;
  late Directory dbDir;
  late Directory localDir;
  late DirectoryCredentialStore store;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('dir_cred_store_test_');
    dbDir = Directory('${tmpDir.path}/db')..createSync();
    localDir = Directory('${dbDir.path}/local');
    store = DirectoryCredentialStore(dbDir: dbDir.path);
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('write — POSIX permission hardening', () {
    test(
      'creates local/ at 700 and the credential file at 600',
      () async {
        await store.write('creds.json', '{"token":"abc"}');

        expect(await _modeOf(localDir), 0x1C0); // 0o700
        final file = File('${localDir.path}/creds.json');
        expect(await _modeOf(file), 0x180); // 0o600
      },
      skip: Platform.isWindows ? _posixOnly : false,
    );

    test('creates local/ if it does not already exist', () async {
      expect(localDir.existsSync(), isFalse);
      await store.write('creds.json', '{"token":"abc"}');
      expect(localDir.existsSync(), isTrue);
    });

    test('overwrites an existing secret for the same account', () async {
      await store.write('creds.json', '{"token":"first"}');
      await store.write('creds.json', '{"token":"second"}');

      final content = await store.read('creds.json');
      expect(content, '{"token":"second"}');
    });

    test('tightening an already-widened local/ back to 700 does not disturb '
        'unrelated files already in it', () async {
      // Simulate KmdbConfig.save() having already created local/config.json
      // at the process umask before any credential write happens.
      localDir.createSync(recursive: true);
      final configFile = File('${localDir.path}/config.json')
        ..writeAsStringSync('{}');

      await store.write('creds.json', '{"token":"abc"}');

      // The credential write path chmods local/ to 700 as a side effect,
      // but config.json's own permissions and content are untouched.
      expect(configFile.readAsStringSync(), '{}');
      expect(await _modeOf(localDir), 0x1C0); // 0o700
    }, skip: Platform.isWindows ? _posixOnly : false);
  });

  group('read — null/value/throw contract', () {
    test('returns null when no credential has been written', () async {
      final result = await store.read('missing.json');
      expect(result, isNull);
    });

    test('returns the secret JSON on a well-permissioned read', () async {
      await store.write('creds.json', '{"token":"abc"}');
      final result = await store.read('creds.json');
      expect(result, '{"token":"abc"}');
    });

    test('throws CredentialPermissionException when the file is group/world '
        'readable', () async {
      await store.write('creds.json', '{"token":"abc"}');
      final file = File('${localDir.path}/creds.json');
      Process.runSync('chmod', ['644', file.path]);

      await expectLater(
        store.read('creds.json'),
        throwsA(isA<CredentialPermissionException>()),
      );
    }, skip: Platform.isWindows ? _posixOnly : false);

    test(
      'the CredentialPermissionException message names the exact chmod fix',
      () async {
        await store.write('creds.json', '{"token":"abc"}');
        final file = File('${localDir.path}/creds.json');
        Process.runSync('chmod', ['644', file.path]);

        await expectLater(
          store.read('creds.json'),
          throwsA(
            isA<CredentialPermissionException>().having(
              (e) => e.toString(),
              'toString()',
              allOf(contains('chmod 600'), contains(file.path)),
            ),
          ),
        );
      },
      skip: Platform.isWindows ? _posixOnly : false,
    );

    test('throws CredentialPermissionException when local/ is group/world '
        'accessible even though the file itself is 600', () async {
      await store.write('creds.json', '{"token":"abc"}');
      Process.runSync('chmod', ['755', localDir.path]);

      await expectLater(
        store.read('creds.json'),
        throwsA(
          isA<CredentialPermissionException>().having(
            (e) => e.toString(),
            'toString()',
            allOf(contains('chmod 700'), contains(localDir.path)),
          ),
        ),
      );
    }, skip: Platform.isWindows ? _posixOnly : false);
  });

  group('delete', () {
    test('removes an existing credential', () async {
      await store.write('creds.json', '{"token":"abc"}');
      await store.delete('creds.json');
      expect(await store.read('creds.json'), isNull);
    });

    test('is a no-op when the credential does not exist', () async {
      await expectLater(store.delete('missing.json'), completes);
    });
  });

  group('account-key collision-freedom', () {
    test(
      'two distinct accounts within the same dbDir address distinct files',
      () async {
        await store.write('a.json', '{"token":"a"}');
        await store.write('b.json', '{"token":"b"}');

        expect(await store.read('a.json'), '{"token":"a"}');
        expect(await store.read('b.json'), '{"token":"b"}');
      },
    );
  });

  // ── Windows (no permission enforcement) ───────────────────────────────────
  //
  // These assertions only exercise meaningful behaviour on Windows, where
  // DirectoryCredentialStore performs no chmod/stat checks at all — relying
  // instead on default NTFS ACL inheritance from the user's profile
  // directory. On POSIX they are skipped; RC-24 in
  // docs/spec/28_release_checklist.md covers the manual Windows
  // verification this automated suite cannot perform in this environment.
  group('Windows (no permission enforcement)', () {
    test(
      'write does not attempt to chmod',
      () async {
        // If write() attempted to shell out to chmod on Windows, it would
        // either throw (no chmod binary) or be a slow no-op subprocess; a
        // successful, fast write is evidence no chmod was attempted.
        await expectLater(
          store.write('creds.json', '{"token":"abc"}'),
          completes,
        );
      },
      skip: Platform.isWindows ? false : _windowsOnly,
    );

    test(
      'read succeeds even when the fixture file has loose permissions',
      () async {
        localDir.createSync(recursive: true);
        final file = File('${localDir.path}/creds.json')
          ..writeAsStringSync('{"token":"abc"}');
        // On POSIX this would be refused; on Windows there is no such check.
        Process.runSync('chmod', ['644', file.path]);

        final result = await store.read('creds.json');
        expect(result, '{"token":"abc"}');
      },
      skip: Platform.isWindows ? false : _windowsOnly,
    );
  });
}
