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

import 'package:kmdb_cli/src/config/credential_store.dart';
import 'package:kmdb_cli/src/config/credential_store/directory_credential_store.dart';
import 'package:test/test.dart';

void main() {
  group('CredentialStore.forPlatform', () {
    test('resolves to a DirectoryCredentialStore rooted at dbDir', () {
      final store = CredentialStore.forPlatform(dbDir: '/tmp/some-db');
      expect(store, isA<DirectoryCredentialStore>());
      expect((store as DirectoryCredentialStore).dbDir, '/tmp/some-db');
    });
  });

  group('CredentialPermissionException', () {
    test('toString names the exact chmod fix for a file', () {
      final e = CredentialPermissionException(
        path: '/db/local/creds.json',
        actualMode: 0x1A4, // 0o644
        expectedMode: 0x180, // 0o600
      );
      expect(
        e.toString(),
        'Credentials at /db/local/creds.json are readable by others '
        '(mode 644). Fix with: chmod 600 /db/local/creds.json',
      );
    });

    test('toString names the exact chmod fix for a directory', () {
      final e = CredentialPermissionException(
        path: '/db/local',
        actualMode: 0x1ED, // 0o755
        expectedMode: 0x1C0, // 0o700
      );
      expect(
        e.toString(),
        'Credentials at /db/local are readable by others '
        '(mode 755). Fix with: chmod 700 /db/local',
      );
    });

    test('exposes path/actualMode/expectedMode fields', () {
      final e = CredentialPermissionException(
        path: '/x',
        actualMode: 0x1A4,
        expectedMode: 0x180,
      );
      expect(e.path, '/x');
      expect(e.actualMode, 0x1A4);
      expect(e.expectedMode, 0x180);
    });
  });
}
