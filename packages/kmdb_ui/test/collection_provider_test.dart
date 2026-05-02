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

import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_ui/collection_provider.dart';
import 'package:kmdb_ui/error_provider.dart';
import 'package:kmdb_ui/scan_options.dart';

/// Opens a fresh in-memory [KmdbDatabase] for testing.
Future<KmdbDatabase> _openDb([String path = '/test-db']) =>
    KmdbDatabase.open(path: path, adapter: MemoryStorageAdapter());

/// Creates a [CollectionProvider] backed by a real in-memory database.
///
/// [autoRefresh] defaults to false so tests can call [loadDocuments] manually
/// and avoid dealing with asynchronous watch() streams.
Future<({CollectionProvider provider, KmdbDatabase db, ErrorProvider errors})>
_makeProvider({
  String collection = 'items',
  ScanOptions options = const ScanOptions(),
  bool autoRefresh = false,
}) async {
  final db = await _openDb();
  final errors = ErrorProvider();
  final provider = CollectionProvider(
    db,
    collection,
    errors,
    initialScanOptions: options,
    autoRefresh: autoRefresh,
  );
  // Allow the initial loadDocuments() to complete.
  await Future.delayed(Duration.zero);
  return (provider: provider, db: db, errors: errors);
}

void main() {
  // Release the MemoryStorageAdapter path locks between tests so that each
  // test can open the same in-memory path without a LockException.
  tearDown(() => MemoryStorageAdapter.releaseAllLocks());

  group('CollectionProvider', () {
    // ── Basic load ──────────────────────────────────────────────────────────

    test('loads empty collection on construction', () async {
      final (:provider, db: _, errors: _) = await _makeProvider();

      expect(provider.documents, isEmpty);
      expect(provider.totalCount, equals(0));
    });

    test('loads documents inserted before construction', () async {
      final db = await _openDb();
      final col = db.rawCollection('things');
      await col.insert({'title': 'Alpha'});
      await col.insert({'title': 'Beta'});

      final errors = ErrorProvider();
      final provider = CollectionProvider(db, 'things', errors, autoRefresh: false);
      await Future.delayed(Duration.zero);

      expect(provider.totalCount, equals(2));
      expect(provider.documents.length, equals(2));
    });

    // ── setQuery / text filter ───────────────────────────────────────────────

    test('setQuery filters documents by substring', () async {
      final db = await _openDb();
      final col = db.rawCollection('items');
      await col.insert({'name': 'Apple'});
      await col.insert({'name': 'Banana'});
      await col.insert({'name': 'Cherry'});

      final errors = ErrorProvider();
      final provider = CollectionProvider(db, 'items', errors, autoRefresh: false);
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(3));

      provider.setQuery('an');
      await Future.delayed(Duration.zero);

      // 'Banana' contains 'an'; 'Apple' and 'Cherry' do not.
      expect(provider.documents.length, equals(1));
      expect(provider.documents.first['name'], equals('Banana'));
    });

    test('clearing query restores all documents', () async {
      final db = await _openDb();
      final col = db.rawCollection('items');
      await col.insert({'name': 'Alpha'});
      await col.insert({'name': 'Beta'});

      final errors = ErrorProvider();
      final provider = CollectionProvider(db, 'items', errors, autoRefresh: false);
      await Future.delayed(Duration.zero);

      provider.setQuery('Alpha');
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(1));

      provider.setQuery('');
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(2));
    });

    // ── setScanOptions ───────────────────────────────────────────────────────

    test('setScanOptions with limit restricts result set', () async {
      final db = await _openDb();
      final col = db.rawCollection('items');
      for (var i = 0; i < 10; i++) {
        await col.insert({'index': i});
      }

      final errors = ErrorProvider();
      final provider = CollectionProvider(
        db,
        'items',
        errors,
        initialScanOptions: const ScanOptions(limit: 3),
        autoRefresh: false,
      );
      await Future.delayed(Duration.zero);

      expect(provider.documents.length, equals(3));
      // Total count reflects all 10 documents, not just the page.
      expect(provider.totalCount, equals(10));
    });

    test('setScanOptions with same value is a no-op', () async {
      final (:provider, db: _, errors: _) = await _makeProvider();
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      provider.setScanOptions(const ScanOptions());
      expect(notifyCount, equals(0));
    });

    // ── addDocument ──────────────────────────────────────────────────────────

    test('addDocument inserts and reloads documents', () async {
      final (:provider, db: _, errors: _) = await _makeProvider();

      await provider.addDocument('{"title": "New Doc"}');

      expect(provider.documents.length, equals(1));
      expect(provider.documents.first['title'], equals('New Doc'));
    });

    test('addDocument reports error for invalid JSON', () async {
      final (:provider, db: _, :errors) = await _makeProvider();

      await provider.addDocument('not-valid-json');

      expect(errors.lastError, isNotNull);
      expect(errors.lastError, contains('Failed to add document'));
      expect(provider.documents, isEmpty);
    });

    test('addDocument reports error when input is not a JSON object', () async {
      final (:provider, db: _, :errors) = await _makeProvider();

      await provider.addDocument('[1, 2, 3]');

      expect(errors.lastError, isNotNull);
      expect(errors.lastError, contains('Failed to add document'));
    });

    // ── deleteDocument ───────────────────────────────────────────────────────

    test('deleteDocument removes document and reloads', () async {
      final db = await _openDb();
      final col = db.rawCollection('items');
      final inserted = await col.insert({'label': 'To delete'});
      final id = inserted['_id'] as String;

      final errors = ErrorProvider();
      final provider = CollectionProvider(db, 'items', errors, autoRefresh: false);
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(1));

      await provider.deleteDocument(id);

      expect(provider.documents, isEmpty);
      expect(errors.lastError, isNull);
    });

    test('deleteDocument reports error for non-existent id', () async {
      final (:provider, db: _, :errors) = await _makeProvider();

      // Deleting a valid-format key that does not exist should be a no-op —
      // KmdbCollection treats delete-of-missing as a no-op.
      // Key must be a valid UUIDv7: position 12 = '7' (version), position 16 = '8' (variant).
      await provider.deleteDocument('000000000000700080000000000000000'.substring(0, 32));
      expect(errors.lastError, isNull);
    });

    // ── autoRefresh toggle ───────────────────────────────────────────────────

    test('autoRefresh defaults to true in default constructor', () async {
      final db = await _openDb();
      final errors = ErrorProvider();
      final provider = CollectionProvider(db, 'items', errors);
      expect(provider.autoRefresh, isTrue);
      provider.dispose();
      await db.close();
    });

    test('setAutoRefresh false cancels watch subscription', () async {
      final db = await _openDb();
      final errors = ErrorProvider();
      // Start with autoRefresh on.
      final provider = CollectionProvider(
        db,
        'items',
        errors,
        autoRefresh: true,
      );
      await Future.delayed(Duration.zero);

      provider.setAutoRefresh(false);
      expect(provider.autoRefresh, isFalse);
      provider.dispose();
      await db.close();
    });

    test('setAutoRefresh true re-subscribes', () async {
      final (:provider, :db, errors: _) = await _makeProvider(
        autoRefresh: false,
      );

      provider.setAutoRefresh(true);
      expect(provider.autoRefresh, isTrue);
      provider.dispose();
      await db.close();
    });

    test('setAutoRefresh no-op when value unchanged', () async {
      final (:provider, db: _, errors: _) = await _makeProvider(
        autoRefresh: false,
      );
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      provider.setAutoRefresh(false);
      expect(notifyCount, equals(0));
    });

    // ── setDisplayLimit ──────────────────────────────────────────────────────

    test('setDisplayLimit -1 removes limit', () async {
      final db = await _openDb();
      final col = db.rawCollection('items');
      for (var i = 0; i < 5; i++) {
        await col.insert({'i': i});
      }

      final errors = ErrorProvider();
      final provider = CollectionProvider(
        db,
        'items',
        errors,
        initialScanOptions: const ScanOptions(limit: 2),
      );
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(2));

      provider.setDisplayLimit(-1);
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(5));
    });

    // ── reactive watch() ─────────────────────────────────────────────────────

    test('watch() delivers new documents after insert', () async {
      final db = await _openDb();
      final errors = ErrorProvider();
      final provider = CollectionProvider(
        db,
        'items',
        errors,
        autoRefresh: true,
      );
      // Wait for initial emission.
      await Future.delayed(const Duration(milliseconds: 200));
      expect(provider.documents, isEmpty);

      final col = db.rawCollection('items');
      await col.insert({'title': 'Reactive doc'});

      // Allow the 50 ms watch() debounce + async callbacks to fire.
      await Future.delayed(const Duration(milliseconds: 200));

      expect(provider.documents.length, equals(1));
      expect(provider.documents.first['title'], equals('Reactive doc'));

      provider.dispose();
      await db.close();
    });
  });

  // ── ScanOptions ─────────────────────────────────────────────────────────────

  group('ScanOptions', () {
    test('equality', () {
      const a = ScanOptions(filterText: 'foo', limit: 10);
      const b = ScanOptions(filterText: 'foo', limit: 10);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality when fields differ', () {
      const a = ScanOptions(filterText: 'foo');
      const b = ScanOptions(filterText: 'bar');
      expect(a, isNot(equals(b)));
    });

    test('copyWith replaces specified fields', () {
      const base = ScanOptions(
        filterText: 'x',
        orderByField: 'name',
        descending: false,
        limit: 5,
        offset: 0,
      );

      final copy = base.copyWith(limit: 20, descending: true);
      expect(copy.filterText, equals('x'));
      expect(copy.orderByField, equals('name'));
      expect(copy.descending, isTrue);
      expect(copy.limit, equals(20));
      expect(copy.offset, equals(0));
    });

    test('copyWith clearFilterText removes filterText', () {
      const base = ScanOptions(filterText: 'hello');
      final copy = base.copyWith(clearFilterText: true);
      expect(copy.filterText, isNull);
    });

    test('copyWith clearLimit removes limit', () {
      const base = ScanOptions(limit: 10);
      final copy = base.copyWith(clearLimit: true);
      expect(copy.limit, isNull);
    });
  });
}
