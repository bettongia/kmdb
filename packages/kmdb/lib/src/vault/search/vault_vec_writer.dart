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

/// SQ8 vector index writer for vault blob chunks.
///
/// Mirrors [VecManager]'s SQ8 quantization pattern but keyed by
/// `{sha256}:{chunkIndex}` rather than `{docId}`.
library;

import 'dart:math' show min, max;
import 'dart:typed_data';

import '../../engine/kvstore/kv_store.dart';
import 'vault_namespaces.dart' show kVaultVecIdxPrefix, kVaultChunkKey;

/// Writes SQ8 vector index entries for vault blob chunks into a [WriteBatch].
///
/// ## Namespace layout
///
/// | Namespace | Key | Value |
/// |-----------|-----|-------|
/// | `$$vault:vec:idx:{sha256}` | [kVaultChunkKey](chunkIndex) | D-byte SQ8 vector |
///
/// One namespace per blob makes GC deletion efficient (delete the whole
/// namespace rather than needing to know the chunk count).
///
/// The `$$` prefix routes these namespaces to `.local.sst` files (WI-0 §20.7)
/// and guarantees they are never uploaded to the sync folder. Each device
/// rebuilds its vault vector index independently by re-running the embedding
/// model.
///
/// ## SQ8 quantisation
///
/// SQ8 encodes each float32 component as a uint8:
/// ```
/// encode: u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)
/// decode: f = u / 255.0 * 2.0 - 1.0
/// ```
/// This maps the L2-normalised range `[-1, 1]` → `[0, 255]` with ≤0.004 error.
/// See §22 and [VecManager] for the canonical description.
///
/// The quantisation helpers are copied from [VecManager] intentionally —
/// the storage engine must remain self-contained for decode-only paths that
/// do not load the model.
///
/// ## Model dimension
///
/// The writer is dimension-agnostic: the SQ8 byte length equals the model's
/// `dimensions` property (derived from the [Float32List] length). For BGE
/// Small En v1.5 this is 384 bytes per chunk vector.
///
/// ## WriteBatch semantics
///
/// All writes are appended to the caller-supplied [WriteBatch]. The caller
/// commits the batch; [VaultVecWriter] never commits directly.
final class VaultVecWriter {
  /// Creates a [VaultVecWriter]. Has no state beyond the injected codec.
  const VaultVecWriter();

  /// Writes all vector entries for [sha256] into [batch].
  ///
  /// [embeddings] is a list of raw float32 vectors, one per chunk. Each
  /// vector is quantised to SQ8 before storage. Caller is responsible for
  /// ensuring vectors are L2-normalised (same contract as [VecManager]).
  void write({
    required String sha256,
    required List<Float32List> embeddings,
    required WriteBatch batch,
  }) {
    final ns = vecNamespace(sha256);
    for (var chunkIndex = 0; chunkIndex < embeddings.length; chunkIndex++) {
      final key = kVaultChunkKey(chunkIndex);
      final quantised = _quantise(embeddings[chunkIndex]);
      batch.put(ns, key, quantised);
    }
  }

  /// Deletes all vector entries for [sha256] and [chunkCount] chunks.
  ///
  /// Used during re-index. Requires the caller to know [chunkCount]
  /// (read from the corpus sentinel or the extract state).
  void deleteAll({
    required String sha256,
    required int chunkCount,
    required WriteBatch batch,
  }) {
    final ns = vecNamespace(sha256);
    for (var i = 0; i < chunkCount; i++) {
      batch.delete(ns, kVaultChunkKey(i));
    }
  }

  // ── Namespace/key helpers (public for readers) ────────────────────────────

  /// Returns the per-blob vector namespace `$$vault:vec:idx:{sha256}`.
  ///
  /// Each blob has its own namespace so GC can delete all entries efficiently
  /// without needing to know the chunk count.
  static String vecNamespace(String sha256) => '$kVaultVecIdxPrefix$sha256';

  /// Returns the 32-char UUIDv7-format key for [chunkIndex].
  ///
  /// Delegates to [kVaultChunkKey]; exposed here for readers that do not
  /// import [vault_namespaces.dart] directly.
  static String chunkKey(int chunkIndex) => kVaultChunkKey(chunkIndex);

  /// Returns the 8-digit zero-padded hex suffix for [chunkIndex].
  ///
  /// Not used for KV storage (keys must be 32-char UUIDv7). Exposed for
  /// diagnostic output and the legacy vec-key parse path.
  static String chunkIndexSuffix(int chunkIndex) =>
      chunkIndex.toRadixString(16).padLeft(8, '0');

  // ── SQ8 quantisation (mirrors VecManager; self-contained by design) ─────────

  /// Quantises [vector] from float32 to SQ8.
  ///
  /// Public alias for use by [VaultSearchManager] when packing the vector
  /// binary file. Formula: `u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)`
  static Uint8List quantiseSq8(Float32List vector) => _quantise(vector);

  /// Quantises [vector] from float32 to SQ8 (internal implementation).
  static Uint8List _quantise(Float32List vector) {
    final out = Uint8List(vector.length);
    for (var i = 0; i < vector.length; i++) {
      final u = ((vector[i] + 1.0) / 2.0 * 255.0).roundToDouble();
      out[i] = min(255, max(0, u.toInt()));
    }
    return out;
  }

  /// Dequantises [vector] from SQ8 back to float32.
  ///
  /// Formula: `f = u / 255.0 * 2.0 - 1.0`
  ///
  /// Exposed as a public static for use by [VaultSearcher] at query time.
  static Float32List dequantise(Uint8List vector) {
    final out = Float32List(vector.length);
    for (var i = 0; i < vector.length; i++) {
      out[i] = vector[i] / 255.0 * 2.0 - 1.0;
    }
    return out;
  }
}
