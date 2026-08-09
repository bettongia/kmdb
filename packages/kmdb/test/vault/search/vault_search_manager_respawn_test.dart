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

/// V1 (S-8, 0.10.01): [VaultSearchManager] must discard a wedged
/// [VaultIndexingIsolate] on any `sendWork` failure — including the
/// [VaultIndexingIsolate.kWorkTimeout] backstop — and serve the *next* work
/// item from a freshly spawned isolate, rather than re-using an isolate that
/// can never make progress again.
///
/// This test is deliberately real-time (it waits out the actual 30s
/// [VaultIndexingIsolate.kWorkTimeout], not a mocked clock) because the fix
/// under test is a cross-isolate timing race: [FakeAsync]-style virtual
/// clocks do not advance a real spawned isolate's event loop, so there is no
/// faster way to exercise the genuine backstop. See
/// `vault_indexing_isolate_test.dart` for the companion V2 (stale-result
/// guard) test, which exercises [VaultIndexingIsolate] directly rather than
/// through the manager — see that test's doc comment for why V1 makes the
/// mis-delivery unreachable through this manager-level path.
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/search/vault_extraction_state.dart';
import 'package:kmdb/src/vault/search/vault_indexing_isolate.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';
import 'package:kmdb/src/vault/search/vault_search_config.dart';
import 'package:kmdb/src/vault/search/vault_search_manager.dart';
import 'package:kmdb/src/vault/search/vault_text_extractor.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [VaultTextExtractor] whose [extract] never completes.
///
/// Simulates a Dart-level wedge (an unbounded extraction the pipeline's own
/// bounds — [ExtractorLimits] — failed to catch, or a bug in a third-party
/// extractor). Because the isolate processes one work item at a time via an
/// `await for` loop that awaits `_processWorkItem` to completion before
/// reading its next message, an item routed to this extractor wedges the
/// *entire* isolate's message loop forever, not just this one item — which
/// is exactly the scenario V1 must recover from for the *next* item.
final class _HangingExtractor implements VaultTextExtractor {
  const _HangingExtractor();

  static const mediaType = 'application/x-hang-forever';

  @override
  Set<String> get supportedMediaTypes => const {mediaType};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    // Never completes.
    await Completer<String?>().future;
    return null; // unreachable
  }
}

/// A [VaultTextExtractor] that handles `text/plain` by decoding as UTF-8,
/// completing immediately. Used as the "next item" that must succeed
/// promptly once the wedged isolate from a prior item has been discarded.
final class _FastTextExtractor implements VaultTextExtractor {
  const _FastTextExtractor();

  @override
  Set<String> get supportedMediaTypes => const {'text/plain'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async =>
      utf8.decode(bytes, allowMalformed: true);
}

final class _AlwaysPlainDetector implements MediaTypeDetector {
  const _AlwaysPlainDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [
    'text/plain',
  ];
}

/// A [VaultStore] subclass wiring [listFilesRecursive] for the flat
/// [MemoryStorageAdapter] key space (same pattern used throughout the vault
/// test suite).
final class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(
        dbDir: '/db',
        adapter: adapter,
        detector: const _AlwaysPlainDetector(),
      );

  final MemoryStorageAdapter _mem;

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return [
      for (final path in _mem.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _dbDir = '/vsm-respawn-test';
const _deviceId = 'vsmRspwn0';
const _hlc = 't1';

Future<KvStoreImpl> _openStore(MemoryStorageAdapter adapter) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: _deviceId,
  );
  return store;
}

Future<String> _ingest(_TestVaultStore store, Uint8List content) async {
  final ref = await store.ingest(bytes: content, hlcTimestamp: _hlc);
  return ref.sha256;
}

Future<VaultExtractionState?> _readState(
  KvStoreImpl kvStore,
  String sha256,
) async {
  final ns = '$kVaultExtractPrefix$sha256';
  final bytes = await kvStore.get(ns, kVaultCorpusSentinelKey);
  if (bytes == null) return null;
  return VaultExtractionState.decode(bytes, sha256);
}

/// Polls until [sha256] reaches a terminal indexing status or [timeout] elapses.
Future<VaultExtractionState> _awaitTerminal(
  KvStoreImpl kvStore,
  String sha256, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final state = await _readState(kvStore, sha256);
    if (state != null &&
        (state.status == VaultExtractionStatus.indexed ||
            state.status == VaultExtractionStatus.failed ||
            state.status == VaultExtractionStatus.unsupported)) {
      return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException(
    'Timed out waiting for $sha256 to reach terminal state',
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late MemoryStorageAdapter adapter;
  late KvStoreImpl kvStore;
  late _TestVaultStore vaultStore;

  setUp(() async {
    adapter = MemoryStorageAdapter();
    kvStore = await _openStore(adapter);
    vaultStore = _TestVaultStore(adapter);
  });

  tearDown(() async {
    await kvStore.close();
    MemoryStorageAdapter.releaseAllLocks();
  });

  test(
    'a kWorkTimeout backstop for one item does not wedge the queue — the '
    'next item is served by a freshly spawned isolate and succeeds (V1)',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final manager = VaultSearchManager(
        config: VaultSearchConfig(
          chunkSize: 50,
          chunkOverlap: 5,
          extractors: const [_HangingExtractor(), _FastTextExtractor()],
        ),
        kvStore: kvStore,
        vaultStore: vaultStore,
      );
      addTearDown(manager.close);

      // Item 1 routes to the extractor that never returns. The isolate's
      // message loop is now wedged forever on this item — sendWork's
      // kWorkTimeout (30s) backstop is the only thing that ever resolves it.
      final sha1 = await _ingest(
        vaultStore,
        Uint8List.fromList(utf8.encode('will hang forever')),
      );
      await manager.queueBlob(sha1, _HangingExtractor.mediaType);

      final item1Stopwatch = Stopwatch()..start();
      final state1 = await _awaitTerminal(
        kvStore,
        sha1,
        timeout: const Duration(seconds: 60),
      );
      item1Stopwatch.stop();

      expect(state1.status, equals(VaultExtractionStatus.failed));
      expect(
        item1Stopwatch.elapsed,
        greaterThanOrEqualTo(VaultIndexingIsolate.kWorkTimeout),
        reason:
            'item 1 can only resolve via the kWorkTimeout backstop, since '
            'its extractor never returns',
      );

      // Item 2 routes to a fast extractor. WITHOUT the V1 fix, the manager
      // would still hold a reference to item 1's isolate — permanently
      // wedged, since its message loop can never advance past item 1's
      // hung extraction — and this item would never complete. WITH the fix,
      // the manager discarded that isolate in the sendWork catch block
      // (`_isolate = null`), so this item is served by a freshly spawned
      // isolate and must complete promptly.
      final sha2 = await _ingest(
        vaultStore,
        Uint8List.fromList(utf8.encode('quick item two')),
      );
      await manager.queueBlob(sha2, 'text/plain');

      final item2Stopwatch = Stopwatch()..start();
      final state2 = await _awaitTerminal(
        kvStore,
        sha2,
        // Generous relative to normal indexing latency, but far short of a
        // second kWorkTimeout — proof this did NOT re-use the wedged isolate.
        timeout: const Duration(seconds: 10),
      );
      item2Stopwatch.stop();

      expect(state2.status, equals(VaultExtractionStatus.indexed));
      expect(state2.chunkCount, greaterThan(0));
      expect(
        item2Stopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'item 2 must be served by a fresh isolate, not the isolate '
            'wedged by item 1 — a second kWorkTimeout wait here would mean '
            'the re-spawn fix regressed',
      );
    },
  );
}
