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

import 'package:kmdb/kmdb_test_cloud_support.dart';
import 'package:test/test.dart';

import 'package:kmdb/test_support.dart';

void main() {
  group('SharedCloudBackend', () {
    late SharedCloudBackend backend;

    setUp(() => backend = SharedCloudBackend());

    test('starts empty', () {
      expect(backend.fileCount, equals(0));
      expect(backend.currentWriteSeq, equals(0));
    });

    test('write stores a file and increments writeSeq', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final file = backend.write('a.sst', bytes);
      expect(file.bytes, equals(bytes));
      expect(file.version, equals(1));
      expect(file.writeSeq, equals(1));
      expect(backend.currentWriteSeq, equals(1));
      expect(backend.fileCount, equals(1));
    });

    test('write increments version on overwrite', () {
      backend.write('a.sst', Uint8List.fromList([1]));
      final file2 = backend.write('a.sst', Uint8List.fromList([2]));
      expect(file2.version, equals(2));
      expect(file2.writeSeq, equals(2));
    });

    test('each write gets a distinct monotonic writeSeq', () {
      backend.write('a.sst', Uint8List.fromList([1]));
      backend.write('b.sst', Uint8List.fromList([2]));
      expect(backend.getFile('a.sst')!.writeSeq, equals(1));
      expect(backend.getFile('b.sst')!.writeSeq, equals(2));
    });

    test('compareAndSwap create-if-absent succeeds when absent', () {
      final file = backend.compareAndSwap(
        'new.sst',
        Uint8List.fromList([42]),
        ifMatchEtag: null,
      );
      expect(file, isNotNull);
      expect(file!.writeSeq, equals(1));
    });

    test('compareAndSwap create-if-absent returns null when file exists', () {
      backend.write('exists.sst', Uint8List.fromList([1]));
      final result = backend.compareAndSwap(
        'exists.sst',
        Uint8List.fromList([99]),
        ifMatchEtag: null,
      );
      expect(result, isNull);
      expect(backend.getFile('exists.sst')!.bytes, equals([1]));
    });

    test('compareAndSwap update-if-match succeeds with matching ETag', () {
      backend.write('upd.sst', Uint8List.fromList([1]));
      final etag = backend.getEtag('upd.sst');
      final file = backend.compareAndSwap(
        'upd.sst',
        Uint8List.fromList([2]),
        ifMatchEtag: etag,
      );
      expect(file, isNotNull);
      expect(file!.bytes, equals([2]));
    });

    test('compareAndSwap update-if-match returns null on stale ETag', () {
      backend.write('stale.sst', Uint8List.fromList([1]));
      backend.write('stale.sst', Uint8List.fromList([2])); // version now 2
      final result = backend.compareAndSwap(
        'stale.sst',
        Uint8List.fromList([3]),
        ifMatchEtag: '1', // stale
      );
      expect(result, isNull);
    });

    test('delete removes the file', () {
      backend.write('del.sst', Uint8List.fromList([1]));
      backend.delete('del.sst');
      expect(backend.containsFile('del.sst'), isFalse);
    });

    test('delete is idempotent for missing files', () {
      expect(() => backend.delete('missing.sst'), returnsNormally);
    });

    test('filesVisibleUpTo filters by writeSeq', () {
      backend.write('a.sst', Uint8List.fromList([1])); // seq 1
      backend.write('b.sst', Uint8List.fromList([2])); // seq 2
      backend.write('c.sst', Uint8List.fromList([3])); // seq 3

      final visible = backend.filesVisibleUpTo(2);
      expect(visible.keys, containsAll(['a.sst', 'b.sst']));
      expect(visible.keys, isNot(contains('c.sst')));
    });

    test('clear resets all state', () {
      backend.write('a.sst', Uint8List.fromList([1]));
      backend.clear();
      expect(backend.fileCount, equals(0));
      expect(backend.currentWriteSeq, equals(0));
    });
  });

  group('SharedBackendAdapter', () {
    late SharedCloudBackend backend;
    late SharedBackendAdapter adapterA;
    late SharedBackendAdapter adapterB;

    setUp(() {
      backend = SharedCloudBackend();
      adapterA = SharedBackendAdapter(backend, deviceId: 'dev-a');
      adapterB = SharedBackendAdapter(backend, deviceId: 'dev-b');
    });

    test(
      'upload from A is immediately visible to B (strong consistency)',
      () async {
        final bytes = Uint8List.fromList([1, 2, 3]);
        await adapterA.upload('sstables/foo.sst', bytes);
        expect(await adapterB.download('sstables/foo.sst'), equals(bytes));
      },
    );

    test('list returns direct children only', () async {
      await adapterA.upload('sstables/a.sst', Uint8List.fromList([1]));
      await adapterA.upload('sstables/b.sst', Uint8List.fromList([2]));
      await adapterA.upload('sstables/sub/c.sst', Uint8List.fromList([3]));
      final files = await adapterA.list('sstables', extension: '.sst');
      expect(files, containsAll(['a.sst', 'b.sst']));
      expect(files, isNot(contains('c.sst')));
    });

    test('download returns null for missing file', () async {
      expect(await adapterA.download('missing.sst'), isNull);
    });

    test('delete removes file', () async {
      await adapterA.upload('del.sst', Uint8List.fromList([1]));
      await adapterA.delete('del.sst');
      expect(await adapterB.download('del.sst'), isNull);
    });

    test('visibleWriteSeq always equals backend currentWriteSeq', () async {
      expect(adapterA.visibleWriteSeq, equals(0));
      await adapterA.upload('a.sst', Uint8List.fromList([1]));
      expect(adapterA.visibleWriteSeq, equals(backend.currentWriteSeq));
    });

    test('providesAtomicCas is true', () {
      expect(adapterA.providesAtomicCas, isTrue);
    });

    group('conformance (SharedBackendAdapter)', () {
      runSyncAdapterConformance(
        factory: () => SharedBackendAdapter(SharedCloudBackend()),
        expectAtomicCas: true,
      );
    });
  });

  group('CloudProfile', () {
    test('strong() profile has correct defaults', () {
      const profile = CloudProfile.strong();
      expect(profile.atomicConditionalCreate, isTrue);
      expect(profile.allowsDuplicateNames, isFalse);
      expect(profile.consistency.isStrong, isTrue);
    });

    test('eventual() profile has correct defaults', () {
      final profile = CloudProfile.eventual(maxPropagationDelayMs: 100);
      expect(profile.atomicConditionalCreate, isFalse);
      expect(profile.allowsDuplicateNames, isFalse);
      expect(profile.consistency.isEventual, isTrue);
      expect(profile.consistency.maxPropagationDelayMs, equals(100));
    });

    test('ConsistencyModelX getters work correctly', () {
      const strong = StrongConsistency();
      expect(strong.isStrong, isTrue);
      expect(strong.isEventual, isFalse);
      expect(strong.maxPropagationDelayMs, equals(0));
      expect(strong.jitterMs, equals(0));

      const eventual = EventualConsistency(
        maxPropagationDelayMs: 200,
        jitterMs: 50,
      );
      expect(eventual.isStrong, isFalse);
      expect(eventual.isEventual, isTrue);
      expect(eventual.maxPropagationDelayMs, equals(200));
      expect(eventual.jitterMs, equals(50));
    });
  });

  group('CloudSemanticsAdapter — strong profile', () {
    late SharedCloudBackend backend;
    late CloudSemanticsAdapter adapter;

    setUp(() {
      backend = SharedCloudBackend();
      adapter = CloudSemanticsAdapter(
        backend: SharedBackendAdapter(backend),
        profile: const CloudProfile.strong(),
      );
    });

    test('uploads are immediately visible (strong consistency)', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      await adapter.upload('sstables/foo.sst', bytes);
      expect(await adapter.download('sstables/foo.sst'), equals(bytes));
    });

    test('visibleWriteSeq equals backend currentWriteSeq', () async {
      await adapter.upload('a.sst', Uint8List.fromList([1]));
      expect(adapter.visibleWriteSeq, equals(backend.currentWriteSeq));
    });

    test('providesAtomicCas matches profile.atomicConditionalCreate', () {
      expect(adapter.providesAtomicCas, isTrue);
    });

    test('advancePropagationClock is a no-op for strong profile', () async {
      await adapter.upload('a.sst', Uint8List.fromList([1]));
      final seqBefore = adapter.visibleWriteSeq;
      adapter.advancePropagationClock();
      expect(adapter.visibleWriteSeq, equals(seqBefore));
    });

    group('conformance (CloudSemanticsAdapter / strong)', () {
      runSyncAdapterConformance(
        factory: () => CloudSemanticsAdapter(
          backend: SharedBackendAdapter(SharedCloudBackend()),
          profile: const CloudProfile.strong(),
        ),
        expectAtomicCas: true,
      );
    });
  });

  group('CloudSemanticsAdapter — eventual profile', () {
    late SharedCloudBackend backend;
    late CloudSemanticsAdapter adapter;
    late SharedBackendAdapter directView;

    setUp(() {
      backend = SharedCloudBackend();
      directView = SharedBackendAdapter(backend);
      adapter = CloudSemanticsAdapter(
        backend: directView,
        profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
      );
    });

    test('writes are committed to backend immediately', () async {
      await adapter.upload('a.sst', Uint8List.fromList([1]));
      // The direct view (strongly-consistent) sees it immediately.
      expect(await directView.download('a.sst'), isNotNull);
    });

    test(
      'uploads are NOT visible to a different observer before clock advance',
      () async {
        final observer = CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        );
        await adapter.upload('a.sst', Uint8List.fromList([1]));
        // Writer sees its own write immediately (read-your-writes).
        expect(await adapter.download('a.sst'), isNotNull);
        // A separate observer has not advanced its cursor — write is invisible.
        expect(await observer.download('a.sst'), isNull);
      },
    );

    test('uploads ARE visible after advancePropagationClock()', () async {
      await adapter.upload('a.sst', Uint8List.fromList([1]));
      adapter.advancePropagationClock();
      expect(await adapter.download('a.sst'), isNotNull);
    });

    test(
      'list does not include files for a different observer before propagation',
      () async {
        final observer = CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        );
        await adapter.upload('a.sst', Uint8List.fromList([1]));
        // A separate observer has not advanced its cursor — list is empty.
        final files = await observer.list('', extension: '.sst');
        expect(files, isEmpty);
      },
    );

    test('list includes files after propagation', () async {
      await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));
      adapter.advancePropagationClock();
      final files = await adapter.list('sstables', extension: '.sst');
      expect(files, contains('a.sst'));
    });

    test(
      'getEtag returns null for a different observer before propagation, non-null after',
      () async {
        final observer = CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        );
        await adapter.upload('a.sst', Uint8List.fromList([1]));
        // Observer has not advanced its cursor — ETag is null.
        expect(await observer.getEtag('a.sst'), isNull);
        observer.advancePropagationClock();
        expect(await observer.getEtag('a.sst'), isNotNull);
      },
    );

    test(
      'advancePropagationClockTo partially reveals writes to an observer',
      () async {
        final observer = CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        );
        await adapter.upload('a.sst', Uint8List.fromList([1])); // seq 1
        await adapter.upload('b.sst', Uint8List.fromList([2])); // seq 2

        // Advance the observer to seq 1 only — a.sst visible, b.sst not.
        observer.advancePropagationClockTo(backend.currentWriteSeq - 1);
        expect(await observer.download('a.sst'), isNotNull);
        expect(await observer.download('b.sst'), isNull);

        // Full advance reveals both.
        observer.advancePropagationClock();
        expect(await observer.download('b.sst'), isNotNull);
      },
    );

    test('providesAtomicCas is false for eventual profile', () {
      expect(adapter.providesAtomicCas, isFalse);
    });

    group('conformance (CloudSemanticsAdapter / eventual)', () {
      runSyncAdapterConformance(
        factory: () => CloudSemanticsAdapter(
          backend: SharedBackendAdapter(SharedCloudBackend()),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        ),
        expectAtomicCas: false,
      );
    });
  });

  group('Mixed-mode: REST + FS-view front-ends over one backend', () {
    test(
      'write via REST front-end is eventually visible to FS-view front-end',
      () async {
        final backend = SharedCloudBackend();

        // Device 0: REST-style eventual-consistency front-end.
        final restView = CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend, deviceId: 'dev-rest'),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        );

        // Device 1: FS-view front-end (strongly consistent — local-FS semantics).
        final fsView = SharedBackendAdapter(backend, deviceId: 'dev-fs');

        // A second REST observer (different device, no clock advance yet).
        final restObserver = CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend, deviceId: 'dev-rest-2'),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 100),
        );

        final bytes = Uint8List.fromList([1, 2, 3]);
        await restView.upload('sstables/foo.sst', bytes);

        // FS-view sees it immediately (strong consistency).
        expect(await fsView.download('sstables/foo.sst'), equals(bytes));

        // Writer (restView) sees its own write immediately (read-your-writes).
        expect(await restView.download('sstables/foo.sst'), equals(bytes));

        // A different REST observer has not advanced its cursor — not visible.
        expect(await restObserver.download('sstables/foo.sst'), isNull);

        // After settling, the observer sees it too.
        restObserver.advancePropagationClock();
        expect(await restObserver.download('sstables/foo.sst'), equals(bytes));
      },
    );

    test('write via FS front-end is immediately visible to REST front-end '
        'after propagation', () async {
      final backend = SharedCloudBackend();

      final restView = CloudSemanticsAdapter(
        backend: SharedBackendAdapter(backend, deviceId: 'dev-rest'),
        profile: CloudProfile.eventual(maxPropagationDelayMs: 50),
      );
      final fsView = SharedBackendAdapter(backend, deviceId: 'dev-fs');

      final bytes = Uint8List.fromList([10, 20]);
      await fsView.upload('sstables/bar.sst', bytes);

      // FS-view reads back immediately.
      expect(await fsView.download('sstables/bar.sst'), equals(bytes));

      // REST-view not yet.
      expect(await restView.download('sstables/bar.sst'), isNull);

      restView.advancePropagationClock();
      expect(await restView.download('sstables/bar.sst'), equals(bytes));
    });

    test('CAS on shared backend is reflected across both front-ends', () async {
      final backend = SharedCloudBackend();
      final fsView = SharedBackendAdapter(backend, deviceId: 'dev-fs');
      final restView = CloudSemanticsAdapter(
        backend: SharedBackendAdapter(backend, deviceId: 'dev-rest'),
        profile: const CloudProfile.strong(),
      );

      // REST-view creates the lease file via CAS.
      final created = await restView.compareAndSwap(
        '.lease',
        Uint8List.fromList([1]),
        ifMatchEtag: null,
      );
      expect(created, isTrue);

      // FS-view sees it immediately.
      expect(await fsView.download('.lease'), isNotNull);

      // A second CAS create-if-absent from FS-view must fail.
      final duplicate = await fsView.compareAndSwap(
        '.lease',
        Uint8List.fromList([2]),
        ifMatchEtag: null,
      );
      expect(duplicate, isFalse);
    });
  });
}
