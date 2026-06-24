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

/// Orchestrates vault text extraction, chunking, embedding, and indexing.
///
/// [VaultSearchManager] is the central coordinator for the vault search
/// subsystem. It owns the indexing queue, the background [VaultIndexingIsolate],
/// and the filesystem artifact lifecycle. All durable writes happen on the main
/// isolate in the caller's [Isolate] (§18 synchronous model).
///
/// ## Lifecycle
///
/// 1. Constructed with [VaultSearchConfig], [KvStoreImpl], [VaultStore], and
///    the borrowed [EmbeddingModel] reference.
/// 2. [attach] registers the [VaultStore.onAfterIngest] hook so new ingests
///    are automatically queued.
/// 3. [recover] is called by [KmdbDatabase.open] after WAL replay to repair
///    interrupted indexing and enqueue blobs that missed the ingest hook.
/// 4. Blobs are processed one-at-a-time through [VaultIndexingIsolate]:
///    extraction + chunking + tokenisation happen in the isolate; embedding and
///    all durable writes happen on the main isolate.
/// 5. [close] drains the in-flight item, shuts down the isolate, and releases
///    resources.
library;

import 'dart:async';
import 'dart:convert' show json, utf8;
import 'dart:typed_data';

import 'package:betto_inferencing/betto_inferencing.dart' show EmbeddingModel;

// ignore_for_file: prefer_initializing_formals
// Dart does not permit `this._fieldName` in named constructor parameters when
// the field is private. The initialiser list pattern is unavoidable here.

import '../../encryption/encryption_provider.dart';
import '../../engine/kvstore/kv_store.dart';
import '../../engine/kvstore/kv_store_impl.dart';
import '../vault_store.dart';
import 'vault_bm25_writer.dart';
import 'vault_chunk.dart';
import 'vault_chunker.dart';
import 'vault_extraction_state.dart';
import 'vault_indexing_isolate.dart';
import 'vault_indexing_status.dart';
import 'vault_namespaces.dart';
import 'vault_search_config.dart';
import 'vault_vec_writer.dart';

/// Orchestrates the full vault search indexing lifecycle.
///
/// Constructed once per [KmdbDatabase.open] call. The database owns this
/// instance and disposes it in [KmdbDatabase.close].
///
/// ## Ownership rules (RQ-3)
///
/// [VaultSearchManager] holds a **borrowed** reference to [EmbeddingModel]. It
/// never disposes it — [KmdbDatabase] is the sole owner. When [embeddingModel]
/// is non-null, semantic indexing is active; when null, lexical-only mode.
///
/// ## Crash safety
///
/// The write sequence per blob (documented in §32):
///
/// 0. Write `$$vault:extract:{sha256}` as `extracting` (pre-flight marker in LSM).
/// 1. Send work item to isolate; await [VaultIndexResult].
/// 2. Write `extract/text.txt`.
/// 3. Write `extract/chunks_v1.json`.
/// 4. Write `extract/vectors_{modelId}_sq8.bin` (semantic only).
/// 5. Apply atomic [WriteBatch]: `$$vault:fts:`, `$$vault:vec:idx`,
///    `$$vault:extract` → `indexed`.
///
/// A crash between steps 0 and 5 leaves `$$vault:extract` as `extracting`.
/// [recover] detects this and either rebuilds from filesystem artifacts
/// (if steps 2–4 are complete) or resets to `pending`.
final class VaultSearchManager {
  /// Creates a [VaultSearchManager].
  ///
  /// [config] controls extraction, chunking, and the extractor list.
  /// [kvStore] is the KV store for LSM index reads/writes. Must be a
  /// [KvStoreImpl] to allow internal writes to `$$`-prefixed system namespaces
  /// (the same contract as [FtsManager] and [VecManager]).
  /// [vaultStore] provides blob bytes and filesystem path helpers.
  /// [embeddingModel] is the borrowed (not owned) database-level model —
  /// pass `null` for lexical-only mode.
  /// [encryption] is passed through for encrypted databases (currently unused
  /// in this layer; LSM encryption is handled by the KvStore).
  VaultSearchManager({
    required VaultSearchConfig config,
    required KvStoreImpl kvStore,
    required VaultStore vaultStore,
    EmbeddingModel? embeddingModel,
    EncryptionProvider? encryption,
  }) : _config = config,
       _kvStore = kvStore,
       _vaultStore = vaultStore,
       _embeddingModel = embeddingModel,
       _encryption = encryption;

