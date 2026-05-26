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
import 'package:test/test.dart';

/// Runs the full [SyncStorageAdapter] conformance suite against [factory].
///
/// Every adapter the codebase ships (and every downstream provider adapter,
/// e.g. Google Drive, Dropbox, iCloud) must pass this suite — it is the
/// single source of truth for the `SyncStorageAdapter` contract.
///
/// [factory] must return a *fresh* adapter on each call (the suite calls it
/// at least once per test). [expectAtomicCas] declares whether the adapter
/// claims to provide atomic compare-and-swap; the contention test
/// downgrades from "exactly one winner" to "at least one winner" when this
/// is `false`, so it can still run against intentionally-non-atomic backends
/// without spurious failures.
///
/// Example:
/// ```dart
/// void main() {
///   group('MemorySyncAdapter conformance', () {
///     runSyncAdapterConformance(
///       factory: MemorySyncAdapter.new,
///       expectAtomicCas: true,
///     );
///   });
/// }
/// ```
void runSyncAdapterConformance({
  required SyncStorageAdapter Function() factory,
  required bool expectAtomicCas,
}) {
  _runCasConformanceTests(factory: factory);
  _runEtagConformanceTests(factory: factory);
  _runDeleteConformanceTests(factory: factory);
  _runCapabilityConformanceTests(
    factory: factory,
    expectAtomicCas: expectAtomicCas,
  );
  runSyncAdapterContentionTest(
    factory: factory,
    expectAtomicCas: expectAtomicCas,
  );
}

// ── compareAndSwap conformance ────────────────────────────────────────────────

void _runCasConformanceTests({required SyncStorageAdapter Function() factory}) {
  group('compareAndSwap (conformance)', () {
    // ── create-if-absent (ifMatchEtag == null) ────────────────────────────────

    test('create-if-absent succeeds when file is absent', () async {
      final adapter = factory();
      final bytes = Uint8List.fromList([1, 2, 3]);
      final result = await adapter.compareAndSwap(
        'cas/new.bin',
        bytes,
        ifMatchEtag: null,
      );
      expect(result, isTrue);
      expect(await adapter.download('cas/new.bin'), equals(bytes));
    });

    test(
      'create-if-absent returns false (conflict) when file already exists',
      () async {
        final adapter = factory();
        final original = Uint8List.fromList([1]);
        await adapter.upload('cas/exists.bin', original);

        final result = await adapter.compareAndSwap(
          'cas/exists.bin',
          Uint8List.fromList([99]),
          ifMatchEtag: null,
        );
        expect(result, isFalse);
        // Original content is preserved.
        expect(await adapter.download('cas/exists.bin'), equals(original));
      },
    );

    test('create-if-absent assigns a non-null ETag after success', () async {
      final adapter = factory();
      await adapter.compareAndSwap(
        'cas/etag.bin',
        Uint8List.fromList([42]),
        ifMatchEtag: null,
      );
      expect(await adapter.getEtag('cas/etag.bin'), isNotNull);
    });

    // ── update-if-match (ifMatchEtag != null) ─────────────────────────────────

    test('update-if-match succeeds with matching ETag', () async {
      final adapter = factory();
      await adapter.upload('cas/update.bin', Uint8List.fromList([1]));
      final etag = await adapter.getEtag('cas/update.bin');
      final newBytes = Uint8List.fromList([2, 3]);

      final result = await adapter.compareAndSwap(
        'cas/update.bin',
        newBytes,
        ifMatchEtag: etag,
      );
      expect(result, isTrue);
      expect(await adapter.download('cas/update.bin'), equals(newBytes));
    });

    test('update-if-match returns false when ETag is stale', () async {
      final adapter = factory();
      await adapter.upload('cas/stale.bin', Uint8List.fromList([1]));
      final staleEtag = await adapter.getEtag('cas/stale.bin');
      // Another write changes the content — ETag is now stale.
      await adapter.upload('cas/stale.bin', Uint8List.fromList([2]));

      final result = await adapter.compareAndSwap(
        'cas/stale.bin',
        Uint8List.fromList([3]),
        ifMatchEtag: staleEtag,
      );
      expect(result, isFalse);
      // Intervening write is preserved.
      expect(
        await adapter.download('cas/stale.bin'),
        equals(Uint8List.fromList([2])),
      );
    });

    test('update-if-match returns false when file does not exist', () async {
      final adapter = factory();
      final result = await adapter.compareAndSwap(
        'cas/missing.bin',
        Uint8List.fromList([1]),
        ifMatchEtag: 'nonexistent',
      );
      expect(result, isFalse);
    });

    test('update-if-match updates ETag on success', () async {
      final adapter = factory();
      await adapter.upload('cas/retag.bin', Uint8List.fromList([1]));
      final etag1 = await adapter.getEtag('cas/retag.bin');
      await adapter.compareAndSwap(
        'cas/retag.bin',
        Uint8List.fromList([2]),
        ifMatchEtag: etag1,
      );
      final etag2 = await adapter.getEtag('cas/retag.bin');
      expect(etag2, isNotNull);
      expect(etag2, isNot(equals(etag1)));
    });
  });
}

