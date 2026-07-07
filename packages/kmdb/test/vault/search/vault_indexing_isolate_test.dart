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

/// Tests for the vault indexing isolate's extraction logic.
///
/// Per the plan, these tests exercise the entry-point processing function
/// directly (not via a spawned isolate) to keep the tests fast and free of
/// isolate communication overhead. The [VaultIndexingIsolate.processWorkItemForTesting]
/// @visibleForTesting hook allows direct invocation of `_processWorkItem` to
/// reach error paths (extractor throws, extractor returns null) that cannot be
/// sent across the real isolate boundary.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/src/vault/search/plain_text_extractor.dart';
import 'package:kmdb/src/vault/search/vault_indexing_isolate.dart';
import 'package:kmdb/src/vault/search/vault_text_extractor.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:test/test.dart';

// ── Test helpers ───────────────────────────────────────────────────────────────

/// Creates a VaultWorkItem with the given bytes and mediaType.
VaultWorkItem _workItem({
  required Uint8List bytes,
  String mediaType = 'text/plain',
  int chunkSize = 5,
  int chunkOverlap = 1,
}) => VaultWorkItem(
  sha256: 'b' * 64,
  mediaType: mediaType,
  bytes: bytes,
  chunkSize: chunkSize,
  chunkOverlap: chunkOverlap,
);

/// A [VaultTextExtractor] that claims to support `text/plain` but throws.
///
/// Used to exercise the defensive `catch(e)` path in `_processWorkItem`.
final class _ThrowingExtractor implements VaultTextExtractor {
  @override
  Set<String> get supportedMediaTypes => const {'text/plain'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async =>
      throw StateError('deliberate extraction failure for testing');
}

/// A [VaultTextExtractor] that claims to support `text/plain` but returns null.
///
/// Used to exercise the null-return branch in `_processWorkItem`
/// (extractor matched but could not process the blob).
final class _NullReturningExtractor implements VaultTextExtractor {
  @override
  Set<String> get supportedMediaTypes => const {'text/plain'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async =>
      null;
}

void main() {
  group('VaultIndexingIsolate', () {
    late VaultIndexingIsolate isolate;

    setUp(() async {
      isolate = await VaultIndexingIsolate.spawn([PlainTextExtractor()]);
    });

    tearDown(() async {
      await isolate.shutdown();
    });

    // ── text/plain extraction ───────────────────────────────────────────────

    test('text/plain blob → extracted text and chunks', () async {
      final text = 'hello world foo bar baz qux quux corge grault garply';
      final bytes = utf8.encode(text);
      final item = _workItem(bytes: Uint8List.fromList(bytes), chunkSize: 5);

      final result = await isolate.sendWork(item);

      expect(result.isSuccess, isTrue);
      expect(result.extractedText, equals(text));
      expect(result.chunks, isNotEmpty);
      expect(result.termFrequencies.length, equals(result.chunks.length));
    });

    test('text/plain blob → charset recorded', () async {
      final bytes = utf8.encode('hello world foo bar');
      final item = _workItem(bytes: Uint8List.fromList(bytes));

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.charset, equals('utf-8'));
    });

    // ── WI-6: script/language detection ─────────────────────────────────────

    test('English prose → script Latn, confident language en', () async {
      final text =
          'The quick brown fox jumps over the lazy dog near the riverbank.';
      final item = _workItem(bytes: Uint8List.fromList(utf8.encode(text)));

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.script, equals('Latn'));
      expect(result.language, equals('en'));
      expect(result.stemmerLanguageCode, equals('en'));
    });

    test('pure-Han (Chinese) text → script Hani, script-exclusive language '
        'trusted unconditionally', () async {
      const text = '这是一个测试文档包含多个词语';
      final item = _workItem(bytes: Uint8List.fromList(utf8.encode(text)));

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.script, equals('Hani'));
      // Chinese resolves via the script pre-filter's script-exclusive
      // branch (a single ranked candidate), which is trusted
      // unconditionally regardless of word count or margin — see
      // language_detection.dart's doc comment.
      expect(result.language, equals('zh'));
      expect(result.stemmerLanguageCode, equals('zh'));
    });

    test('Arabic text → script Arab', () async {
      const text =
          'هذا نص عربي طويل يحتوي على عدة كلمات مختلفة للتحقق من اكتشاف اللغة';
      final item = _workItem(bytes: Uint8List.fromList(utf8.encode(text)));

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.script, equals('Arab'));
      // Unlike Chinese/Japanese, Arabic script covers multiple candidate
      // languages (ar, fa, ur, ps, ...), so this does NOT necessarily
      // resolve via the script-exclusive branch — script population is
      // unconditional and reliable either way, which is what this test
      // asserts; the language/stemmer code is not pinned here.
    });

