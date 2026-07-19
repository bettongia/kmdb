// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// D-1 (2026-07-18 release-readiness review): a dead or hung vault-indexing
/// isolate must never prevent [KmdbDatabase.close] from flushing the
/// memtable.
///
/// This test exercises the actual trigger the review describes: an
/// extraction that never returns (standing in for a native crash that
/// doesn't propagate as a catchable Dart error, or an unbounded extraction —
/// see S-2/S-8). Before the Phase 3b/close()-reordering fix, this hung
/// `close()` indefinitely *before* the flush ran; a forced kill after that
/// hang lost whatever was still in the memtable.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/query/kmdb_database.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/search/vault_search_config.dart';
import 'package:kmdb/src/vault/search/vault_text_extractor.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

/// An extractor whose [extract] never returns — the trigger this test
/// exercises. Deliberately stateless (`const`) so it is trivially sendable
/// across the isolate boundary, matching how the built-in extractors are
/// already passed to [VaultIndexingIsolate.spawn].
final class _HangingExtractor implements VaultTextExtractor {
  const _HangingExtractor();

  static const mediaType = 'application/x-hang-forever';

  @override
  Set<String> get supportedMediaTypes => {mediaType};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    // Never completes — simulates a native crash that doesn't propagate as a
    // catchable Dart error, or an unbounded extraction (S-2/S-8).
    await Completer<String?>().future;
    return null; // unreachable
  }
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

/// A [VaultStore] subclass wiring [listFilesRecursive] for the flat
/// [MemoryStorageAdapter] key space (same pattern used throughout the vault
/// test suite).
final class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(adapter: adapter, detector: const _NoOpDetector(), dbDir: '/db');

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

void main() {
  test('close() flushes the memtable even when the vault-indexing isolate is '
      'hung on an in-flight extraction (D-1)', () async {
    final dbAdapter = MemoryStorageAdapter();
    final vaultStore = _TestVaultStore(MemoryStorageAdapter());

    var db = await KmdbDatabase.open(
      path: '/db',
      adapter: dbAdapter,
      vaultStore: vaultStore,
      vaultSearch: VaultSearchConfig(extractors: const [_HangingExtractor()]),
    );

    // Write a plain document — this is what must survive close()'s flush.
    final col = db.rawCollection('notes');
    final inserted = await col.insert({'text': 'must survive the flush'});
    final noteId = inserted['_id'] as String;

    // Ingest a blob whose media type routes to the hanging extractor. This
    // fires VaultSearchManager's onAfterIngest hook, which enqueues and
    // (asynchronously) spawns the indexing isolate and sends it this item.
    await vaultStore.ingest(
      bytes: Uint8List.fromList('blob content'.codeUnits),
      hlcTimestamp: '0000000000000001',
      explicitMediaType: _HangingExtractor.mediaType,
    );

    // Give the isolate a moment to spawn and actually start (and hang on)
    // the extraction — otherwise close() might race ahead of the isolate
    // even being spawned, which wouldn't exercise the hang at all.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // The actual assertion: close() must return in bounded time. Before
    // the fix this could hang indefinitely (the isolate never responds).
    // VaultIndexingIsolate.kShutdownDrainTimeout is 5s; comfortable slack
    // is given here without waiting anywhere close to "forever".
    final stopwatch = Stopwatch()..start();
    await db.close().timeout(
      const Duration(seconds: 15),
      onTimeout: () => fail(
        'KmdbDatabase.close() did not return within 15s — the hung vault '
        'indexing isolate blocked the flush (D-1 regression).',
      ),
    );
    stopwatch.stop();
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 15)),
      reason:
          'close() must be bounded by the isolate shutdown timeout, '
          'not hang indefinitely',
    );

    // Reopen and confirm the plain document actually made it to disk —
    // proof the flush ran, not just that close() happened to return.
    db = await KmdbDatabase.open(path: '/db', adapter: dbAdapter);
    final reopenedCol = db.rawCollection('notes');
    final reopened = await reopenedCol.get(noteId);
    expect(reopened, isNotNull);
    expect(reopened!['text'], equals('must survive the flush'));
    await db.close(flush: false);
  });
}