// ── getEtag conformance ───────────────────────────────────────────────────────

void _runEtagConformanceTests({
  required SyncStorageAdapter Function() factory,
}) {
  group('getEtag (conformance)', () {
    test('returns null for a missing file', () async {
      final adapter = factory();
      expect(await adapter.getEtag('etag/missing.bin'), isNull);
    });

    test('returns a non-null, non-empty string after upload', () async {
      final adapter = factory();
      await adapter.upload('etag/file.bin', Uint8List.fromList([7]));
      final etag = await adapter.getEtag('etag/file.bin');
      expect(etag, isNotNull);
      expect(etag, isNotEmpty);
    });

    test('is stable: same content produces the same ETag', () async {
      final adapter = factory();
      final bytes = Uint8List.fromList([10, 20, 30]);
      await adapter.upload('etag/a.bin', bytes);
      await adapter.upload('etag/b.bin', bytes);
      expect(
        await adapter.getEtag('etag/a.bin'),
        equals(await adapter.getEtag('etag/b.bin')),
      );
    });

    test('changes when content changes', () async {
      final adapter = factory();
      await adapter.upload('etag/mut.bin', Uint8List.fromList([1]));
      final etag1 = await adapter.getEtag('etag/mut.bin');
      await adapter.upload('etag/mut.bin', Uint8List.fromList([2]));
      final etag2 = await adapter.getEtag('etag/mut.bin');
      expect(etag2, isNot(equals(etag1)));
    });

    test('returns null after the file is deleted', () async {
      final adapter = factory();
      await adapter.upload('etag/del.bin', Uint8List.fromList([1]));
      await adapter.delete('etag/del.bin');
      expect(await adapter.getEtag('etag/del.bin'), isNull);
    });
  });
}

// ── delete conformance ────────────────────────────────────────────────────────

void _runDeleteConformanceTests({
  required SyncStorageAdapter Function() factory,
}) {
  group('delete (conformance)', () {
    test('removes the file so download returns null', () async {
      final adapter = factory();
      await adapter.upload('del/file.bin', Uint8List.fromList([1]));
      await adapter.delete('del/file.bin');
      expect(await adapter.download('del/file.bin'), isNull);
    });

    test('is idempotent — no error when file is already absent', () async {
      final adapter = factory();
      await expectLater(adapter.delete('del/missing.bin'), completes);
    });

    test('delete twice does not throw', () async {
      final adapter = factory();
      await adapter.upload('del/twice.bin', Uint8List.fromList([1]));
      await adapter.delete('del/twice.bin');
      await expectLater(adapter.delete('del/twice.bin'), completes);
    });
  });
}

// ── capability conformance ────────────────────────────────────────────────────

void _runCapabilityConformanceTests({
  required SyncStorageAdapter Function() factory,
  required bool expectAtomicCas,
}) {
  group('capability (conformance)', () {
    test('providesAtomicCas returns the declared value', () {
      final adapter = factory();
      expect(adapter.providesAtomicCas, equals(expectAtomicCas));
    });
  });
}

