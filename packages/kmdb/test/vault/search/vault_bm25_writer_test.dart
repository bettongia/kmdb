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

/// Tests for [VaultBm25Writer]: key format, value encoding, and WriteBatch contents.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/vault/search/vault_bm25_writer.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart'
    show
        kVaultFtsPrefix,
        kVaultFtsCorpusPrefix,
        kVaultCorpusSentinelKey,
        kVaultChunkKey;
import 'package:test/test.dart';

void main() {
  const writer = VaultBm25Writer();
  // 64-char hex SHA-256 placeholder.
  final sha256 = 'a' * 64;

  group('VaultBm25Writer', () {
    // ── write() — term namespace keys ───────────────────────────────────────

    test('writes per-chunk term entries with correct namespace', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: [
          {'hello': 2, 'world': 1},
        ],
        totalTokens: 3,
        batch: batch,
      );

      // The term 'hello' in UTF-8 hex = '68656c6c6f'.
      final helloHex = VaultBm25Writer.termToHex('hello');
      final worldHex = VaultBm25Writer.termToHex('world');
      // Chunk key is 32-char UUIDv7-format; delegates to kVaultChunkKey.
      final chunkKey = VaultBm25Writer.chunkIndexKey(0);

      expect(helloHex, equals('68656c6c6f'));
      expect(chunkKey.length, equals(32));
      expect(chunkKey[12], equals('7')); // version nibble
      expect(chunkKey[16], equals('8')); // variant nibble for chunk keys

      final termNs = '$kVaultFtsPrefix$sha256:$helloHex';
      final helloEntry = batch.entries.firstWhere(
        (e) => e.namespace == termNs && e.key == chunkKey,
        orElse: () => throw StateError('hello entry not found'),
      );
      expect(helloEntry.value, isNotNull);

      // Decode CBOR int.
      final tf = VaultBm25Writer.decodeTf(helloEntry.value!);
      expect(tf, equals(2));

      final worldNs = '$kVaultFtsPrefix$sha256:$worldHex';
      final worldEntry = batch.entries.firstWhere(
        (e) => e.namespace == worldNs && e.key == chunkKey,
        orElse: () => throw StateError('world entry not found'),
      );
      expect(VaultBm25Writer.decodeTf(worldEntry.value!), equals(1));
    });

    test('chunk index key is 32-char UUIDv7-format via kVaultChunkKey', () {
      // Each key must satisfy KeyCodec: 32 hex chars, char[12]='7', char[16]='8'.
      for (final i in [0, 1, 255, 65536]) {
        final key = VaultBm25Writer.chunkIndexKey(i);
        expect(key.length, equals(32), reason: 'key for chunk $i');
        expect(key[12], equals('7'), reason: 'version nibble for chunk $i');
        expect(key[16], equals('8'), reason: 'variant nibble for chunk $i');
      }
      // Different chunk indices produce different keys.
      expect(
        VaultBm25Writer.chunkIndexKey(0),
        isNot(equals(VaultBm25Writer.chunkIndexKey(1))),
      );
    });

    // ── write() — corpus sentinel ───────────────────────────────────────────

    test('writes corpus sentinel with correct namespace and key', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: [
          {'foo': 1},
          {'bar': 2},
        ],
        totalTokens: 3,
        batch: batch,
      );

      final corpusNs = '$kVaultFtsCorpusPrefix$sha256';
      final sentinel = batch.entries.firstWhere(
        (e) => e.namespace == corpusNs && e.key == kVaultCorpusSentinelKey,
        orElse: () => throw StateError('corpus sentinel not found'),
      );
      expect(sentinel.value, isNotNull);

      final decoded = VaultBm25Writer.decodeCorpus(sentinel.value!);
      expect(decoded, isNotNull);
      expect(decoded!.n, equals(2)); // 2 chunks
      expect(decoded.totalTokens, equals(3));
    });

    test('corpus sentinel n = number of chunks', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: [
          {'a': 1},
          {'b': 1},
          {'c': 1},
        ],
        totalTokens: 3,
        batch: batch,
      );
      final corpusNs = '$kVaultFtsCorpusPrefix$sha256';
      final sentinel = batch.entries.firstWhere(
        (e) => e.namespace == corpusNs && e.key == kVaultCorpusSentinelKey,
      );
      final decoded = VaultBm25Writer.decodeCorpus(sentinel.value!);
      expect(decoded!.n, equals(3));
    });

    // ── write() — multiple chunks ───────────────────────────────────────────

    test('writes multiple chunks with correct key index', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: [
          {'foo': 1},
          {'foo': 3},
          {'bar': 2},
        ],
        totalTokens: 6,
        batch: batch,
      );
      final fooHex = VaultBm25Writer.termToHex('foo');
      final ns = '$kVaultFtsPrefix$sha256:$fooHex';
      final chunk0 = batch.entries.firstWhere(
        (e) => e.namespace == ns && e.key == kVaultChunkKey(0),
      );
      final chunk1 = batch.entries.firstWhere(
        (e) => e.namespace == ns && e.key == kVaultChunkKey(1),
      );
      expect(VaultBm25Writer.decodeTf(chunk0.value!), equals(1));
      expect(VaultBm25Writer.decodeTf(chunk1.value!), equals(3));
    });

    // ── write() — empty term maps ───────────────────────────────────────────

    test('empty term maps produce only corpus sentinel (no term entries)', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: [{}],
        totalTokens: 0,
        batch: batch,
      );
      // Only the corpus sentinel should be present.
      final nonCorpus = batch.entries.where(
        (e) => !e.namespace.startsWith(kVaultFtsCorpusPrefix),
      );
      expect(nonCorpus, isEmpty);
    });

    test('empty chunk list produces only corpus sentinel with n=0', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: const [],
        totalTokens: 0,
        batch: batch,
      );
      final corpusNs = '$kVaultFtsCorpusPrefix$sha256';
      final entries = batch.entries
          .where((e) => e.namespace == corpusNs)
          .toList();
      expect(entries.length, equals(1));
      final decoded = VaultBm25Writer.decodeCorpus(entries.first.value!);
      expect(decoded!.n, equals(0));
    });

    // ── deleteCorpus() ─────────────────────────────────────────────────────

    test('deleteCorpus adds delete entry for corpus sentinel', () {
      final batch = WriteBatch();
      writer.deleteCorpus(sha256: sha256, batch: batch);
      final corpusNs = '$kVaultFtsCorpusPrefix$sha256';
      final entry = batch.entries.firstWhere(
        (e) => e.namespace == corpusNs && e.key == kVaultCorpusSentinelKey,
      );
      expect(entry.value, isNull); // null value = delete
    });

    // ── deleteTermEntry() ──────────────────────────────────────────────────

    test('deleteTermEntry adds delete entry for correct namespace and key', () {
      final batch = WriteBatch();
      writer.deleteTermEntry(
        sha256: sha256,
        term: 'hello',
        chunkIndex: 3,
        batch: batch,
      );
      final helloHex = VaultBm25Writer.termToHex('hello');
      final ns = '$kVaultFtsPrefix$sha256:$helloHex';
      final entry = batch.entries.firstWhere(
        (e) => e.namespace == ns && e.key == kVaultChunkKey(3),
      );
      expect(entry.value, isNull);
    });

    // ── Namespace prefix correctness ────────────────────────────────────────

    test(r'term namespace uses $$ prefix (local-only)', () {
      expect(kVaultFtsPrefix, startsWith(r'$$'));
    });

    test(r'corpus namespace uses $$ prefix (local-only)', () {
      expect(kVaultFtsCorpusPrefix, startsWith(r'$$'));
    });

    // ── decodeCorpus() edge cases ───────────────────────────────────────────

    test('decodeCorpus returns null for null input', () {
      expect(VaultBm25Writer.decodeCorpus(null), isNull);
    });

    test('decodeCorpus returns null for malformed bytes', () {
      expect(
        VaultBm25Writer.decodeCorpus(Uint8List.fromList([0xFF, 0xFF])),
        isNull,
      );
    });

    // ── decodeTf() edge cases ───────────────────────────────────────────────

    test('decodeTf returns 0 for null input', () {
      expect(VaultBm25Writer.decodeTf(null), equals(0));
    });

    test('decodeTf round-trips various values', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        termFrequencies: [
          {'x': 42},
        ],
        totalTokens: 42,
        batch: batch,
      );
      final xHex = VaultBm25Writer.termToHex('x');
      final ns = '$kVaultFtsPrefix$sha256:$xHex';
      final entry = batch.entries.firstWhere((e) => e.namespace == ns);
      expect(VaultBm25Writer.decodeTf(entry.value!), equals(42));
    });
  });
}
