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

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/wal/wal_record.dart';
import 'package:test/test.dart';

const _dbDir = '/db';
const _deviceId = 'testdev1';

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _deviceId,
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

String _key(int n) => SequentialKeyGenerator(start: n).next();

String _activeWalPath(MemoryStorageAdapter adapter) {
  final wals = adapter.files.keys.where((k) => k.endsWith('.log')).toList()
    ..sort();
  return wals.last;
}

/// Returns every WAL file path under [adapter], sorted by name.
List<String> _allWalPaths(MemoryStorageAdapter adapter) {
  final wals = adapter.files.keys.where((k) => k.endsWith('.log')).toList()
    ..sort();
  return wals;
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('H2 — WriteBatch wire format', () {
    test(
      'multi-entry writeBatch produces a single batch frame on disk',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);

        final batch = WriteBatch()
          ..put('tasks', _key(1), _bytes('a'))
          ..put('tasks', _key(2), _bytes('b'))
          ..put('tasks', _key(3), _bytes('c'));
        await store.writeBatch(batch);

        // Walk every WAL file and confirm at least one batch frame is present.
        // The user batch is folded with gen-counter + namespace-registry +
        // dirty-flag writes into a single frame.
        final wals = _allWalPaths(adapter);
        var sawBatchFrame = false;
        for (final p in wals) {
          final bytes = adapter.files[p]!;
          var pos = 0;
          while (pos < bytes.length) {
            if (bytes.length - pos < 9) break;
            final type = bytes[pos + 8];
            if (type == WalRecordType.batch.byte) {
              sawBatchFrame = true;
              final decoded = WalBatchFrame.tryDecode(bytes, pos)!;
              pos += decoded.$2;
            } else {
              final decoded = WalRecord.tryDecode(bytes, pos)!;
              pos += decoded.$2;
            }
          }
        }
        expect(
          sawBatchFrame,
          isTrue,
          reason: 'multi-entry batch should land as a single WAL batch frame',
        );

        await store.close();
      },
    );

    test(
      'single put folds document + meta writes into one batch frame',
      () async {
        // After D2, a single put() is no longer one isolated WAL record:
        // the document write, the dirty-flag set, the gen-counter bump, and the
        // namespace registration are folded into one atomic batch frame.
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);

        await store.put('tasks', _key(1), _bytes('v'));

        final walPath = _activeWalPath(adapter);
        final bytes = adapter.files[walPath]!;
        // The first record at offset 0 must be a batch frame.
        expect(bytes[8], equals(WalRecordType.batch.byte));
        final decoded = WalBatchFrame.tryDecode(bytes, 0);
        expect(decoded, isNotNull);
        // The frame should carry the document write and at least one meta write
        // (dirty flag), and the gen-counter and namespace-registry puts.
        expect(decoded!.$1.records.length, greaterThanOrEqualTo(2));
        // At least one record must be in $meta — confirming the fold landed.
        final hasMeta = decoded.$1.records.any((r) => r.namespace == r'$meta');
        expect(
          hasMeta,
          isTrue,
          reason:
              'meta writes (dirty/gen/namespace) must land in the same frame',
        );

        await store.close();
      },
    );
  });

  group('H2 — crash all-or-nothing', () {
    test('truncated batch frame: NONE of the batch is recovered', () async {
      // Write a multi-entry batch, then truncate the WAL so the trailing batch
      // frame's checksum cannot verify. Recovery must drop the whole frame.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);

      final batch = WriteBatch()
        ..put('tasks', _key(1), _bytes('alpha'))
        ..put('tasks', _key(2), _bytes('beta'))
        ..put('tasks', _key(3), _bytes('gamma'));
      await store.writeBatch(batch);

      MemoryStorageAdapter.releaseAllLocks();

      // Truncate the last 5 bytes of the active WAL — guaranteed to break the
      // checksum of the trailing batch frame.
      final walPath = _activeWalPath(adapter);
      final original = adapter.files[walPath]!;
      adapter.files[walPath] = Uint8List.sublistView(
        original,
        0,
        original.length - 5,
      );

      final (store2, result) = await _open(adapter);
      expect(result.hadInterruptedWrites, isTrue);
      // ALL three keys must be absent — never a prefix.
      expect(
        await store2.get('tasks', _key(1)),
        isNull,
        reason: 'truncated batch must drop every entry, not a prefix',
      );
      expect(await store2.get('tasks', _key(2)), isNull);
      expect(await store2.get('tasks', _key(3)), isNull);
      await store2.close();
    });

    test('intact batch frame: ALL of the batch is recovered', () async {
      // The mirror of the previous test — confirm that without truncation, the
      // batch round-trips correctly.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);

      final batch = WriteBatch()
        ..put('tasks', _key(1), _bytes('alpha'))
        ..put('tasks', _key(2), _bytes('beta'))
        ..put('tasks', _key(3), _bytes('gamma'));
      await store.writeBatch(batch);

      MemoryStorageAdapter.releaseAllLocks();

      final (store2, _) = await _open(adapter);
      expect(await store2.get('tasks', _key(1)), equals(_bytes('alpha')));
      expect(await store2.get('tasks', _key(2)), equals(_bytes('beta')));
      expect(await store2.get('tasks', _key(3)), equals(_bytes('gamma')));
      await store2.close();
    });

    test('document + index entries survive together or not at all', () async {
      // The case the spec promises: a doc + its `$index:` entries must never
      // be observed split across a crash. We simulate the Query-layer write
      // pattern by sending both in one batch through writeBatchInternal (the
      // internal API the Query Layer uses), then truncate and confirm both
      // entries are dropped together.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);

      // writeBatchInternal allows $-prefixed entries.
      final batch = WriteBatch()
        ..put('tasks', _key(1), _bytes('doc'))
        ..put(r'$index:tasks:title', _key(2), _bytes('idx'));
      await store.writeBatchInternal(batch);

      MemoryStorageAdapter.releaseAllLocks();

      // Truncate the last 5 bytes of the active WAL.
      final walPath = _activeWalPath(adapter);
      final original = adapter.files[walPath]!;
      adapter.files[walPath] = Uint8List.sublistView(
        original,
        0,
        original.length - 5,
      );

      final (store2, _) = await _open(adapter);
      // Both the document AND its index entry must be absent (never split).
      expect(await store2.get('tasks', _key(1)), isNull);
      expect(await store2.get(r'$index:tasks:title', _key(2)), isNull);
      await store2.close();
    });

    test('meta writes are atomic with the document: dropped together', () async {
      // Confirm D2: the gen-counter bump and namespace registration are in the
      // same frame as the document. After a crash that truncates the frame,
      // none of {document, gen counter, registry entry} should be present —
      // the WAL is dropped whole.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('first'));
      MemoryStorageAdapter.releaseAllLocks();

      // Truncate the WAL to corrupt the single frame containing both the
      // document and its meta writes.
      final walPath = _activeWalPath(adapter);
      final original = adapter.files[walPath]!;
      adapter.files[walPath] = Uint8List.sublistView(
        original,
        0,
        original.length - 5,
      );

      final (store2, _) = await _open(adapter);
      // Document is gone:
      expect(await store2.get('tasks', _key(1)), isNull);
      // Gen counter stayed at 0 (the put never landed atomically):
      expect(await store2.meta.getGenerationCounter('tasks'), equals(0));
      // The namespace was never registered:
      expect(await store2.meta.getNamespaces(), isNot(contains('tasks')));
      await store2.close();
    });
  });

  group('H2 — in-process atomicity', () {
    test(
      'writeEvents only fires after all memtable mutations are visible',
      () async {
        // After the fix, the engine applies all memtable mutations synchronously
        // (no `await` between them) BEFORE emitting any write event. So any
        // subscriber that re-reads in response to a write event must see every
        // entry of the batch — never a prefix.
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);

        const n = 20;
        // Subscribe to write events; on each event, re-read every key in the
        // batch and record which keys are visible. If memtable application were
        // not synchronous-after-fsync, an early event could be observed with a
        // partially-applied batch.
        final observations = <List<bool>>[];
        final sub = store.writeEvents.listen((ns) {
          if (ns != 'tasks') return;
          // Read synchronously inside the event handler — but get() is async, so
          // we await each. Even with awaits, every memtable mutation has already
          // landed before the event fired, so all 20 keys must be present.
          Future.microtask(() async {
            final present = <bool>[];
            for (var i = 0; i < n; i++) {
              present.add(await store.get('tasks', _key(i)) != null);
            }
            observations.add(present);
          });
        });

        final batch = WriteBatch();
        for (var i = 0; i < n; i++) {
          batch.put('tasks', _key(i), _bytes('v$i'));
        }
        await store.writeBatch(batch);
        // Give microtasks a chance to drain.
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(observations, isNotEmpty);
        for (final present in observations) {
          expect(
            present.every((p) => p),
            isTrue,
            reason:
                'event subscriber observed partial batch: $present — the batch '
                'must be fully visible by the time writeEvents fires',
          );
        }

        await store.close();
      },
    );
  });

  group('H2 — meta fold (D2)', () {
    test('gen counter advances atomically with document writes', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);

      final gen0 = await store.meta.getGenerationCounter('tasks');
      await store.put('tasks', _key(1), _bytes('v1'));
      final gen1 = await store.meta.getGenerationCounter('tasks');
      await store.put('tasks', _key(2), _bytes('v2'));
      final gen2 = await store.meta.getGenerationCounter('tasks');

      expect(gen1, equals(gen0 + 1));
      expect(gen2, equals(gen1 + 1));

      await store.close();
    });

    test(
      'namespace is registered atomically with first document write',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);

        final namespacesBefore = await store.meta.getNamespaces();
        expect(namespacesBefore, isNot(contains('tasks')));

        await store.put('tasks', _key(1), _bytes('v'));

        final namespacesAfter = await store.meta.getNamespaces();
        expect(namespacesAfter, contains('tasks'));

        await store.close();
      },
    );

    test(
      'dirty-open flag is set on first write and cleared on close',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, openResult) = await _open(adapter);
        expect(openResult.hadUnclosedSession, isFalse);

        await store.put('tasks', _key(1), _bytes('v'));
        // The flag should now be set in $meta.
        expect(await store.meta.getDirtyFlag(), isTrue);

        await store.close();
        // After clean close the flag is cleared.
        final (store2, openResult2) = await _open(adapter);
        expect(openResult2.hadUnclosedSession, isFalse);
        await store2.close();
      },
    );

    test(
      'first-write crash leaves dirty flag set (folded with document)',
      () async {
        // Folding the dirty flag into the same frame as the first document
        // write guarantees that if the very first write crashes mid-frame, the
        // entire frame (flag + document) is dropped; if it survives, both land.
        // Either way, on next open hadUnclosedSession reflects reality.
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        await store.put('tasks', _key(1), _bytes('v'));
        MemoryStorageAdapter.releaseAllLocks();

        final (store2, openResult2) = await _open(adapter);
        // The clean-write case: flag is set, hadUnclosedSession is true.
        expect(openResult2.hadUnclosedSession, isTrue);
        await store2.close();
      },
    );
  });

  group('H2 — back-compat', () {
    test('legacy individual put records still replay', () async {
      // Build a WAL containing a legacy individual put record (the format
      // older builds wrote before H2) and confirm crash recovery still
      // replays it correctly.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      // Write a put so a WAL file is actually created on disk.
      await store.put('seed_ns', _key(0), _bytes('seed'));
      MemoryStorageAdapter.releaseAllLocks();

      // Append a hand-crafted legacy WalRecord to the active WAL.
      final activeWal = _activeWalPath(adapter);
      const keyHex = '00000000000070008000000000000001';
      final keyBytes = KeyCodec.keyToBytes(keyHex);
      final legacy = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(99_999_000, 1),
        namespace: 'legacy_ns',
        key: keyBytes,
        value: _bytes('legacy-value'),
      );
      final legacyBytes = legacy.encode();
      final existing = adapter.files[activeWal]!;
      final combined = Uint8List(existing.length + legacyBytes.length)
        ..setAll(0, existing)
        ..setAll(existing.length, legacyBytes);
      adapter.files[activeWal] = combined;

      final (store2, _) = await _open(adapter);
      expect(
        await store2.get('legacy_ns', keyHex),
        equals(_bytes('legacy-value')),
        reason: 'legacy individual records must still replay (back-compat)',
      );
      // The original batch-framed put must also still be present.
      expect(await store2.get('seed_ns', _key(0)), equals(_bytes('seed')));
      await store2.close();
    });

    test('mixed legacy records + new batch frames replay correctly', () async {
      // A WAL with a batch frame (from the new write path) followed by a
      // legacy record (simulating a mid-upgrade WAL state) must replay both.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      // First do a normal put (lands as a batch frame).
      await store.put('ns', _key(1), _bytes('from-batch'));
      MemoryStorageAdapter.releaseAllLocks();

      // Append a legacy individual put record to the same WAL.
      final activeWal = _activeWalPath(adapter);
      const keyHex = '00000000000070008000000000000002';
      final keyBytes = KeyCodec.keyToBytes(keyHex);
      final legacy = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(99_999_001, 0),
        namespace: 'ns',
        key: keyBytes,
        value: _bytes('from-legacy'),
      );
      final legacyBytes = legacy.encode();
      final existing = adapter.files[activeWal]!;
      final combined = Uint8List(existing.length + legacyBytes.length)
        ..setAll(0, existing)
        ..setAll(existing.length, legacyBytes);
      adapter.files[activeWal] = combined;

      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns', _key(1)), equals(_bytes('from-batch')));
      expect(await store2.get('ns', keyHex), equals(_bytes('from-legacy')));
      await store2.close();
    });
  });
}
