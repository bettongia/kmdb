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

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../engine/kvstore/kv_store.dart';
import '../../engine/kvstore/kv_store_impl.dart';
import '../../engine/kvstore/meta_store.dart';
import '../../encoding/value_codec.dart';
import '../../encryption/encryption_envelope.dart';
import '../../encryption/encryption_provider.dart';
import '../write_augmentor.dart';
import 'index_definition.dart';
import 'index_reader.dart';
import 'index_writer.dart';

/// The local-only namespace holding persisted [IndexState] for every declared
/// secondary index.
///
/// Introduced by the 0.10.01 WI-11 fix (SC-10): index state — including
/// `status: current` — used to live in synced `$meta`, so a device that
/// pulled a peer's `$meta` inherited `current` for an index it never built
/// locally, then scanned its own empty `$$index:*` namespaces and silently
/// returned zero rows for present, matching documents. Moving the state
/// itself into a `$$`-prefixed (local-only) namespace makes that
/// structurally impossible: `$$indexstate` is never uploaded (see
/// `isLocalOnly` in `namespace_codec.dart`), so every device's index state
/// reflects only what *that device* has built.
///
/// The key within this namespace is unchanged — [MetaStore.indexKey] — and
/// the value is the same CBOR-encoded [IndexState] as before, still wrapped
/// with [EncryptionEnvelope] (see [IndexManager._loadState] /
/// [IndexManager._persistState]). Only the target namespace moved.
const String kIndexStateNamespace = r'$$indexstate';

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

/// Discriminates how index-entry namespace tokens (the `{token}` segment of
/// `$$index:{ns}:{path}:{token}`) were computed when this index was last
/// (re)built.
///
/// Mirrors [FtsTokenMode] — see that type's doc comment for the full
/// rationale (Encryption confidentiality reconciliation plan, Gap 2, Q5). Not
/// a runtime toggle: the only way this can mismatch what the current code
/// would produce is a software upgrade of an already-encrypted database.
enum IndexTokenMode {
  /// Values are hex-encoded in plaintext ([IndexWriter._encodeValueHex]).
  /// Used when the database is unencrypted, and also the value read back
  /// from indexes built before Gap 2 shipped.
  hex,

  /// Values are tokenised via [EncryptionProvider.indexToken]. Used when the
  /// database is encrypted.
  hmac,
}

/// Persistent state for a secondary index, stored as a CBOR map in the
/// local-only [kIndexStateNamespace] (moved out of synced `$meta` by the
/// 0.10.01 WI-11 fix — see that constant's doc comment for why).
final class IndexState {
  const IndexState({
    required this.namespace,
    required this.path,
    required this.status,
    this.builtThrough = 0,
    this.builtAt = '',
    this.tokenMode = IndexTokenMode.hex,
  });

  final String namespace;
  final String path;
  final IndexStatus status;

  /// Namespace generation counter at the time of the last successful build.
  final int builtThrough;

  /// HLC timestamp string recorded when the build completed (diagnostics only).
  final String builtAt;

  /// How index-entry namespace tokens were computed as of the last build.
  /// See [IndexTokenMode].
  final IndexTokenMode tokenMode;

  IndexState copyWith({
    IndexStatus? status,
    int? builtThrough,
    String? builtAt,
    IndexTokenMode? tokenMode,
  }) => IndexState(
    namespace: namespace,
    path: path,
    status: status ?? this.status,
    builtThrough: builtThrough ?? this.builtThrough,
    builtAt: builtAt ?? this.builtAt,
    tokenMode: tokenMode ?? this.tokenMode,
  );
}

/// Manages the lifecycle and persistent state of secondary indexes.
///
/// [IndexManager] reads and writes index state from the local-only
/// [kIndexStateNamespace] system namespace and coordinates lazy index builds
/// (spec §16).
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
/// Implements [WriteAugmentor] so it integrates cleanly with the formal write
/// pipeline in [KmdbCollection] without requiring special-casing.
final class IndexManager implements WriteAugmentor {
  /// Creates an [IndexManager].
  ///
  /// [encryption] is the optional encryption provider. When non-null, source
  /// document values are decrypted before indexing (they were written through
  /// the same encrypted [ValueCodec] path).
  IndexManager({
    required this._store,
    required List<IndexDefinition> definitions,
    this.onIndexReady,
    this._encryption,
  }) : _definitions = List.unmodifiable(definitions);

  final KvStoreImpl _store;
  final List<IndexDefinition> _definitions;

  /// Optional encryption provider threaded through all [ValueCodec] calls.
  final EncryptionProvider? _encryption;

  /// Called when an index transitions from `building` to `current`.
  ///
  /// The application can use this to re-run any queries that fell back to a
  /// full scan during the build.
  final void Function(String namespace, String path)? onIndexReady;

  /// All index definitions registered with this manager.
  List<IndexDefinition> get definitions => _definitions;

