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

/// Background isolate for vault text extraction, chunking, and tokenisation.
///
/// ## Architecture (RQ-5)
///
/// §18 (`docs/spec/18_concurrency.md`) requires the LSM write path to run
/// synchronously on the main isolate. The [VaultIndexingIsolate] does NOT
/// violate this invariant:
///
/// - The isolate touches **no LSM state**: no [KvStore], no [WriteBatch], no
///   compaction.
/// - The isolate receives raw decrypted bytes (encryption is handled by
///   [VaultStore.getBytes] on the main isolate before the send) and returns
///   plain data (extracted text, chunk metadata, per-chunk term/tf maps).
/// - **Embedding does NOT happen in the isolate.** [OnnxEmbeddingModel] is
///   thread-affine (its ORT session must be created and called in the same
///   isolate). The live model is owned by [KmdbDatabase] on the main isolate.
///   Embedding stays on the main isolate, just as [VecManager] already does.
/// - All durable writes — embedding, [WriteBatch] commit, filesystem artifacts
///   — happen on the **main isolate**, synchronously, exactly as today.
///
/// The isolate is therefore a pure CPU-offload for extraction/chunking/
/// tokenisation — the work that benefits most from being off the main thread
/// for large text files.
///
/// ## Cancellation protocol
///
/// The isolate processes **one work item at a time**. Cancellation granularity
/// is one blob. [VaultSearchManager] implements the following protocol:
///
/// - **`close()` (graceful):** stop dequeuing new items; `await` the in-flight
///   result (single text/plain blob is bounded and fast); commit or discard;
///   then send a [_kShutdownMessage] and let the isolate exit. Do NOT call
///   [Isolate.kill] mid-result — that risks torn filesystem artifacts.
/// - **`reindexVault()` during active indexing:** discard the in-flight result
///   (the blob will be re-queued); reset all blobs; restart. The one in-flight
///   item is sacrificed — it's cheaper than implementing mid-extraction
///   cancellation, and the blob will be re-indexed anyway.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../vault_manifest.dart';
import 'plain_text_extractor.dart';
import 'vault_chunker.dart';
import 'vault_search_config.dart';
import 'vault_text_extractor.dart';

/// The message type sent to the isolate: a [VaultWorkItem].
final class VaultWorkItem {
  /// Creates a [VaultWorkItem].
  const VaultWorkItem({
    required this.sha256,
    required this.mediaType,
    required this.bytes,
    required this.chunkSize,
    required this.chunkOverlap,
  });

  /// SHA-256 hex digest of the blob.
  final String sha256;

  /// MIME media type (e.g. `"text/plain"`).
  final String mediaType;

  /// Raw, decrypted blob bytes (decryption performed on main isolate by
  /// [VaultStore.getBytes] before this item is sent).
  final Uint8List bytes;

  /// Chunk size in words.
  final int chunkSize;

  /// Chunk overlap in words.
  final int chunkOverlap;
}

/// The result message returned by the isolate: a [VaultIndexResult].
///
/// The isolate returns extracted text, chunk metadata, and per-chunk BM25
/// term/tf maps. It does NOT return SQ8 vectors — embedding happens on the
/// main isolate (RQ-3, RQ-5: ORT session is thread-affine).
final class VaultIndexResult {
  /// Creates a successful [VaultIndexResult].
  const VaultIndexResult({
    required this.sha256,
    required this.extractedText,
    required this.chunks,
    required this.termFrequencies,
    required this.charset,
    this.error,
  });

  /// SHA-256 of the indexed blob (echoed from [VaultWorkItem.sha256]).
  final String sha256;

  /// The full extracted UTF-8 text, or `null` if unsupported or failed.
  final String? extractedText;

  /// Chunk metadata (byte offsets and word counts in [extractedText]).
  ///
  /// Empty when [extractedText] is null or when the text produces no tokens.
  final List<({int index, int byteStart, int byteEnd, int wordCount})> chunks;

  /// BM25 per-chunk term frequency maps.
  ///
  /// `termFrequencies[i]` corresponds to `chunks[i]`.
  final List<Map<String, int>> termFrequencies;

  /// IANA charset label detected during extraction, or `null` if unavailable.
  final String? charset;

  /// Error message if extraction failed; `null` on success.
  final String? error;

  /// `true` if extraction succeeded (extractedText non-null and no error).
  bool get isSuccess => extractedText != null && error == null;

  /// `true` if the media type was not supported by any extractor.
  bool get isUnsupported => extractedText == null && error == null;