  final VaultSearchConfig _config;
  final KvStoreImpl _kvStore;
  final VaultStore _vaultStore;

  /// Borrowed (not owned) embedding model. May be null for lexical-only mode.
  /// [VaultSearchManager] must NEVER call [EmbeddingModel.dispose] on this.
  final EmbeddingModel? _embeddingModel;

  // Kept for potential future use (e.g. per-entry encryption in docref).
  // ignore: unused_field
  final EncryptionProvider? _encryption;

  // ── Indexing queue and isolate ─────────────────────────────────────────────

  /// Pending sha256 → mediaType entries waiting to be sent to the isolate.
  final _queue = <(String sha256, String mediaType)>[];

  /// The currently live indexing isolate, or null if not yet spawned.
  VaultIndexingIsolate? _isolate;

  /// True when [close] has been called — prevents new items from being queued.
  bool _closed = false;

  /// True when the isolate is processing an item (guards queue draining).
  bool _processing = false;

  // ── Status stream ──────────────────────────────────────────────────────────

  final _statusController = StreamController<VaultIndexingStatus>.broadcast();

  // ── Writers ────────────────────────────────────────────────────────────────

  static const _bm25Writer = VaultBm25Writer();
  static const _vecWriter = VaultVecWriter();

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Returns the borrowed [EmbeddingModel], or `null` for lexical-only mode.
  ///
  /// Exposed for [VaultSearcher] to embed queries at search time.
  EmbeddingModel? get embeddingModel => _embeddingModel;

  /// Returns the vault store (for path helpers used by [VaultSearcher]).
  VaultStore get vaultStore => _vaultStore;

  /// Returns the KV store (for reading index entries during search).
  KvStoreImpl get kvStore => _kvStore;

  /// Returns the active search config.
  VaultSearchConfig get config => _config;

  /// Registers [VaultStore.onAfterIngest] so newly ingested blobs are
  /// automatically queued for extraction and indexing.
  ///
  /// Must be called once, before any new blobs are ingested. Safe to call
  /// multiple times (idempotent — replaces the previous callback).
  void attach() {
    _vaultStore.onAfterIngest = (sha256, mediaType) {
      if (!_closed) {
        _enqueue(sha256, mediaType);
      }
    };
  }

  /// Repairs interrupted indexing after a crash and enqueues blobs that
  /// missed the ingest hook.
  ///
  /// Called by [KmdbDatabase.open] after WAL replay, before the database is
  /// returned to callers.
  ///
  /// Recovery actions:
  ///
  /// 1. Enumerate all `$$vault:extract:{sha256}` namespaces from
  ///    [KvStore.listNamespaces] and apply Q6 recovery logic for each.
  /// 2. Check model version for `indexed` blobs and reset if stale.
  /// 3. Scan `$vault` ref-count entries for blobs not in `$$vault:extract` →
  ///    enqueue them (missed on first ingest, or status lost).
  Future<void> recover() async {
    // Enumerate all known blobs from the vault filesystem (authoritative source).
    // $$vault:extract:{sha256} namespaces are never registered in the KV
    // namespace registry because SHA-256 hashes (64 hex chars) cannot be stored
    // as KV keys (the key codec requires 32-char UUIDv7 hex). We probe each
    // known sha256 directly instead of calling listNamespaces().
    final knownSha256s = await _vaultStore.listAllHashes();

    for (final sha256 in knownSha256s) {
      final ns = '$kVaultExtractPrefix$sha256';
      final bytes = await _kvStore.get(ns, kVaultCorpusSentinelKey);

      if (bytes == null) {
        // No extract state — blob was never indexed or state was lost.
        if (await _vaultStore.isHydrated(sha256)) {
          final manifest = await _vaultStore.getManifest(sha256);
          _enqueue(sha256, manifest.mediaType);
        }
        continue;
      }

      try {
        final map = json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
        final state = VaultExtractionState.fromMap(map, sha256);

        switch (state.status) {
          case VaultExtractionStatus.extracting:
            // Interrupted mid-extraction — try to rebuild from filesystem.
            await _recoverExtractingBlob(sha256, state);

          case VaultExtractionStatus.indexed:
            // Check model version — may need re-index if model changed.
            await _checkModelVersion(sha256, state);

          case VaultExtractionStatus.pending:
            // Re-enqueue (was pending at crash time — lost from in-memory queue).
            if (await _vaultStore.isHydrated(sha256)) {
              final manifest = await _vaultStore.getManifest(sha256);
              _enqueue(sha256, manifest.mediaType);
            }

          case VaultExtractionStatus.unsupported:
          case VaultExtractionStatus.failed:
            // Leave as-is — no re-queue needed.
            break;
        }
      } catch (_) {
        // Undecodable state — reset to pending as safe default.
        if (await _vaultStore.isHydrated(sha256)) {
          final manifest = await _vaultStore.getManifest(sha256);
          _enqueue(sha256, manifest.mediaType);
        }
      }
    }
  }

