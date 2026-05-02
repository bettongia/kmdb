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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';

import 'error_provider.dart';
import 'scan_options.dart';

/// Provider for the document list of a single collection.
///
/// [CollectionProvider] operates at the Query Layer boundary, using
/// [KmdbCollection] APIs rather than the raw [KvStore] scan interface.
///
/// Key behaviours:
/// - **Server-side scan**: filtering, ordering, limit, and offset are driven
///   by [ScanOptions] and delegated to [KmdbQuery] rather than performed
///   in memory after fetching all documents.
/// - **Reactive updates via `watch()`**: when [autoRefresh] is true, the
///   provider subscribes to [KmdbQuery.watch] so that mutations propagate
///   automatically without explicit [loadDocuments] calls.
/// - **Manual refresh**: when [autoRefresh] is false, a [watch()] subscription
///   is not held and the caller must invoke [loadDocuments] explicitly.
class CollectionProvider with ChangeNotifier {
  final KmdbDatabase _database;
  final String _collectionName;
  final ErrorProvider _errorProvider;

  final List<Map<String, dynamic>> _documents = [];

  ScanOptions _scanOptions;
  int _totalCount = 0;
  bool _isLoading = false;

  /// Whether the document list reacts to writes automatically via [watch()].
  bool _autoRefresh;

  StreamSubscription<List<Map<String, dynamic>>>? _watchSubscription;
  bool _disposed = false;

  /// The list of documents currently visible according to [scanOptions].
  List<Map<String, dynamic>> get documents => List.unmodifiable(_documents);

  /// The current scan parameters.
  ScanOptions get scanOptions => _scanOptions;

  /// Alias for [scanOptions.filterText] — kept for backwards compat in tests.
  String get query => _scanOptions.filterText ?? '';

  /// The name of the collection being browsed.
  String get collectionName => _collectionName;

  /// The total document count as of the last [loadDocuments] call.
  int get totalCount => _totalCount;

  /// True while an async load is in progress.
  bool get isLoading => _isLoading;

  /// True if reactive auto-refresh via [watch()] is active.
  bool get autoRefresh => _autoRefresh;

  /// Creates a [CollectionProvider].
  ///
  /// [database] is the open [KmdbDatabase].
  /// [collectionName] is the namespace to browse.
  /// [errorProvider] receives any operation errors.
  /// [initialScanOptions] configures the initial filter/order/limit.
  /// [autoRefresh] defaults to true; pass false to start in manual-refresh mode.
  CollectionProvider(
    this._database,
    this._collectionName,
    this._errorProvider, {
    ScanOptions initialScanOptions = const ScanOptions(limit: 25),
    bool autoRefresh = true,
  }) : _scanOptions = initialScanOptions,
       _autoRefresh = autoRefresh {
    if (_autoRefresh) {
      _startWatching();
    } else {
      loadDocuments();
    }
  }

  // ── Query controls ───────────────────────────────────────────────────────────

  /// Replaces the current [ScanOptions] and reloads.
  ///
  /// Resets the [watch] subscription when [autoRefresh] is enabled so that
  /// the new query drives the reactive stream.
  void setScanOptions(ScanOptions options) {
    if (_scanOptions == options) return;
    _scanOptions = options;
    if (_autoRefresh) {
      _restartWatching();
    } else {
      loadDocuments();
    }
  }

  /// Sets a simple text filter and reloads.
  ///
  /// This convenience method preserves all other [ScanOptions] fields.
  void setQuery(String query) {
    final text = query.isEmpty ? null : query;
    setScanOptions(
      _scanOptions.copyWith(filterText: text, clearFilterText: text == null),
    );
  }

  /// Sets the display limit and reloads.
  ///
  /// Pass -1 for no limit.
  void setDisplayLimit(int limit) {
    setScanOptions(
      _scanOptions.copyWith(
        limit: limit == -1 ? null : limit,
        clearLimit: limit == -1,
      ),
    );
  }

  // ── Auto-refresh toggle ──────────────────────────────────────────────────────

  /// Enables or disables reactive auto-refresh.
  ///
  /// When switching to true, a new [watch()] subscription is started.
  /// When switching to false, the subscription is cancelled and a one-shot
  /// [loadDocuments] is issued to bring the list up to date.
  void setAutoRefresh(bool value) {
    if (_autoRefresh == value) return;
    _autoRefresh = value;
    if (_autoRefresh) {
      _startWatching();
    } else {
      _stopWatching();
      loadDocuments();
    }
    notifyListeners();
  }

  // ── Document mutations ───────────────────────────────────────────────────────

