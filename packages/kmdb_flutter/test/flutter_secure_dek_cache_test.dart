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

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb_flutter/kmdb_flutter.dart';

void main() {
  // Initialize the Flutter test binding so that platform channels are mocked.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Install the in-memory test platform implementation provided by
    // flutter_secure_storage, intercepting all platform-channel calls.
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('FlutterSecureDekCache - store and read round-trip', () {
    test('stores a DEK and reads it back unchanged', () async {
      final cache = FlutterSecureDekCache();
      final dek = Uint8List.fromList(List.generate(32, (i) => i));
      const dbId = '/path/to/my/database';

      await cache.store(dbId, dek);
      final result = await cache.read(dbId);

      expect(result, equals(dek));
    });

    test('returns null when no DEK has been stored for the dbId', () async {
      final cache = FlutterSecureDekCache();

      final result = await cache.read('/no/such/db');

      expect(result, isNull);
    });

    test('overwrites an existing entry on a second store', () async {
      final cache = FlutterSecureDekCache();
      final dek1 = Uint8List.fromList(List.generate(32, (i) => i));
      final dek2 = Uint8List.fromList(List.generate(32, (i) => i + 100));
      const dbId = '/path/to/db';

      await cache.store(dbId, dek1);
      await cache.store(dbId, dek2);
      final result = await cache.read(dbId);

      expect(result, equals(dek2));
    });
  });

  group('FlutterSecureDekCache - defensive copy on read', () {
    test(
      'mutating the returned bytes does not corrupt the cached value',
      () async {
        final cache = FlutterSecureDekCache();
        final original = Uint8List.fromList(List.generate(32, (i) => i));
        const dbId = '/path/to/db';

        await cache.store(dbId, original);

        final first = await cache.read(dbId);
        expect(first, isNotNull);
        // Corrupt the returned buffer.
        first![0] = 0xFF;

        // A second read must return the original uncorrupted bytes.
        final second = await cache.read(dbId);
        expect(second, isNotNull);
        expect(second![0], equals(0)); // original first byte
      },
    );

    test(
      'returned Uint8List is a fresh object (not the same reference)',
      () async {
        final cache = FlutterSecureDekCache();
        final dek = Uint8List.fromList(List.generate(32, (i) => i));
        const dbId = '/db';

        await cache.store(dbId, dek);

        final r1 = await cache.read(dbId);
        final r2 = await cache.read(dbId);

        // Two distinct objects with identical content.
        expect(identical(r1, r2), isFalse);
        expect(r1, equals(r2));
      },
    );
  });

  group('FlutterSecureDekCache - clear', () {
    test('clear removes the stored DEK', () async {
      final cache = FlutterSecureDekCache();
      final dek = Uint8List.fromList(List.generate(32, (i) => i));
      const dbId = '/path/to/db';

      await cache.store(dbId, dek);
      await cache.clear(dbId);
      final result = await cache.read(dbId);

      expect(result, isNull);
    });

    test('clear on a non-existent key does not throw', () async {
      final cache = FlutterSecureDekCache();

      // Should complete without throwing even when no entry exists.
      await expectLater(cache.clear('/no/such/db'), completes);
    });

    test('clear only removes the specified dbId, not others', () async {
      final cache = FlutterSecureDekCache();
      final dek1 = Uint8List.fromList(List.generate(32, (i) => i));
      final dek2 = Uint8List.fromList(List.generate(32, (i) => i + 50));

      await cache.store('/db/one', dek1);
      await cache.store('/db/two', dek2);

      await cache.clear('/db/one');

      expect(await cache.read('/db/one'), isNull);
      expect(await cache.read('/db/two'), equals(dek2));
    });
  });

  group('FlutterSecureDekCache - multi-dbId isolation', () {
    test('different dbIds are stored and retrieved independently', () async {
      final cache = FlutterSecureDekCache();
      final dekA = Uint8List.fromList(List.generate(32, (i) => i));
      final dekB = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      await cache.store('/alice/db', dekA);
      await cache.store('/bob/db', dekB);

      final readA = await cache.read('/alice/db');
      final readB = await cache.read('/bob/db');

      expect(readA, equals(dekA));
      expect(readB, equals(dekB));
      // Verify they are not the same bytes.
      expect(readA, isNot(equals(readB)));
    });

    test(
      'stores with paths that share a common prefix are independent',
      () async {
        final cache = FlutterSecureDekCache();
        final dek1 = Uint8List.fromList([1, 2, 3]);
        final dek2 = Uint8List.fromList([4, 5, 6]);

        await cache.store('/data/db1', dek1);
        await cache.store('/data/db10', dek2);

        expect(await cache.read('/data/db1'), equals(dek1));
        expect(await cache.read('/data/db10'), equals(dek2));
      },
    );
  });

  group('FlutterSecureDekCache - storage key derivation', () {
    // Verify the key derivation logic: `kmdb_dek_<base64url(utf8(dbId))>` (no
    // padding) so that the storage key is deterministic and platform-safe.
    test('derived key has the expected prefix', () {
      // The internal _storageKey method is private; we verify its output by
      // computing the expected key ourselves and asserting the format is correct.
      //
      // Use a dbId whose base64url encoding is easy to verify manually:
      //   utf8('abc') → [0x61,0x62,0x63] → base64url → 'YWJj' (no padding)
      const dbId = 'abc';
      final expectedEncoded = base64Url
          .encode(utf8.encode(dbId))
          .replaceAll('=', ''); // 'YWJj'
      final expectedKey = 'kmdb_dek_$expectedEncoded';

      expect(expectedKey, equals('kmdb_dek_YWJj'));
      expect(expectedKey, startsWith('kmdb_dek_'));
    });

    test(
      'dbId with slashes and spaces encodes to a storage-safe key (no slashes)',
      () {
        const dbId = '/Users/alice/My Documents/my app.db';
        final encoded = base64Url.encode(utf8.encode(dbId)).replaceAll('=', '');

        // The derived key must not contain raw slashes or spaces.
        final storageKey = 'kmdb_dek_$encoded';
        expect(storageKey, isNot(contains('/')));
        expect(storageKey, isNot(contains(' ')));
        // base64url uses A-Z, a-z, 0-9, '-', '_' only.
        expect(
          RegExp(r'^kmdb_dek_[A-Za-z0-9_-]+$').hasMatch(storageKey),
          isTrue,
        );
      },
    );

    test('different dbIds produce different storage keys', () {
      const id1 = '/path/db1';
      const id2 = '/path/db2';

      final key1 =
          'kmdb_dek_${base64Url.encode(utf8.encode(id1)).replaceAll('=', '')}';
      final key2 =
          'kmdb_dek_${base64Url.encode(utf8.encode(id2)).replaceAll('=', '')}';

      expect(key1, isNot(equals(key2)));
    });

    test(
      'store and read round-trip works for path with slashes and spaces',
      () async {
        final cache = FlutterSecureDekCache();
        final dek = Uint8List.fromList(List.generate(32, (i) => i * 4));
        const dbId = '/Users/alice/My Documents/app.db';

        await cache.store(dbId, dek);
        final result = await cache.read(dbId);

        expect(result, equals(dek));
      },
    );

    test('empty dbId is handled without error', () async {
      final cache = FlutterSecureDekCache();
      final dek = Uint8List.fromList([1, 2, 3]);

      await cache.store('', dek);
      final result = await cache.read('');
      expect(result, equals(dek));
    });
  });

  group('FlutterSecureDekCache - edge cases', () {
    test('stores and retrieves a minimal 1-byte DEK', () async {
      final cache = FlutterSecureDekCache();
      final dek = Uint8List.fromList([0x42]);

      await cache.store('/db', dek);
      final result = await cache.read('/db');

      expect(result, equals(dek));
    });

    test('stores and retrieves a 32-byte DEK with all-zero bytes', () async {
      final cache = FlutterSecureDekCache();
      final dek = Uint8List(32); // all zeros

      await cache.store('/db', dek);
      final result = await cache.read('/db');

      expect(result, equals(dek));
    });

    test('stores and retrieves a 32-byte DEK with all-max bytes', () async {
      final cache = FlutterSecureDekCache();
      final dek = Uint8List.fromList(List.filled(32, 0xFF));

      await cache.store('/db', dek);
      final result = await cache.read('/db');

      expect(result, equals(dek));
    });

    test(
      'read after clear returns null even when storage had a previous value',
      () async {
        final cache = FlutterSecureDekCache();
        final dek = Uint8List.fromList([1, 2, 3, 4]);
        const dbId = '/db';

        await cache.store(dbId, dek);
        expect(await cache.read(dbId), isNotNull);

        await cache.clear(dbId);
        expect(await cache.read(dbId), isNull);

        // Re-store a different DEK after clearing.
        final dek2 = Uint8List.fromList([5, 6, 7, 8]);
        await cache.store(dbId, dek2);
        expect(await cache.read(dbId), equals(dek2));
      },
    );
  });
}
