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

/// Mandatory regression for the 0.10.01 WI-13 defect #1 — "LWW-backwards
/// cache resurrection" — see `MetaStore.kGenStateNamespace`'s doc comment.
///
/// ## Why this exact construction, and not a lighter one
///
/// The naive construction ("cache an entry, then a peer's later-HLC-but-lower
/// `gen` value moves the counter backwards") is *vacuous*: the session cache
/// (`SessionCache`) is keyed by `(namespace, key)` only, with `gen` stored as
/// a match *field* on the entry (`_cacheKey` = `'$namespace\x00$key'`,
/// [SessionCache.get] returns the entry only when `entry.generation ==
/// generation`). A gen mismatch produces a **miss without removing the stale
/// entry** — it physically persists in the LRU until either overwritten by a
/// later `put` or proactively purged by `evictNamespace`. A *local* write can
/// never resurrect the bug, because `CacheLayer._onWriteEvent` fires
/// `evictNamespace` on every local write and removes the stale entry
/// immediately. The store must instead be advanced by an **ingest** — which,
/// pre-fix, emits only `$sync` (not a per-namespace event), so the proactive
/// eviction path never runs and the stale entry survives to be resurrected.
///
/// The four-step sequence below (see the reviewer's corrected write-up in the
/// plan) is the minimal deterministic construction that avoids this
/// vacuousness:
///
/// 1. A local `put` establishes `V1` at gen `G`; `cache.get` caches
///    `(ns,key)` → `(G, V1)`.
/// 2. **Ingest** a synthetic SSTable carrying the peer's fresher document
///    `V2` (higher HLC) *and* a `$meta` `gen:ns = G+1` entry — modelling how,
///    pre-fix, the gen counter rode along in the same synced `$meta`
///    namespace as ordinary documents. Pre-fix, this ingest evicts nothing
///    (`$sync`-only emit); the stale `(G, V1)` entry survives untouched.
/// 3. A **second** ingest carries only a `$meta` `gen:ns = G` entry at an HLC
///    *later* than step 2's — pre-fix, plain last-write-wins moves the
///    (still lazily-read) `$meta` value back to `G`, exactly matching the
///    surviving stale entry's discriminator.
/// 4. `cache.get(ns, key)` — pre-fix, the lazily-read gen is `G`, matching
///    the stale entry: a **cache hit on stale `V1`** (a silent
///    resurrection — the underlying LSM data was always `V2`; only the
///    session cache served wrong data).
///
/// Post-fix, the counter lives in the local-only `$$genstate` namespace —
/// these synthetic `$meta` `gen:ns` entries are completely inert (never read
/// by [MetaStore.getGenerationCounter]) — and step 2's ingest itself bumps
/// `$$genstate` and emits a per-namespace `writeEvent` for `ns` (because the
/// ingested SSTable's own document entry names `ns`), proactively evicting
/// the stale entry *immediately*, well before step 3 ever runs. Step 4 then
/// misses on a clean cache and reads `V2` from disk.
///
/// This test **must fail** if the fix is reverted (gen back in `$meta`, and
/// the ingest-side bump/emit in `LsmEngine.ingestAt0` removed) — verified
/// manually during implementation (see the plan's checklist) by toggling
/// `MetaStore.kGenStateNamespace` back to `MetaStore.kNamespace` and
/// commenting out the ingest bump/emit block; re-verifying this by weakening
/// the test is not an acceptable substitute.
///
/// Uses [FaultyStorageAdapter] rather than [MemoryStorageAdapter], per
/// CLAUDE.md's durability-test guidance — no `crash()` is ever injected here
/// (this test is about read-time LWW precedence, not power-loss durability),
/// but the adapter still exercises the real `syncFile`/`syncDir` durability
/// bookkeeping the in-memory adapter stubs out entirely.
library;

import 'dart:typed_data';

import 'package:kmdb/src/cache/cache_layer.dart';
import 'package:kmdb/src/cache/cache_tier.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _dbDir = '/db';
const _deviceIdA = 'devicea1';

const _testConfig = KvStoreConfig(
  singleFileThresholdBytes: 0,
  fsyncOnWrite: true,
  tableCacheSize: 16,
);

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

/// Encodes [value] the same way [EncryptionEnvelope.wrap] does for a `null`
/// (plaintext) provider: a leading `EncryptionFlag.none` (0x00) byte followed
/// by the big-endian uint64. Building this by hand (rather than importing the
/// private helper) keeps this test's synthetic SSTable byte-for-byte
/// indistinguishable from a value [MetaStore] would have written pre-fix.
Uint8List _wrapPlaintextGenValue(int value) {
  final out = Uint8List(9);
  out[0] = 0x00; // EncryptionFlag.none
  final bd = ByteData.sublistView(out, 1);
  bd.setUint64(0, value, Endian.big);
  return out;
}

