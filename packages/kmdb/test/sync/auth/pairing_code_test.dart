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

import 'package:kmdb/src/sync/auth/pairing_code.dart';
import 'package:kmdb/src/sync/auth/sync_set_key.dart';
import 'package:test/test.dart';

void main() {
  group('PairingCode', () {
    test('encode produces a KSA1--prefixed code', () async {
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      expect(code, startsWith('KSA1-'));
    });

    test('encode/decode round-trips a generated key', () async {
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      final decoded = await PairingCode.decode(code);
      expect(decoded, equals(key));
    });

    test('decode tolerates whitespace and re-grouping differences', () async {
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      // Strip all dashes after the prefix and add stray whitespace.
      final body = code.substring('KSA1-'.length).replaceAll('-', '');
      final reformatted =
          '  KSA1-${body.substring(0, 4)} '
          '${body.substring(4)}  ';
      final decoded = await PairingCode.decode(reformatted);
      expect(decoded, equals(key));
    });

    test('decode is case-insensitive on the prefix and body', () async {
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      final lower = code.toLowerCase();
      final decoded = await PairingCode.decode(lower);
      expect(decoded, equals(key));
    });

    test('decode throws FormatException for a missing prefix', () async {
      await expectLater(
        PairingCode.decode('NOTAPREFIX-ABCDE'),
        throwsFormatException,
      );
    });

    test(
      'decode throws FormatException for an invalid base32 character',
      () async {
        await expectLater(
          PairingCode.decode('KSA1-!!!!!'),
          throwsFormatException,
        );
      },
    );

    test('decode throws FormatException for a truncated code', () async {
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      final truncated = code.substring(0, code.length - 10);
      await expectLater(PairingCode.decode(truncated), throwsFormatException);
    });

    test('decode throws FormatException on a corrupted checksum (a single '
        'transcription typo)', () async {
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      // Flip the first base32 character after the prefix — guaranteed to
      // land within the real payload (the syncSetId-length byte), unlike
      // the very last character, whose bits may fall entirely within
      // base32's padding region and therefore not change the decoded
      // bytes at all.
      const prefixLen = 5; // 'KSA1-'.length
      final targetChar = code[prefixLen];
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      final replacement = alphabet
          .split('')
          .firstWhere((c) => c != targetChar.toUpperCase());
      final corrupted =
          code.substring(0, prefixLen) +
          replacement +
          code.substring(prefixLen + 1);
      await expectLater(PairingCode.decode(corrupted), throwsFormatException);
    });

    test('two different keys never produce the same pairing code', () async {
      final a = SyncSetKey.generate();
      final b = SyncSetKey.generate();
      expect(await PairingCode.encode(a), isNot(await PairingCode.encode(b)));
    });
  });
}
