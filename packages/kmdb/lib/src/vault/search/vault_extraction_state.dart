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

/// Extraction status lifecycle types for vault search indexing.
///
/// The lifecycle state machine is:
/// ```
/// (new blob) → pending → extracting → indexed
///                                   ↘ failed
/// (unsupported media type) → unsupported
/// ```
/// On startup recovery, any blob stuck in `extracting` (crashed mid-index) is
/// checked against the filesystem — if all artifacts are present it is rebuilt
/// from files (→ `indexed`), otherwise it is reset to `pending`.
library;

import 'dart:typed_data';

import '../../encoding/value_codec.dart';
import '../../encryption/encryption_provider.dart';

/// The lifecycle status of a single vault blob's text extraction and indexing.
enum VaultExtractionStatus {
  /// The blob has been ingested but not yet extracted or indexed.
  ///
  /// This is the initial status when a blob is first seen by the search manager.
  pending,

  /// Extraction and indexing is currently in progress.
  ///
  /// Written before the isolate begins work (before filesystem writes). If the
  /// process crashes while in this state, startup recovery checks whether all
  /// filesystem artifacts are present and either rebuilds from them or resets
  /// to [pending].
  extracting,

  /// Extraction and indexing completed successfully.
  ///
  /// All filesystem artifacts (`text.txt`, `chunks_v1.json`,
  /// `vectors_{modelId}_sq8.bin` — there is no fourth `extract_status.json`
  /// file) and all LSM entries (`$$vault:fts:`, `$$vault:vec:idx`,
  /// `$$vault:extract:`) are present and consistent.
  indexed,

  /// Extraction or indexing failed with an error.
  ///
  /// The error message is stored in the `error` field of the
  /// `$$vault:extract:{sha256}` entry — the sole persisted copy of
  /// extraction status (there is no filesystem mirror).
  failed,

  /// No extractor supports this blob's media type.
  ///
  /// For example, `image/png` blobs are unsupported in v1. These blobs are
  /// accessible normally but are absent from `searchVault()` results.
  unsupported;

  /// Parses a string representation produced by [name].
  static VaultExtractionStatus fromName(String name) {
    return VaultExtractionStatus.values.firstWhere(
      (s) => s.name == name,
      orElse: () =>
          throw FormatException('Unknown VaultExtractionStatus: "$name"'),
    );
  }
}

/// A snapshot of a vault blob's extraction and indexing state.
///
/// Stored as a [ValueCodec]-encoded map in the `$$vault:extract:{sha256}` KV
/// namespace (keyed by [kVaultCorpusSentinelKey]) — encrypted when the
/// database has an [EncryptionProvider] configured (Encryption
/// confidentiality reconciliation plan, Gap 1: this value carries `charset`,
/// `script`, `language`, `modelVersion`, `chunkCount`, and `error`, which may
/// contain content fragments). This is the **only** persisted copy of
/// extraction status — there is no filesystem mirror (no
/// `extract_status.json` file is ever written; only `text.txt`,
/// `chunks_v1.json`, and `vectors_*.bin` exist on disk, see §32).
///
/// ## Crash recovery
///
/// The LSM entry is the sole authoritative source used by
/// [VaultSearchManager] during startup recovery.
///
/// ## Design note
///
/// The [modelVersion] is `""` (empty string) in lexical-only mode (when no
/// embedding model is configured). Startup recovery uses a mismatch between
/// the stored [modelVersion] and the active model's `modelId` to trigger
/// re-indexing when the model changes between sessions.
final class VaultExtractionState {
  /// Creates a [VaultExtractionState].
  const VaultExtractionState({
    required this.status,
    required this.sha256,
    this.modelVersion,
    this.chunkCount,
    this.chunkSize,
    this.chunkOverlap,
    this.extractedAt,
    this.error,
    this.charset,
    this.script,
    this.language,
  });

  /// The sha256 of the vault blob this state belongs to.
  ///
  /// Not stored in the CBOR map value (it is part of the namespace key), but
  /// kept here for convenience.
  final String sha256;

  /// The current lifecycle status.
  final VaultExtractionStatus status;

  /// The model ID of the embedding model used at index time.
  ///
  /// `null` before indexing. `""` (empty string) for lexical-only indexing.
  /// A non-empty string (e.g. `"bge-small-en-v1.5"`) for semantic indexing.
  final String? modelVersion;

  /// Total number of chunks produced during extraction.
  ///
  /// `null` before indexing or for unsupported/failed blobs.
  final int? chunkCount;

  /// Chunk size (in words) used during extraction.
  final int? chunkSize;

  /// Chunk overlap (in words) used during extraction.
  final int? chunkOverlap;

  /// ISO-8601 wall-clock timestamp of when extraction completed.
  ///
  /// `null` before indexing completes.
  final String? extractedAt;

  /// Error message when [status] is [VaultExtractionStatus.failed].
  ///
  /// `null` for all other statuses.
  final String? error;

  /// IANA charset label detected and used during text decoding.
  ///
  /// For example, `"utf-8"` or `"windows-1252"`. Populated by
  /// [PlainTextExtractor] using the [decodeText] function from WI-2.
  /// `null` before extraction or for non-text blobs.
  final String? charset;

  /// The dominant ISO 15924 script code of the extracted text (e.g.
  /// `"Latn"`, `"Cyrl"`, `"Hani"`), from `dominantScript()`.
  ///
  /// A cheap, deterministic Unicode-property lookup over the whole extracted
  /// text — computed regardless of [language]'s confidence gate. `null`
  /// before extraction or for script-less input (e.g. digits/punctuation
  /// only). See WI-6 (`docs/spec/32_vault_search.md`) for the design
  /// rationale behind storing [script] and [language] as separate fields.
  final String? script;

