// Copyright 2026 The KMDB Authors
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

import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:test/test.dart';

void main() {
  const kSha256 =
      'dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8';
  const kCrc32c = 'a1b2c3d4';

  VaultManifest validManifest() => const VaultManifest(
    sha256: kSha256,
    size: 12345,
    crc32c: kCrc32c,
    mediaType: 'image/jpeg',
    originalName: 'photo.jpg',
    createdAt: '2026-04-08T12:00:00.000Z',
  );

  group('VaultManifest', () {
    group('construction', () {
      test('creates with valid fields', () {
        final m = validManifest();
        expect(m.schemaVersion, equals('1'));
        expect(m.sha256, equals(kSha256));
        expect(m.size, equals(12345));
        expect(m.crc32c, equals(kCrc32c));
        expect(m.mediaType, equals('image/jpeg'));
        expect(m.originalName, equals('photo.jpg'));
        expect(m.createdAt, equals('2026-04-08T12:00:00.000Z'));
      });

      test('kSchemaVersion is "1"', () {
        expect(VaultManifest.kSchemaVersion, equals('1'));
      });

      test('default schemaVersion is "1"', () {
        expect(validManifest().schemaVersion, equals('1'));
      });
    });

    group('toJson', () {
      test('produces expected map', () {
        final json = validManifest().toJson();
        expect(json['schemaVersion'], equals('1'));
        expect(json['sha256'], equals(kSha256));
        expect(json['size'], equals(12345));
        expect(json['crc32c'], equals(kCrc32c));
        expect(json['mediaType'], equals('image/jpeg'));
        expect(json['originalName'], equals('photo.jpg'));
        expect(json['createdAt'], equals('2026-04-08T12:00:00.000Z'));
      });

      test('toJsonString produces valid JSON', () {
        final s = validManifest().toJsonString();
        expect(s, contains('"schemaVersion"'));
        expect(s, contains('"1"'));
        expect(s, contains(kSha256));
      });
    });

    group('fromJson round-trip', () {
      test('round-trips through toJson/fromJson', () {
        final original = validManifest();
        final decoded = VaultManifest.fromJson(original.toJson());
        expect(decoded, equals(original));
      });

      test('round-trips through toJsonString/fromJsonString', () {
        final original = validManifest();
        final decoded = VaultManifest.fromJsonString(original.toJsonString());
        expect(decoded, equals(original));
      });
    });

    group('fromJson validation', () {
      Map<String, dynamic> baseJson() => validManifest().toJson();

      test('throws FormatException for missing schemaVersion', () {
        final json = baseJson()..remove('schemaVersion');
        expect(
          () => VaultManifest.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('schemaVersion'),
            ),
          ),
        );
      });

      test('throws FormatException for unknown schemaVersion', () {
        final json = baseJson()..[('schemaVersion')] = '2';
        expect(
          () => VaultManifest.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('unsupported schemaVersion'),
            ),
          ),
        );
      });

      test('throws FormatException for non-string schemaVersion', () {
        final json = baseJson()..[('schemaVersion')] = 1;
        expect(
          () => VaultManifest.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for missing sha256', () {
        final json = baseJson()..remove('sha256');
        expect(
          () => VaultManifest.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('sha256'),
            ),
          ),
        );
      });

      test('throws FormatException for sha256 with wrong length', () {
        final json = baseJson()..[('sha256')] = 'abc123';
        expect(
          () => VaultManifest.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for sha256 with uppercase', () {
        final json = baseJson()..[('sha256')] = kSha256.toUpperCase();
        expect(
          () => VaultManifest.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for missing crc32c', () {
        final json = baseJson()..remove('crc32c');
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });

      test('throws FormatException for crc32c with wrong length', () {
        final json = baseJson()..[('crc32c')] = 'abc';
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });

      test('throws FormatException for missing size', () {
        final json = baseJson()..remove('size');
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });

      test('throws FormatException for non-int size', () {
        final json = baseJson()..[('size')] = '12345';
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });

      test('throws FormatException for missing mediaType', () {
        final json = baseJson()..remove('mediaType');
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });

      test('throws FormatException for missing originalName', () {
        final json = baseJson()..remove('originalName');
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });

      test('throws FormatException for missing createdAt', () {
        final json = baseJson()..remove('createdAt');
        expect(() => VaultManifest.fromJson(json), throwsA(isA<FormatException>()));
      });
    });

    group('fromJsonString validation', () {
      test('throws FormatException for invalid JSON', () {
        expect(
          () => VaultManifest.fromJsonString('not json'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for JSON array (not object)', () {
        expect(
          () => VaultManifest.fromJsonString('[]'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('equality and hashCode', () {
      test('two identical manifests are equal', () {
        expect(validManifest(), equals(validManifest()));
      });

      test('manifests differing by size are not equal', () {
        final a = validManifest();
        final b = VaultManifest(
          sha256: kSha256,
          size: 999,
          crc32c: kCrc32c,
          mediaType: 'image/jpeg',
          originalName: 'photo.jpg',
          createdAt: '2026-04-08T12:00:00.000Z',
        );
        expect(a, isNot(equals(b)));
      });

      test('equal manifests have the same hashCode', () {
        expect(validManifest().hashCode, equals(validManifest().hashCode));
      });
    });

    group('toString', () {
      test('contains sha256 prefix and relevant fields', () {
        final s = validManifest().toString();
        expect(s, contains('VaultManifest'));
        expect(s, contains('image/jpeg'));
        expect(s, contains('photo.jpg'));
      });
    });
  });
}