  // ── Startup ─────────────────────────────────────────────────────────────────

  /// Called during [KmdbDatabase.open] to detect a namespace-token
  /// format-version upgrade and purge+rebuild any affected index
  /// (Encryption confidentiality reconciliation plan, Gap 2, Q5).
  ///
  /// Compares each declared index's persisted [IndexState.tokenMode] against
  /// what the currently-running code would produce (`hmac` when an
  /// [EncryptionProvider] is configured, `hex` otherwise). On a mismatch, the
  /// index's sub-namespaces were tokenised under a scheme the current code no
  /// longer computes — those entries are effectively orphaned (unreachable by
  /// future reads/writes) and, if left in place, would defeat Gap 2 by
  /// leaving the very plaintext-derivable tokens it closes on disk
  /// indefinitely. [removeIndex] purges every sub-namespace and the
  /// [kIndexStateNamespace] state entry, after which the index reads back as
  /// [IndexStatus.undefined]
  /// and rebuilds lazily on the next write/query — the same path used for a
  /// brand-new index (mirrors [VecManager.checkAndTransitionOnOpen]'s
  /// model-identity check).
  ///
  /// Must run **after** [MetaStore]'s [EncryptionProvider] has been bound
  /// (`KmdbDatabase.open`, Gap 3/Q1) and before [checkInterruptedBuilds], so a
  /// purge-triggered index is never also reported as an interrupted build.
  ///
  /// This is not a runtime encryption toggle — see [IndexTokenMode]'s doc
  /// comment. Indexes still in [IndexStatus.undefined] are skipped: there is
  /// nothing to purge.
  Future<void> checkTokenModeOnOpen() async {
    final expected = _encryption != null
        ? IndexTokenMode.hmac
        : IndexTokenMode.hex;
    for (final def in _definitions) {
      final state = await _loadState(def);
      if (state.status == IndexStatus.undefined) continue;
      if (state.tokenMode == expected) continue;
      await removeIndex(def.namespace, def.path);
    }
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns the definitions for [namespace] whose status is [current] or
  /// [IndexStatus.building] (i.e. write interception is active for them).
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

  /// Returns the document keys whose [definition]'s field equals [value].
  ///
  /// Delegates to [IndexReader.lookupByValue] using the private store,
  /// keeping the [KvStore] reference encapsulated. Call [getOrActivate] before
  /// this method to confirm the index is [IndexStatus.current]; this method
  /// performs the lookup unconditionally.
  ///
  /// Returns an empty list when [value] is not indexable (null, Map, List) or
  /// when no documents match.
  Future<List<String>> lookupByValue(
    IndexDefinition definition,
    Object? value,
  ) => IndexReader.lookupByValue(
    store: _store,
    definition: definition,
    value: value,
    encryption: _encryption,
  );

  /// Removes all stored data for the index on [namespace]/[path].
  ///
  /// This method:
  /// 1. Enumerates every `$$index:{namespace}:{path}:*` sub-namespace in
  ///    storage (one sub-namespace per distinct indexed value).
  /// 2. Deletes all entries in each sub-namespace in batches of 200.
  /// 3. Deletes the [kIndexStateNamespace] state entry for the index.
  ///
  /// It is a no-op if the index was never built (undefined state) — the method
  /// still deletes any sub-namespaces that might exist from a partial build.
  ///
  /// Other indexes on the same collection or on other collections are
  /// unaffected.
  Future<void> removeIndex(String namespace, String path) async {
    // Compute the prefix that all sub-namespaces for this index share.
    // Each sub-namespace has the form: $$index:{namespace}:{path}:{hexValue}
    final def = IndexDefinition(namespace, path);
    final subNsPrefix = '${def.indexNamespace}:';

    // Collect all sub-namespaces that belong to this index.
    final all = await _store.allStoredNamespaces();
    final indexSubNamespaces = all
        .where((ns) => ns.startsWith(subNsPrefix))
        .toList();

    // Delete entries from each sub-namespace in batches of 200.
    for (final subNs in indexSubNamespaces) {
      const batchSize = 200;
      var batch = WriteBatch();
      var count = 0;

      await for (final entry in _store.scan(subNs)) {
        batch.delete(subNs, entry.key);
        count++;
        if (count >= batchSize) {
          await _store.writeBatchInternal(batch);
          batch = WriteBatch();
          count = 0;
        }
      }
      if (!batch.isEmpty) {
        await _store.writeBatchInternal(batch);
      }
    }

    // Delete the persisted state entry for this index. Lives in the
    // local-only $$indexstate namespace (WI-11/SC-10), not $meta — see
    // kIndexStateNamespace's doc comment.
    final key = MetaStore.indexKey(namespace, path);
    await _store.deleteRaw(kIndexStateNamespace, key);
  }

  /// Adds index entry operations to [batch] for a document write.
  ///
  /// Call this for every active index on [namespace] before committing a
  /// [WriteBatch]. [oldDoc] is the previous version (null if inserting);
  /// [newDoc] is the new version (null if deleting).
  ///
  /// For indexes in `undefined` state, a lazy build is triggered on the first
  /// write to the namespace so that [KmdbQuery.requireFreshIndex] queries issued shortly
  /// after can find the index current without waiting for the first explicit
  /// query to activate it.
  @override
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
    final active = await activeDefinitionsFor(namespace);
    for (final def in active) {
      if (oldDoc != null) {
        await IndexWriter.removeEntries(
          batch: batch,
          definition: def,
          docKey: docKey,
          document: oldDoc,
          encryption: _encryption,
        );
      }
      if (newDoc != null) {
        await IndexWriter.addEntries(
          batch: batch,
          definition: def,
          docKey: docKey,
          document: newDoc,
          encryption: _encryption,
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
  /// Returns interrupted-build events for any index found in the `building` state,
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

  /// The [IndexTokenMode] the currently-configured [_encryption] would
  /// produce. Stamped onto every [IndexState] this manager persists so a
  /// later [checkTokenModeOnOpen] can detect a format-version mismatch
  /// (Gap 2, Q5).
  IndexTokenMode get _currentTokenMode =>
      _encryption != null ? IndexTokenMode.hmac : IndexTokenMode.hex;

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
        tokenMode: _currentTokenMode,
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
        tokenMode: _currentTokenMode,
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
          tokenMode: _currentTokenMode,
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
        doc = await ValueCodec.decode(entry.value, encryption: _encryption);
      } catch (_) {
        continue; // skip corrupt values
      }

      await IndexWriter.addEntries(
        batch: batch,
        definition: definition,
        docKey: entry.key,
        document: doc,
        encryption: _encryption,
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

  /// Reads the persisted [IndexState] for [definition] from the local-only
  /// [kIndexStateNamespace] (moved from `$meta` by WI-11/SC-10 — see that
  /// namespace's doc comment).
  ///
  /// Returns an `undefined` state if no state has been persisted yet.
  Future<IndexState> _loadState(IndexDefinition definition) async {
    final key = MetaStore.indexKey(definition.namespace, definition.path);
    final bytes = await _store.get(kIndexStateNamespace, key);
    if (bytes == null || bytes.isEmpty) {
      return IndexState(
        namespace: definition.namespace,
        path: definition.path,
        status: IndexStatus.undefined,
      );
    }
    final unwrapped = await EncryptionEnvelope.unwrap(bytes, _encryption);
    return _decodeState(definition, unwrapped);
  }

  /// Persists [state] to the local-only [kIndexStateNamespace].
  ///
  /// Uses [KvStoreImpl.putRaw] (not [KvStoreImpl.writeBatchInternal]) so an
  /// index status flip never marks the dirty-open flag — building or
  /// rebuilding a derived index is not a document write (see [putRaw]'s doc
  /// comment).
  Future<void> _persistState(IndexState state) async {
    final key = MetaStore.indexKey(state.namespace, state.path);
    final bytes = _encodeState(state);
    final wrapped = await EncryptionEnvelope.wrap(bytes, _encryption);
    await _store.putRaw(kIndexStateNamespace, key, wrapped);
  }

  // ── CBOR serialisation ─────────────────────────────────────────────────────

  static Uint8List _encodeState(IndexState state) {
    final map = CborMap({
      CborString('path'): CborString(state.path),
      CborString('namespace'): CborString(state.namespace),
      CborString('status'): CborString(state.status.name),
      CborString('builtThrough'): CborSmallInt(state.builtThrough),
      CborString('builtAt'): CborString(state.builtAt),
      CborString('tokenMode'): CborString(state.tokenMode.name),
    });
    return Uint8List.fromList(cbor.encode(map));
  }

  /// Decodes an [IndexState] from CBOR. [tokenMode] defaults to
  /// [IndexTokenMode.hex] when absent from the serialised map — indexes
  /// built before Gap 2 shipped were always hex-tokenised, so this default is
  /// the actual prior behaviour, not a guess. This is what lets
  /// [checkTokenModeOnOpen] detect the pre-Gap-2 → Gap-2 upgrade on an
  /// already-encrypted database.
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
      final tokenModeStr = map['tokenMode'] as String? ?? 'hex';
      final tokenMode = IndexTokenMode.values.firstWhere(
        (m) => m.name == tokenModeStr,
        orElse: () => IndexTokenMode.hex,
      );
      return IndexState(
        namespace: def.namespace,
        path: def.path,
        status: status,
        builtThrough: (map['builtThrough'] as num?)?.toInt() ?? 0,
        builtAt: map['builtAt'] as String? ?? '',
        tokenMode: tokenMode,
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
