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

/// Tests for [VaultVecWriter]: namespace format, key format, SQ8 encoding,
/// and WriteBatch contents.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';
import 'package:kmdb/src/vault/search/vault_vec_writer.dart';
import 'package:test/test.dart';

void main() {
  const writer = VaultVecWriter();
  final sha256 = 'b' * 64;

  // Creates a simple L2-normalised vector with [dims] dimensions.
  Float32List makeVec(int dims, {double value = 0.5}) {
    final v = Float32List(dims);
    for (var i = 0; i < dims; i++) {
      v[i] = value;
    }
    // Normalize (cheap stand-in for a real embedding).
    final norm = v.fold<double>(0, (sum, x) => sum + x * x);
    final scale = 1.0 / (norm == 0 ? 1 : norm);
    for (var i = 0; i < dims; i++) {
      v[i] *= scale;
    }
    return v;
  }

  group('VaultVecWriter', () {
    // ── vecNamespace() ─────────────────────────────────────────────────────

    test(r'vecNamespace is per-blob: $$vault:vec:idx:{sha256}', () {
      final ns = VaultVecWriter.vecNamespace(sha256);
      expect(ns, equals('$kVaultVecIdxPrefix$sha256'));
      expect(ns, startsWith(r'$$'));
    });

    // ── write() — namespace and key format ─────────────────────────────────

    test('write() stores entries in the per-blob namespace', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        embeddings: [makeVec(4), makeVec(4)],
        batch: batch,
      );

      final expectedNs = VaultVecWriter.vecNamespace(sha256);
      final keys = batch.entries
          .where((e) => e.namespace == expectedNs)
          .map((e) => e.key)
          .toList();

      // Keys are 32-char UUIDv7-format chunk keys (kVaultChunkKey).
      expect(keys, contains(kVaultChunkKey(0)));
      expect(keys, contains(kVaultChunkKey(1)));
    });

    test('chunkKey is 32-char UUIDv7-format', () {
      final key0 = kVaultChunkKey(0);
      expect(key0.length, equals(32));
      // Version nibble at position 12 must be '7'.
      expect(key0[12], equals('7'));
      // Variant nibble at position 16 must be '8' (chunk keys use '8',
      // distinguishing them from the corpus sentinel which uses '9').
      expect(key0[16], equals('8'));
    });

    test('chunkIndexSuffix is 8-digit zero-padded hex (diagnostic only)', () {
      expect(VaultVecWriter.chunkIndexSuffix(0), equals('00000000'));
      expect(VaultVecWriter.chunkIndexSuffix(1), equals('00000001'));
      expect(VaultVecWriter.chunkIndexSuffix(256), equals('00000100'));
    });

    // ── write() — value format ──────────────────────────────────────────────

    test('value length equals vector dimension (SQ8 = 1 byte/component)', () {
      const dims = 384;
      final batch = WriteBatch();
      writer.write(sha256: sha256, embeddings: [makeVec(dims)], batch: batch);
      final entry = batch.entries.first;
      expect(entry.value!.length, equals(dims));
    });

    test('SQ8 quantisation round-trip error < 0.004', () {
      // A vector with values known to stay within [-1, 1] and L2-normalised.
      const dims = 4;
      final original = Float32List.fromList([0.5, -0.5, 0.5, -0.5]);
      // Normalise.
      final norm = original.fold<double>(0, (s, x) => s + x * x);
      final scale = 1.0 / (norm == 0 ? 1 : norm);
      for (var i = 0; i < dims; i++) {
        original[i] *= scale;
      }

      final batch = WriteBatch();
      writer.write(sha256: sha256, embeddings: [original], batch: batch);
      final entry = batch.entries.first;
      final dequantised = VaultVecWriter.dequantise(entry.value!);

      for (var i = 0; i < dims; i++) {
        expect(
          (original[i] - dequantised[i]).abs(),
          lessThan(0.004),
          reason:
              'Component $i: original=${original[i]}, dequantised=${dequantised[i]}',
        );
      }
    });

    // ── write() — multiple chunks ───────────────────────────────────────────

    test('writes correct number of entries for multiple chunks', () {
      final batch = WriteBatch();
      writer.write(
        sha256: sha256,
        embeddings: [makeVec(8), makeVec(8), makeVec(8)],
        batch: batch,
      );
      final entries = batch.entries
          .where((e) => e.namespace == VaultVecWriter.vecNamespace(sha256))
          .toList();
      expect(entries.length, equals(3));
    });

    // ── write() — empty embeddings ──────────────────────────────────────────

    test('empty embeddings produces no entries', () {
      final batch = WriteBatch();
      writer.write(sha256: sha256, embeddings: const [], batch: batch);
      expect(batch.entries, isEmpty);
    });

    // ── deleteAll() ─────────────────────────────────────────────────────────

    test('deleteAll adds delete entries for all chunks', () {
      final batch = WriteBatch();
      writer.deleteAll(sha256: sha256, chunkCount: 3, batch: batch);
      final expectedNs = VaultVecWriter.vecNamespace(sha256);
      final deletes = batch.entries
          .where((e) => e.namespace == expectedNs && e.value == null)
          .map((e) => e.key)
          .toSet();
      expect(deletes, contains(kVaultChunkKey(0)));
      expect(deletes, contains(kVaultChunkKey(1)));
      expect(deletes, contains(kVaultChunkKey(2)));
    });

    test('deleteAll with chunkCount=0 produces no entries', () {
      final batch = WriteBatch();
      writer.deleteAll(sha256: sha256, chunkCount: 0, batch: batch);
      expect(batch.entries, isEmpty);
    });

    // ── Namespace prefix correctness ────────────────────────────────────────

    test(r'vec index namespace prefix uses $$ (local-only)', () {
      expect(kVaultVecIdxPrefix, startsWith(r'$$'));
    });

    // ── dequantise() — boundary values ─────────────────────────────────────

    test('dequantise(0) ≈ -1.0 and dequantise(255) ≈ 1.0', () {
      final low = VaultVecWriter.dequantise(Uint8List.fromList([0]));
      final high = VaultVecWriter.dequantise(Uint8List.fromList([255]));
      expect(low[0], closeTo(-1.0, 0.01));
      expect(high[0], closeTo(1.0, 0.01));
    });
  });
}