  /// Queues [sha256] / [mediaType] for extraction and indexing.
  ///
  /// Writes a `pending` status entry to `$$vault:extract` immediately
  /// (before the isolate picks it up) so that [vaultIndexingStatus] can
  /// report it.
  Future<void> queueBlob(String sha256, String mediaType) async {
    await _writeExtractStatusToKv(sha256, VaultExtractionState.pending(sha256));
    _enqueue(sha256, mediaType);
  }

  /// Returns a point-in-time snapshot of vault indexing progress.
  ///
  /// Blob discovery uses [VaultStore.listAllHashes] (filesystem-based) rather
  /// than scanning the `$vault` KV namespace. SHA-256 hashes (64 hex chars)
  /// cannot be stored as KV keys (the key codec requires 32-char UUIDv7 hex),
  /// so the filesystem is the authoritative source of truth for known blobs.
  Future<VaultIndexingStatus> vaultIndexingStatus() async {
    var indexed = 0;
    var pending = 0;
    var extracting = 0;
    var failed = 0;
    var unsupported = 0;
    var stub = 0;

    // Count all known blobs from the vault filesystem (hash directories).
    // The filesystem is the authoritative source: SHA-256 hashes (64 hex chars)
    // cannot be stored as KV keys (the key codec requires 32-char UUIDv7 hex),
    // so $$vault:extract:{sha256} namespaces are NEVER registered in the KV
    // namespace registry. We iterate over known hashes and probe each one directly
    // rather than relying on listNamespaces().
    final knownSha256s = await _vaultStore.listAllHashes();
    final total = knownSha256s.length;

    for (final sha256 in knownSha256s) {
      final ns = '$kVaultExtractPrefix$sha256';
      final bytes = await _kvStore.get(ns, kVaultCorpusSentinelKey);
      if (bytes == null) {
        // No extract state at all.
        if (!await _vaultStore.isHydrated(sha256)) {
          // Manifest exists but no blob file — this blob is a remote stub that
          // has not been downloaded yet.
          stub++;
        } else {
          // Hydrated blob with no extract state — awaiting indexing.
          pending++;
        }
        continue;
      }
      try {
        final map = json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
        final state = VaultExtractionState.fromMap(map, sha256);
        switch (state.status) {
          case VaultExtractionStatus.indexed:
            indexed++;
          case VaultExtractionStatus.pending:
            pending++;
          case VaultExtractionStatus.extracting:
            extracting++;
          case VaultExtractionStatus.failed:
            failed++;
          case VaultExtractionStatus.unsupported:
            unsupported++;
        }
      } catch (_) {
        // Undecodable state — treat as pending.
        pending++;
      }
    }

    return VaultIndexingStatus(
      total: total,
      indexed: indexed,
      pending: pending,
      extracting: extracting,
      failed: failed,
      unsupported: unsupported,
      stub: stub,
    );
  }

