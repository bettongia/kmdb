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

import 'dart:typed_data';

import 'package:kmdb/src/encryption/dek_cache.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryDekCache', () {
    late InMemoryDekCache cache;
    const dbId = 'test-db-001';

    setUp(() {
      cache = InMemoryDekCache();
    });

    test('read returns null when no DEK is stored', () async {
      expect(await cache.read(dbId), isNull);
    });

    test('store then read returns the same bytes', () async {
      final dek = Uint8List.fromList(List.generate(32, (i) => i));
      await cache.store(dbId, dek);
      final result = await cache.read(dbId);
      expect(result, equals(dek));
    });

    test(
      'read returns a defensive copy (mutation does not affect cache)',
      () async {
        final dek = Uint8List.fromList(List.generate(32, (i) => i));
        await cache.store(dbId, dek);

        final result = await cache.read(dbId);
        result![0] = 0xFF; // mutate the copy

        // Read again — should still return the original value.
        final result2 = await cache.read(dbId);
        expect(result2![0], equals(0)); // original first byte
      },
    );

    test('store overwrites an existing DEK', () async {
      final dek1 = Uint8List.fromList(List.generate(32, (i) => i));
      final dek2 = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      await cache.store(dbId, dek1);
      await cache.store(dbId, dek2);

      final result = await cache.read(dbId);
      expect(result, equals(dek2));
    });

    test('clear removes the stored DEK', () async {
      final dek = Uint8List.fromList(List.generate(32, (i) => i));
      await cache.store(dbId, dek);
      await cache.clear(dbId);
      expect(await cache.read(dbId), isNull);
    });

    test('clear is idempotent (no error when key not present)', () async {
      // Should not throw.
      await cache.clear(dbId);
      await cache.clear(dbId);
    });

    test('multiple dbIds are stored independently', () async {
      const id1 = 'db-1';
      const id2 = 'db-2';
      final dek1 = Uint8List.fromList(List.generate(32, (_) => 0xAA));
      final dek2 = Uint8List.fromList(List.generate(32, (_) => 0xBB));

      await cache.store(id1, dek1);
      await cache.store(id2, dek2);

      expect(await cache.read(id1), equals(dek1));
      expect(await cache.read(id2), equals(dek2));

      await cache.clear(id1);
      expect(await cache.read(id1), isNull);
      expect(await cache.read(id2), equals(dek2)); // id2 unaffected
    });

    test(
      'store preserves the original bytes (does not modify caller\'s array)',
      () async {
        final original = Uint8List.fromList(List.generate(32, (i) => i));
        final copy = Uint8List.fromList(original);
        await cache.store(dbId, original);

        // Mutate original after store.
        original[0] = 0xFF;

        // The cached value should be the state at store() time, not the mutation.
        final result = await cache.read(dbId);
        expect(result![0], equals(copy[0]));
      },
    );
  });
}
