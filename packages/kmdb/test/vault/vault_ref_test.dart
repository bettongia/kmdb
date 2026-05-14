// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:kmdb/src/vault/vault_ref.dart';
import 'package:test/test.dart';

void main() {
  const kHash =
      'dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8';
  const kUri = 'kmdb-vault://sha256/$kHash';

  group('VaultRef', () {
    group('valid URIs', () {
      test('constructs from a valid URI', () {
        final ref = VaultRef(kUri);
        expect(ref.uri, equals(kUri));
        expect(ref.sha256, equals(kHash));
      });

      test('toString returns the URI', () {
        final ref = VaultRef(kUri);
        expect(ref.toString(), equals(kUri));
      });

      test('handles all-zero sha256', () {
        final allZero = '0' * 64;
        final ref = VaultRef('kmdb-vault://sha256/$allZero');
        expect(ref.sha256, equals(allZero));
      });

      test('handles all-f sha256', () {
        final allF = 'f' * 64;
        final ref = VaultRef('kmdb-vault://sha256/$allF');
        expect(ref.sha256, equals(allF));
      });
    });

    group('malformed URIs throw FormatException', () {
      test('wrong scheme', () {
        expect(
          () => VaultRef('vault://sha256/$kHash'),
          throwsA(isA<FormatException>()),
        );
      });

      test('missing sha256 algorithm', () {
        expect(
          () => VaultRef('kmdb-vault://$kHash'),
          throwsA(isA<FormatException>()),
        );
      });

      test('hash too short', () {
        expect(
          () => VaultRef('kmdb-vault://sha256/${kHash.substring(0, 63)}'),
          throwsA(isA<FormatException>()),
        );
      });

      test('hash too long', () {
        expect(
          () => VaultRef('kmdb-vault://sha256/${kHash}ab'),
          throwsA(isA<FormatException>()),
        );
      });

      test('hash contains uppercase', () {
        expect(
          () => VaultRef('kmdb-vault://sha256/${kHash.toUpperCase()}'),
          throwsA(isA<FormatException>()),
        );
      });

      test('hash contains non-hex character', () {
        expect(
          () => VaultRef('kmdb-vault://sha256/${'g' * 64}'),
          throwsA(isA<FormatException>()),
        );
      });

      test('empty string', () {
        expect(() => VaultRef(''), throwsA(isA<FormatException>()));
      });

      test('plain sha256 without scheme', () {
        expect(() => VaultRef(kHash), throwsA(isA<FormatException>()));
      });
    });

    group('equality and hashCode', () {
      test('two refs with the same URI are equal', () {
        expect(VaultRef(kUri), equals(VaultRef(kUri)));
      });

      test('refs with different URIs are not equal', () {
        final a = VaultRef(kUri);
        final b = VaultRef('kmdb-vault://sha256/${'a' * 64}');
        expect(a, isNot(equals(b)));
      });

      test('equal refs have the same hashCode', () {
        expect(VaultRef(kUri).hashCode, equals(VaultRef(kUri).hashCode));
      });
    });

    group('isVaultUri', () {
      test('returns true for a valid URI', () {
        expect(VaultRef.isVaultUri(kUri), isTrue);
      });

      test('returns false for a plain string', () {
        expect(VaultRef.isVaultUri('hello'), isFalse);
      });

      test('returns false for a malformed URI', () {
        expect(VaultRef.isVaultUri('kmdb-vault://sha256/short'), isFalse);
      });
    });

    group('getBlob / getMetadata without wired store', () {
      test('getBlob throws StateError when store is not wired', () {
        final ref = VaultRef(kUri);
        expect(() => ref.getBlob(), throwsA(isA<StateError>()));
      });

      test('getMetadata throws StateError when store is not wired', () {
        final ref = VaultRef(kUri);
        expect(() => ref.getMetadata(), throwsA(isA<StateError>()));
      });
    });
  });
}
