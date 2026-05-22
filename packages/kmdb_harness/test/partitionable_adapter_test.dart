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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

void main() {
  group('NetworkPartitionException', () {
    test('toString with message', () {
      const e = NetworkPartitionException('test partition');
      expect(e.toString(), contains('NetworkPartitionException'));
      expect(e.toString(), contains('test partition'));
    });

    test('toString without message', () {
      const e = NetworkPartitionException();
      expect(e.toString(), contains('NetworkPartitionException'));
    });
  });

  group('PartitionableAdapter', () {
    late MemorySyncAdapter delegate;
    late PartitionableAdapter adapter;

    setUp(() {
      delegate = MemorySyncAdapter();
      adapter = PartitionableAdapter(delegate);
    });

    test('not partitioned by default', () {
      expect(adapter.isPartitioned, isFalse);
    });

    test('setPartitioned(true) activates partition', () {
      adapter.setPartitioned(true);
      expect(adapter.isPartitioned, isTrue);
    });

    test('setPartitioned(false) restores connectivity', () {
      adapter.setPartitioned(true);
      adapter.setPartitioned(false);
      expect(adapter.isPartitioned, isFalse);
    });

    test('list throws when partitioned', () {
      adapter.setPartitioned(true);
      expect(
        () => adapter.list('sstables/'),
        throwsA(isA<NetworkPartitionException>()),
      );
    });

    test('download throws when partitioned', () {
      adapter.setPartitioned(true);
      expect(
        () => adapter.download('sstables/foo.sst'),
        throwsA(isA<NetworkPartitionException>()),
      );
    });

    test('upload throws when partitioned', () {
      adapter.setPartitioned(true);
      expect(
        () => adapter.upload('sstables/foo.sst', Uint8List(0)),
        throwsA(isA<NetworkPartitionException>()),
      );
    });

    test('delete throws when partitioned', () {
      adapter.setPartitioned(true);
      expect(
        () => adapter.delete('sstables/foo.sst'),
        throwsA(isA<NetworkPartitionException>()),
      );
    });

    test('compareAndSwap throws when partitioned', () {
      adapter.setPartitioned(true);
      expect(
        () => adapter.compareAndSwap('lease.json', Uint8List(0)),
        throwsA(isA<NetworkPartitionException>()),
      );
    });

    test('getEtag throws when partitioned', () {
      adapter.setPartitioned(true);
      expect(
        () => adapter.getEtag('lease.json'),
        throwsA(isA<NetworkPartitionException>()),
      );
    });

    test('delegates list when not partitioned', () async {
      final result = await adapter.list('sstables/');
      expect(result, isA<List<String>>());
    });

    test('delegates upload/download round-trip when not partitioned', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      await adapter.upload('sstables/test.sst', bytes);
      final downloaded = await adapter.download('sstables/test.sst');
      expect(downloaded, equals(bytes));
    });

    test('delegates delete when not partitioned', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      await adapter.upload('sstables/del.sst', bytes);
      await adapter.delete('sstables/del.sst');
      final result = await adapter.download('sstables/del.sst');
      expect(result, isNull);
    });

    test('partition can be toggled multiple times', () async {
      adapter.setPartitioned(true);
      expect(
        () => adapter.list('sstables/'),
        throwsA(isA<NetworkPartitionException>()),
      );

      adapter.setPartitioned(false);
      final result = await adapter.list('sstables/');
      expect(result, isA<List<String>>());

      adapter.setPartitioned(true);
      expect(
        () => adapter.list('sstables/'),
        throwsA(isA<NetworkPartitionException>()),
      );
    });
  });
}
