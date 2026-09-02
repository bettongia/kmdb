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

// Web (browser) end-to-end persistence test for the `StorageAdapterSahPool`
// barrel export (0.10.01 WI-9 Phase C, release-ninja finding #2).
//
// Before this plan, a web caller had no way to construct persistent storage
// through `package:kmdb/kmdb.dart` — only `MemoryStorageAdapter` (lost on
// reload) and `StorageAdapterNative` (throws at the first file op on web)
// were exported. This test proves the closed gap end-to-end: construct
// `StorageAdapterSahPool` **through the public barrel import only**, open a
// `KmdbDatabase` with it, write a document, close the database, then reopen
// the **same OPFS path** with a **freshly constructed** adapter instance and
// confirm the document is still there. The close-and-fresh-reopen (rather
// than reusing the same adapter/db handle) is what actually proves durable
// persistence through the public API, as opposed to merely proving an
// in-process cache hit — see the plan's Implementation plan for why this
// shape was pinned by the reviewer.
@TestOn('browser')
library;

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

void main() {
  test('a document written via StorageAdapterSahPool (constructed through the '
      'public barrel) survives close() and reopen with a fresh adapter '
      'instance at the same OPFS path', () async {
    // Unique path per test run so OPFS state from a previous run (or a
    // concurrently-run test file) cannot leak in and produce a false pass.
    final dbPath =
        '/sahpool_barrel_test/${DateTime.now().microsecondsSinceEpoch}';

    // ── First session: write through a fresh StorageAdapterSahPool ──────
    final adapter1 = StorageAdapterSahPool();
    final db1 = await KmdbDatabase.open(path: dbPath, adapter: adapter1);
    final written = await db1.rawCollection('articles').insert({
      'title': 'Persisted via the public barrel',
      'body': 'StorageAdapterSahPool is now reachable from kmdb.dart.',
    });
    final key = written['_id'] as String;

    // Closing the database releases the OPFS lock (via
    // StorageAdapter.releaseLock) so a second adapter instance can acquire
    // it. Closing the adapter itself terminates its Worker — the realistic
    // cleanup sequence a web app would perform when it is done with a
    // database handle.
    await db1.close();
    await adapter1.close();

    // ── Second session: reopen with a brand-new adapter instance ────────
    // A freshly constructed StorageAdapterSahPool spawns its own Worker
    // with no in-memory state from adapter1 — the only way the document
    // can be found is if it was actually persisted to OPFS.
    final adapter2 = StorageAdapterSahPool();
    final db2 = await KmdbDatabase.open(path: dbPath, adapter: adapter2);
    final reread = await db2.rawCollection('articles').get(key);

    expect(reread, isNotNull);
    expect(reread!['title'], 'Persisted via the public barrel');
    expect(
      reread['body'],
      'StorageAdapterSahPool is now reachable from kmdb.dart.',
    );

    await db2.close();
    await adapter2.close();
  });
}