  /// Returns a stream of [VaultIndexingStatus] that emits each time the index
  /// state changes.
  ///
  /// Callers should cancel the subscription when done. The stream is broadcast
  /// (multiple listeners allowed).
  Stream<VaultIndexingStatus> watchVaultIndexingStatus() =>
      _statusController.stream;

  /// Resets all `indexed` and `extracting` blobs to `pending` and re-enqueues
  /// them.
  ///
  /// Returns the number of blobs reset.
  ///
  /// Any in-flight work item is discarded (the blob will be re-indexed anyway).
  /// This is the safe cancellation approach for one-at-a-time processing.
  Future<int> reindexVault() async {
    // Clear the queue — we will re-populate from scratch.
    _queue.clear();
    _processing = false;

    var count = 0;

    // $$vault:extract:{sha256} namespaces are never registered in the KV
    // namespace registry (SHA-256 hashes are 64 hex chars, not 32-char UUIDv7
    // keys). Iterate over known filesystem hashes and probe each directly.
    final knownSha256s = await _vaultStore.listAllHashes();

    for (final sha256 in knownSha256s) {
      final ns = '$kVaultExtractPrefix$sha256';
      final bytes = await _kvStore.get(ns, kVaultCorpusSentinelKey);

      bool needsReset;
      if (bytes == null) {
        // No state — treat as if indexed (reset unconditionally).
        needsReset = true;
      } else {
        try {
          final map = json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
          final state = VaultExtractionState.fromMap(map, sha256);
          // Reset indexed and extracting blobs; leave failed/unsupported/pending
          // as-is (failed can be retried with reindex, pending already queued).
          needsReset =
              state.status == VaultExtractionStatus.indexed ||
              state.status == VaultExtractionStatus.extracting;
        } catch (_) {
          needsReset = true;
        }
      }

      if (needsReset) {
        await _writeExtractStatusToKv(
          sha256,
          VaultExtractionState.pending(sha256),
        );
        if (await _vaultStore.isHydrated(sha256)) {
          final manifest = await _vaultStore.getManifest(sha256);
          _enqueue(sha256, manifest.mediaType);
          count++;
        }
      }
    }

    await _emitStatus();
    return count;
  }

  /// Gracefully shuts down the [VaultIndexingIsolate] and releases resources.
  ///
  /// Waits for the in-flight item to complete (if any) before shutting down.
  /// New items added after [close] is called are silently dropped.
  Future<void> close() async {
    _closed = true;
    _queue.clear();
    await _isolate?.shutdown();
    _isolate = null;
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }

  // ── Internal: queue management ─────────────────────────────────────────────

  void _enqueue(String sha256, String mediaType) {
    if (_closed) return;
    _queue.add((sha256, mediaType));
    _drainQueue();
  }

  /// Pulls the next item from the queue and processes it.
  ///
  /// Guards against concurrent calls with [_processing].
  void _drainQueue() {
    if (_processing || _queue.isEmpty || _closed) return;
    _processing = true;
    final (sha256, mediaType) = _queue.removeAt(0);
    _processNextItem(sha256, mediaType)
        .then((_) {
          _processing = false;
          _drainQueue();
        })
        .catchError((Object e) {
          _processing = false;
          _drainQueue();
        });
  }

  /// Processes a single blob: extraction → embedding → durable writes.
  ///
  /// Write sequence:
  ///
  /// 0. Write `$$vault:extract:{sha256}` as `extracting` (pre-flight).
  /// 1. Read blob bytes (decryption on main isolate).
  /// 2. Send work item to isolate → await [VaultIndexResult].
  /// 3. Write `extract/text.txt`.
  /// 4. Write `extract/chunks_v1.json`.
  /// 5. Write `extract/vectors_{modelId}_sq8.bin` (semantic only).
  /// 6. Commit atomic [WriteBatch].
  Future<void> _processNextItem(String sha256, String mediaType) async {
    if (_closed) return;

    // Step 0: Write extracting status marker (pre-flight).
    await _writeExtractStatusToKv(
      sha256,
      VaultExtractionState.extracting(sha256),
    );

    // Step 1: Read blob bytes on main isolate (handles encryption).
    final Uint8List bytes;
    try {
      bytes = await _vaultStore.getBytes(sha256);
    } catch (e) {
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.failed(sha256, 'Failed to read blob: $e'),
      );
      await _emitStatus();
      return;
    }