/// Builds a two-entry SSTable containing a document put for
/// `ns/docKey = docValue` at [docHlc], *and* a `$meta` `gen:ns` put at
/// [metaHlc]. Entries are added in ascending internal-key byte order, as
/// [SstableWriter] requires.
Uint8List _buildDocAndMetaGenSstable({
  required String ns,
  required String docKey,
  required Uint8List docValue,
  required Hlc docHlc,
  required int genValue,
  required Hlc metaHlc,
}) {
  final docInternalKey = KeyCodec.encodeInternalKey(
    ns,
    KeyCodec.keyToBytes(docKey),
    docHlc,
    RecordType.put,
  );
  final metaInternalKey = KeyCodec.encodeInternalKey(
    MetaStore.kNamespace,
    KeyCodec.keyToBytes(MetaStore.genKey(ns)),
    metaHlc,
    RecordType.put,
  );
  // Sort the two entries by raw internal-key byte order — SstableWriter
  // requires ascending order across the whole file, not just per-namespace.
  final entries = [
    (docInternalKey, docValue),
    (metaInternalKey, _wrapPlaintextGenValue(genValue)),
  ]..sort((a, b) => _compareBytes(a.$1, b.$1));

  final writer = SstableWriter();
  for (final (key, value) in entries) {
    writer.add(key, value);
  }
  return writer.finish();
}

/// Builds a single-entry SSTable containing only a `$meta` `gen:ns` put at
/// [metaHlc] — no document data.
Uint8List _buildMetaGenOnlySstable({
  required String ns,
  required int genValue,
  required Hlc metaHlc,
}) {
  final writer = SstableWriter()
    ..add(
      KeyCodec.encodeInternalKey(
        MetaStore.kNamespace,
        KeyCodec.keyToBytes(MetaStore.genKey(ns)),
        metaHlc,
        RecordType.put,
      ),
      _wrapPlaintextGenValue(genValue),
    );
  return writer.finish();
}

int _compareBytes(Uint8List a, Uint8List b) {
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

void main() {
  group(
    'CacheLayer — LWW-backwards resurrection is closed (WI-13, defect #1)',
    () {
      test(
        'a stale cache entry surviving an ingest must not be resurrected by a '
        'later ingest that moves the (now-inert) synced \$meta gen value '
        'backwards',
        () async {
          final adapter = FaultyStorageAdapter();
          final (store, _) = await KvStoreImpl.open(
            _dbDir,
            adapter,
            config: _testConfig,
            deviceId: _deviceIdA,
          );
          final cache = CacheLayer(store: store, tier: CacheTier.desktop);

          const ns = 'notes';
          const docKey = '00000000000070008000000000000abc';
          final v1 = _bytes('v1-original');
          final v2 = _bytes('v2-fresh-from-peer');

          // 1. Local put establishes V1 at gen G (=1), then cache.get caches
          // (ns,key) -> (1, V1).
          await store.put(ns, docKey, v1);
          expect(await store.meta.getGenerationCounter(ns), equals(1));
          expect(await cache.get(ns, docKey), equals(v1));

          // Flush V1 to an L0 SSTable *before* ingesting the peer's fresher
          // data below. Load-bearing (see the dirty-flag WI-14 cross-device
          // test for the identical reasoning): LsmEngine.get() checks the
          // active memtable unconditionally first, regardless of any
          // ingested file's HLC. If V1 were still sitting in the memtable
          // when V2's SSTable is ingested as a separate L0 file, the memtable
          // entry would shadow it forever and V2 would never become visible —
          // this test would then fail for the wrong reason.
          await store.flush();

          // 2. Ingest a synthetic SSTable carrying the peer's fresher V2 (at
          // a higher HLC) *and* a $meta gen:ns = G+1 (=2) entry — modelling
          // how, pre-fix, the gen counter rode along in synced $meta as part
          // of a normal flush. Pre-fix, ingestAt0 emits only '$sync', so
          // CacheLayer's proactive eviction never runs and the stale (1, V1)
          // entry survives untouched. Post-fix, this ingest's own scan finds
          // 'notes' as an affected namespace (the doc entry) and bumps+emits
          // for it, proactively evicting the stale entry immediately.
          final ingestHlc1 = Hlc(
            DateTime.now().millisecondsSinceEpoch + 10000,
            0,
          );
          final sstable1 = _buildDocAndMetaGenSstable(
            ns: ns,
            docKey: docKey,
            docValue: v2,
            docHlc: ingestHlc1,
            genValue: 2,
            metaHlc: ingestHlc1,
          );
          final filename1 = SstableInfo.flushName(
            'deviceb2', // a different device — this is simulating a pull.
            ingestHlc1,
            ingestHlc1,
          );
          await cache.ingestSstable(filename1, sstable1);

          // 3. A second ingest carries only a $meta gen:ns = G (=1) entry, at
          // an HLC strictly later than step 2's. Pre-fix, plain
          // last-write-wins moves the (lazily-read) $meta value back to 1 —
          // exactly matching the surviving stale entry's discriminator.
          // Post-fix, this value is never read at all (gen lives in
          // $$genstate) and this ingest's scan finds only '$meta' as an
          // affected namespace, which CacheLayer ignores ($-prefixed).
          final ingestHlc2 = Hlc(
            DateTime.now().millisecondsSinceEpoch + 20000,
            0,
          );
          final sstable2 = _buildMetaGenOnlySstable(
            ns: ns,
            genValue: 1,
            metaHlc: ingestHlc2,
          );
          final filename2 = SstableInfo.flushName(
            'devicec3',
            ingestHlc2,
            ingestHlc2,
          );
          await cache.ingestSstable(filename2, sstable2);

          // 4. Assert the fresh V2 is returned — not a resurrected stale V1.
          final result = await cache.get(ns, docKey);
          expect(
            result,
            equals(v2),
            reason:
                'the cache must never resurrect a stale value via a synced '
                '\$meta gen entry moving backwards — the counter must be '
                'device-local and the ingest path must proactively evict',
          );

          await cache.close();
        },
      );
    },
  );
}