  /// `true` if extraction failed with an error.
  bool get isFailed => error != null;
}

/// Shutdown sentinel message sent to the isolate to request graceful exit.
const _kShutdownMessage = 'shutdown';

/// Manages the background Dart [Isolate] used for vault text extraction,
/// chunking, and tokenisation.
///
/// Processing is **one-at-a-time**: [sendWork] sends a [VaultWorkItem] to the
/// isolate and returns a [Future<VaultIndexResult>] that resolves when the
/// isolate responds. There is no internal queue inside the isolate — queueing
/// is handled by [VaultSearchManager].
///
/// ## Lifecycle
///
/// 1. [spawn] — creates the isolate and sets up the communication ports.
/// 2. [sendWork] — sends one work item; await the returned future for the result.
/// 3. [shutdown] — sends the shutdown sentinel and kills the isolate gracefully.
///
/// [VaultIndexingIsolate] is created lazily by [VaultSearchManager] on the
/// first pending work item.
final class VaultIndexingIsolate {
  // ignore: prefer_initializing_formals
  VaultIndexingIsolate._(
    SendPort sendPort,
    Isolate isolate,
    RawReceivePort rawPort,
  ) : _sendPort = sendPort,
      _isolate = isolate,
      _rawPort = rawPort;

  final SendPort _sendPort;
  final Isolate _isolate;
  final RawReceivePort _rawPort;

  // Completer for the in-flight work item (at most one at a time).
  _PendingWork? _inflight;

  /// Creates and starts the indexing isolate.
  ///
  /// [extractors] are the text extractors available in this session.
  static Future<VaultIndexingIsolate> spawn(
    List<VaultTextExtractor> extractors,
  ) async {
    // Use a RawReceivePort so we have full control over the message handler.
    // ReceivePort.skip() does not work correctly as it creates a non-broadcast
    // stream that conflicts with the .first await.
    final rawPort = RawReceivePort();
    final sendPortCompleter = Completer<SendPort>();
    VaultIndexingIsolate? instance;

    rawPort.handler = (dynamic message) {
      if (!sendPortCompleter.isCompleted) {
        // First message from the isolate: its own SendPort.
        sendPortCompleter.complete(message as SendPort);
      } else {
        // Subsequent messages: work results, forwarded to the instance handler.
        instance?._onResult(message);
      }
    };

    // The isolate entry point is a top-level function (required by Dart).
    // We pass the extractors and the reply port as the initial message.
    final isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _IsolateInit(replyPort: rawPort.sendPort, extractors: extractors),
      debugName: 'VaultIndexingIsolate',
    );

    // Wait for the isolate to send back its own SendPort.
    final sendPort = await sendPortCompleter.future;

    instance = VaultIndexingIsolate._(sendPort, isolate, rawPort);

    return instance;
  }

  /// Sends [item] to the isolate and returns a Future that resolves with the
  /// result.
  ///
  /// MUST NOT be called while another work item is in-flight. The caller
  /// ([VaultSearchManager]) is responsible for enforcing this invariant.
  Future<VaultIndexResult> sendWork(VaultWorkItem item) {
    assert(_inflight == null, 'Another work item is already in-flight');
    final pending = _PendingWork();
    _inflight = pending;
    _sendPort.send(item);
    return pending.completer.future;
  }

  /// Sends the shutdown signal and kills the isolate after the current work
  /// item completes.
  ///
  /// After [shutdown] returns, this instance must not be used again.
  Future<void> shutdown() async {
    // Wait for any in-flight work to complete before sending shutdown.
    // This prevents torn filesystem artifacts (graceful close protocol).
    final inflight = _inflight;
    if (inflight != null) {
      await inflight.completer.future.catchError(
        (_) => const VaultIndexResult(
          sha256: '',
          extractedText: null,
          chunks: [],
          termFrequencies: [],
          charset: null,
        ),
      );
    }
    _sendPort.send(_kShutdownMessage);
    // Give the isolate a moment to exit cleanly, then kill it.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    // Close our receive port so the Dart VM can GC the isolate's memory.
    _rawPort.close();
  }

  void _onResult(dynamic message) {
    final pending = _inflight;
    _inflight = null;
    if (message is VaultIndexResult) {
      pending?.completer.complete(message);
    } else {
      pending?.completer.completeError(
        StateError('Unexpected message from indexing isolate: $message'),
      );
    }
  }

  /// Exposes [_processWorkItem] for unit testing without spawning a real
  /// isolate.
  ///
  /// This allows tests to verify the extraction logic — including error and
  /// null-return paths — directly on the main isolate, without the overhead
  /// and indirection of cross-isolate communication.
  @visibleForTesting
  static Future<VaultIndexResult> processWorkItemForTesting(
    VaultWorkItem item,
    List<VaultTextExtractor> extractors,
  ) => _processWorkItem(item, extractors);
}

