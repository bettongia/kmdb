// Copyright 2026 The KMDB Authors
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

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../engine/kvstore/kv_store.dart';
import '../../engine/kvstore/kv_store_impl.dart';
import '../../encoding/value_codec.dart';
import 'index_definition.dart';
import 'index_writer.dart';

/// The four lifecycle states of a secondary index (spec §16).
///
/// ```
/// undefined → building → current
///                      ↘ stale → (rebuild) → current
/// ```
enum IndexStatus {
  /// Declared in config but never queried. No entries written. Zero overhead.
  undefined,

  /// First query triggered a background build. Index entries are written for
  /// new writes during the build, but the full namespace has not been scanned.
  building,

  /// Built and current. Index entries are maintained on every write.
  current,

  /// Built previously, but the namespace generation has advanced since the
  /// build completed. Falls back to full-scan for queries. A subsequent query
  /// triggers a delta rebuild.
  stale,
}

/// Persistent state for a secondary index, stored as a CBOR map in `$meta`.
final class IndexState {
  const IndexState({
    required this.namespace,
    required this.path,
    required this.status,
    this.builtThrough = 0,
    this.builtAt = '',
  });

  final String namespace;
  final String path;
  final IndexStatus status;

  /// Namespace generation counter at the time of the last successful build.
  final int builtThrough;

  /// HLC timestamp string recorded when the build completed (diagnostics only).
  final String builtAt;

  IndexState copyWith({
    IndexStatus? status,
    int? builtThrough,
    String? builtAt,
  }) => IndexState(
    namespace: namespace,
    path: path,
    status: status ?? this.status,
    builtThrough: builtThrough ?? this.builtThrough,
    builtAt: builtAt ?? this.builtAt,
  );
}

/// Manages the lifecycle and persistent state of secondary indexes.
///
/// [IndexManager] reads and writes index state from the `$meta` system
/// namespace and coordinates lazy index builds (spec §16).
///
/// ## Usage
///
/// ```dart
/// final manager = IndexManager(store: kvStoreImpl, definitions: indexes);
///
/// // On every document write:
/// await manager.interceptWrite(batch, namespace, docKey, oldDoc, newDoc);
///
/// // Before a query that would benefit from an index:
/// final state = await manager.getOrActivate(namespace, path);
/// if (state.status == IndexStatus.current) {
///   // use index
/// } else {
///   // fall back to full scan
/// }
/// ```
final class IndexManager {
  IndexManager({
    required KvStoreImpl store,
    required List<IndexDefinition> definitions,
    this.onIndexReady,
  }) : _store = store,
       _definitions = List.unmodifiable(definitions);

  final KvStoreImpl _store;
  final List<IndexDefinition> _definitions;

  /// Called when an index transitions from `building` to `current`.
  ///
  /// The application can use this to re-run any queries that fell back to a
  /// full scan during the build.
  final void Function(String namespace, String path)? onIndexReady;

  /// All index definitions registered with this manager.
  List<IndexDefinition> get definitions => _definitions;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns the definitions for [namespace] whose status is [current] or
  /// [building] (i.e. write interception is active for them).
  Future<List<IndexDefinition>> activeDefinitionsFor(String namespace) async {
    final result = <IndexDefinition>[];
    for (final def in _definitions) {
      if (def.namespace != namespace) continue;
      final state = await _loadState(def);
      if (state.status == IndexStatus.current ||
          state.status == IndexStatus.building) {
        result.add(def);
      }
    }
    return result;
  }

  /// Returns the current [IndexState] for [namespace]/[path].
  ///
  /// If the index is declared but has no persisted state, returns an
  /// [IndexState] with [IndexStatus.undefined].
  Future<IndexState> getState(String namespace, String path) async {
    final def = _find(namespace, path);
    if (def == null) {
      return IndexState(
        namespace: namespace,
        path: path,
        status: IndexStatus.undefined,
      );
    }
    return _loadState(def);
  }

