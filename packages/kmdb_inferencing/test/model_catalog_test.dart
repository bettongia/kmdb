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

import 'package:kmdb_inferencing/kmdb_inferencing.dart';
import 'package:test/test.dart';

void main() {
  group('ModelSpec (via ModelCatalog)', () {
    test('BGE Small En v1.5 spec has correct dimensions in meta', () {
      final spec = ModelCatalog.lookup('bge-small-en-v1.5');
      expect(spec.id, equals('bge-small-en-v1.5'));
      // Dimensions are stored in spec.meta['dimensions'] — not as a direct
      // field — because betto_onnxrt uses a generic ModelSpec shape.
      expect(spec.meta['dimensions'], equals(384));
    });

    test('BGE Small En v1.5 has non-empty URLs and checksums', () {
      final spec = ModelCatalog.lookup('bge-small-en-v1.5');
      expect(spec.files['onnx']!.url.toString(), isNotEmpty);
      expect(spec.files['vocab']!.url.toString(), isNotEmpty);
      expect(spec.files['onnx']!.sha256, isNotEmpty);
      expect(spec.files['vocab']!.sha256, isNotEmpty);
    });

    test('BGE Small En v1.5 onnx URL points to HuggingFace', () {
      final spec = ModelCatalog.lookup('bge-small-en-v1.5');
      expect(spec.files['onnx']!.url.toString(), contains('huggingface.co'));
    });

    test('BGE Small En v1.5 has onnx and vocab file entries', () {
      final spec = ModelCatalog.lookup('bge-small-en-v1.5');
      expect(spec.files.containsKey('onnx'), isTrue);
      expect(spec.files.containsKey('vocab'), isTrue);
    });
  });

  group('ModelCatalog.lookup', () {
    test('returns the correct spec for a known validated model', () {
      final spec = ModelCatalog.lookup('bge-small-en-v1.5');
      expect(spec.id, equals('bge-small-en-v1.5'));
      expect(spec.meta['dimensions'], equals(384));
    });

    test('throws ArgumentError for an unknown model ID', () {
      expect(
        () => ModelCatalog.lookup('unknown-model-v99'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Unknown embedding model ID'),
          ),
        ),
      );
    });

    test('error message for unknown model lists registered IDs', () {
      expect(
        () => ModelCatalog.lookup('unknown-model'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message as String,
            'message',
            allOf(contains('bge-small-en-v1.5'), contains('bge-m3-v1.0')),
          ),
        ),
      );
    });

    test('throws UnsupportedError for a registered but unvalidated model', () {
      // BGE-M3 is registered as infrastructure but not yet validated.
      expect(
        () => ModelCatalog.lookup('bge-m3-v1.0'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('not yet been validated'),
          ),
        ),
      );
    });

    test('error message for unvalidated model mentions the model ID', () {
      expect(
        () => ModelCatalog.lookup('bge-m3-v1.0'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('bge-m3-v1.0'),
          ),
        ),
      );
    });
  });

  group('ModelCatalog.isKnown', () {
    test('returns true for a registered validated model', () {
      expect(ModelCatalog.isKnown('bge-small-en-v1.5'), isTrue);
    });

    test('returns true for a registered but unvalidated model', () {
      // isKnown does not check validation state — it only checks registration.
      expect(ModelCatalog.isKnown('bge-m3-v1.0'), isTrue);
    });

    test('returns false for an unknown model ID', () {
      expect(ModelCatalog.isKnown('nonexistent-model'), isFalse);
    });
  });

  group('ModelCatalog.all', () {
    test('contains at least two entries (BGE Small En and BGE-M3)', () {
      final all = ModelCatalog.all.toList();
      expect(all.length, greaterThanOrEqualTo(2));
    });

    test('contains BGE Small En v1.5', () {
      expect(ModelCatalog.all.any((s) => s.id == 'bge-small-en-v1.5'), isTrue);
    });

    test('contains BGE-M3 (as infrastructure, unvalidated)', () {
      expect(ModelCatalog.all.any((s) => s.id == 'bge-m3-v1.0'), isTrue);
    });
  });

  group('ModelCatalog.defaultModelId', () {
    test('default model ID is bge-small-en-v1.5', () {
      expect(ModelCatalog.defaultModelId, equals('bge-small-en-v1.5'));
    });

    test('default model is validated', () {
      final spec = ModelCatalog.lookup(ModelCatalog.defaultModelId);
      expect(spec.id, equals(ModelCatalog.defaultModelId));
    });
  });

  group('ModelCatalog as AllowlistProvider', () {
    test('isAllowed returns true for a registered model', () {
      const catalog = ModelCatalog();
      final spec = ModelCatalog.lookup('bge-small-en-v1.5');
      expect(catalog.isAllowed(spec), isTrue);
    });

    test('isAllowed returns true for a registered but unvalidated model', () {
      const catalog = ModelCatalog();
      // BGE-M3 is registered but unvalidated — isAllowed only checks
      // registration, not validation status.
      final bgeM3 = ModelCatalog.all.firstWhere((s) => s.id == 'bge-m3-v1.0');
      expect(catalog.isAllowed(bgeM3), isTrue);
    });

    test('isAllowed returns false for an unregistered model', () {
      const catalog = ModelCatalog();
      const unknownSpec = ModelSpec(id: 'unknown-model', files: {});
      expect(catalog.isAllowed(unknownSpec), isFalse);
    });
  });
}