  /// The detected ISO 639-1 language code of the extracted text (e.g.
  /// `"en"`, `"fr"`), from `detectLanguageForStemming()`
  /// (`lib/src/search/language_detection.dart`).
  ///
  /// This is the **trust-gated** value (`confidentLanguageCode` —
  /// `LanguageDetectionResult`'s field of the same purpose) — user-facing
  /// metadata, distinct from `stemmerLanguageCode`, the value used
  /// internally to select a BM25 stemmer (see WI-6 Q6, revised 2026-07-07).
  /// As of that revision both fields are derived from the same margin +
  /// word-count + Stemmer-support gate (not a standalone `>= 0.5` raw-
  /// confidence check, which was found unreliable — see
  /// `language_detection.dart`'s doc comment): `null` before extraction, when
  /// detection wasn't trustworthy enough to clear that gate, or for
  /// non-text blobs. Script-exclusive detections (CJK, Thai, etc. — a
  /// deterministic Unicode-property lookup, not an n-gram comparison) are
  /// trusted unconditionally and populate this field even for single-word
  /// text; same-script (e.g. Latin-vs-Latin) detections additionally require
  /// at least 2 words of signal, so a single non-English word (however
  /// distinctive) will not populate this field either — a known, accepted
  /// conservative trade-off (see the WI-6 plan's "Implementation finding"
  /// section for the full rationale).
  final String? language;

  /// Encodes this state as a CBOR-serialisable [Map].
  ///
  /// Only non-null fields are included (except [status] and [modelVersion],
  /// which are always emitted for the `indexed` status).
  Map<String, dynamic> toMap() => {
    'status': status.name,
    if (modelVersion != null) 'modelVersion': modelVersion,
    if (chunkCount != null) 'chunkCount': chunkCount,
    if (chunkSize != null && chunkOverlap != null)
      'chunkingParams': {'chunkSize': chunkSize, 'chunkOverlap': chunkOverlap},
    if (extractedAt != null) 'extractedAt': extractedAt,
    if (error != null) 'error': error,
    if (charset != null) 'charset': charset,
    if (script != null) 'script': script,
    if (language != null) 'language': language,
  };

  /// Decodes a [VaultExtractionState] from a CBOR-decoded [Map] and [sha256].
  ///
  /// Throws [FormatException] if [map] does not contain a valid `status` string.
  factory VaultExtractionState.fromMap(
    Map<String, dynamic> map,
    String sha256,
  ) {
    final statusName = map['status'] as String?;
    if (statusName == null) {
      throw const FormatException(
        'VaultExtractionState: missing required field "status"',
      );
    }
    final status = VaultExtractionStatus.fromName(statusName);

    // Parse optional chunkingParams sub-map.
    int? chunkSize;
    int? chunkOverlap;
    final params = map['chunkingParams'];
    if (params is Map) {
      chunkSize = (params['chunkSize'] as num?)?.toInt();
      chunkOverlap = (params['chunkOverlap'] as num?)?.toInt();
    }

    return VaultExtractionState(
      sha256: sha256,
      status: status,
      modelVersion: map['modelVersion'] as String?,
      chunkCount: (map['chunkCount'] as num?)?.toInt(),
      chunkSize: chunkSize,
      chunkOverlap: chunkOverlap,
      extractedAt: map['extractedAt'] as String?,
      error: map['error'] as String?,
      charset: map['charset'] as String?,
      script: map['script'] as String?,
      language: map['language'] as String?,
    );
  }

  /// Creates a minimal `pending` state for a new blob.
  factory VaultExtractionState.pending(String sha256) => VaultExtractionState(
    sha256: sha256,
    status: VaultExtractionStatus.pending,
  );

  /// Creates an `extracting` state (in-progress marker written before work begins).
  factory VaultExtractionState.extracting(String sha256) =>
      VaultExtractionState(
        sha256: sha256,
        status: VaultExtractionStatus.extracting,
      );

  /// Creates an `unsupported` state for blobs with no matching extractor.
  factory VaultExtractionState.unsupported(String sha256) =>
      VaultExtractionState(
        sha256: sha256,
        status: VaultExtractionStatus.unsupported,
      );

  /// Creates a `failed` state with an error message.
  factory VaultExtractionState.failed(String sha256, String error) =>
      VaultExtractionState(
        sha256: sha256,
        status: VaultExtractionStatus.failed,
        error: error,
      );

  /// Encodes this state for storage in `$$vault:extract:{sha256}`.
  ///
  /// [toMap] is `Map<String, dynamic>`-shaped, so this routes through
  /// [ValueCodec] directly (Encryption confidentiality reconciliation plan,
  /// Phase 0/B7) rather than a bare CBOR encode — this is the fix for Gap 1's
  /// leak of `charset`/`script`/`language`/`modelVersion`/`chunkCount`/
  /// `error` (which may contain content fragments).
  Future<Uint8List> encode({EncryptionProvider? encryption}) =>
      ValueCodec.encode(toMap(), encryption: encryption);

  /// Decodes a [VaultExtractionState] from [ValueCodec]-encoded bytes and
  /// [sha256].
  ///
  /// Throws [FormatException] if the decoded map is missing the required
  /// `status` field, or any exception [ValueCodec.decode] itself throws for
  /// malformed/undecryptable bytes.
  static Future<VaultExtractionState> decode(
    Uint8List bytes,
    String sha256, {
    EncryptionProvider? encryption,
  }) async {
    final map = await ValueCodec.decode(bytes, encryption: encryption);
    return VaultExtractionState.fromMap(map, sha256);
  }

  @override
  String toString() =>
      'VaultExtractionState(sha256: ${sha256.substring(0, 8)}..., '
      'status: ${status.name}, chunkCount: $chunkCount)';
}