  /// Adds index entry operations to [batch] for a document write.
  ///
  /// Call this for every active index on [namespace] before committing a
  /// [WriteBatch]. [oldDoc] is the previous version (null if inserting);
  /// [newDoc] is the new version (null if deleting).
  ///
  /// For indexes in `undefined` state, a lazy build is triggered on the first
  /// write to the namespace so that [requireFreshIndex] queries issued shortly
  /// after can find the index current without waiting for the first explicit
  /// query to activate it.
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? oldDoc,
    required Map<String, dynamic>? newDoc,
  }) async {
    final active = await activeDefinitionsFor(namespace);
    for (final def in active) {
      if (oldDoc != null) {
        IndexWriter.removeEntries(
          batch: batch,
          definition: def,
          docKey: docKey,
          document: oldDoc,
        );
      }
      if (newDoc != null) {
        IndexWriter.addEntries(
          batch: batch,
          definition: def,
          docKey: docKey,
          document: newDoc,
        );
      }
    }
    // Trigger a build for any undefined indexes on this namespace.  The build
    // is scheduled as an event (not a microtask) so it starts after the
    // current write batch commits, ensuring _buildIndex reads the correct
    // generation counter and finds the document in its initial scan.
    for (final def in _definitions) {
      if (def.namespace != namespace) continue;
      final state = await _loadState(def);
      if (state.status == IndexStatus.undefined) {
        _launchBuild(def);
      }
    }
  }

  /// Returns the [IndexState] for [namespace]/[path], triggering a lazy build
  /// if the index is in the `undefined` state.
  ///
  /// When the index is `stale` (built previously, but the namespace generation
  /// has advanced), a background rebuild is also triggered.
  ///
  /// During a build, queries should fall back to a full namespace scan.
  Future<IndexState> getOrActivate(String namespace, String path) async {
    final def = _find(namespace, path);
    if (def == null) {
      return IndexState(
        namespace: namespace,
        path: path,
        status: IndexStatus.undefined,
      );
    }

    final state = await _loadState(def);
    switch (state.status) {
      case IndexStatus.undefined:
        // Trigger lazy build asynchronously; return building state so caller
        // falls back to full scan for this query.
        _launchBuild(def);
        return state.copyWith(status: IndexStatus.building);

      case IndexStatus.current:
        // Verify the generation still matches (cheap meta read).
        final currentGen = await _store.meta.getGenerationCounter(namespace);
        if (currentGen != state.builtThrough) {
          // Generation advanced since the build — mark stale and rebuild.
          final staleState = state.copyWith(status: IndexStatus.stale);
          await _persistState(staleState);
          _launchBuild(def);
          return staleState;
        }
        return state;

      case IndexStatus.building:
      case IndexStatus.stale:
        // Already rebuilding; caller falls back to full scan.
        return state;
    }
  }

  /// Checks all declared indexes for interrupted builds on database open.
  ///
  /// Returns [IndexRebuildEvents] for any index found in the `building` state,
  /// which indicates a build was interrupted by an unclean shutdown (spec §16
  /// "Interrupted Build Recovery").
  Future<List<({String namespace, String path})>>
  checkInterruptedBuilds() async {
    final events = <({String namespace, String path})>[];
    for (final def in _definitions) {
      final state = await _loadState(def);
      if (state.status == IndexStatus.building) {
        events.add((namespace: def.namespace, path: def.path));
      }
    }
    return events;
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  /// Launches an asynchronous index build for [definition].
  ///
  /// Persists `status = building` immediately, then scans the namespace in
  /// batches of 200 to write index entries. On completion, marks `current` or
  /// `stale` depending on whether concurrent writes advanced the generation.
  void _launchBuild(IndexDefinition definition) {
    // Fire-and-forget: the build is scheduled as an event (Duration.zero timer)
    // so it runs after all pending microtasks — including any in-flight write
    // batch — have completed. This guarantees _buildIndex reads the generation
    // counter after the triggering write commits, avoiding a spurious stale
    // transition. Errors (e.g. DB closed before build finishes) are swallowed —
    // the state remains `building` and will be recovered on next open.
    Future(() => _buildIndex(definition)).catchError((_) {});
  }

  Future<void> _buildIndex(IndexDefinition definition) async {
    // 1. Record the generation at build start and mark status = building.
    final startGen = await _store.meta.getGenerationCounter(
      definition.namespace,
    );
    await _persistState(
      IndexState(
        namespace: definition.namespace,
        path: definition.path,
        status: IndexStatus.building,
        builtThrough: startGen,
      ),
    );

    // 2. Scan the entire namespace in batches of 200, writing index entries.
    //    Write interception is now active (activeDefinitionsFor returns this
    //    index in 'building' state) so new writes during the build are covered.
    try {
      await _scanAndIndex(definition);
    } catch (_) {
      // Build failed; leave state as `building` so recovery picks it up on
      // next open. Do not propagate — the build is fire-and-forget.
      return;
    }

    // 3. Check if the generation advanced during the build.
    final endGen = await _store.meta.getGenerationCounter(definition.namespace);
    if (endGen == startGen) {
      // No concurrent writes — index is current.
      final currentState = IndexState(
        namespace: definition.namespace,
        path: definition.path,
        status: IndexStatus.current,
        builtThrough: endGen,
      );
      await _persistState(currentState);
      onIndexReady?.call(definition.namespace, definition.path);
    } else {
      // Concurrent writes arrived; index is stale. A subsequent query will
      // trigger another rebuild.
      await _persistState(
        IndexState(
          namespace: definition.namespace,
          path: definition.path,
          status: IndexStatus.stale,
          builtThrough: startGen,
        ),
      );
    }
  }

  /// Scans [definition]'s namespace and writes index entries in batches of 200.
  Future<void> _scanAndIndex(IndexDefinition definition) async {
    const batchSize = 200;
    var count = 0;
    var batch = WriteBatch();

    await for (final entry in _store.scan(definition.namespace)) {
      Map<String, dynamic> doc;
      try {
        doc = ValueCodec.decode(entry.value);
      } catch (_) {
        continue; // skip corrupt values
      }

      IndexWriter.addEntries(
        batch: batch,
        definition: definition,
        docKey: entry.key,
        document: doc,
      );
      count++;

      if (count >= batchSize) {
        if (!batch.isEmpty) {
          await _store.writeBatchInternal(batch);
        }
        batch = WriteBatch();
        count = 0;
      }
    }

    if (!batch.isEmpty) {
      await _store.writeBatchInternal(batch);
    }
  }

  // ── State persistence ──────────────────────────────────────────────────────

  /// Reads the persisted [IndexState] for [definition] from `$meta`.
  ///
  /// Returns an `undefined` state if no state has been persisted yet.
  Future<IndexState> _loadState(IndexDefinition definition) async {
    final symbolicName = 'index:${definition.namespace}:${definition.path}';
    final bytes = await _store.meta.getRawByName(symbolicName);
    if (bytes == null || bytes.isEmpty) {
      return IndexState(
        namespace: definition.namespace,
        path: definition.path,
        status: IndexStatus.undefined,
      );
    }
    return _decodeState(definition, bytes);
  }

  /// Persists [state] to `$meta`.
  Future<void> _persistState(IndexState state) async {
    final symbolicName = 'index:${state.namespace}:${state.path}';
    final bytes = _encodeState(state);
    await _store.meta.putRawByName(symbolicName, bytes);
  }

  // ── CBOR serialisation ─────────────────────────────────────────────────────

  static Uint8List _encodeState(IndexState state) {
    final map = CborMap({
      CborString('path'): CborString(state.path),
      CborString('namespace'): CborString(state.namespace),
      CborString('status'): CborString(state.status.name),
      CborString('builtThrough'): CborSmallInt(state.builtThrough),
      CborString('builtAt'): CborString(state.builtAt),
    });
    return Uint8List.fromList(cbor.encode(map));
  }

  static IndexState _decodeState(IndexDefinition def, Uint8List bytes) {
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborMap) {
        return IndexState(
          namespace: def.namespace,
          path: def.path,
          status: IndexStatus.undefined,
        );
      }
      final map = decoded.toObject() as Map<dynamic, dynamic>;
      final statusStr = map['status'] as String? ?? 'undefined';
      final status = IndexStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => IndexStatus.undefined,
      );
      return IndexState(
        namespace: def.namespace,
        path: def.path,
        status: status,
        builtThrough: (map['builtThrough'] as num?)?.toInt() ?? 0,
        builtAt: map['builtAt'] as String? ?? '',
      );
    } catch (_) {
      return IndexState(
        namespace: def.namespace,
        path: def.path,
        status: IndexStatus.undefined,
      );
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Finds the [IndexDefinition] for [namespace]/[path], or `null`.
  IndexDefinition? _find(String namespace, String path) {
    for (final def in _definitions) {
      if (def.namespace == namespace && def.path == path) return def;
    }
    return null;
  }
}