    test('Cyrillic (Russian) text → script Cyrl', () async {
      const text =
          'Это длинный русский текст для тестирования определения '
          'языка компьютерной программы сегодня';
      final item = _workItem(bytes: Uint8List.fromList(utf8.encode(text)));

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.script, equals('Cyrl'));
    });

    test('digits/punctuation-only text → script null, language null, '
        'stemmerLanguageCode still defaults to en', () async {
      final item = _workItem(
        bytes: Uint8List.fromList(utf8.encode('12345 !@#\$% 67890')),
      );

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.script, isNull);
      expect(result.language, isNull);
      expect(result.stemmerLanguageCode, equals('en'));
    });

    test('empty text/plain blob → empty chunks, indexed', () async {
      final item = _workItem(bytes: Uint8List(0));

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);
      expect(result.extractedText, equals(''));
      expect(result.chunks, isEmpty);
      expect(result.termFrequencies, isEmpty);
    });

    // ── Unsupported media type ──────────────────────────────────────────────

    test('unsupported media type → isUnsupported', () async {
      final item = _workItem(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        mediaType: 'image/jpeg',
      );

      final result = await isolate.sendWork(item);
      expect(result.isUnsupported, isTrue);
      expect(result.extractedText, isNull);
      expect(result.error, isNull);
    });

    // ── Multiple work items processed sequentially ──────────────────────────

    test('processes multiple work items in sequence', () async {
      final item1 = _workItem(
        bytes: Uint8List.fromList(utf8.encode('one two three four five')),
      );
      final item2 = _workItem(
        bytes: Uint8List.fromList(utf8.encode('six seven eight nine ten')),
      );

      final r1 = await isolate.sendWork(item1);
      final r2 = await isolate.sendWork(item2);

      expect(r1.isSuccess, isTrue);
      expect(r2.isSuccess, isTrue);
    });

    // ── Term frequency maps ─────────────────────────────────────────────────

    test(
      'term frequency maps are populated for content-bearing chunks',
      () async {
        final text =
            'databases store documents efficiently with indexes queries';
        final item = _workItem(
          bytes: Uint8List.fromList(utf8.encode(text)),
          chunkSize: 10,
          chunkOverlap: 0,
        );

        final result = await isolate.sendWork(item);
        expect(result.isSuccess, isTrue);

        // At least some TF maps should have non-zero entries (words survive
        // stop-word filtering and stemming).
        final nonEmpty = result.termFrequencies
            .where((tf) => tf.isNotEmpty)
            .length;
        expect(nonEmpty, greaterThan(0));
      },
    );

    // ── Chunk byte offset integrity ─────────────────────────────────────────

    test('chunk byte offsets correctly reference extractedText', () async {
      final text =
          'hello world foo bar baz qux quux corge grault garply waldo fred';
      final item = _workItem(
        bytes: Uint8List.fromList(utf8.encode(text)),
        chunkSize: 5,
        chunkOverlap: 1,
      );

      final result = await isolate.sendWork(item);
      expect(result.isSuccess, isTrue);

      final textBytes = utf8.encode(result.extractedText!);
      for (final chunk in result.chunks) {
        expect(chunk.byteStart, greaterThanOrEqualTo(0));
        expect(chunk.byteEnd, lessThanOrEqualTo(textBytes.length));
        // Byte slice must decode cleanly.
        final slice = textBytes.sublist(chunk.byteStart, chunk.byteEnd);
        expect(() => utf8.decode(slice), returnsNormally);
      }
    });
  });

  // ── processWorkItemForTesting — direct invocation of _processWorkItem ──────
  //
  // These tests call VaultIndexingIsolate.processWorkItemForTesting, which
  // delegates directly to _processWorkItem on the main isolate (no isolate
  // spawn, no cross-isolate message). This allows exercising error paths that
  // cannot be reached via sendWork because the error-inducing extractor
  // implementations cannot be transferred across the isolate boundary.

  group('processWorkItemForTesting — error paths', () {
    // ── Extractor throws ─────────────────────────────────────────────────────

    test('extractor that throws → isFailed with error message', () async {
      final item = _workItem(
        bytes: Uint8List.fromList(utf8.encode('hello world')),
      );

      final result = await VaultIndexingIsolate.processWorkItemForTesting(
        item,
        [_ThrowingExtractor()],
      );

      expect(
        result.isFailed,
        isTrue,
        reason: 'catch(e) path should mark the result as failed',
      );
      expect(
        result.error,
        contains('deliberate extraction failure for testing'),
        reason: 'error message should include the original exception text',
      );
      expect(result.extractedText, isNull);
      expect(result.chunks, isEmpty);
    });

    // ── Extractor returns null ───────────────────────────────────────────────

    test('extractor that returns null → isFailed with error message', () async {
      final item = _workItem(
        bytes: Uint8List.fromList(utf8.encode('hello world')),
      );

      final result = await VaultIndexingIsolate.processWorkItemForTesting(
        item,
        [_NullReturningExtractor()],
      );

      // Null return from a matched extractor is treated as a failure, not as
      // "unsupported" (the latter requires no extractor to match at all).
      expect(
        result.isFailed,
        isTrue,
        reason:
            'null return from matched extractor should mark result as failed',
      );
      expect(result.error, isNotNull);
      expect(result.extractedText, isNull);
      expect(result.chunks, isEmpty);
    });

    // ── Unsupported media type (direct) ─────────────────────────────────────

    test('unsupported media type via direct call → isUnsupported', () async {
      final item = _workItem(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        mediaType: 'image/jpeg',
      );

      final result = await VaultIndexingIsolate.processWorkItemForTesting(
        item,
        [PlainTextExtractor()],
      );

      expect(result.isUnsupported, isTrue);
      expect(result.extractedText, isNull);
      expect(result.error, isNull);
    });

    // ── Normal text/plain path (direct) ─────────────────────────────────────

    test('text/plain blob via direct call → isSuccess', () async {
      final text = 'one two three four five six seven eight nine ten';
      final item = _workItem(
        bytes: Uint8List.fromList(utf8.encode(text)),
        chunkSize: 5,
        chunkOverlap: 1,
      );

      final result = await VaultIndexingIsolate.processWorkItemForTesting(
        item,
        [PlainTextExtractor()],
      );

      expect(result.isSuccess, isTrue);
      expect(result.extractedText, equals(text));
      expect(result.chunks, isNotEmpty);
    });
  });
}
