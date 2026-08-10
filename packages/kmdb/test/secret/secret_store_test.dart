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

import 'package:kmdb/src/secret/secret_store.dart';
import 'package:test/test.dart';

void main() {
  group('InMemorySecretStore', () {
    late InMemorySecretStore store;
    const key = 'test-key-001';

    setUp(() {
      store = InMemorySecretStore();
    });

    test('read returns null when no secret is stored', () async {
      expect(await store.read(key), isNull);
    });

    test('write then read returns the same bytes', () async {
      final value = Uint8List.fromList(List.generate(32, (i) => i));
      await store.write(key, value);
      final result = await store.read(key);
      expect(result, equals(value));
    });

    test('read returns a defensive copy (mutating the result does not affect '
        'the store)', () async {
      final value = Uint8List.fromList(List.generate(32, (i) => i));
      await store.write(key, value);

      final result = await store.read(key);
      result![0] = 0xFF; // mutate the returned copy

      final result2 = await store.read(key);
      expect(result2![0], equals(0)); // original first byte, unaffected
    });

    test('write preserves the original bytes (does not alias the caller\'s '
        'array)', () async {
      final original = Uint8List.fromList(List.generate(32, (i) => i));
      final copy = Uint8List.fromList(original);
      await store.write(key, original);

      // Mutate the caller's array after write() returns.
      original[0] = 0xFF;

      // The stored value should reflect the state at write() time, not the
      // caller's later mutation.
      final result = await store.read(key);
      expect(result![0], equals(copy[0]));
    });

    test('write overwrites an existing secret for the same key', () async {
      final value1 = Uint8List.fromList(List.generate(32, (i) => i));
      final value2 = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      await store.write(key, value1);
      await store.write(key, value2);

      final result = await store.read(key);
      expect(result, equals(value2));
    });

    test('non-UTF-8 byte payloads round-trip verbatim', () async {
      // Bytes that are not valid UTF-8 on their own (e.g. a lone continuation
      // byte) — the interface promises byte fidelity, not text fidelity.
      final value = Uint8List.fromList([0x80, 0xFF, 0x00, 0x01, 0xC0]);
      await store.write(key, value);
      expect(await store.read(key), equals(value));
    });

    test('delete removes the stored secret', () async {
      final value = Uint8List.fromList(List.generate(32, (i) => i));
      await store.write(key, value);
      await store.delete(key);
      expect(await store.read(key), isNull);
    });

    test('delete is a no-op when the key is not present', () async {
      // Should not throw.
      await store.delete(key);
      await store.delete(key);
    });

    test('list returns an empty list for a fresh store', () async {
      expect(await store.list(), isEmpty);
    });

    test('list returns all currently-held keys', () async {
      await store.write('a', Uint8List.fromList([1]));
      await store.write('b', Uint8List.fromList([2]));
      await store.write('c', Uint8List.fromList([3]));

      expect(await store.list(), unorderedEquals(['a', 'b', 'c']));
    });

    test('list reflects delete', () async {
      await store.write('a', Uint8List.fromList([1]));
      await store.write('b', Uint8List.fromList([2]));
      await store.delete('a');

      expect(await store.list(), equals(['b']));
    });

    test('multiple keys are stored independently', () async {
      const key1 = 'key-1';
      const key2 = 'key-2';
      final value1 = Uint8List.fromList(List.generate(32, (_) => 0xAA));
      final value2 = Uint8List.fromList(List.generate(32, (_) => 0xBB));

      await store.write(key1, value1);
      await store.write(key2, value2);

      expect(await store.read(key1), equals(value1));
      expect(await store.read(key2), equals(value2));

      await store.delete(key1);
      expect(await store.read(key1), isNull);
      expect(await store.read(key2), equals(value2)); // key2 unaffected
    });
  });

  group('SecretPermissionException', () {
    test('toString names the exact chmod fix for a file', () {
      final e = SecretPermissionException(
        path: '/db/local/secret.bin',
        actualMode: 0x1A4, // 0o644
        expectedMode: 0x180, // 0o600
      );
      expect(
        e.toString(),
        'Secret at /db/local/secret.bin is readable by others '
        '(mode 644). Fix with: chmod 600 /db/local/secret.bin',
      );
    });

    test('toString names the exact chmod fix for a directory', () {
      final e = SecretPermissionException(
        path: '/db/local',
        actualMode: 0x1ED, // 0o755
        expectedMode: 0x1C0, // 0o700
      );
      expect(
        e.toString(),
        'Secret at /db/local is readable by others '
        '(mode 755). Fix with: chmod 700 /db/local',
      );
    });

    test('exposes path/actualMode/expectedMode fields', () {
      final e = SecretPermissionException(
        path: '/x',
        actualMode: 0x1A4,
        expectedMode: 0x180,
      );
      expect(e.path, '/x');
      expect(e.actualMode, 0x1A4);
      expect(e.expectedMode, 0x180);
    });

    test('is an Exception', () {
      final e = SecretPermissionException(
        path: '/x',
        actualMode: 0x1A4,
        expectedMode: 0x180,
      );
      expect(e, isA<Exception>());
    });
  });
}
