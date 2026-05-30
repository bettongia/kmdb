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

/// Tests for real UTF-8 namespace encoding (plan M2).
library;

// Covers the requirements from the plan:
///
/// - Round-trip non-ASCII namespaces (accented Latin, CJK, emoji/astral)
///   through put → get → scan → delete at every layer (KeyCodec, WalRecord,
///   LsmEngine scan prefixes, and KvStore public boundary).
/// - ASCII byte-identity: utf8.encode(ns) must equal codeUnits(ns) for all
///   pure-ASCII namespaces (no migration required for existing databases).
/// - NFC normalisation: the same logical name in NFC vs NFD resolves to one
///   namespace.
/// - 255-byte UTF-8 length limit: a namespace that exceeds 255 UTF-8 bytes
///   throws a clear ArgumentError; one just under (255 bytes) succeeds.
/// - WAL round-trip: namespace strings survive encode → tryDecode at the
///   WalRecord and WalBatchFrame level.
/// - KvStore integration: put/get/scan/delete with non-ASCII namespaces
///   round-trip correctly end-to-end.
///
/// Reactivity and secondary-index tests live in the query-layer test
/// (namespace_encoding_query_test.dart) because they require KmdbDatabase.

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/util/namespace_codec.dart';
import 'package:kmdb/src/engine/wal/wal_record.dart';
import 'package:test/test.dart';

// ── Helpers ────────────────────────────────────────────────────────────────────

const _dbDir = '/utf8ns_test';
const _deviceId = 'testdev1';

MemoryStorageAdapter _newAdapter() => MemoryStorageAdapter();

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _deviceId,
    );

/// A valid UUIDv7 key for test use.
const _hexKey = 'aaaaaaaaaaaa7aa8aaaaaaaaaaaaaaaa';
String _key(int n) => SequentialKeyGenerator(start: n).next();
Uint8List _value(String s) => Uint8List.fromList(utf8.encode(s));

// Pairs of (NFC form, NFD form) for the same logical name.
// NFC: precomposed U+00E9 (é)
// NFD: U+0065 (e) + U+0301 (combining acute accent)
const _nfcCafe = 'café'; // NFC é (U+00E9)
// ignore: invalid_unicode_escape_sequences
final _nfdCafe = 'café'; // NFD: e + combining acute

