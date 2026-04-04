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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/memtable/memtable.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';

Uint8List _key(String ns, String hexKey, Hlc hlc, RecordType type) =>
    KeyCodec.encodeInternalKey(ns, KeyCodec.keyToBytes(hexKey), hlc, type);

const _k0 = '00000000000070008000000000000000';
const _kf = 'ffffffffffff7fff8fffffffffffffff';

final _v1 = Uint8List.fromList([0x01]);
final _v2 = Uint8List.fromList([0x02]);
final _empty = Uint8List(0);

void main() {
  group('Memtable.put / get', () {
    test('stores and retrieves a value', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      m.put(k, _v1);
      expect(m.get(k), equals(_v1));
    });

    test('get returns null for absent key', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      expect(m.get(k), isNull);
    });

    test('overwrite updates value, length stays 1', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      m.put(k, _v1);
      m.put(k, _v2);
      expect(m.get(k), equals(_v2));
      expect(m.length, equals(1));
    });
  });

  group('Memtable size tracking', () {
    test('sizeBytes increases on put', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      m.put(k, _v1);
      expect(m.sizeBytes, equals(k.length + _v1.length));
    });

    test('sizeBytes adjusts on value overwrite', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      m.put(k, _v1); // value: 1 byte
      final after1 = m.sizeBytes;
      m.put(k, _v2); // same key, same value size
      expect(m.sizeBytes, equals(after1)); // no change
      final bigVal = Uint8List(100);
      m.put(k, bigVal);
      expect(m.sizeBytes, equals(k.length + 100));
    });

    test('shouldFlush false below threshold', () {
      final m = Memtable();
      expect(m.shouldFlush, isFalse);
    });

    test('shouldFlush true at threshold', () {
      final m = Memtable();
      // Write enough bytes to hit the 64 KB threshold.
      final largeVal = Uint8List(kMemtableFlushThreshold);
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      m.put(k, largeVal);
      expect(m.shouldFlush, isTrue);
    });

    test('tombstone (empty value) is tracked correctly', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.delete);
      m.put(k, _empty);
      expect(m.sizeBytes, equals(k.length)); // +0 for empty value
      expect(m.length, equals(1));
    });
  });

  group('Memtable scan', () {
    test('entries come out in ascending internal key order', () {
      final m = Memtable();
      final k1 = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      final k2 = _key('ns', _k0, const Hlc(2, 0), RecordType.put);
      final k3 = _key('ns', _kf, const Hlc(1, 0), RecordType.put);
      m.put(k3, _v1);
      m.put(k1, _v1);
      m.put(k2, _v2);
      final keys = m.scan().map((e) => e.key).toList();
      // k1 < k2 (same user key, lower HLC < higher HLC) < k3
      expect(keys[0], equals(k1));
      expect(keys[1], equals(k2));
      expect(keys[2], equals(k3));
    });
  });

  group('FrozenMemtable', () {
    test('freeze produces readable snapshot', () {
      final m = Memtable();
      final k = _key('ns', _k0, const Hlc(1, 0), RecordType.put);
      m.put(k, _v1);
      final frozen = m.freeze();
      expect(frozen.get(k), equals(_v1));
      expect(frozen.sizeBytes, greaterThan(0));
    });

    test('frozen entries iterable contains all entries', () {
      final m = Memtable();
      for (var i = 1; i <= 5; i++) {
        final keyHex =
            i.toRadixString(16).padLeft(12, '0') +
            '70008' +
            i.toRadixString(16).padLeft(15, '0');
        final k = _key('ns', keyHex, const Hlc(1, 0), RecordType.put);
        m.put(k, Uint8List.fromList([i]));
      }
      final frozen = m.freeze();
      expect(frozen.entries.length, equals(5));
    });
  });
}
