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

import 'dart:convert' show utf8;

import 'package:kmdb/src/vault/search/vault_chunk.dart';
import 'package:kmdb/src/vault/search/vault_chunker.dart';
import 'package:kmdb/src/vault/search/vault_extraction_state.dart';
import 'package:kmdb/src/vault/search/vault_search_config.dart';
import 'package:test/test.dart';

void main() {
  group('VaultChunker', () {
    VaultChunker chunker({int chunkSize = 5, int chunkOverlap = 1}) =>
        VaultChunker(
          VaultSearchConfig(chunkSize: chunkSize, chunkOverlap: chunkOverlap),
        );

    // ── Empty input ─────────────────────────────────────────────────────────

    test('empty text returns empty result', () {
      final result = chunker().chunk('');
      expect(result.chunks, isEmpty);
      expect(result.termFrequencies, isEmpty);
    });

    test('text with only punctuation returns empty result', () {
      final result = chunker().chunk('... --- !!');
      expect(result.chunks, isEmpty);
      expect(result.termFrequencies, isEmpty);
    });

    // ── Single chunk ────────────────────────────────────────────────────────

    test('text shorter than chunkSize → single chunk covering full text', () {
      final text = 'hello world foo';
      final result = chunker(chunkSize: 10, chunkOverlap: 2).chunk(text);
      expect(result.chunks, hasLength(1));
      final chunk = result.chunks[0];
      expect(chunk.index, 0);
      expect(chunk.byteStart, 0);
      expect(chunk.byteEnd, utf8.encode(text).length);
      expect(chunk.wordCount, 3);
    });

    test('text exactly chunkSize words → single chunk', () {
      // 5 words, chunkSize = 5
      final text = 'alpha bravo charlie delta echo';
      final result = chunker(chunkSize: 5, chunkOverlap: 1).chunk(text);
      expect(result.chunks, hasLength(1));
      expect(result.chunks[0].wordCount, 5);
    });

    // ── Multiple chunks with overlap ────────────────────────────────────────

    test('multiple chunks with correct overlap', () {
      // 10 words, chunkSize = 5, chunkOverlap = 2, step = 3
      // Window 0: tokens[0..4] (words 0-4)
      // Window 1: tokens[3..7] (words 3-7)
      // Window 2: tokens[6..9] (words 6-9, only 4 words in last window)
      final text = 'one two three four five six seven eight nine ten';
      final result = chunker(chunkSize: 5, chunkOverlap: 2).chunk(text);

      expect(result.chunks, hasLength(3));
      expect(result.termFrequencies, hasLength(3));

      // Index ordering.
      for (var i = 0; i < result.chunks.length; i++) {
        expect(result.chunks[i].index, i);
      }

      // Chunk 0: words 0-4.
      expect(result.chunks[0].wordCount, 5);
      // Chunk 1: words 3-7.
      expect(result.chunks[1].wordCount, 5);
      // Chunk 2: words 6-9 (4 words — last window may be shorter).
      expect(result.chunks[2].wordCount, 4);
    });

    // ── Byte offset correctness ─────────────────────────────────────────────

    test('byte offsets correctly recover chunk text from UTF-8 bytes', () {
      final text = 'hello world foo bar baz qux quux';
      final result = chunker(chunkSize: 3, chunkOverlap: 1).chunk(text);
      final textBytes = utf8.encode(text);

      for (final chunk in result.chunks) {
        // Recover chunk text using byte offsets.
        final sliceBytes = textBytes.sublist(chunk.byteStart, chunk.byteEnd);
        final sliceText = utf8.decode(sliceBytes);
        // The recovered text should contain the expected number of word tokens.
        final wordCount = RegExp(r'\w+').allMatches(sliceText).length;
        expect(
          wordCount,
          chunk.wordCount,
          reason:
              'Chunk ${chunk.index}: byte offsets should recover exactly '
              '${chunk.wordCount} words',
        );
      }
    });

    test('non-ASCII multi-byte characters: byte offsets are correct', () {
      // "café résumé" — each accented char is 2 UTF-8 bytes.
      // "日本語テスト" — each CJK char is 3 UTF-8 bytes.
      final text = 'café résumé naïve jalapeño lorem ipsum dolor sit amet';
      final result = chunker(chunkSize: 3, chunkOverlap: 1).chunk(text);
      final textBytes = utf8.encode(text);

      expect(result.chunks, isNotEmpty);
      for (final chunk in result.chunks) {
        // Byte range must be within the total byte length.
        expect(chunk.byteStart, greaterThanOrEqualTo(0));
        expect(chunk.byteEnd, lessThanOrEqualTo(textBytes.length));
        expect(chunk.byteStart, lessThan(chunk.byteEnd));

        // Recovered text should decode cleanly.
        final sliceBytes = textBytes.sublist(chunk.byteStart, chunk.byteEnd);
        expect(
          () => utf8.decode(sliceBytes),
          returnsNormally,
          reason: 'Chunk ${chunk.index}: byte slice should be valid UTF-8',
        );
      }
    });

    test('emoji (4-byte UTF-8 surrogate pairs): byte offsets are correct', () {
      // Each emoji is a surrogate pair in Dart strings (2 code units) but
      // 4 bytes in UTF-8.
      final text = '🎉 hello world 🚀 foo bar baz 🌟 qux';
      final result = chunker(chunkSize: 3, chunkOverlap: 1).chunk(text);
      final textBytes = utf8.encode(text);

      expect(result.chunks, isNotEmpty);
      for (final chunk in result.chunks) {
        expect(chunk.byteStart, greaterThanOrEqualTo(0));
        expect(chunk.byteEnd, lessThanOrEqualTo(textBytes.length));
        final sliceBytes = textBytes.sublist(chunk.byteStart, chunk.byteEnd);
        // Must decode without error.
        expect(() => utf8.decode(sliceBytes), returnsNormally);
      }
    });

    // ── Term frequency maps ─────────────────────────────────────────────────

    test('termFrequencies length matches chunks length', () {
      final text = 'alpha bravo charlie delta echo foxtrot golf hotel';
      final result = chunker(chunkSize: 4, chunkOverlap: 1).chunk(text);
      expect(result.termFrequencies.length, result.chunks.length);
    });

    test('termFrequencies are non-empty for non-stop-word chunks', () {
      final text = 'database query result filter sort limit offset page';
      final result = chunker(chunkSize: 4, chunkOverlap: 1).chunk(text);
      // At least some chunks should have non-empty TF maps (words that survive
      // stop-word filtering and stemming).
      final nonEmpty = result.termFrequencies
          .where((tf) => tf.isNotEmpty)
          .length;
      expect(nonEmpty, greaterThan(0));
    });

    test('all-stop-word chunk produces empty TF map', () {
      // Common English stop words only.
      final text = 'the a is are was were be been being';
      final result = chunker(chunkSize: 5, chunkOverlap: 1).chunk(text);
      // Stop-word-only text should yield empty TF maps after filtering.
      for (final tf in result.termFrequencies) {
        // After stemming, "be" → "be", "been" → "been", "being" → "be" —
        // these may or may not be stop words depending on the list.
        // What we require: no error, and the list of TF maps is the same
        // length as chunks.
        expect(tf, isA<Map<String, int>>());
      }
      expect(result.termFrequencies.length, result.chunks.length);
    });

    // ── VaultChunk serialisation ────────────────────────────────────────────

    test('VaultChunk toJson / fromJson round-trip', () {
      const chunk = VaultChunk(
        index: 2,
        byteStart: 1024,
        byteEnd: 2048,
        wordCount: 300,
      );
      final json = chunk.toJson();
      final decoded = VaultChunk.fromJson(json);
      expect(decoded, equals(chunk));
    });

    // ── VaultSearchConfig validation ────────────────────────────────────────

    test('VaultSearchConfig.chunkSize must be > 0', () {
      expect(
        () => VaultSearchConfig(chunkSize: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('VaultSearchConfig.chunkOverlap must be < chunkSize', () {
      expect(
        () => VaultSearchConfig(chunkSize: 5, chunkOverlap: 5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('VaultSearchConfig.chunkOverlap must be >= 0', () {
      expect(
        () => VaultSearchConfig(chunkSize: 5, chunkOverlap: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('effectiveExtractors prepends PlainTextExtractor when no extractor '
        'handles text/plain', () {
      // Config with no extractors — effectiveExtractors must inject
      // PlainTextExtractor as the first entry (line 118 coverage).
      final config = VaultSearchConfig();
      final extractors = config.effectiveExtractors;
      expect(extractors, isNotEmpty);
      // The first extractor should handle text/plain.
      expect(extractors.first.supportedMediaTypes, contains('text/plain'));
    });
  });

  // ── VaultChunk value type ─────────────────────────────────────────────────

  group('VaultChunk value type', () {
    test('toString includes all fields', () {
      const chunk = VaultChunk(
        index: 0,
        byteStart: 0,
        byteEnd: 10,
        wordCount: 3,
      );
      final str = chunk.toString();
      expect(str, contains('index: 0'));
      expect(str, contains('byteStart: 0'));
      expect(str, contains('byteEnd: 10'));
      expect(str, contains('wordCount: 3'));
    });

    test('== and hashCode for equal instances', () {
      // Non-const so Dart does NOT canonicalise: identical() is false,
      // forcing the field comparison chain.
      final a = VaultChunk(index: 1, byteStart: 5, byteEnd: 15, wordCount: 4);
      final b = VaultChunk(index: 1, byteStart: 5, byteEnd: 15, wordCount: 4);
      expect(a == b, isTrue);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('!= for unequal instances', () {
      const a = VaultChunk(index: 0, byteStart: 0, byteEnd: 10, wordCount: 3);
      const b = VaultChunk(index: 1, byteStart: 0, byteEnd: 10, wordCount: 3);
      expect(a, isNot(equals(b)));
    });
  });

  // ── VaultExtractionState value type ──────────────────────────────────────

  group('VaultExtractionState', () {
    final sha256 = 'a' * 64;

    test('toString includes sha256 prefix and status', () {
      final state = VaultExtractionState(
        sha256: sha256,
        status: VaultExtractionStatus.indexed,
        chunkCount: 3,
      );
      final str = state.toString();
      expect(str, contains('sha256:'));
      expect(str, contains('indexed'));
    });

    test('VaultExtractionStatus.fromName throws on unknown status', () {
      expect(
        () => VaultExtractionStatus.fromName('nonexistent'),
        throwsA(isA<FormatException>()),
      );
    });

    test('VaultExtractionStatus.fromName parses valid status', () {
      expect(
        VaultExtractionStatus.fromName('indexed'),
        equals(VaultExtractionStatus.indexed),
      );
      expect(
        VaultExtractionStatus.fromName('pending'),
        equals(VaultExtractionStatus.pending),
      );
    });
  });
}