/// Holds the completer for an in-flight work item.
final class _PendingWork {
  final completer = Completer<VaultIndexResult>();
}

/// Initialization message sent to the isolate at spawn time.
final class _IsolateInit {
  const _IsolateInit({required this.replyPort, required this.extractors});

  /// The main isolate's receive port — used to send back the work SendPort.
  final SendPort replyPort;

  /// Text extractors available in this session.
  final List<VaultTextExtractor> extractors;
}

/// The isolate entry point.
///
/// Sets up a receive port, sends its own [SendPort] back to the main isolate,
/// then processes work items one at a time until a shutdown message is received.
///
/// This is a **top-level function** — required by [Isolate.spawn].
Future<void> _isolateEntryPoint(_IsolateInit init) async {
  final receivePort = ReceivePort();

  // Send our SendPort back to the main isolate so it can submit work.
  init.replyPort.send(receivePort.sendPort);

  await for (final message in receivePort) {
    if (message == _kShutdownMessage) {
      receivePort.close();
      return;
    }
    if (message is VaultWorkItem) {
      final result = await _processWorkItem(message, init.extractors);
      init.replyPort.send(result);
    }
  }
}

/// Processes a single [VaultWorkItem] inside the isolate.
///
/// Finds the first extractor that supports [item.mediaType], extracts text,
/// chunks it, and returns per-chunk BM25 term/tf maps.
///
/// **Does NOT embed** — embedding happens on the main isolate (RQ-5).
Future<VaultIndexResult> _processWorkItem(
  VaultWorkItem item,
  List<VaultTextExtractor> extractors,
) async {
  // Find the first extractor that supports this media type.
  VaultTextExtractor? extractor;
  for (final e in extractors) {
    if (e.supportedMediaTypes.contains(item.mediaType)) {
      extractor = e;
      break;
    }
  }

  if (extractor == null) {
    // No extractor supports this media type → unsupported.
    return VaultIndexResult(
      sha256: item.sha256,
      extractedText: null,
      chunks: const [],
      termFrequencies: const [],
      charset: null,
    );
  }

  // Create a minimal manifest for the extractor (mediaType is the key field).
  final manifest = VaultManifest(
    sha256: item.sha256,
    size: item.bytes.length,
    crc32c: '00000000',
    mediaType: item.mediaType,
    originalName: '',
    createdAt: '',
  );

  final String? extractedText;
  String? charset;
  try {
    extractedText = await extractor.extract(item.bytes, manifest);
    // Read the charset if the extractor recorded it.
    // PlainTextExtractor exposes lastCharset after extraction.
    if (extractor is PlainTextExtractor) {
      charset = extractor.lastCharset;
    }
  } catch (e) {
    return VaultIndexResult(
      sha256: item.sha256,
      extractedText: null,
      chunks: const [],
      termFrequencies: const [],
      charset: null,
      error: 'Extraction error: $e',
    );
  }

  if (extractedText == null) {
    // Extractor returned null → failure (not unsupported — the extractor did
    // match but couldn't process this particular blob).
    return VaultIndexResult(
      sha256: item.sha256,
      extractedText: null,
      chunks: const [],
      termFrequencies: const [],
      charset: charset,
      error: 'Extractor returned null',
    );
  }

  // Chunk the extracted text.
  final config = VaultSearchConfig(
    chunkSize: item.chunkSize,
    chunkOverlap: item.chunkOverlap,
  );
  final chunker = VaultChunker(config);
  final chunkResult = chunker.chunk(extractedText);

  // Convert VaultChunk records to plain Maps for cross-isolate transfer.
  final chunkMaps = chunkResult.chunks
      .map(
        (c) => (
          index: c.index,
          byteStart: c.byteStart,
          byteEnd: c.byteEnd,
          wordCount: c.wordCount,
        ),
      )
      .toList();

  return VaultIndexResult(
    sha256: item.sha256,
    extractedText: extractedText,
    chunks: chunkMaps,
    termFrequencies: chunkResult.termFrequencies,
    charset: charset,
  );
}