  /// Inserts [jsonContent] as a new document in the collection.
  ///
  /// The document is assigned a new UUIDv7 key. Any error is forwarded to
  /// [ErrorProvider] rather than being silently injected into the document
  /// list.
  Future<void> addDocument(String jsonContent) async {
    try {
      final decoded = json.decode(jsonContent);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Input must be a JSON object.');
      }
      final col = _database.rawCollection(_collectionName);
      await col.insert(decoded);
      // When autoRefresh is off, reload manually so the new doc is visible.
      if (!_autoRefresh) await loadDocuments();
    } catch (e) {
      _errorProvider.show('Failed to add document: $e');
    }
  }

  /// Updates the document with [id] using [jsonContent] as the new body.
  ///
  /// The `_id` field is always preserved from [id] regardless of what
  /// [jsonContent] contains. Errors are forwarded to [ErrorProvider].
  Future<void> updateDocument(String id, String jsonContent) async {
    try {
      final decoded = json.decode(jsonContent);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Input must be a JSON object.');
      }
      decoded['_id'] = id;
      final col = _database.rawCollection(_collectionName);
      await col.put(decoded);
      if (!_autoRefresh) await loadDocuments();
    } catch (e) {
      _errorProvider.show('Failed to update document: $e');
    }
  }

  /// Returns the document with [id], or null if it does not exist.
  ///
  /// Errors (including malformed keys) are forwarded to [ErrorProvider].
  Future<Map<String, dynamic>?> getDocumentById(String id) async {
    try {
      final col = _database.rawCollection(_collectionName);
      return await col.get(id);
    } catch (e) {
      _errorProvider.show('Failed to get document: $e');
      return null;
    }
  }

  /// Deletes the document with [id] from the collection.
  ///
  /// Any error is forwarded to [ErrorProvider].
  Future<void> deleteDocument(String id) async {
    try {
      final col = _database.rawCollection(_collectionName);
      await col.delete(id);
      if (!_autoRefresh) await loadDocuments();
    } catch (e) {
      _errorProvider.show('Failed to delete document: $e');
    }
  }

  // ── Manual load ──────────────────────────────────────────────────────────────

  /// Executes the current [scanOptions] against the server and updates the
  /// document list.
  ///
  /// Called automatically when [autoRefresh] is false (or on construction when
  /// false). Callers may also call this to force a refresh in manual mode.
  Future<void> loadDocuments() async {
    if (_disposed) return;
    _isLoading = true;
    notifyListeners();

    try {
      final col = _database.rawCollection(_collectionName);
      final results = await _buildQuery(col).get();
      _documents
        ..clear()
        ..addAll(results);
      // Fetch total count independently so pagination knows the full set size.
      _totalCount = await col.all().count();
    } catch (e) {
      _errorProvider.show('Failed to load documents: $e');
    } finally {
      _isLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  // ── Internal helpers ─────────────────────────────────────────────────────────

  /// Builds a [KmdbQuery] from the current [_scanOptions].
  KmdbQuery<Map<String, dynamic>> _buildQuery(
    KmdbCollection<Map<String, dynamic>> col,
  ) {
    var query = col.all();

    // Apply text filter: a simple contains() check across the whole document
    // string representation is used as a broad approximation until Phase 1
    // adds a structured filter UI.
    final text = _scanOptions.filterText;
    if (text != null && text.isNotEmpty) {
      // The filter is applied in memory by KmdbQuery since there is no
      // single-field target; we build an OR across every string field.
      // For the Phase 0 scope this replicates the previous behaviour while
      // wiring through the query layer.
      query = query.where(_TextAnywhereFilter(text));
    }

    // Apply ordering.
    final orderBy = _scanOptions.orderByField;
    if (orderBy != null) {
      query = query.orderBy(orderBy, descending: _scanOptions.descending);
    }

    // Apply limit and offset.
    final limit = _scanOptions.limit;
    if (limit != null) {
      query = query.limit(limit);
    }
    if (_scanOptions.offset > 0) {
      query = query.offset(_scanOptions.offset);
    }

    return query;
  }

  /// Subscribes to [KmdbQuery.watch] so the list reacts to writes automatically.
  void _startWatching() {
    _stopWatching();
    final col = _database.rawCollection(_collectionName);
    final stream = _buildQuery(col).watch();
    _watchSubscription = stream.listen(
      (docs) {
        _documents
          ..clear()
          ..addAll(docs);
        // Refresh the total count whenever the list changes.
        col
            .all()
            .count()
            .then((c) {
              if (!_disposed) {
                _totalCount = c;
                notifyListeners();
              }
            })
            .catchError((Object e) {
              // Non-fatal — list already updated.
              debugPrint('count refresh error: $e');
            });
        notifyListeners();
      },
      onError: (Object e) {
        _errorProvider.show('Document stream error: $e');
      },
    );
  }

  /// Cancels any active [watch] subscription.
  void _stopWatching() {
    _watchSubscription?.cancel();
    _watchSubscription = null;
  }

  /// Cancels and restarts the [watch] subscription (used after option changes).
  void _restartWatching() {
    _stopWatching();
    _startWatching();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopWatching();
    super.dispose();
  }
}

// ── Private filter ───────────────────────────────────────────────────────────

/// A [Filter] that matches documents whose full string representation contains
/// [_text] (case-insensitive).
///
/// This replicates the previous `CollectionProvider` in-memory filter
/// behaviour while operating through the query layer. Phase 1 will replace
/// this with a structured field-level filter.
final class _TextAnywhereFilter extends Filter {
  final String _text;

  const _TextAnywhereFilter(this._text);

  @override
  bool evaluate(Map<String, dynamic> document) {
    return document.toString().toLowerCase().contains(_text.toLowerCase());
  }
}