/// The H5 regression guard: a focused test that proves [SyncStorageAdapter]
/// honours its atomic-compare-and-swap contract under concurrency.
///
/// The hazard this test is designed to catch is a non-atomic
/// `read-check-write` `compareAndSwap` implementation, where two concurrent
/// callers both observe the file as absent, both write a temp file, and
/// both successfully rename — yielding two "winners" of a create-if-absent
/// race. In the [ConsolidationCoordinator] this exact race lets two devices
/// both believe they hold the lease and delete each other's input SSTables
/// (review finding H5).
///
/// ## How the test actually races
///
/// Dart is single-isolate, but `compareAndSwap` implementations that touch
/// the filesystem `await` on I/O. Every `await` is a yield point — other
/// pending futures can interleave. By launching N concurrent
/// `compareAndSwap(path, _, ifMatchEtag: null)` calls and waiting for all
/// of them, we exercise exactly the interleaving that produces the bug:
///
/// 1. caller A: `await file.existsSync()` → false, yields
/// 2. caller B: `await file.existsSync()` → false, yields
/// 3. caller A: write temp, rename → returns true
/// 4. caller B: write temp (different microsecond suffix), rename → also true
///
/// On a backend with true atomic CAS, exactly one caller returns `true`.
/// On the current non-atomic [LocalDirectoryAdapter], multiple callers can
/// return `true` — which the H5 plan step 3 will fix by switching to
/// `File.create(exclusive: true)`.
///
/// ## What this test does NOT cover
///
/// * **Cross-process contention.** Two `dart` processes racing on the same
///   directory cannot be simulated within a single isolate. The plan's
///   `kmdb_harness` work adds that coverage; this test is the in-isolate
///   regression guard that runs in normal CI.
/// * **Cross-device contention.** Cloud-synced folders are eventually
///   consistent; no local test can prove or disprove their behaviour.
///   Adapters pointed at such folders must declare
///   [SyncStorageAdapter.providesAtomicCas] `false` and call this test
///   with `expectAtomicCas: false`.
void runSyncAdapterContentionTest({
  required SyncStorageAdapter Function() factory,
  required bool expectAtomicCas,
}) {
  group('contention (H5 regression guard)', () {
    // 32 concurrent contenders is high enough to make accidental serialisation
    // unlikely on any host while keeping the test under a few hundred ms.
    const concurrency = 32;
    const path = 'contention/lease';

    test(
      'create-if-absent: at most one winner under concurrent contention',
      () async {
        final adapter = factory();

        // Build the list of pending futures first so they are all queued before
        // any of them yield — this guarantees they are racing rather than
        // running sequentially. Each future writes its own distinctive bytes so
        // we can later check which one's content actually persisted.
        final futures = <Future<bool>>[];
        for (var i = 0; i < concurrency; i++) {
          futures.add(
            adapter.compareAndSwap(
              path,
              Uint8List.fromList([i & 0xff]),
              ifMatchEtag: null,
            ),
          );
        }

        final results = await Future.wait(futures);
        final winners = results.where((r) => r).length;

        if (expectAtomicCas) {
          expect(
            winners,
            equals(1),
            reason:
                'Adapter advertises providesAtomicCas=true but $winners of '
                '$concurrency concurrent create-if-absent callers won the '
                'race (expected exactly 1). This is the H5 split-lease '
                'data-loss hazard.',
          );
        } else {
          // Non-atomic adapters: we only require that the operation makes
          // forward progress. At least one caller must have observed the file
          // as absent and successfully written it; the file must end up
          // readable. We do NOT assert single-winner here because the whole
          // point of the providesAtomicCas=false declaration is that multiple
          // winners are tolerated by the gating in ConsolidationCoordinator.
          expect(
            winners,
            greaterThanOrEqualTo(1),
            reason: 'At least one contender should observe the create succeed.',
          );
        }

        // Regardless of how many writers claimed to win, the file must now
        // exist and be readable — there must not be a state where every
        // contender lost or where the file ended up corrupt/empty.
        final bytes = await adapter.download(path);
        expect(
          bytes,
          isNotNull,
          reason:
              'After contention, the path must hold a single readable file.',
        );
        expect(
          bytes!.length,
          equals(1),
          reason:
              'Each contender writes exactly one byte; the surviving '
              'content must be one of them, not a partial write.',
        );
      },
    );
  });
}
