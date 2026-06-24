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

/// BM25 index writer for vault blobs.
///
/// Mirrors [FtsManager]'s term-encoding pattern but scoped to per-blob chunks
/// rather than per-document fields. Each vault blob is its own BM25 corpus —
/// cross-blob IDF is out of scope for v1.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../engine/kvstore/kv_store.dart';
import 'vault_namespaces.dart';

/// Writes BM25 index entries for vault blob chunks into a [WriteBatch].
///
/// ## Namespace layout
///
/// | Namespace | Key | Value |
/// |-----------|-----|-------|
/// | `$$vault:fts:{sha256}:{hexTerm}` | [kVaultChunkKey](chunkIndex) | CBOR int — TF in chunk |
/// | `$$vault:fts:corpus:{sha256}` | [kVaultCorpusSentinelKey] | CBOR `{n, totalTokens}` |
///
/// The `$$` prefix routes these namespaces to `.local.sst` files (WI-0 §20.7)
/// and guarantees they are never uploaded to the sync folder. Each device
/// rebuilds its vault FTS index independently from the synced document data.
///
/// ## DF at query time
///
/// Document frequency (DF) is **not** stored in the corpus sentinel. It is
/// computed dynamically at query time by scanning the per-term namespace and
/// counting chunk-index keys — exactly the same approach used by [FtsManager]
/// (`fts_manager.dart:765`). The corpus sentinel stores only
/// `{n: chunkCount, totalTokens}`.
///
/// ## WriteBatch semantics
///
/// All writes are appended to the caller-supplied [WriteBatch]. The caller
/// commits the batch; [VaultBm25Writer] never commits directly.
final class VaultBm25Writer {
  /// Creates a [VaultBm25Writer]. Has no state beyond the injected codec.
  const VaultBm25Writer();

  /// Writes all BM25 entries for [sha256] into [batch].
  ///
  /// [termFrequencies] is a list of per-chunk term→tf maps, one per chunk.
  /// [totalTokens] is the sum of all TF values across all chunks.
  ///
  /// Both the per-chunk term entries and the corpus sentinel are written in
  /// the same call, so the batch is always internally consistent.
  void write({
    required String sha256,
    required List<Map<String, int>> termFrequencies,
    required int totalTokens,
    required WriteBatch batch,
  }) {
    final n = termFrequencies.length;

    // Write per-chunk term entries: namespace = $$vault:fts:{sha256}:{hexTerm}.
    // Key = 8-digit zero-padded hex chunk index.
    for (var chunkIndex = 0; chunkIndex < n; chunkIndex++) {
      final chunkKey = _chunkIndexKey(chunkIndex);
      final tf = termFrequencies[chunkIndex];
      for (final entry in tf.entries) {
        batch.put(
          _termNamespace(sha256, entry.key),
          chunkKey,
          _encodeCborInt(entry.value),
        );
      }
    }

    // Write corpus sentinel: namespace = $$vault:fts:corpus:{sha256}.
    // Key = fixed sentinel, Value = CBOR {n, totalTokens}.
    batch.put(
      _corpusNamespace(sha256),
      kVaultCorpusSentinelKey,
      _encodeCorpus(n, totalTokens),
    );
  }

  /// Deletes all BM25 entries for [sha256] from [batch].
  ///
  /// Used when a blob is GC'd or re-indexed. Because deleting the individual
  /// per-chunk term entries requires knowing the terms and chunk count
  /// (which the caller reads from the stored corpus sentinel), this method
  /// deletes only the corpus sentinel. Stale per-chunk term entries are
  /// cleaned up lazily by query-time filtering (checking the corpus sentinel
  /// for existence) and compaction (SSTable tombstones).
  ///
  /// Use [deleteTermEntry] to delete individual term entries when the caller
  /// knows the terms.
  void deleteCorpus({required String sha256, required WriteBatch batch}) {
    batch.delete(_corpusNamespace(sha256), kVaultCorpusSentinelKey);
  }

