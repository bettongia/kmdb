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

/// @docImport '../../encoding/value_codec.dart';
/// @docImport '../vault_store.dart';
library;

import 'plain_text_extractor.dart';
import 'vault_text_extractor.dart';

/// Configuration for vault content search indexing.
///
/// Pass to [KmdbDatabase.open] via the `vaultSearch` parameter to enable
/// automatic extraction and indexing of vault blob content. Omit or pass
/// `null` to disable vault search entirely.
///
/// ## Extractors
///
/// The [extractors] list controls which blob media types are indexed. The
/// default includes [PlainTextExtractor] for `text/plain`. Additional
/// extractors for PDF, HTML, and other formats will be added in future WIs.
/// The search manager tries each extractor in order and uses the first one
/// whose [VaultTextExtractor.supportedMediaTypes] contains the blob's media
/// type.
///
/// ## Chunking
///
/// [chunkSize] and [chunkOverlap] control text chunking. The chunker uses a
/// sliding window of [chunkSize] tokens with [chunkOverlap] tokens of overlap
/// between adjacent chunks. Defaults are suitable for general-purpose BM25
/// and semantic indexing of English-language documents.
///
/// ## Embedding model (RQ-3)
///
/// [VaultSearchConfig] does NOT carry an embedding model parameter. Vault
/// search reuses the database-level
/// `KmdbDatabase.open(embeddingModel: ...)` instance — the same model that
/// drives [VecManager]. Semantic vault indexing is enabled if and only if that
/// model is non-null; otherwise vault search runs in lexical-only mode.
/// [KmdbDatabase] owns the model lifecycle and is the only caller of
/// [EmbeddingModel.dispose]; [VaultSearchManager] holds a borrowed reference
/// and MUST NOT dispose it.
///
/// ## Example
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vaultStore: vaultStore,
///   vaultSearch: VaultSearchConfig(
///     chunkSize: 300,
///     chunkOverlap: 50,
///   ),
/// );
/// ```
final class VaultSearchConfig {
  /// Creates a [VaultSearchConfig].
  ///
  /// All parameters have reasonable defaults. Override [chunkSize] or
  /// [chunkOverlap] to tune chunking for your document corpus.
  ///
  /// [chunkSize] must be greater than 0. [chunkOverlap] must be ≥ 0 and
  /// less than [chunkSize] (an overlap ≥ chunkSize would produce infinite
  /// chunks). These constraints are validated at construction time.
  VaultSearchConfig({
    this.extractors = const [],
    this.chunkSize = 300,
    this.chunkOverlap = 50,
    this.maxBlobBytes = 200 * 1024 * 1024,
  }) : assert(chunkSize > 0, 'chunkSize must be > 0'),
       assert(chunkOverlap >= 0, 'chunkOverlap must be >= 0'),
       assert(chunkOverlap < chunkSize, 'chunkOverlap must be < chunkSize');

  /// The list of text extractors tried in order for each blob.
  ///
  /// The first extractor whose [VaultTextExtractor.supportedMediaTypes] set
  /// contains the blob's media type is used. Blobs with no matching extractor
  /// are recorded as `unsupported` and are not searchable.
  ///
  /// Defaults to `const []` — [VaultSearchManager] always prepends a
  /// [PlainTextExtractor] to this list at construction time so that
  /// `text/plain` blobs are handled by default regardless of what the caller
  /// provides.
  final List<VaultTextExtractor> extractors;

  /// Number of words (tokens) per chunk.
  ///
  /// BM25 IDF and semantic cosine similarity are both computed within a chunk's
  /// token window. Smaller values improve BM25 precision; larger values improve
  /// context coverage for semantic search. Default: 300.
  final int chunkSize;

  /// Number of words (tokens) of overlap between adjacent chunks.
  ///
  /// Overlap ensures that phrases spanning a chunk boundary are not missed by
  /// either chunk's BM25 or semantic scoring. Default: 50.
  final int chunkOverlap;

  /// Maximum blob size, in bytes, that will be handed to an extractor.
  ///
  /// Blobs are attachments, not documents — §02's 50 MB "legitimate large
  /// attachment" example is well within this default, unlike
  /// [ValueCodec.kMaxDecodedValueBytes] which bounds *document* values. A
  /// blob larger than this is recorded as a failed extraction
  /// (`VaultExtractionState.failed`) rather than sent to an extractor; the
  /// blob itself is untouched and remains retrievable via
  /// [VaultStore.getBytes] — only indexing is skipped.
  ///
  /// This is a distinct, deliberately much larger bound than
  /// [ValueCodec.kMaxDecodedValueBytes] (2026-07-18 release-readiness review,
  /// S-2): a bound sized for documents would reject legitimate attachments,
  /// and one sized for attachments would be useless against a document-sized
  /// decompression bomb. Default: 200 MiB.
  final int maxBlobBytes;

  /// Returns the effective extractor list: [PlainTextExtractor] prepended to
  /// [extractors], deduplicating by media type (callers who supply their own
  /// PlainTextExtractor won't get two).
  ///
  /// This method is called by [VaultSearchManager] at construction time to
  /// build the final extractor pipeline.
  List<VaultTextExtractor> get effectiveExtractors {
    // Check if any extractor in the caller list already handles text/plain.
    final hasTxtExtractor = extractors.any(
      (e) => e.supportedMediaTypes.contains('text/plain'),
    );
    if (hasTxtExtractor) return extractors;
    return [PlainTextExtractor(), ...extractors];
  }
}
