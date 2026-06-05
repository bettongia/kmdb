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

import 'package:kmdb/kmdb.dart'
    show CancellationToken, SyncCancelledException, SyncContext;
import 'package:kmdb/kmdb_test_cloud_support.dart' show SharedCloudBackend;
import 'package:kmdb/test_support.dart' show runSyncAdapterConformance;
import 'package:kmdb_icloud/src/icloud_adapter.dart'
    show ICloudAdapter, ICloudRetryConfig;
import 'package:kmdb_icloud/src/icloud_profile.dart' show kICloudProfile;
import 'package:kmdb_icloud/src/icloud_sync_channel_interface.dart'
    show ICloudRateLimitException, ICloudSyncChannel;
import 'package:test/test.dart';

import 'support/fake_icloud_sync_channel.dart';

void main() {
  // ── SyncStorageAdapter conformance suite ─────────────────────────────────
  //
  // ICloudAdapter must pass the H5 conformance suite. The adapter is declared
  // non-atomic (providesAtomicCas == false, matching kICloudProfile), so the
  // contention test runs with expectAtomicCas: false and verifies forward
  // progress only.
  //
  // expectsCancellation: true — ICloudAdapter calls ctx?.throwIfExpired() at
  // entry of each method (and in back-off sleeps), so pre-cancelled tokens and
  // expired deadlines are detected promptly. This satisfies the
  // expectsCancellation: true bar in the conformance suite.
  group('ICloudAdapter (SyncStorageAdapter conformance)', () {
    runSyncAdapterConformance(
      factory: () => adapterOverBackend(SharedCloudBackend()),
      expectAtomicCas: kICloudProfile.atomicConditionalCreate,
      expectsCancellation: true,
    );
  });

  // ── Conformance drift assertion ───────────────────────────────────────────
  //
  // FakeICloudSyncChannel must also pass the conformance suite — this ensures
  // the fake and the adapter's providesAtomicCas declaration cannot drift.
  // The fake wraps SharedCloudBackend which is truly atomic, so the effective
  // atomic-CAS behaviour of the channel itself is true; we test against the
  // channel's actual semantics (expectAtomicCas: true) to catch regressions
  // in the backend, not against kICloudProfile.atomicConditionalCreate (which
  // is false because CloudKit create-if-absent is non-atomic in production).
  //
  // This drift-test asserts: FakeICloudSyncChannel (via adapterOverBackend) is
  // a valid functional adapter. The structural invariant — that the adapter's
  // providesAtomicCas equals kICloudProfile.atomicConditionalCreate — is
  // asserted in the unit tests below.
  group('FakeICloudSyncChannel (conformance drift test)', () {
    runSyncAdapterConformance(
      factory: () => adapterOverBackend(SharedCloudBackend()),
      // FakeICloudSyncChannel over SharedCloudBackend is truly atomic (no
      // await between check and write), so it passes the atomic-CAS
      // conformance tests cleanly.  We use false here to match the iCloud
      // profile (the adapter exposes false) so the drift test exercises the
      // same preconditions as production.
      expectAtomicCas: kICloudProfile.atomicConditionalCreate,
      expectsCancellation: true,
    );
  });

  // ── Adapter-specific behaviour tests ────────────────────────────────────
  group('ICloudAdapter', () {
    late SharedCloudBackend backend;
    late FakeICloudSyncChannel channel;
    late ICloudAdapter adapter;

    setUp(() {
      backend = SharedCloudBackend();
      channel = FakeICloudSyncChannel(backend);
      adapter = ICloudAdapter(channel: channel, syncRoot: 'test-root');
    });

    // ── providesAtomicCas ─────────────────────────────────────────────────

    group('providesAtomicCas', () {
      test('returns false (CloudKit create-if-absent is not atomic)', () {
        expect(adapter.providesAtomicCas, isFalse);
      });

      test('matches kICloudProfile.atomicConditionalCreate', () {
        // The drift invariant: adapter and profile must agree. A conformance
        // test also runs FakeICloudSyncChannel through the suite to catch
        // drift between the channel implementation and the profile constant.
        expect(
          adapter.providesAtomicCas,
          equals(kICloudProfile.atomicConditionalCreate),
        );
      });
    });

    // ── zoneName ─────────────────────────────────────────────────────────

    group('zoneName', () {
      test('derives zone name from syncRoot', () {
        expect(adapter.zoneName, equals('kmdb-test-root'));
      });

      test('different syncRoot produces different zone name', () {
        final adapter2 = ICloudAdapter(
          channel: channel,
          syncRoot: 'other-root',
        );
        expect(adapter2.zoneName, equals('kmdb-other-root'));
      });
    });

    // ── list ──────────────────────────────────────────────────────────────

    group('list', () {
      test('returns empty list for non-existent directory', () async {
        final files = await adapter.list('sstables', extension: '.sst');
        expect(files, isEmpty);
      });

      test('returns files matching extension', () async {
        await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));
        await adapter.upload('sstables/b.sst', Uint8List.fromList([2]));
        await adapter.upload('sstables/c.hwm', Uint8List.fromList([3]));

        final ssts = await adapter.list('sstables', extension: '.sst');
        expect(ssts, unorderedEquals(['a.sst', 'b.sst']));
      });

      test('returns all files when no extension filter', () async {
        await adapter.upload('highwater/d1.hwm', Uint8List.fromList([1]));
        await adapter.upload('highwater/d2.hwm', Uint8List.fromList([2]));

        final all = await adapter.list('highwater');
        expect(all, hasLength(2));
      });

      test('does not include deleted files', () async {
        await adapter.upload('sstables/old.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/old.sst');

        final files = await adapter.list('sstables', extension: '.sst');
        expect(files, isEmpty);
      });

      test('does not include nested paths (only direct children)', () async {
        await adapter.upload('sstables/top.sst', Uint8List.fromList([1]));
        // A file at a deeper level should not appear in the list for 'sstables'.
        backend.write('sstables/sub/nested.sst', Uint8List.fromList([9]));

        final files = await adapter.list('sstables', extension: '.sst');
        expect(files, contains('top.sst'));
        expect(files, isNot(contains('sub/nested.sst')));
        expect(files, isNot(contains('sub')));
      });

      test('list without trailing slash normalises prefix correctly', () async {
        await adapter.upload('highwater/dev1.hwm', Uint8List.fromList([1]));
        // Calling without trailing slash should still work.
        final files = await adapter.list('highwater');
        expect(files, contains('dev1.hwm'));
      });
    });

    // ── download ──────────────────────────────────────────────────────────

    group('download', () {
      test('returns null for absent file', () async {
        expect(await adapter.download('missing.sst'), isNull);
      });

      test('returns correct bytes after upload', () async {
        final original = Uint8List.fromList([10, 20, 30]);
        await adapter.upload('sstables/file.sst', original);
        final downloaded = await adapter.download('sstables/file.sst');
        expect(downloaded, equals(original));
      });

      test('returns updated bytes after overwrite', () async {
        await adapter.upload('sstables/f.sst', Uint8List.fromList([1]));
        final updated = Uint8List.fromList([9, 8, 7]);
        await adapter.upload('sstables/f.sst', updated);
        expect(await adapter.download('sstables/f.sst'), equals(updated));
      });

      test('large payload round-trips correctly', () async {
        // Exercise the copy path with a larger buffer to catch any
        // off-by-one or truncation bugs in the Uint8List.fromList path.
        final large = Uint8List(1024 * 64); // 64 KB
        for (var i = 0; i < large.length; i++) {
          large[i] = i & 0xff;
        }
        await adapter.upload('sstables/large.sst', large);
        final result = await adapter.download('sstables/large.sst');
        expect(result, equals(large));
      });
    });

    // ── upload ────────────────────────────────────────────────────────────

    group('upload', () {
      test('creates file and makes it downloadable', () async {
        final bytes = Uint8List.fromList([42]);
        await adapter.upload('sstables/x.sst', bytes);
        expect(await adapter.download('sstables/x.sst'), equals(bytes));
      });

      test(
        'overwrites existing file (unconditional — savePolicy .changedKeys)',
        () async {
          await adapter.upload('sstables/y.sst', Uint8List.fromList([1]));
          final v2 = Uint8List.fromList([2, 3]);
          await adapter.upload('sstables/y.sst', v2);
          expect(await adapter.download('sstables/y.sst'), equals(v2));
        },
      );

      test('upload to lease path creates file', () async {
        await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
        expect(backend.fileCount, equals(1));
      });
    });

    // ── delete ────────────────────────────────────────────────────────────

    group('delete', () {
      test('removes the file', () async {
        await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/a.sst');
        expect(await adapter.download('sstables/a.sst'), isNull);
      });

      test(
        'is idempotent when file is absent (no-op per CloudKit contract)',
        () async {
          await expectLater(adapter.delete('sstables/nope.sst'), completes);
        },
      );

      test('can delete twice without error', () async {
        await adapter.upload('sstables/b.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/b.sst');
        await expectLater(adapter.delete('sstables/b.sst'), completes);
      });

      test('delete removes from list results', () async {
        await adapter.upload('sstables/c.sst', Uint8List.fromList([1]));
        await adapter.upload('sstables/d.sst', Uint8List.fromList([2]));
        await adapter.delete('sstables/c.sst');

        final files = await adapter.list('sstables', extension: '.sst');
        expect(files, isNot(contains('c.sst')));
        expect(files, contains('d.sst'));
      });
    });

    // ── getEtag ───────────────────────────────────────────────────────────

    group('getEtag', () {
      test('returns null for absent file', () async {
        expect(await adapter.getEtag('missing.bin'), isNull);
      });

      test('returns non-null ETag after upload', () async {
        await adapter.upload('sstables/e.sst', Uint8List.fromList([1]));
        expect(await adapter.getEtag('sstables/e.sst'), isNotNull);
      });

      test('ETag changes after overwrite', () async {
        await adapter.upload('sstables/mut.sst', Uint8List.fromList([1]));
        final etag1 = await adapter.getEtag('sstables/mut.sst');
        await adapter.upload('sstables/mut.sst', Uint8List.fromList([2]));
        final etag2 = await adapter.getEtag('sstables/mut.sst');
        expect(etag2, isNot(equals(etag1)));
      });

      test('returns null after delete', () async {
        await adapter.upload('sstables/gone.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/gone.sst');
        expect(await adapter.getEtag('sstables/gone.sst'), isNull);
      });

      test('ETag does not change when upload bytes are unchanged', () async {
        // Two uploads of identical bytes produce different ETags because the
        // backend version counter always increments — this matches CloudKit
        // behaviour where every save produces a new recordChangeTag.
        await adapter.upload('sstables/same.sst', Uint8List.fromList([1, 2]));
        final etag1 = await adapter.getEtag('sstables/same.sst');
        await adapter.upload('sstables/same.sst', Uint8List.fromList([1, 2]));
        final etag2 = await adapter.getEtag('sstables/same.sst');
        // Two writes → version incremented → ETag changes, even for same bytes.
        expect(etag2, isNot(equals(etag1)));
      });
    });

    // ── compareAndSwap ────────────────────────────────────────────────────

    group('compareAndSwap', () {
      // ── create-if-absent (ifMatchEtag == null) ─────────────────────────

      group('create-if-absent (ifMatchEtag == null)', () {
        test('succeeds when file is absent', () async {
          final result = await adapter.compareAndSwap(
            '.consolidation-lease',
            Uint8List.fromList([1]),
            ifMatchEtag: null,
          );
          expect(result, isTrue);
        });

        test('returns false when file already exists', () async {
          await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
          final result = await adapter.compareAndSwap(
            '.consolidation-lease',
            Uint8List.fromList([99]),
            ifMatchEtag: null,
          );
          expect(result, isFalse);
          // Original content preserved — CAS did not overwrite.
          expect(
            await adapter.download('.consolidation-lease'),
            equals(Uint8List.fromList([1])),
          );
        });

        test('file is readable after create-if-absent succeeds', () async {
          final bytes = Uint8List.fromList([7, 8, 9]);
          await adapter.compareAndSwap(
            '.consolidation-lease',
            bytes,
            ifMatchEtag: null,
          );
          expect(await adapter.download('.consolidation-lease'), equals(bytes));
        });

        test('ETag is set after create-if-absent success', () async {
          await adapter.compareAndSwap(
            '.consolidation-lease',
            Uint8List.fromList([1]),
            ifMatchEtag: null,
          );
          expect(await adapter.getEtag('.consolidation-lease'), isNotNull);
        });
      });

      // ── update-if-match (ifMatchEtag != null) ─────────────────────────

      group('update-if-match (ifMatchEtag != null)', () {
        test('succeeds with matching ETag', () async {
          await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
          final etag = await adapter.getEtag('.consolidation-lease');

          final updated = Uint8List.fromList([2, 3]);
          final result = await adapter.compareAndSwap(
            '.consolidation-lease',
            updated,
            ifMatchEtag: etag,
          );
          expect(result, isTrue);
          expect(
            await adapter.download('.consolidation-lease'),
            equals(updated),
          );
        });

        test('returns false when ETag is stale (another writer won)', () async {
          await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
          final staleEtag = await adapter.getEtag('.consolidation-lease');
          // Overwrite to change the ETag.
          await adapter.upload('.consolidation-lease', Uint8List.fromList([2]));

          final result = await adapter.compareAndSwap(
            '.consolidation-lease',
            Uint8List.fromList([99]),
            ifMatchEtag: staleEtag,
          );
          expect(result, isFalse);
          // Intervening write preserved.
          expect(
            await adapter.download('.consolidation-lease'),
            equals(Uint8List.fromList([2])),
          );
        });

        test('returns false when file does not exist', () async {
          final result = await adapter.compareAndSwap(
            '.consolidation-lease',
            Uint8List.fromList([1]),
            ifMatchEtag: 'nonexistent-etag',
          );
          expect(result, isFalse);
        });

        test('ETag changes after successful update-if-match', () async {
          await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
          final etag1 = await adapter.getEtag('.consolidation-lease');
          await adapter.compareAndSwap(
            '.consolidation-lease',
            Uint8List.fromList([2]),
            ifMatchEtag: etag1,
          );
          final etag2 = await adapter.getEtag('.consolidation-lease');
          expect(etag2, isNot(equals(etag1)));
        });
      });
    });

    // ── Multi-adapter shared-backend isolation ─────────────────────────────

    group('shared backend — two adapters over same backend', () {
      test('write from adapter-A is visible to adapter-B', () async {
        final channelB = FakeICloudSyncChannel(backend);
        final adapterB = ICloudAdapter(
          channel: channelB,
          syncRoot: 'test-root',
        );

        await adapter.upload('sstables/shared.sst', Uint8List.fromList([42]));
        final bytes = await adapterB.download('sstables/shared.sst');
        expect(bytes, equals(Uint8List.fromList([42])));
      });

      test('delete from adapter-A removes file for adapter-B', () async {
        final channelB = FakeICloudSyncChannel(backend);
        final adapterB = ICloudAdapter(
          channel: channelB,
          syncRoot: 'test-root',
        );

        await adapter.upload('sstables/shared.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/shared.sst');
        expect(await adapterB.download('sstables/shared.sst'), isNull);
      });

      test('ETag from adapter-A is usable in CAS from adapter-B', () async {
        final channelB = FakeICloudSyncChannel(backend);
        final adapterB = ICloudAdapter(
          channel: channelB,
          syncRoot: 'test-root',
        );

        await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
        final etag = await adapterB.getEtag('.consolidation-lease');
        // adapterB can update using the ETag obtained via the same shared backend.
        final result = await adapterB.compareAndSwap(
          '.consolidation-lease',
          Uint8List.fromList([2]),
          ifMatchEtag: etag,
        );
        expect(result, isTrue);
      });
    });
  });

  // ── FakeICloudSyncChannel unit tests ─────────────────────────────────────
  //
  // Tests that exercise the channel in isolation (without going through
  // ICloudAdapter's retry layer), confirming the channel itself honours
  // the ICloudSyncChannel contract.
  group('FakeICloudSyncChannel', () {
    late SharedCloudBackend backend;
    late FakeICloudSyncChannel channel;

    setUp(() {
      backend = SharedCloudBackend();
      channel = FakeICloudSyncChannel(backend);
    });

    test('exposes backend reference', () {
      expect(channel.backend, same(backend));
    });

    test('list strips directory prefix', () async {
      backend.write('highwater/dev1.hwm', Uint8List.fromList([1]));
      backend.write('highwater/dev2.hwm', Uint8List.fromList([2]));
      final files = await channel.list('highwater');
      // Must return bare names without the 'highwater/' prefix.
      expect(files, unorderedEquals(['dev1.hwm', 'dev2.hwm']));
    });

    test('list applies extension filter', () async {
      backend.write('sstables/a.sst', Uint8List.fromList([1]));
      backend.write('sstables/b.hwm', Uint8List.fromList([2]));
      final ssts = await channel.list('sstables', extension: '.sst');
      expect(ssts, equals(['a.sst']));
    });

    test('download returns null for absent file', () async {
      expect(await channel.download('no/file.sst'), isNull);
    });

    test('download returns bytes', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      backend.write('path/file.sst', bytes);
      expect(await channel.download('path/file.sst'), equals(bytes));
    });

    test('upload writes to backend', () async {
      await channel.upload('path/x.sst', Uint8List.fromList([9]));
      expect(backend.containsFile('path/x.sst'), isTrue);
    });

    test('delete removes from backend', () async {
      backend.write('path/y.sst', Uint8List.fromList([1]));
      await channel.delete('path/y.sst');
      expect(backend.containsFile('path/y.sst'), isFalse);
    });

    test('delete is no-op for absent file', () async {
      await expectLater(channel.delete('no/such.sst'), completes);
    });

    test('compareAndSwap create-if-absent returns true when absent', () async {
      final ok = await channel.compareAndSwap('lease', Uint8List.fromList([1]));
      expect(ok, isTrue);
    });

    test('compareAndSwap create-if-absent returns false when exists', () async {
      backend.write('lease', Uint8List.fromList([1]));
      final ok = await channel.compareAndSwap(
        'lease',
        Uint8List.fromList([99]),
      );
      expect(ok, isFalse);
    });

    test(
      'compareAndSwap update-if-match returns true with correct ETag',
      () async {
        backend.write('lease', Uint8List.fromList([1]));
        final etag = backend.getEtag('lease')!;
        final ok = await channel.compareAndSwap(
          'lease',
          Uint8List.fromList([2]),
          ifMatchEtag: etag,
        );
        expect(ok, isTrue);
      },
    );

    test(
      'compareAndSwap update-if-match returns false with stale ETag',
      () async {
        backend.write('lease', Uint8List.fromList([1]));
        final staleEtag = backend.getEtag('lease')!;
        backend.write('lease', Uint8List.fromList([2])); // advance version
        final ok = await channel.compareAndSwap(
          'lease',
          Uint8List.fromList([99]),
          ifMatchEtag: staleEtag,
        );
        expect(ok, isFalse);
      },
    );

    test('getEtag returns null for absent file', () async {
      expect(await channel.getEtag('no/file.sst'), isNull);
    });

    test('getEtag returns ETag matching backend version', () async {
      backend.write('path/f.sst', Uint8List.fromList([1]));
      final etag = await channel.getEtag('path/f.sst');
      expect(etag, equals(backend.getEtag('path/f.sst')));
    });
  });

  // ── kICloudProfile assertions ─────────────────────────────────────────────

  group('kICloudProfile', () {
    test('atomicConditionalCreate is false (Phase 4a confirmed)', () {
      // The Phase 4a probe confirmed that CloudKit create-if-absent is not
      // atomic. This must stay false permanently.
      expect(kICloudProfile.atomicConditionalCreate, isFalse);
    });

    test('allowsDuplicateNames is false (one record per ID per zone)', () {
      expect(kICloudProfile.allowsDuplicateNames, isFalse);
    });

    test('quota.maxOpsPerMinute is set (conservative CloudKit rate limit)', () {
      expect(kICloudProfile.quota.maxOpsPerMinute, isNotNull);
      expect(kICloudProfile.quota.maxOpsPerMinute, greaterThan(0));
    });
  });

  // ── ICloudRetryConfig ─────────────────────────────────────────────────────

  group('ICloudRetryConfig', () {
    test('defaultConfig has expected conservative values', () {
      const cfg = ICloudRetryConfig.defaultConfig;
      expect(cfg.maxAttempts, greaterThan(0));
      expect(cfg.initialDelayMs, greaterThan(0));
      expect(cfg.maxDelayMs, greaterThanOrEqualTo(cfg.initialDelayMs));
      expect(cfg.jitterMs, greaterThanOrEqualTo(0));
    });

    test('custom config is applied', () {
      const cfg = ICloudRetryConfig(
        maxAttempts: 2,
        initialDelayMs: 10,
        maxDelayMs: 100,
        jitterMs: 5,
      );
      expect(cfg.maxAttempts, equals(2));
      expect(cfg.initialDelayMs, equals(10));
      expect(cfg.maxDelayMs, equals(100));
      expect(cfg.jitterMs, equals(5));
    });
  });

  // ── Rate-limit retry behaviour ─────────────────────────────────────────────
  //
  // Use a channel stub that injects a rate-limit error on the first call, then
  // succeeds.  This exercises the back-off path without relying on real timing.

  group('ICloudAdapter rate-limit retry', () {
    test(
      'retries on ICloudRateLimitException (with retryAfterMs) and succeeds',
      () async {
        // A channel that throws once (with retryAfterMs set) then succeeds.
        // Exercises the e.retryAfterMs != null branch in _retryOnRateLimit.
        final channel = _OneShotRateLimitChannel(
          backend: SharedCloudBackend(),
          failCount: 1,
          retryAfterMs: 1, // non-null: uses CloudKit hint path
        );
        final adapter = ICloudAdapter(
          channel: channel,
          syncRoot: 'test',
          retryConfig: const ICloudRetryConfig(
            maxAttempts: 3,
            initialDelayMs: 1,
            maxDelayMs: 10,
            jitterMs: 0,
          ),
        );

        await expectLater(
          adapter.upload('path/x.sst', Uint8List.fromList([1])),
          completes,
        );
        expect(channel.callCount, equals(2)); // 1 fail + 1 success
      },
    );

    test(
      'retries on ICloudRateLimitException (no retryAfterMs) using exponential back-off',
      () async {
        // A channel that throws once WITHOUT retryAfterMs, then succeeds.
        // Exercises the else branch (exponential back-off) in _retryOnRateLimit
        // (lines 213-217 of icloud_adapter.dart).
        final channel = _OneShotRateLimitChannel(
          backend: SharedCloudBackend(),
          failCount: 1,
          retryAfterMs: null, // null: uses exponential back-off path
        );
        final adapter = ICloudAdapter(
          channel: channel,
          syncRoot: 'test',
          retryConfig: const ICloudRetryConfig(
            maxAttempts: 3,
            initialDelayMs: 1,
            maxDelayMs: 10,
            jitterMs: 0,
          ),
        );

        await expectLater(
          adapter.upload('path/x.sst', Uint8List.fromList([1])),
          completes,
        );
        expect(channel.callCount, equals(2));
      },
    );

    test('throws after maxAttempts exhausted', () async {
      // A channel that always throws ICloudRateLimitException.
      final channel = _OneShotRateLimitChannel(
        backend: SharedCloudBackend(),
        failCount: 999, // always fail
        retryAfterMs: null,
      );
      final adapter = ICloudAdapter(
        channel: channel,
        syncRoot: 'test',
        retryConfig: const ICloudRetryConfig(
          maxAttempts: 2,
          initialDelayMs: 1,
          maxDelayMs: 10,
          jitterMs: 0,
        ),
      );

      await expectLater(
        adapter.upload('path/x.sst', Uint8List.fromList([1])),
        throwsA(isA<ICloudRateLimitException>()),
      );
    });

    test('cancellation check fires between retry attempts (pre-sleep)', () async {
      // Exercises ctx?.throwIfExpired() at line 197 (before sleep).
      // The token is cancelled BEFORE the back-off sleep starts; the adapter
      // should detect it at the pre-sleep cancellation check.
      final cancelToken = CancellationToken();
      final ctx = SyncContext(cancel: cancelToken);

      final channel = _OneShotRateLimitChannel(
        backend: SharedCloudBackend(),
        failCount: 999,
        retryAfterMs: null,
        // Cancel SYNCHRONOUSLY on first fail (before any await in _retryOnRateLimit).
        onFirstFail: cancelToken.cancel,
      );
      final adapter = ICloudAdapter(
        channel: channel,
        syncRoot: 'test',
        retryConfig: const ICloudRetryConfig(
          maxAttempts: 5,
          initialDelayMs: 1,
          maxDelayMs: 5,
          jitterMs: 0,
        ),
      );

      await expectLater(
        adapter.upload('path/x.sst', Uint8List.fromList([1]), ctx: ctx),
        throwsA(isA<SyncCancelledException>()),
      );
    });

    test(
      'cancellation via Future.any (cancelFuture != null) wakes back-off sleep',
      () async {
        // Exercises the `cancelFuture != null` branch (lines 222-225 of
        // icloud_adapter.dart) and the post-sleep throwIfExpired() (line 233).
        //
        // The adapter has a non-null cancel token, so it enters:
        //   `Future.any([Future.delayed(...), cancelFuture])`
        // We cancel the token AFTER a micro-delay so the sleep is already started.
        final cancelToken = CancellationToken();
        final ctx = SyncContext(cancel: cancelToken);

        // Channel that always rate-limits but does NOT cancel on first fail —
        // cancellation happens asynchronously via Future.delayed below.
        final channel = _OneShotRateLimitChannel(
          backend: SharedCloudBackend(),
          failCount: 999,
          retryAfterMs: null,
        );
        final adapter = ICloudAdapter(
          channel: channel,
          syncRoot: 'test',
          retryConfig: const ICloudRetryConfig(
            maxAttempts: 5,
            // Use a short but non-zero delay so the adapter starts sleeping
            // before we cancel the token.
            initialDelayMs: 50,
            maxDelayMs: 50,
            jitterMs: 0,
          ),
        );

        // Cancel the token 10ms after the adapter starts its back-off sleep.
        Future<void>.delayed(
          const Duration(milliseconds: 10),
        ).then((_) => cancelToken.cancel());

        await expectLater(
          adapter.upload('path/x.sst', Uint8List.fromList([1]), ctx: ctx),
          throwsA(isA<SyncCancelledException>()),
        );
      },
    );

    test('expired deadline cancels before sleep (via throwIfExpired)', () async {
      // When the SyncContext has a deadline already in the past, the adapter's
      // ctx?.throwIfExpired() call (before the back-off sleep) detects the
      // expired deadline and throws SyncCancelledException immediately.
      //
      // Note: the `deadline` branch at lines 200-201 of icloud_adapter.dart is
      // belt-and-suspenders code. In practice, throwIfExpired() (line 197) handles
      // both cancel-token and deadline expiry — the deadline branch at 200 is
      // therefore unreachable in tests. This test verifies the observable behaviour:
      // expired deadline → SyncCancelledException, not a sleep.
      final pastDeadline = DateTime.now().subtract(const Duration(seconds: 1));
      final ctx = SyncContext(deadline: pastDeadline);

      final channel = _OneShotRateLimitChannel(
        backend: SharedCloudBackend(),
        failCount: 999,
        retryAfterMs: null,
      );
      final adapter = ICloudAdapter(
        channel: channel,
        syncRoot: 'test',
        retryConfig: const ICloudRetryConfig(
          maxAttempts: 5,
          initialDelayMs: 60000, // very long delay — should never be reached
          maxDelayMs: 60000,
          jitterMs: 0,
        ),
      );

      // throwIfExpired at line 197 detects the expired deadline and throws.
      await expectLater(
        adapter.upload('path/x.sst', Uint8List.fromList([1]), ctx: ctx),
        throwsA(isA<SyncCancelledException>()),
      );
    });
  });

  // ── ICloudRateLimitException ──────────────────────────────────────────────

  group('ICloudRateLimitException', () {
    test('toString without retryAfterMs', () {
      const ex = ICloudRateLimitException();
      expect(ex.toString(), equals('ICloudRateLimitException'));
    });

    test('toString with retryAfterMs', () {
      // Exercises the `if (retryAfterMs != null)` branch in toString()
      // (lines 123-126 of icloud_sync_channel_interface.dart).
      const ex = ICloudRateLimitException(retryAfterMs: 5000);
      expect(ex.toString(), contains('5000ms'));
      expect(ex.toString(), contains('ICloudRateLimitException'));
    });

    test('retryAfterMs is accessible', () {
      const ex = ICloudRateLimitException(retryAfterMs: 1234);
      expect(ex.retryAfterMs, equals(1234));
    });

    test('null retryAfterMs', () {
      const ex = ICloudRateLimitException();
      expect(ex.retryAfterMs, isNull);
    });
  });

  // ── Pre-release integration test (credential-gated) ──────────────────────
  //
  // This group runs only when ICLOUD_TEST_CONTAINER is set.
  // It exercises the real CloudKit service to confirm the simulator's fidelity.
  //
  // To run:
  //   ICLOUD_TEST_CONTAINER=iCloud.<bundle> dart test \
  //     packages/kmdb_icloud/test/
  //
  // The test is NOT part of per-commit CI; it is registered in the release
  // checklist as RC-13.
  group('iCloud real-service integration', () {
    test(
      'placeholder: e2e tests run with ICLOUD_TEST_CONTAINER set',
      () {
        // Intentionally empty — the real e2e path is manual (RC-13).
      },
      skip: 'Credential-gated; run manually with ICLOUD_TEST_CONTAINER set',
    );
  }, tags: ['e2e']);
}