  /// Deletes a single per-chunk term entry.
  ///
  /// Used during re-index to remove stale entries for a specific term+chunk.
  void deleteTermEntry({
    required String sha256,
    required String term,
    required int chunkIndex,
    required WriteBatch batch,
  }) {
    batch.delete(_termNamespace(sha256, term), _chunkIndexKey(chunkIndex));
  }

  // ── Namespace helpers ───────────────────────────────────────────────────────

  /// Per-term namespace: `$$vault:fts:{sha256}:{hexTerm}`.
  static String _termNamespace(String sha256, String term) {
    final hexTerm = _termToHex(term);
    return '$kVaultFtsPrefix$sha256:$hexTerm';
  }

  /// Corpus namespace: `$$vault:fts:corpus:{sha256}`.
  static String _corpusNamespace(String sha256) =>
      '$kVaultFtsCorpusPrefix$sha256';

  /// Returns the public corpus namespace for [sha256], for use by readers.
  ///
  /// Exposed as a static method so [VaultSearcher] can construct the key
  /// without importing implementation details.
  static String corpusNamespace(String sha256) => _corpusNamespace(sha256);

  /// Returns the public per-term namespace for [sha256] and [term].
  ///
  /// Used by [VaultSearcher] to read term entries at query time.
  static String termNamespace(String sha256, String term) =>
      _termNamespace(sha256, term);

  /// Encodes [term] as a lowercase hex string of its UTF-8 bytes.
  ///
  /// Mirrors [FtsManager._termToHex]: the same hex encoding is used for all
  /// FTS terms in KMDB, ensuring consistent namespace naming.
  static String _termToHex(String term) {
    final bytes = utf8.encode(term);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Converts [termToHex] for public access from readers.
  static String termToHex(String term) => _termToHex(term);

  /// Returns the 32-char UUIDv7-format key for [chunkIndex].
  ///
  /// Delegates to [kVaultChunkKey] so that readers and writers always
  /// produce identical key strings. See [kVaultChunkKey] for the encoding.
  static String _chunkIndexKey(int chunkIndex) => kVaultChunkKey(chunkIndex);

  /// Converts chunk index to key for public access from readers.
  static String chunkIndexKey(int chunkIndex) => _chunkIndexKey(chunkIndex);

  // ── CBOR helpers ────────────────────────────────────────────────────────────

  /// Encodes an integer as minimal CBOR.
  ///
  /// Uses the same bare-CBOR approach as [FtsManager._encodeCborInt]: no
  /// [ValueCodec] wrapper here because these are internal index entries that
  /// never need compression or encryption at this layer (encryption happens at
  /// the KvStore level for the whole SSTable). The bare-CBOR approach avoids
  /// double-encoding overhead.
  static Uint8List _encodeCborInt(int value) =>
      Uint8List.fromList(cbor.encode(CborSmallInt(value)));

  static Uint8List _encodeCorpus(int n, int totalTokens) => Uint8List.fromList(
    cbor.encode(
      CborMap({
        CborString('n'): CborSmallInt(n),
        CborString('totalTokens'): CborSmallInt(totalTokens),
      }),
    ),
  );

  /// Decodes a corpus sentinel value.
  ///
  /// Returns `null` if [bytes] is null or malformed.
  static ({int n, int totalTokens})? decodeCorpus(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborMap) return null;
      final map = decoded.toObject() as Map<dynamic, dynamic>;
      final n = map['n'];
      final totalTokens = map['totalTokens'];
      if (n is! int || totalTokens is! int) return null;
      return (n: n, totalTokens: totalTokens);
    } catch (_) {
      return null;
    }
  }

  /// Decodes a per-chunk TF value.
  ///
  /// Returns `0` if [bytes] is null or malformed.
  static int decodeTf(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return 0;
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is CborInt) return decoded.toObject() as int;
      return 0;
    } catch (_) {
      return 0;
    }
  }
}
