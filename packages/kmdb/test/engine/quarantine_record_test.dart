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

/// Unit tests for the [QuarantinedSstable] CBOR codec (A3 / WI-7), focused on
/// the malformed-record decode branches: a durable `$$quarantine` record is
/// untrusted the moment it is read back (a partial write, a record from a newer
/// build, on-disk corruption), so `fromCbor` must reject every ill-formed shape
/// with a `FormatException` rather than returning a half-built record.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:kmdb/src/engine/kvstore/quarantine.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:test/test.dart';

/// A well-formed record map, mutated per-test to inject a single fault.
Map<String, dynamic> _validMap() => <String, dynamic>{
  'v': 1,
  'peerDeviceId': 'peer0001',
  'filename': 'peer0001-0000000000001388-0000000000001770.sst',
  'maxHlc': const Hlc(6000, 0).encoded,
  'reason': QuarantineReason.corruptedSstable.name,
  'detail': 'footer checksum failed',
  'quarantinedAt': 1700000000000,
};

Uint8List _encode(Object? map) =>
    Uint8List.fromList(cbor.encode(CborValue(map)));

void main() {
  group('QuarantinedSstable CBOR codec (A3 / WI-7)', () {
    test('round-trips every field for every QuarantineReason', () {
      for (final reason in QuarantineReason.values) {
        final record = QuarantinedSstable(
          peerDeviceId: 'peer0001',
          filename: 'peer0001-0000000000001388-0000000000001770.sst',
          maxHlc: const Hlc(6000, 3),
          reason: reason,
          detail: 'why: $reason',
          quarantinedAt: DateTime.fromMillisecondsSinceEpoch(
            1700000000000,
            isUtc: true,
          ),
        );
        final decoded = QuarantinedSstable.fromCbor(record.toCbor());
        expect(decoded.peerDeviceId, equals(record.peerDeviceId));
        expect(decoded.filename, equals(record.filename));
        expect(decoded.maxHlc, equals(record.maxHlc));
        expect(decoded.reason, equals(reason));
        expect(decoded.detail, equals(record.detail));
        expect(decoded.quarantinedAt, equals(record.quarantinedAt));
      }
    });

    test('rejects bytes that are not valid CBOR', () {
      // Major type 0 with reserved additional-info 28 — not decodable.
      expect(
        () => QuarantinedSstable.fromCbor(Uint8List.fromList([0x1c])),
        throwsFormatException,
      );
    });

    test('rejects a CBOR value that is not a map', () {
      expect(
        () => QuarantinedSstable.fromCbor(_encode('not a map')),
        throwsFormatException,
      );
    });

    test('rejects a map with a mistyped string field', () {
      final map = _validMap()..['filename'] = 123; // int, not String
      expect(
        () => QuarantinedSstable.fromCbor(_encode(map)),
        throwsFormatException,
      );
    });

    test('rejects a map with a missing string field', () {
      final map = _validMap()..remove('peerDeviceId');
      expect(
        () => QuarantinedSstable.fromCbor(_encode(map)),
        throwsFormatException,
      );
    });

    test('rejects a map with a mistyped int field', () {
      final map = _validMap()..['maxHlc'] = 'not-an-int';
      expect(
        () => QuarantinedSstable.fromCbor(_encode(map)),
        throwsFormatException,
      );
    });

    // Note: `getInt`'s `v is BigInt → toInt()` branch is defensive
    // normalisation for CBOR's int representation. It is not exercised here on
    // purpose: CBOR only decodes an integer as `BigInt` when it overflows a
    // 64-bit word, and every such value is then out of range for the fields
    // that consume it (`Hlc`, `DateTime`), so the only inputs that reach the
    // branch fail downstream regardless. A legitimately-written record's
    // `maxHlc`/`quarantinedAt` always fit in a 64-bit `int`.

    test('rejects an unrecognised QuarantineReason name', () {
      final map = _validMap()..['reason'] = 'someFutureReasonThisBuildLacks';
      expect(
        () => QuarantinedSstable.fromCbor(_encode(map)),
        throwsFormatException,
      );
    });
  });
}