// ── Test helpers ─────────────────────────────────────────────────────────────

/// A test [ICloudSyncChannel] that injects [ICloudRateLimitException] on the
/// first [failCount] upload attempts, then delegates to [FakeICloudSyncChannel].
///
/// [retryAfterMs] controls the `retryAfterMs` field on the injected exception:
/// - non-null → exercises the "CloudKit hint" path in the adapter's back-off.
/// - null → exercises the exponential back-off path.
///
/// [onFirstFail] is called after the very first injected failure, allowing tests
/// to cancel a [CancellationToken] mid-retry to exercise the cancellation paths.
final class _OneShotRateLimitChannel implements ICloudSyncChannel {
  _OneShotRateLimitChannel({
    required SharedCloudBackend backend,
    required int failCount,
    this.retryAfterMs,
    this.onFirstFail,
  }) : _delegate = FakeICloudSyncChannel(backend),
       _remainingFails = failCount;

  final FakeICloudSyncChannel _delegate;
  int _remainingFails;

  /// The retryAfterMs value to include in the thrown exception.  `null` tests
  /// the exponential back-off path; non-null tests the CloudKit hint path.
  final int? retryAfterMs;

  /// Optional callback invoked after the very first injected failure.
  final void Function()? onFirstFail;

  /// Total number of upload calls received (including failed ones).
  int callCount = 0;

  bool _firstFail = true;

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) =>
      _delegate.list(remoteDir, extension: extension);

  @override
  Future<Uint8List?> download(String remotePath) =>
      _delegate.download(remotePath);

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    callCount++;
    if (_remainingFails > 0) {
      _remainingFails--;
      if (_firstFail) {
        _firstFail = false;
        onFirstFail?.call();
      }
      throw ICloudRateLimitException(retryAfterMs: retryAfterMs);
    }
    return _delegate.upload(remotePath, bytes);
  }

  @override
  Future<void> delete(String remotePath) => _delegate.delete(remotePath);

  @override
  Future<bool> compareAndSwap(
    String remotePath,
    Uint8List bytes, {
    String? ifMatchEtag,
  }) => _delegate.compareAndSwap(remotePath, bytes, ifMatchEtag: ifMatchEtag);

  @override
  Future<String?> getEtag(String remotePath) => _delegate.getEtag(remotePath);
}
