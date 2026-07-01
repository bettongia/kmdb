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

/// KV namespace constants for vault search storage.
///
/// ## Sync exclusion
///
/// Namespaces prefixed with `$$` are **local-only** (WI-0 convention). At
/// flush time the LSM engine routes these into `.local.sst` files, which
/// `SyncEngine.push` skips entirely. Each device rebuilds these derived
/// indexes independently from document data that syncs via the regular
/// namespaces.
///
/// | Namespace prefix              | Syncable? |
/// | ----------------------------- | --------- |
/// | `$$vault:fts:`                | No        |
/// | `$$vault:vec:idx`             | No        |
/// | `$$vault:extract:`            | No        |
/// | `$vault:docref:`              | Yes       |
library;

/// Prefix for BM25 per-term entries for a specific vault blob.
///
/// Full namespace: `$$vault:fts:{sha256}:{hexTerm}`.
/// Keys: 32-char UUIDv7-format chunk key produced by [kVaultChunkKey].
/// Values: CBOR int — term frequency in that chunk.
///
/// Additional corpus-level entry per blob:
/// `$$vault:fts:corpus:{sha256}` (key: [kVaultCorpusSentinelKey])
/// Value: CBOR map `{n: chunkCount, totalTokens: N}`.
const String kVaultFtsPrefix = r'$$vault:fts:';

/// Prefix for corpus statistics entries for vault blobs.
///
/// Full namespace: `$$vault:fts:corpus:{sha256}`.
/// Contains a single entry keyed by [kVaultCorpusSentinelKey] with CBOR
/// map `{n: chunkCount, totalTokens: N}`.
const String kVaultFtsCorpusPrefix = r'$$vault:fts:corpus:';

/// Prefix for per-blob SQ8 vector index entries.
///
/// Full namespace: `$$vault:vec:idx:{sha256}`.
/// Keys: 32-char UUIDv7-format chunk key produced by [kVaultChunkKey].
/// Values: D-byte SQ8 vector (D = model.dimensions, 384 for BGE Small En v1.5).
///
/// One namespace per blob allows efficient range deletion at GC time without
/// needing to know the chunk count: simply delete the whole namespace.
const String kVaultVecIdxPrefix = r'$$vault:vec:idx:';

/// Prefix for per-blob extraction status entries.
///
/// Full namespace: `$$vault:extract:{sha256}`.
/// Contains a single entry keyed by [kVaultCorpusSentinelKey] with CBOR map:
/// `{status, modelVersion?, chunkCount?, chunkingParams?, extractedAt?, error?, charset?}`.
const String kVaultExtractPrefix = r'$$vault:extract:';

/// Prefix for per-blob document-reference index entries.
///
/// Full namespace: `$vault:docref:{sha256}`.
/// Keys: `{docId}` (32-char UUIDv7 hex).
/// Values: CBOR string — field path (dot-notation) of the first field
/// in the document that holds the vault URI for this sha256.
///
/// This namespace uses a **single** `$` prefix — it syncs normally alongside
/// other document data so that other devices know which documents reference
/// which blobs.
const String kVaultDocRefPrefix = r'$vault:docref:';

/// Fixed 32-character hex sentinel key used for single-entry namespaces.
///
/// Used in [kVaultFtsCorpusPrefix] and [kVaultExtractPrefix] namespaces,
/// each of which holds exactly one entry per blob.
///
/// UUIDv7 keys begin with a 48-bit millisecond timestamp in the high bits,
/// so they never start with all-zero bytes. This sentinel is therefore safe
/// to use as a non-colliding fixed key (mirroring [FtsManager._corpusKey]).
///
/// The variant nibble at position 16 is `'9'`, distinct from chunk keys which
/// use `'8'` (see [kVaultChunkKey]).
const String kVaultCorpusSentinelKey = '01900000000070009000000000000000';

/// Returns the 32-char UUIDv7-format key for chunk [index].
///
/// Satisfies [KeyCodec.keyToBytes] requirements: exactly 32 hex chars, version
/// nibble at position 12 = `'7'`, variant nibble at position 16 = `'8'`.
///
/// The chunk index occupies the last 15 hex characters, supporting up to
/// 2^60 ≈ 10^18 chunks per blob (far beyond any practical limit).
///
/// This key is used in:
/// - [kVaultFtsPrefix] namespaces (BM25 per-chunk term frequency entries)
/// - [kVaultVecIdxPrefix] namespaces (SQ8 vector entries)
String kVaultChunkKey(int index) =>
    '01900000000070008${index.toRadixString(16).padLeft(15, '0')}';