    // Step 2: Send work item to the isolate.
    _isolate ??= await VaultIndexingIsolate.spawn(_config.effectiveExtractors);
    final item = VaultWorkItem(
      sha256: sha256,
      mediaType: mediaType,
      bytes: bytes,
      chunkSize: _config.chunkSize,
      chunkOverlap: _config.chunkOverlap,
    );

    VaultIndexResult result;
    try {
      result = await _isolate!.sendWork(item);
    } catch (e) {
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.failed(sha256, 'Isolate error: $e'),
      );
      await _emitStatus();
      return;
    }

    if (_closed) return; // Shutdown while extracting — discard.

    if (result.isUnsupported) {
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.unsupported(sha256),
      );
      await _emitStatus();
      return;
    }

    if (result.isFailed || result.extractedText == null) {
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.failed(sha256, result.error ?? 'Unknown error'),
      );
      await _emitStatus();
      return;
    }

    // Step 3: Embed chunks on the main isolate (RQ-5: ORT is thread-affine).
    final List<Float32List> embeddings;
    final String modelVersion;
    final model = _embeddingModel;
    if (model != null && result.chunks.isNotEmpty) {
      try {
        final textUtf8 = utf8.encode(result.extractedText!);
        // model.embed() returns (Float32List embedding, bool truncated).
        // We use only the embedding; truncation is informational.
        embeddings = await Future.wait(
          result.chunks.map((c) async {
            final slice = Uint8List.fromList(
              textUtf8.sublist(c.byteStart, c.byteEnd),
            );
            final (embedding, _) = await model.embed(utf8.decode(slice));
            return embedding;
          }),
        );
        modelVersion = model.modelId;
      } catch (e) {
        await _writeExtractStatusToKv(
          sha256,
          VaultExtractionState.failed(sha256, 'Embedding error: $e'),
        );
        await _emitStatus();
        return;
      }
    } else {
      embeddings = const [];
      modelVersion = model?.modelId ?? '';
    }

    // Steps 4–6: Write filesystem artifacts, then commit WriteBatch.
    final extractDir = '${_vaultStore.hashDir(sha256)}/extract';
    try {
      await _vaultStore.adapter.createDirectory(extractDir);

      // Step 4: text.txt
      await _vaultStore.adapter.writeFile(
        '$extractDir/text.txt',
        Uint8List.fromList(utf8.encode(result.extractedText!)),
      );

      // Step 5: chunks_v1.json — chunk metadata with byte offsets.
      // The isolate returns records; convert to JSON maps.
      final chunksJson = json.encode(
        result.chunks
            .map(
              (c) => {
                'index': c.index,
                'byteStart': c.byteStart,
                'byteEnd': c.byteEnd,
                'wordCount': c.wordCount,
              },
            )
            .toList(),
      );
      await _vaultStore.adapter.writeFile(
        '$extractDir/chunks_v1.json',
        Uint8List.fromList(utf8.encode(chunksJson)),
      );

      // Step 6: vectors_{modelId}_sq8.bin (semantic only).
      if (embeddings.isNotEmpty) {
        final safeModelId = _safeFileName(modelVersion);
        final vecPath = '$extractDir/vectors_${safeModelId}_sq8.bin';
        final dims = embeddings.first.length;
        final packed = Uint8List(embeddings.length * dims);
        for (var i = 0; i < embeddings.length; i++) {
          final sq8 = VaultVecWriter.quantiseSq8(embeddings[i]);
          packed.setAll(i * dims, sq8);
        }
        await _vaultStore.adapter.writeFile(vecPath, packed);
      }
    } catch (e) {
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.failed(sha256, 'Filesystem write error: $e'),
      );
      await _emitStatus();
      return;
    }

    // Step 7: Commit atomic WriteBatch.
    final totalTokens = result.termFrequencies.fold<int>(
      0,
      (sum, tf) => sum + tf.values.fold<int>(0, (s, v) => s + v),
    );

    final batch = WriteBatch();
    _bm25Writer.write(
      sha256: sha256,
      termFrequencies: result.termFrequencies,
      totalTokens: totalTokens,
      batch: batch,
    );
    if (embeddings.isNotEmpty) {
      _vecWriter.write(sha256: sha256, embeddings: embeddings, batch: batch);
    }

    final finalState = VaultExtractionState(
      sha256: sha256,
      status: VaultExtractionStatus.indexed,
      modelVersion: modelVersion,
      chunkCount: result.chunks.length,
      chunkSize: _config.chunkSize,
      chunkOverlap: _config.chunkOverlap,
      charset: result.charset,
    );
    _writeExtractStatusToBatch(sha256, finalState, batch);
    await _kvStore.writeBatchInternal(batch);

    await _emitStatus();
  }

  // ── Internal: recovery helpers ─────────────────────────────────────────────

  /// Attempts to recover a blob that was in `extracting` state at startup.
  ///
  /// If filesystem artifacts are present and complete, rebuilds the
  /// [WriteBatch] from them and commits. Otherwise resets to `pending`.
  Future<void> _recoverExtractingBlob(
    String sha256,
    VaultExtractionState state,
  ) async {
    final extractDir = '${_vaultStore.hashDir(sha256)}/extract';
    final textPath = '$extractDir/text.txt';
    final chunksPath = '$extractDir/chunks_v1.json';

    if (!await _vaultStore.adapter.fileExists(textPath) ||
        !await _vaultStore.adapter.fileExists(chunksPath)) {
      // Incomplete artifacts — reset to pending.
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.pending(sha256),
      );
      if (await _vaultStore.isHydrated(sha256)) {
        final manifest = await _vaultStore.getManifest(sha256);
        _enqueue(sha256, manifest.mediaType);
      }
      return;
    }

    // Artifacts are complete — rebuild WriteBatch from files.
    try {
      final chunksBytes = await _vaultStore.adapter.readFile(chunksPath);
      final chunksList = json.decode(utf8.decode(chunksBytes)) as List;
      final chunks = chunksList
          .cast<Map<String, dynamic>>()
          .map(VaultChunk.fromJson)
          .toList();

      final textBytes = await _vaultStore.adapter.readFile(textPath);
      final text = utf8.decode(textBytes);

      // Re-tokenise chunks from the extracted text.
      final recoveryConfig = VaultSearchConfig(
        chunkSize: state.chunkSize ?? _config.chunkSize,
        chunkOverlap: state.chunkOverlap ?? _config.chunkOverlap,
      );
      final chunker = VaultChunker(recoveryConfig);
      final chunkResult = chunker.chunk(text);

      // Re-embed or reload vectors if model is available.
      final model = _embeddingModel;
      final List<Float32List> embeddings;
      final String modelVersion;
      if (model != null && chunks.isNotEmpty) {
        final safeModelId = _safeFileName(model.modelId);
        final vecPath = '$extractDir/vectors_${safeModelId}_sq8.bin';
        if (await _vaultStore.adapter.fileExists(vecPath)) {
          // Reload from the packed SQ8 file.
          final vecBytes = await _vaultStore.adapter.readFile(vecPath);
          final dims = vecBytes.length ~/ chunks.length;
          embeddings = List.generate(chunks.length, (i) {
            final sq8 = Uint8List.sublistView(
              vecBytes,
              i * dims,
              (i + 1) * dims,
            );
            return VaultVecWriter.dequantise(sq8);
          });
        } else {
          // Vec file missing — re-embed from text.
          embeddings = await Future.wait(
            chunks.map((c) async {
              final slice = Uint8List.fromList(
                textBytes.sublist(c.byteStart, c.byteEnd),
              );
              final (embedding, _) = await model.embed(utf8.decode(slice));
              return embedding;
            }),
          );
        }
        modelVersion = model.modelId;
      } else {
        embeddings = const [];
        modelVersion = model?.modelId ?? '';
      }

      final totalTokens = chunkResult.termFrequencies.fold<int>(
        0,
        (sum, tf) => sum + tf.values.fold<int>(0, (s, v) => s + v),
      );

      final batch = WriteBatch();
      _bm25Writer.write(
        sha256: sha256,
        termFrequencies: chunkResult.termFrequencies,
        totalTokens: totalTokens,
        batch: batch,
      );
      if (embeddings.isNotEmpty) {
        _vecWriter.write(sha256: sha256, embeddings: embeddings, batch: batch);
      }
      final finalState = VaultExtractionState(
        sha256: sha256,
        status: VaultExtractionStatus.indexed,
        modelVersion: modelVersion,
        chunkCount: chunks.length,
        chunkSize: state.chunkSize ?? _config.chunkSize,
        chunkOverlap: state.chunkOverlap ?? _config.chunkOverlap,
        charset: state.charset,
      );
      _writeExtractStatusToBatch(sha256, finalState, batch);
      await _kvStore.writeBatchInternal(batch);
    } catch (_) {
      // Recovery failed — reset to pending.
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.pending(sha256),
      );
      if (await _vaultStore.isHydrated(sha256)) {
        final manifest = await _vaultStore.getManifest(sha256);
        _enqueue(sha256, manifest.mediaType);
      }
    }
  }

  /// Checks the model version of an `indexed` blob and resets if stale.
  Future<void> _checkModelVersion(
    String sha256,
    VaultExtractionState state,
  ) async {
    final model = _embeddingModel;
    final storedModelVersion = state.modelVersion ?? '';

    if (model != null && storedModelVersion != model.modelId) {
      // Model changed — full re-index needed.
      await _writeExtractStatusToKv(
        sha256,
        VaultExtractionState.pending(sha256),
      );
      if (await _vaultStore.isHydrated(sha256)) {
        final manifest = await _vaultStore.getManifest(sha256);
        _enqueue(sha256, manifest.mediaType);
      }
    }
    // If model == null and storedModelVersion.isNotEmpty: lexical-only mode
    // but blob has vec entries. Leave FTS as-is; vecs will not be queried.
    // No re-index needed for lexical-only mode.
  }

  // ── Internal: filesystem and LSM write helpers ─────────────────────────────

  /// Writes [state] as a [WriteBatch] entry in the `$$vault:extract` namespace.
  ///
  /// Used for `pending`, `extracting`, `failed`, and `unsupported` states
  /// that need to be persisted immediately (not as part of the final batch).
  Future<void> _writeExtractStatusToKv(
    String sha256,
    VaultExtractionState state,
  ) async {
    final batch = WriteBatch();
    _writeExtractStatusToBatch(sha256, state, batch);
    await _kvStore.writeBatchInternal(batch);
  }

  /// Appends [state] as a `$$vault:extract:{sha256}` entry to [batch].
  ///
  /// The key is [kVaultCorpusSentinelKey] — a fixed, non-colliding hex key
  /// (mirrors [FtsManager]'s corpus sentinel pattern).
  void _writeExtractStatusToBatch(
    String sha256,
    VaultExtractionState state,
    WriteBatch batch,
  ) {
    final encoded = Uint8List.fromList(utf8.encode(json.encode(state.toMap())));
    batch.put('$kVaultExtractPrefix$sha256', kVaultCorpusSentinelKey, encoded);
  }

  // ── Internal: status emission ──────────────────────────────────────────────

  Future<void> _emitStatus() async {
    if (_statusController.isClosed) return;
    try {
      final status = await vaultIndexingStatus();
      _statusController.add(status);
    } catch (_) {
      // Non-fatal — status stream is best-effort.
    }
  }

  // ── Internal: utilities ────────────────────────────────────────────────────

  /// Returns a safe file name component from [modelId].
  ///
  /// Replaces characters that are not alphanumeric, underscore, dot, or dash
  /// with underscores. Ensures vector file names are valid across all platforms.
  static String _safeFileName(String modelId) =>
      modelId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
}
