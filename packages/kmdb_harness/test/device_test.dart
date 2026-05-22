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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

// Valid UUIDv7 hex keys for use in tests.
// Layout: 12 timestamp + '7' + 3 rand + '8' + 15 rand = 32 chars.
const _key1 = '0190000000007000800000000000aa01';

Action _action({
  required int id,
  required ActionType type,
  String? key,
  String? collectionName,
  Map<String, dynamic>? document,
  bool? partitioned,
}) => Action(
  id: id,
  deviceId: 0,
  type: type,
  key: key,
  collectionName: collectionName,
  document: document,
  partitioned: partitioned,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late ReconciliationAgent reconciler;
  late Device device;

  setUp(() {
    MemoryStorageAdapter.releaseAllLocks();
    reconciler = ReconciliationAgent(deviceCount: 1);
    device = Device(
      deviceIndex: 0,
      syncAdapter: MemorySyncAdapter(),
      reconciler: reconciler,
      dbPath: 'device_test_db',
    );
  });

  tearDown(() async {
    await device.close();
    MemoryStorageAdapter.releaseAllLocks();
  });

  group('Device FSM — initial state', () {
    test('starts in uninitialised state', () {
      expect(device.state, equals(DeviceState.uninitialised));
    });

    test('deviceId is 8 hex chars', () {
      expect(device.deviceId, matches(RegExp(r'^[0-9a-f]{8}$')));
    });
  });

  group('Device FSM — createDb', () {
    test('transitions uninitialised → initialised', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      expect(device.state, equals(DeviceState.initialised));
    });

    test('result is not a no-op', () async {
      final result = await device.execute(
        _action(id: 1, type: ActionType.createDb),
      );
      expect(result.isNoOp, isFalse);
      expect(result.type, equals(ActionType.createDb));
    });

    test('second createDb is a no-op (already initialised)', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      final result = await device.execute(
        _action(id: 2, type: ActionType.createDb),
      );
      expect(result.isNoOp, isTrue);
      expect(device.state, equals(DeviceState.initialised));
    });
  });

  group('Device FSM — createCollection', () {
    test('createCollection before createDb is a no-op', () async {
      final result = await device.execute(
        _action(
          id: 1,
          type: ActionType.createCollection,
          collectionName: 'col',
        ),
      );
      expect(result.isNoOp, isTrue);
      expect(device.state, equals(DeviceState.uninitialised));
    });

    test('transitions initialised → ready', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      await device.execute(
        _action(
          id: 2,
          type: ActionType.createCollection,
          collectionName: 'col',
        ),
      );
      expect(device.state, equals(DeviceState.ready));
    });

    test('duplicate collection name is idempotent', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      await device.execute(
        _action(
          id: 2,
          type: ActionType.createCollection,
          collectionName: 'col',
        ),
      );
      await device.execute(
        _action(
          id: 3,
          type: ActionType.createCollection,
          collectionName: 'col',
        ),
      );
      expect(device.state, equals(DeviceState.ready));
      expect(device.collectionNames, equals(['col']));
    });
  });

  group('Device FSM — actions before ready are no-ops', () {
    test('put before ready is a no-op', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      final result = await device.execute(
        _action(
          id: 2,
          type: ActionType.put,
          collectionName: 'col',
          key: _key1,
          document: {'title': 'x'},
        ),
      );
      expect(result.isNoOp, isTrue);
      expect(reconciler.writeLog, isEmpty);
    });

    test('get before ready is a no-op', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      final result = await device.execute(
        _action(id: 2, type: ActionType.get, collectionName: 'col', key: _key1),
      );
      expect(result.isNoOp, isTrue);
    });

    test('delete before ready is a no-op', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      final result = await device.execute(
        _action(
          id: 2,
          type: ActionType.delete,
          collectionName: 'col',
          key: _key1,
        ),
      );
      expect(result.isNoOp, isTrue);
      expect(reconciler.writeLog, isEmpty);
    });

    test('sync before createDb is a no-op', () async {
      final result = await device.execute(
        _action(id: 1, type: ActionType.sync),
      );
      expect(result.isNoOp, isTrue);
      expect(reconciler.syncLog, isEmpty);
    });
  });

  group('Device — ready state actions', () {
    setUp(() async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      await device.execute(
        _action(
          id: 2,
          type: ActionType.createCollection,
          collectionName: 'col',
        ),
      );
    });

    test('put succeeds and is not a no-op', () async {
      final result = await device.execute(
        _action(
          id: 3,
          type: ActionType.put,
          collectionName: 'col',
          key: _key1,
          document: {'title': 'hello', '_id': _key1},
        ),
      );
      expect(result.isNoOp, isFalse);
      expect(result.type, equals(ActionType.put));
      expect(result.key, equals(_key1));
      expect(reconciler.writeLog, hasLength(1));
      expect(reconciler.writeLog.first.key, equals(_key1));
    });

    test('get after put returns a result', () async {
      await device.execute(
        _action(
          id: 3,
          type: ActionType.put,
          collectionName: 'col',
          key: _key1,
          document: {'title': 'hello', '_id': _key1},
        ),
      );
      final result = await device.execute(
        _action(id: 4, type: ActionType.get, collectionName: 'col', key: _key1),
      );
      expect(result.isNoOp, isFalse);
      expect(result.type, equals(ActionType.get));
    });

    test('delete succeeds and is recorded in write log', () async {
      await device.execute(
        _action(
          id: 3,
          type: ActionType.put,
          collectionName: 'col',
          key: _key1,
          document: {'title': 'x', '_id': _key1},
        ),
      );
      final result = await device.execute(
        _action(
          id: 4,
          type: ActionType.delete,
          collectionName: 'col',
          key: _key1,
        ),
      );
      expect(result.isNoOp, isFalse);
      expect(result.type, equals(ActionType.delete));
      expect(reconciler.writeLog, hasLength(2));
      expect(reconciler.writeLog.last.isDelete, isTrue);
    });

    test('sync completes when no partition is active', () async {
      final result = await device.execute(
        _action(id: 3, type: ActionType.sync),
      );
      expect(result.isNoOp, isFalse);
      expect(result.type, equals(ActionType.sync));
      expect(result.syncCompleted, isTrue);
      expect(reconciler.syncLog, hasLength(1));
      expect(reconciler.syncLog.first.completed, isTrue);
    });

    test('networkPartition activates partition', () async {
      expect(device.isPartitioned, isFalse);
      await device.execute(
        _action(id: 3, type: ActionType.networkPartition, partitioned: true),
      );
      expect(device.isPartitioned, isTrue);
    });

    test('networkPartition restores connectivity', () async {
      await device.execute(
        _action(id: 3, type: ActionType.networkPartition, partitioned: true),
      );
      await device.execute(
        _action(id: 4, type: ActionType.networkPartition, partitioned: false),
      );
      expect(device.isPartitioned, isFalse);
    });

    test('sync with active partition records syncCompleted: false', () async {
      await device.execute(
        _action(id: 3, type: ActionType.networkPartition, partitioned: true),
      );
      final result = await device.execute(
        _action(id: 4, type: ActionType.sync),
      );
      expect(result.type, equals(ActionType.sync));
      expect(result.syncCompleted, isFalse);
      expect(reconciler.syncLog.first.completed, isFalse);
    });
  });

  group('Device — close', () {
    test('close resets state to uninitialised', () async {
      await device.execute(_action(id: 1, type: ActionType.createDb));
      await device.execute(
        _action(id: 2, type: ActionType.createCollection, collectionName: 'c'),
      );
      expect(device.state, equals(DeviceState.ready));
      await device.close();
      expect(device.state, equals(DeviceState.uninitialised));
    });
  });
}
