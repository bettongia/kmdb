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
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_ui/collection_provider.dart';

class MockKvStore extends Mock implements KvStore {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  late MockKvStore mockStore;
  late String collectionName;

  setUp(() {
    mockStore = MockKvStore();
    collectionName = 'test_collection';

    // Default mock for scan to return empty stream
    when(
      () => mockStore.scan(
        any(),
        startKey: any(named: 'startKey'),
        endKey: any(named: 'endKey'),
      ),
    ).thenAnswer((_) => Stream.empty());
  });

  group('CollectionProvider', () {
    test('initialization loads documents', () async {
      final docs = [
        {'id': 1, 'name': 'Doc 1'},
        {'id': 2, 'name': 'Doc 2'},
      ];

      final entries = docs
          .map((d) => (key: 'key', value: ValueCodec.encode(d)))
          .toList();
      when(
        () => mockStore.scan(
          collectionName,
          startKey: any(named: 'startKey'),
          endKey: any(named: 'endKey'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(entries));

      final provider = CollectionProvider(mockStore, collectionName);

      // Wait for async loading in constructor
      await Future.delayed(Duration.zero);

      expect(provider.documents.length, equals(2));
      expect(provider.documents[0]['name'], equals('Doc 1'));
      expect(provider.totalCount, equals(2));
    });

    test('setting query filters documents', () async {
      final docs = [
        {'id': 1, 'name': 'Apple'},
        {'id': 2, 'name': 'Banana'},
        {'id': 3, 'name': 'Cherry'},
      ];

      final entries = docs
          .map((d) => (key: 'key', value: ValueCodec.encode(d)))
          .toList();
      when(
        () => mockStore.scan(
          collectionName,
          startKey: any(named: 'startKey'),
          endKey: any(named: 'endKey'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(entries));

      final provider = CollectionProvider(mockStore, collectionName);
      await Future.delayed(Duration.zero);

      expect(provider.documents.length, equals(3));

      provider.setQuery('an');
      await Future.delayed(Duration.zero);

      // 'Banana' contains 'an'
      expect(provider.documents.length, equals(1));
      expect(provider.documents[0]['name'], equals('Banana'));
    });

    test('addDocument adds to store and reloads', () async {
      when(
        () => mockStore.scan(
          collectionName,
          startKey: any(named: 'startKey'),
          endKey: any(named: 'endKey'),
        ),
      ).thenAnswer((_) => Stream.empty());
      when(
        () => mockStore.put(any(), any(), any()),
      ).thenAnswer((_) => Future.value());

      final provider = CollectionProvider(mockStore, collectionName);
      await Future.delayed(Duration.zero);

      const jsonDoc = '{"title": "New Doc"}';

      // Setup mock to return the new doc on next scan
      final newDoc = {'title': 'New Doc', '_id': 'generated_id'};
      final entry = (key: 'generated_id', value: ValueCodec.encode(newDoc));
      when(
        () => mockStore.scan(
          collectionName,
          startKey: any(named: 'startKey'),
          endKey: any(named: 'endKey'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([entry]));

      await provider.addDocument(jsonDoc);

      verify(() => mockStore.put(collectionName, any(), any())).called(1);
      expect(provider.documents.length, equals(1));
      expect(provider.documents[0]['title'], equals('New Doc'));
    });

    test('handles invalid JSON in addDocument', () async {
      final provider = CollectionProvider(mockStore, collectionName);
      await Future.delayed(Duration.zero);

      await provider.addDocument('invalid-json');

      expect(provider.documents.any((d) => d.containsKey('error')), isTrue);
    });

    test('deleteDocument removes from store and reloads', () async {
      final doc = {'_id': 'key1', 'name': 'Doc to delete'};
      final entry = (key: 'key1', value: ValueCodec.encode(doc));

      when(
        () => mockStore.scan(
          collectionName,
          startKey: any(named: 'startKey'),
          endKey: any(named: 'endKey'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([entry]));
      when(
        () => mockStore.delete(any(), any()),
      ).thenAnswer((_) => Future.value());

      final provider = CollectionProvider(mockStore, collectionName);
      await Future.delayed(Duration.zero);
      expect(provider.documents.length, equals(1));

      // Setup mock to return empty on next scan after delete
      when(
        () => mockStore.scan(
          collectionName,
          startKey: any(named: 'startKey'),
          endKey: any(named: 'endKey'),
        ),
      ).thenAnswer((_) => Stream.empty());

      await provider.deleteDocument('key1');

      verify(() => mockStore.delete(collectionName, 'key1')).called(1);
      expect(provider.documents.length, equals(0));
    });
  });
}
