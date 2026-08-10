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
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart' show SecretPermissionException;
import 'package:kmdb_cli/src/config/secret_store/directory_secret_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Reason string used to skip POSIX-only tests when running on Windows,
/// where `DirectorySecretStore` performs no chmod/stat checks at all (see
/// the "Windows (no permission enforcement)" group below for the
/// Windows-specific behaviour, and RC-24 in
/// `docs/spec/28_release_checklist.md` for the manual Windows verification
/// these automated tests cannot perform).
const _posixOnly =
    'POSIX-only: DirectorySecretStore performs no '
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

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  late Directory tmpDir;
  late Directory rootDir;
  late DirectorySecretStore store;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('dir_secret_store_test_');
    rootDir = Directory(p.join(tmpDir.path, 'secrets'));
    store = DirectorySecretStore(root: rootDir.path);
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('write — POSIX permission hardening', () {
    test(
      'creates root at 700 and the secret file at 600',
      () async {
        await store.write('creds', _bytes([1, 2, 3]));

        expect(await _modeOf(rootDir), 0x1C0); // 0o700
        final file = File(p.join(rootDir.path, 'creds'));
        expect(await _modeOf(file), 0x180); // 0o600
      },
      skip: Platform.isWindows ? _posixOnly : false,
    );

    test('creates root if it does not already exist', () async {
      expect(rootDir.existsSync(), isFalse);
      await store.write('creds', _bytes([1, 2, 3]));
      expect(rootDir.existsSync(), isTrue);
    });

    test('overwrites an existing secret for the same key', () async {
      await store.write('creds', _bytes([1]));
      await store.write('creds', _bytes([2, 3]));

      final content = await store.read('creds');
      expect(content, equals(_bytes([2, 3])));
    });

    test('non-UTF-8 byte payloads round-trip verbatim', () async {
      final value = _bytes([0x80, 0xFF, 0x00, 0x01, 0xC0]);
      await store.write('creds', value);
      expect(await store.read('creds'), equals(value));
    });

    test('tightening an already-widened root back to 700 does not disturb '
        'unrelated files already in it', () async {
      // Simulate another process having already created root at a looser
      // mode with an unrelated file in it.
      rootDir.createSync(recursive: true);
      final other = File(p.join(rootDir.path, 'unrelated.txt'))
        ..writeAsStringSync('hello');

      await store.write('creds', _bytes([1, 2, 3]));

      // The credential write path chmods root to 700 as a side effect,
      // but unrelated files' content is untouched.
      expect(other.readAsStringSync(), 'hello');
      expect(await _modeOf(rootDir), 0x1C0); // 0o700
    }, skip: Platform.isWindows ? _posixOnly : false);
  });

  group('read — null/value/throw contract', () {
    test('returns null when no secret has been written', () async {
      final result = await store.read('missing');
      expect(result, isNull);
    });

    test('returns null when root does not exist at all', () async {
      expect(rootDir.existsSync(), isFalse);
      final result = await store.read('missing');
      expect(result, isNull);
    });

    test('returns the secret bytes on a well-permissioned read', () async {
      await store.write('creds', _bytes([9, 8, 7]));
      final result = await store.read('creds');
      expect(result, equals(_bytes([9, 8, 7])));
    });

    test('throws SecretPermissionException when the file is group/world '
        'readable', () async {
      await store.write('creds', _bytes([1, 2, 3]));
      final file = File(p.join(rootDir.path, 'creds'));
      Process.runSync('chmod', ['644', file.path]);

      await expectLater(
        store.read('creds'),
        throwsA(isA<SecretPermissionException>()),
      );
    }, skip: Platform.isWindows ? _posixOnly : false);

    test(
      'the SecretPermissionException message names the exact chmod fix',
      () async {
        await store.write('creds', _bytes([1, 2, 3]));
        final file = File(p.join(rootDir.path, 'creds'));
        Process.runSync('chmod', ['644', file.path]);

        await expectLater(
          store.read('creds'),
          throwsA(
            isA<SecretPermissionException>().having(
              (e) => e.toString(),
              'toString()',
              allOf(contains('chmod 600'), contains(file.path)),
            ),
          ),
        );
      },
      skip: Platform.isWindows ? _posixOnly : false,
    );

    test('throws SecretPermissionException when root is group/world accessible '
        'even though the file itself is 600', () async {
      await store.write('creds', _bytes([1, 2, 3]));
      Process.runSync('chmod', ['755', rootDir.path]);

      await expectLater(
        store.read('creds'),
        throwsA(
          isA<SecretPermissionException>().having(
            (e) => e.toString(),
            'toString()',
            allOf(contains('chmod 700'), contains(rootDir.path)),
          ),
        ),
      );
    }, skip: Platform.isWindows ? _posixOnly : false);
  });

  group('delete', () {
    test('removes an existing secret', () async {
      await store.write('creds', _bytes([1, 2, 3]));
      await store.delete('creds');
      expect(await store.read('creds'), isNull);
    });

    test('is a no-op when the secret does not exist', () async {
      await expectLater(store.delete('missing'), completes);
    });
  });

  group('list', () {
    test('returns an empty list when root does not exist', () async {
      expect(rootDir.existsSync(), isFalse);
      expect(await store.list(), isEmpty);
    });

    test('returns an empty list when root exists but is empty', () async {
      rootDir.createSync(recursive: true);
      expect(await store.list(), isEmpty);
    });

    test('returns all currently-held keys', () async {
      await store.write('a', _bytes([1]));
      await store.write('b', _bytes([2]));
      await store.write('c', _bytes([3]));

      expect(await store.list(), unorderedEquals(['a', 'b', 'c']));
    });

    test('reflects delete', () async {
      await store.write('a', _bytes([1]));
      await store.write('b', _bytes([2]));
      await store.delete('a');

      expect(await store.list(), equals(['b']));
    });
  });

  group('key collision-freedom', () {
    test(
      'two distinct keys within the same root address distinct files',
      () async {
        await store.write('a', _bytes([1]));
        await store.write('b', _bytes([2]));

        expect(await store.read('a'), equals(_bytes([1])));
        expect(await store.read('b'), equals(_bytes([2])));
      },
    );
  });

  group('forPlatform', () {
    test('resolves a root rooted at the profile config directory', () {
      final resolved = DirectorySecretStore.forPlatform();
      expect(resolved.root, isNotEmpty);
      if (Platform.isWindows) {
        expect(resolved.root, endsWith(p.join('kmdb')));
      } else {
        expect(resolved.root, endsWith(p.join('.config', 'kmdb')));
      }
    });
  });

  // ── Windows (no permission enforcement) ───────────────────────────────────
  //
  // These assertions only exercise meaningful behaviour on Windows, where
  // DirectorySecretStore performs no chmod/stat checks at all — relying
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
        await expectLater(store.write('creds', _bytes([1, 2, 3])), completes);
      },
      skip: Platform.isWindows ? false : _windowsOnly,
    );

    test(
      'read succeeds even when the fixture file has loose permissions',
      () async {
        rootDir.createSync(recursive: true);
        final file = File(p.join(rootDir.path, 'creds'))
          ..writeAsBytesSync(_bytes([1, 2, 3]));
        // On POSIX this would be refused; on Windows there is no such check.
        Process.runSync('chmod', ['644', file.path]);

        final result = await store.read('creds');
        expect(result, equals(_bytes([1, 2, 3])));
      },
      skip: Platform.isWindows ? false : _windowsOnly,
    );
  });
}