// ── namespaceToBytes / bytesToNamespace ───────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('namespace_codec — namespaceToBytes / bytesToNamespace', () {
    test('ASCII round-trip matches codeUnits (byte-identity invariant)', () {
      // For ASCII namespaces, utf8.encode must produce byte-identical output to
      // codeUnits. This guarantees that every currently-working (ASCII) database
      // is unchanged by the fix — no migration required.
      const asciiNames = ['tasks', 'contacts', 'my-collection', r'snake_case'];
      for (final ns in asciiNames) {
        final utf8Bytes = namespaceToBytes(ns);
        final codeUnitBytes = Uint8List.fromList(ns.codeUnits);
        expect(utf8Bytes, equals(codeUnitBytes), reason: 'ASCII "$ns" differs');
      }
    });

    test('accented Latin — round-trip UTF-8 encode/decode', () {
      const ns = 'café';
      final encoded = namespaceToBytes(ns);
      // é encodes to 2 bytes in UTF-8 (0xC3 0xA9).
      expect(encoded.length, greaterThan(ns.length));
      final decoded = bytesToNamespace(encoded);
      expect(decoded, equals(ns));
    });

    test('CJK namespace — round-trip UTF-8 encode/decode', () {
      const ns = '联系人'; // "contacts" in simplified Chinese (3 chars, 9 bytes)
      final encoded = namespaceToBytes(ns);
      expect(encoded.length, equals(9)); // each char is 3 bytes in UTF-8
      expect(bytesToNamespace(encoded), equals(ns));
    });

    test('emoji namespace — round-trip UTF-8 encode/decode', () {
      const ns = '🗂️items'; // file cabinet + "items"
      final encoded = namespaceToBytes(ns);
      expect(bytesToNamespace(encoded), equals(unormNfc(ns)));
    });

    test('NFC normalisation: NFC and NFD inputs produce identical bytes', () {
      final nfcBytes = namespaceToBytes(_nfcCafe);
      final nfdBytes = namespaceToBytes(_nfdCafe);
      expect(
        nfcBytes,
        equals(nfdBytes),
        reason: 'NFC and NFD forms must produce the same bytes',
      );
    });

    test('normaliseNamespace: NFD input is returned as NFC', () {
      final result = normaliseNamespace(_nfdCafe);
      expect(result, equals(_nfcCafe));
    });

    test('length limit — 255 UTF-8 bytes succeeds', () {
      // Build a namespace that is exactly 255 bytes in UTF-8.
      // 85 × 'é' (2 bytes each) + 85 × 'a' (1 byte each) = 170 + 85 = 255.
      final ns = '${'é' * 85}${'a' * 85}';
      final bytes = namespaceToBytes(ns);
      expect(bytes.length, equals(255));
    });

    test('length limit — 256 UTF-8 bytes throws ArgumentError', () {
      // Build a namespace that is exactly 256 bytes in UTF-8.
      // 85 × 'é' (2 bytes) + 86 × 'a' (1 byte) = 170 + 86 = 256.
      final ns = '${'é' * 85}${'a' * 86}';
      expect(
        () => namespaceToBytes(ns),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('256'),
          ),
        ),
      );
    });

    test('length limit error message names the namespace and byte length', () {
      final longNs = 'x' * 256; // pure ASCII, 256 bytes — exceeds limit
      expect(
        () => namespaceToBytes(longNs),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('256'))
              .having(
                (e) => e.message,
                'message',
                contains(kMaxNamespaceBytes.toString()),
              ),
        ),
      );
    });
  });

  // ── KeyCodec ─────────────────────────────────────────────────────────────────

  group('KeyCodec — non-ASCII namespace encoding', () {
    test('encodeNamespace + decodeNamespace round-trip (accented Latin)', () {
      const ns = 'tâches'; // "tasks" in French
      final encoded = KeyCodec.encodeNamespace(ns);
      // First byte is nsLen, then UTF-8 bytes.
      final nsLen = encoded[0];
      final decoded = bytesToNamespace(encoded.sublist(1, 1 + nsLen));
      expect(decoded, equals(ns));
    });

    test('encodeNamespace + decodeNamespace round-trip (CJK)', () {
      const ns = '联系人';
      final encoded = KeyCodec.encodeNamespace(ns);
      final nsLen = encoded[0];
      expect(nsLen, equals(9)); // 3 chars × 3 bytes each
      final decoded = bytesToNamespace(encoded.sublist(1, 1 + nsLen));
      expect(decoded, equals(ns));
    });

    test('encodeInternalKey + decodeNamespace round-trip (non-ASCII)', () {
      const ns = 'données'; // "data" in French
      final keyBytes = KeyCodec.keyToBytes(_hexKey);
      final internalKey = KeyCodec.encodeInternalKey(
        ns,
        keyBytes,
        const Hlc(1000, 0),
        RecordType.put,
      );
      expect(KeyCodec.decodeNamespace(internalKey), equals(ns));
    });

    test('encodeNamespace rejects namespace exceeding 255 UTF-8 bytes', () {
      // 128 × 'é' = 256 UTF-8 bytes (each é is 2 bytes).
      final longNs = 'é' * 128;
      expect(() => KeyCodec.encodeNamespace(longNs), throwsArgumentError);
    });

    test('NFC normalisation is applied before encoding', () {
      // NFD and NFC forms of the same name must produce identical internal keys.
      final keyBytes = KeyCodec.keyToBytes(_hexKey);
      final hlc = const Hlc(1000, 0);
      final nfcKey = KeyCodec.encodeInternalKey(
        _nfcCafe,
        keyBytes,
        hlc,
        RecordType.put,
      );
      final nfdKey = KeyCodec.encodeInternalKey(
        _nfdCafe,
        keyBytes,
        hlc,
        RecordType.put,
      );
      expect(
        nfcKey,
        equals(nfdKey),
        reason:
            'NFC and NFD namespace forms must produce identical internal keys',
      );
    });
  });

  // ── WalRecord ─────────────────────────────────────────────────────────────────

  group('WalRecord — non-ASCII namespace round-trip', () {
    final keyBytes = KeyCodec.keyToBytes(_hexKey);

    test('WalRecord.encode / tryDecode round-trip (accented Latin)', () {
      const ns = 'données';
      final record = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(1000, 0),
        namespace: ns,
        key: keyBytes,
        value: Uint8List.fromList([0x01, 0x02]),
      );
      final bytes = record.encode();
      final result = WalRecord.tryDecode(bytes, 0);
      expect(result, isNotNull);
      expect(result!.$1.namespace, equals(ns));
    });

    test('WalRecord.encode / tryDecode round-trip (CJK)', () {
      const ns = '联系人';
      final record = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(1000, 0),
        namespace: ns,
        key: keyBytes,
        value: Uint8List.fromList([0x01]),
      );
      final bytes = record.encode();
      final result = WalRecord.tryDecode(bytes, 0);
      expect(result, isNotNull);
      expect(result!.$1.namespace, equals(ns));
    });

    test('WalRecord.encode / tryDecode round-trip (emoji)', () {
      const ns = '🗂️items';
      final record = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(2000, 0),
        namespace: ns,
        key: keyBytes,
        value: Uint8List.fromList([0x01]),
      );
      final bytes = record.encode();
      final result = WalRecord.tryDecode(bytes, 0);
      expect(result, isNotNull);
      // NFC normalisation is applied before encoding.
      expect(result!.$1.namespace, equals(unormNfc(ns)));
    });

    test(
      'WalBatchFrame encode / tryDecode round-trip (non-ASCII namespaces)',
      () {
        const ns1 = 'tâches';
        const ns2 = '联系人';
        final r1 = WalRecord(
          type: WalRecordType.put,
          sequence: const Hlc(1000, 0),
          namespace: ns1,
          key: keyBytes,
          value: Uint8List.fromList([0x01]),
        );
        final r2 = WalRecord(
          type: WalRecordType.put,
          sequence: const Hlc(1001, 0),
          namespace: ns2,
          key: keyBytes,
          value: Uint8List.fromList([0x02]),
        );
        final frame = WalBatchFrame([r1, r2]);
        final bytes = frame.encode();
        final result = WalBatchFrame.tryDecode(bytes, 0);
        expect(result, isNotNull);
        final decoded = result!.$1;
        expect(decoded.records.length, equals(2));
        expect(decoded.records[0].namespace, equals(ns1));
        expect(decoded.records[1].namespace, equals(ns2));
      },
    );

    test(
      'NFC/NFD in WalRecord namespace: both decode to the same NFC string',
      () {
        final r1 = WalRecord(
          type: WalRecordType.put,
          sequence: const Hlc(1000, 0),
          namespace: _nfcCafe,
          key: keyBytes,
          value: Uint8List.fromList([0x01]),
        );
        final r2 = WalRecord(
          type: WalRecordType.put,
          sequence: const Hlc(1000, 0),
          namespace: _nfdCafe,
          key: keyBytes,
          value: Uint8List.fromList([0x01]),
        );
        final d1 = WalRecord.tryDecode(r1.encode(), 0)!.$1.namespace;
        final d2 = WalRecord.tryDecode(r2.encode(), 0)!.$1.namespace;
        expect(
          d1,
          equals(d2),
          reason: 'NFC and NFD must decode to the same NFC string',
        );
      },
    );
  });

  // ── KvStoreImpl end-to-end ───────────────────────────────────────────────────

  group('KvStore — non-ASCII namespace end-to-end', () {
    test('put / get round-trip with accented Latin namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const ns = 'tâches';
      await store.put(ns, _key(0), _value('task-value'));
      final result = await store.get(ns, _key(0));
      expect(result, isNotNull);
      expect(utf8.decode(result!), equals('task-value'));
      await store.close();
    });

    test('put / get round-trip with CJK namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const ns = '联系人';
      await store.put(ns, _key(0), _value('contact-value'));
      final result = await store.get(ns, _key(0));
      expect(result, isNotNull);
      expect(utf8.decode(result!), equals('contact-value'));
      await store.close();
    });

    test('scan returns entries under non-ASCII namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const ns = '联系人';
      await store.put(ns, _key(0), _value('v0'));
      await store.put(ns, _key(1), _value('v1'));
      final entries = await store.scan(ns).toList();
      expect(entries.length, equals(2));
      await store.close();
    });

    test('delete removes entry under non-ASCII namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const ns = 'données';
      await store.put(ns, _key(0), _value('v'));
      await store.delete(ns, _key(0));
      expect(await store.get(ns, _key(0)), isNull);
      await store.close();
    });

    test('NFC/NFD namespace inputs resolve to the same namespace', () async {
      // Writing under NFD and reading under NFC (or vice versa) must work.
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      // Write under NFD form.
      await store.put(_nfdCafe, _key(0), _value('value-nfd'));
      // Read under NFC form — must succeed.
      final resultNfc = await store.get(_nfcCafe, _key(0));
      expect(
        resultNfc,
        isNotNull,
        reason: 'NFC lookup must find the NFD-written entry',
      );
      expect(utf8.decode(resultNfc!), equals('value-nfd'));
      // Scan under NFC must also return the entry.
      final scanResults = await store.scan(_nfcCafe).toList();
      expect(scanResults.length, equals(1));
      await store.close();
    });

    test('ASCII namespace behaviour is unchanged (no migration needed)', () async {
      // Pure ASCII namespaces must produce byte-identical keys before and after
      // the fix. We verify by writing ASCII entries, reopening, and reading them
      // back — simulating what existing databases on disk would see.
      final adapter = _newAdapter();
      {
        final (store, _) = await _open(adapter);
        await store.put('contacts', _key(0), _value('alice'));
        await store.put('tasks', _key(1), _value('buy milk'));
        await store.close();
      }
      {
        final (store, _) = await _open(adapter);
        expect(
          utf8.decode((await store.get('contacts', _key(0)))!),
          equals('alice'),
        );
        expect(
          utf8.decode((await store.get('tasks', _key(1)))!),
          equals('buy milk'),
        );
        await store.close();
      }
    });

    test('WAL replay restores entries under non-ASCII namespace', () async {
      // Write entries without flushing, then reopen (which replays the WAL).
      final adapter = _newAdapter();
      {
        final (store, _) = await _open(adapter);
        const ns = '联系人';
        await store.put(ns, _key(0), _value('replayed-value'));
        // Close without flushing to force WAL replay on next open.
        await store.close(flush: false);
      }
      {
        // Reopen: crash-recovery replays the WAL; the non-ASCII namespace must
        // survive the round-trip through WAL encode → WAL decode → memtable.
        final (store, result) = await _open(adapter);
        // The WAL replay may or may not set hadInterruptedWrites depending on
        // the test config — focus on the data being present.
        expect(result, isNotNull);
        const ns = '联系人';
        final value = await store.get(ns, _key(0));
        expect(
          value,
          isNotNull,
          reason: 'WAL-replayed entry must be readable after reopen',
        );
        expect(utf8.decode(value!), equals('replayed-value'));
        await store.close();
      }
    });

    test(
      'namespace length limit at KvStore boundary throws ArgumentError',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);
        // 128 × 'é' = 256 UTF-8 bytes (each é is 2 bytes in UTF-8).
        final longNs = 'é' * 128;
        expect(
          () => store.put(longNs, _key(0), _value('v')),
          throwsA(isA<ArgumentError>()),
        );
        await store.close();
      },
    );

    test('namespace exactly at 255 UTF-8 bytes is accepted', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      // 85 × 'é' (170 bytes) + 85 × 'a' (85 bytes) = 255 bytes total.
      final ns255 = '${'é' * 85}${'a' * 85}';
      expect(utf8.encode(ns255).length, equals(255));
      // Should not throw.
      await expectLater(store.put(ns255, _key(0), _value('v')), completes);
      expect(await store.get(ns255, _key(0)), isNotNull);
      await store.close();
    });

    test('writeBatch normalises namespaces across entries', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      // One entry written under NFD — should be stored under NFC.
      final batch = WriteBatch()..put(_nfdCafe, _key(0), _value('batch-value'));
      await store.writeBatch(batch);
      // Read under NFC form.
      final result = await store.get(_nfcCafe, _key(0));
      expect(result, isNotNull);
      expect(utf8.decode(result!), equals('batch-value'));
      await store.close();
    });

    test('scan prefix is consistent with write prefix (non-ASCII)', () async {
      // This is the critical test: if the write path and the scan prefix builder
      // diverge, scan returns nothing even though the entry exists.
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const ns = '联系人';
      // Write several entries.
      for (var i = 0; i < 5; i++) {
        await store.put(ns, _key(i), _value('v$i'));
      }
      // Also write under a different namespace to confirm no cross-contamination.
      await store.put('contacts', _key(10), _value('other'));

      final results = await store.scan(ns).toList();
      expect(
        results.length,
        equals(5),
        reason: 'scan must return all entries under the non-ASCII namespace',
      );

      final otherResults = await store.scan('contacts').toList();
      expect(
        otherResults.length,
        equals(1),
        reason:
            'ASCII namespace must not be contaminated by non-ASCII namespace',
      );
      await store.close();
    });
  });
}

// ── Private helper ─────────────────────────────────────────────────────────────

/// NFC-normalise a string using the same normaliser as [namespace_codec].
///
/// Used inside tests to produce expected values without importing unorm directly.
String unormNfc(String s) => normaliseNamespace(s);
