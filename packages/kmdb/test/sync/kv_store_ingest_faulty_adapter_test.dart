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

/// Exercises [KvStoreImpl.ingestSstable] (the sync trust boundary) against
/// [FaultyStorageAdapter] rather than [MemoryStorageAdapter].
///
/// The 2026-05-22 durability-hardening track built [FaultyStorageAdapter]
/// specifically because [MemoryStorageAdapter] cannot exercise crash-safety
/// bugs — it never loses buffered writes and treats `syncFile`/`syncDir` as
/// no-ops. The 2026-07-18 release-readiness review's D-3 finding notes that,
/// despite that harness existing, **no test under `test/sync/` uses it** —
/// the trust boundary (S-1's ingest path in particular) had no fault
/// injection at all. This file closes that specific gap: a hostile SSTable
/// is rejected during ingest, and a crash immediately afterwards still
/// recovers to a database that can accept further (legitimate) ingests.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';
import '../util/hostile_sstable.dart';

const _dbDir = '/db';

void main() {
  group('KvStoreImpl.ingestSstable against FaultyStorageAdapter (D-3)', () {
    test('a checksum-valid, structurally hostile SSTable is rejected, and a '
        'crash immediately afterwards still recovers to a healthy, usable '
        'database', () async {
      final adapter = FaultyStorageAdapter();
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        adapter,
        config: KvStoreConfig.forTesting(),
        deviceId: 'dev00001',
      );

      final hostile = patchFooterField(
        buildValidSstable(basePhysical: 5000),
        field: FooterField.indexOffset,
        value: -1,
      );
      final hostileFilename = SstableInfo.flushName(
        'peer0001',
        const Hlc(5000, 0),
        const Hlc(5003, 0),
      );

      await expectLater(
        store.ingestSstable(hostileFilename, hostile),
        throwsA(isA<CorruptedSstableException>()),
      );

      // Crash immediately after the rejected ingest — this is exactly the
      // sequence the review's D-3 finding says was never exercised: a
      // fault at the sync trust boundary, combined with a real crash.
      adapter.crash();

      final (recoveredStore, _) = await KvStoreImpl.open(
        _dbDir,
        adapter,
        config: KvStoreConfig.forTesting(),
        deviceId: 'dev00001',
      );

      // The database must still be usable: a subsequent legitimate ingest
      // succeeds, proving recovery did not get stuck on the earlier
      // rejected file's on-disk remnants.
      final legitimate = buildValidSstable(basePhysical: 6000);
      final legitimateFilename = SstableInfo.flushName(
        'peer0001',
        const Hlc(6000, 0),
        const Hlc(6003, 0),
      );
      await recoveredStore.ingestSstable(legitimateFilename, legitimate);

      final scanned = <Uint8List>[];
      await for (final entry in recoveredStore.scan('test')) {
        scanned.add(entry.value);
      }
      expect(scanned, isNotEmpty);

      await recoveredStore.close();
    });
  });
}
