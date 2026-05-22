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

import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

ActionResult _putResult({
  required int actionId,
  required int deviceId,
  required String key,
  required String collection,
  required Map<String, dynamic> doc,
  int? hlcEncoded,
}) => ActionResult(
  actionId: actionId,
  deviceId: deviceId,
  type: ActionType.put,
  isNoOp: false,
  key: key,
  collectionName: collection,
  document: doc,
  hlcEncoded: hlcEncoded,
);

ActionResult _deleteResult({
  required int actionId,
  required int deviceId,
  required String key,
  required String collection,
}) => ActionResult(
  actionId: actionId,
  deviceId: deviceId,
  type: ActionType.delete,
  isNoOp: false,
  key: key,
  collectionName: collection,
);

ActionResult _syncResult({
  required int actionId,
  required int deviceId,
  required bool completed,
}) => ActionResult(
  actionId: actionId,
  deviceId: deviceId,
  type: ActionType.sync,
  isNoOp: false,
  syncCompleted: completed,
  syncDirection: 'both',
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late ReconciliationAgent agent;

  setUp(() {
    agent = ReconciliationAgent(deviceCount: 3);
  });

  group('ReconciliationAgent — write log', () {
    test('records a put and advances per-device state', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'key1',
          collection: 'col',
          doc: {'title': 'hello'},
        ),
      );

      expect(agent.writeLog, hasLength(1));
      final state = agent.expectedStateForDevice(0);
      expect(state['col\x00key1'], equals({'title': 'hello'}));
    });

    test('records a delete and advances per-device state', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'key1',
          collection: 'col',
          doc: {'title': 'hello'},
        ),
      );
      agent.record(
        _deleteResult(actionId: 2, deviceId: 0, key: 'key1', collection: 'col'),
      );

      final state = agent.expectedStateForDevice(0);
      expect(state['col\x00key1'], isNull);
    });

    test('no-op results are ignored', () {
      agent.record(
        ActionResult(
          actionId: 1,
          deviceId: 0,
          type: ActionType.noOp,
          isNoOp: true,
        ),
      );
      expect(agent.writeLog, isEmpty);
    });

    test('get results do not affect state', () {
      agent.record(
        ActionResult(
          actionId: 1,
          deviceId: 0,
          type: ActionType.get,
          isNoOp: false,
          key: 'key1',
          collectionName: 'col',
          document: {'title': 'hello'},
        ),
      );
      expect(agent.writeLog, isEmpty);
    });
  });

  group('ReconciliationAgent — LWW in global state', () {
    test('higher HLC wins', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'old'},
          hlcEncoded: 100,
        ),
      );
      agent.record(
        _putResult(
          actionId: 2,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'new'},
          hlcEncoded: 200,
        ),
      );

      final global = agent.globalExpectedState();
      expect(global['col\x00k']!['v'], equals('new'));
    });

    test('lower HLC loses', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'new'},
          hlcEncoded: 200,
        ),
      );
      agent.record(
        _putResult(
          actionId: 2,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'old'},
          hlcEncoded: 100,
        ),
      );

      final global = agent.globalExpectedState();
      expect(global['col\x00k']!['v'], equals('new'));
    });

    test('HLC tie broken by higher deviceId', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'device0'},
          hlcEncoded: 100,
        ),
      );
      agent.record(
        _putResult(
          actionId: 2,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'device1'},
          hlcEncoded: 100,
        ),
      );

      final global = agent.globalExpectedState();
      expect(global['col\x00k']!['v'], equals('device1'));
    });

    test('without HLC falls back to action ID ordering', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'first'},
        ),
      );
      agent.record(
        _putResult(
          actionId: 5,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'later'},
        ),
      );

      final global = agent.globalExpectedState();
      expect(global['col\x00k']!['v'], equals('later'));
    });
  });

  group('ReconciliationAgent — sync log and state propagation', () {
    test('completed sync propagates global state to device', () {
      // Device 1 writes a key.
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'from_device1'},
          hlcEncoded: 200,
        ),
      );

      // Device 0 has not yet received this.
      var state0 = agent.expectedStateForDevice(0);
      expect(state0.containsKey('col\x00k'), isFalse);

      // Device 0 syncs successfully.
      agent.record(_syncResult(actionId: 2, deviceId: 0, completed: true));

      // Now device 0 should have the global state.
      state0 = agent.expectedStateForDevice(0);
      expect(state0['col\x00k']!['v'], equals('from_device1'));
    });

    test('incomplete sync does NOT propagate state', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'from_device1'},
          hlcEncoded: 200,
        ),
      );

      agent.record(_syncResult(actionId: 2, deviceId: 0, completed: false));

      final state0 = agent.expectedStateForDevice(0);
      expect(state0.containsKey('col\x00k'), isFalse);
    });

    test('sync log records direction and sstablesTransferred', () {
      agent.record(
        ActionResult(
          actionId: 10,
          deviceId: 0,
          type: ActionType.sync,
          isNoOp: false,
          syncCompleted: true,
          syncDirection: 'push',
          sstablesTransferred: 3,
        ),
      );

      expect(agent.syncLog, hasLength(1));
      expect(agent.syncLog.first.direction, equals('push'));
      expect(agent.syncLog.first.sstablesTransferred, equals(3));
    });
  });

  group('ReconciliationAgent — fork detection', () {
    test('detects fork when two devices write same key', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'a'},
          hlcEncoded: 100,
        ),
      );
      agent.record(
        _putResult(
          actionId: 2,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'b'},
          hlcEncoded: 200,
        ),
      );

      expect(agent.forkEvents, hasLength(1));
      final fork = agent.forkEvents.first;
      expect(fork.key, equals('k'));
      expect(fork.lwwWinner.deviceId, equals(1)); // higher HLC
    });

    test('no fork for same-device writes', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'first'},
          hlcEncoded: 100,
        ),
      );
      agent.record(
        _putResult(
          actionId: 2,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'second'},
          hlcEncoded: 200,
        ),
      );

      expect(agent.forkEvents, isEmpty);
    });

    test('fork reported via detectedForks is unmodifiable', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'a'},
          hlcEncoded: 100,
        ),
      );
      agent.record(
        _putResult(
          actionId: 2,
          deviceId: 1,
          key: 'k',
          collection: 'col',
          doc: {'v': 'b'},
          hlcEncoded: 200,
        ),
      );

      final forks = agent.detectedForks;
      expect(() => forks.add(forks.first), throwsUnsupportedError);
    });

    test('multiple forks on different keys are all recorded', () {
      for (var k = 0; k < 3; k++) {
        agent.record(
          _putResult(
            actionId: k * 2 + 1,
            deviceId: 0,
            key: 'key$k',
            collection: 'col',
            doc: {'v': 'a'},
            hlcEncoded: 100,
          ),
        );
        agent.record(
          _putResult(
            actionId: k * 2 + 2,
            deviceId: 1,
            key: 'key$k',
            collection: 'col',
            doc: {'v': 'b'},
            hlcEncoded: 200,
          ),
        );
      }
      expect(agent.forkEvents, hasLength(3));
    });
  });

  group('ReconciliationAgent — reset', () {
    test('reset clears all logs and state', () {
      agent.record(
        _putResult(
          actionId: 1,
          deviceId: 0,
          key: 'k',
          collection: 'col',
          doc: {'v': 'a'},
        ),
      );
      agent.record(_syncResult(actionId: 2, deviceId: 0, completed: true));

      agent.reset();

      expect(agent.writeLog, isEmpty);
      expect(agent.syncLog, isEmpty);
      expect(agent.forkEvents, isEmpty);
      expect(agent.expectedStateForDevice(0), isEmpty);
    });
  });

  group('ReconciliationAgent — single-device scenario', () {
    test('single device writes are fully tracked', () {
      for (var i = 1; i <= 5; i++) {
        agent.record(
          _putResult(
            actionId: i,
            deviceId: 0,
            key: 'key$i',
            collection: 'notes',
            doc: {'idx': i},
          ),
        );
      }
      expect(agent.writeLog, hasLength(5));
      final state = agent.expectedStateForDevice(0);
      for (var i = 1; i <= 5; i++) {
        expect(state['notes\x00key$i'], isNotNull);
      }
    });
  });

  group('ReconciliationAgent — hot-key rapid succession', () {
    test('rapid writes to same key from one device keep latest', () {
      // Device 0 writes the same key 10 times.
      for (var i = 1; i <= 10; i++) {
        agent.record(
          _putResult(
            actionId: i,
            deviceId: 0,
            key: 'hot',
            collection: 'col',
            doc: {'seq': i},
            hlcEncoded: i * 10,
          ),
        );
      }
      // No forks since it's all device 0.
      expect(agent.forkEvents, isEmpty);
      // Per-device state should hold the last write's value.
      final state = agent.expectedStateForDevice(0);
      expect(state['col\x00hot']!['seq'], equals(10));
    });

    test('rapid writes to same hot key from two devices produces forks', () {
      for (var i = 1; i <= 5; i++) {
        agent.record(
          _putResult(
            actionId: i * 2 - 1,
            deviceId: 0,
            key: 'hot',
            collection: 'col',
            doc: {'seq': 'd0_$i'},
            hlcEncoded: i,
          ),
        );
        agent.record(
          _putResult(
            actionId: i * 2,
            deviceId: 1,
            key: 'hot',
            collection: 'col',
            doc: {'seq': 'd1_$i'},
            hlcEncoded: i + 1,
          ),
        );
      }
      // One fork per device1 write that follows a device0 write.
      expect(agent.forkEvents.isNotEmpty, isTrue);
      // All LWW winners should be device 1 (higher HLC or tied).
      for (final fork in agent.forkEvents) {
        expect(fork.lwwWinner.deviceId, equals(1));
      }
    });
  });
}
