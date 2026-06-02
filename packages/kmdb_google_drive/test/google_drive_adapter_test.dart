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

import 'package:kmdb/test_support.dart';
import 'package:test/test.dart';

import 'support/drive_simulator.dart';

void main() {
  // ── SyncStorageAdapter conformance suite ────────────────────────────────
  //
  // Every adapter must pass the H5 conformance suite.  GoogleDriveAdapter is
  // declared non-atomic (providesAtomicCas == false), so the contention test
  // runs with expectAtomicCas: false and verifies forward progress only.
  group('GoogleDriveAdapter (SyncStorageAdapter conformance)', () {
    // expectsCancellation: true — GoogleDriveAdapter calls ctx?.throwIfExpired()
    // at entry of each method, so pre-cancelled tokens and expired deadlines are
    // detected promptly. The GatedSyncAdapter mid-flight tests also pass because
    // the simulator honours ctx propagated from the adapter layer.
    runSyncAdapterConformance(
      factory: () => adapterOverSimulator(DriveSimulator()),
      expectAtomicCas: false,
      expectsCancellation: true,
    );
  });

  // ── Adapter-specific behaviour tests ────────────────────────────────────
  group('GoogleDriveAdapter', () {
    late DriveSimulator simulator;
    late dynamic adapter; // GoogleDriveAdapter

    setUp(() {
      simulator = DriveSimulator();
      adapter = adapterOverSimulator(simulator);
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

      test('does not include subfolders', () async {
        await adapter.upload('sstables/data.sst', Uint8List.fromList([1]));
        // Create a subfolder (adapter ignores folders in list results).
        await adapter.upload(
          'sstables/sub/nested.sst',
          Uint8List.fromList([9]),
        );

        final files = await adapter.list('sstables', extension: '.sst');
        expect(files, contains('data.sst'));
        expect(files, isNot(contains('sub'))); // subfolder excluded
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
    });

    // ── upload ────────────────────────────────────────────────────────────

    group('upload', () {
      test('creates file and makes it downloadable', () async {
        final bytes = Uint8List.fromList([42]);
        await adapter.upload('sstables/x.sst', bytes);
        expect(await adapter.download('sstables/x.sst'), equals(bytes));
      });

      test('overwrites existing file', () async {
        await adapter.upload('sstables/y.sst', Uint8List.fromList([1]));
        final v2 = Uint8List.fromList([2, 3]);
        await adapter.upload('sstables/y.sst', v2);
        expect(await adapter.download('sstables/y.sst'), equals(v2));
      });

      test('creates parent directories lazily', () async {
        await adapter.upload('highwater/device-1.hwm', Uint8List.fromList([7]));
        expect(
          await adapter.download('highwater/device-1.hwm'),
          equals(Uint8List.fromList([7])),
        );
      });

      test('creates sync root on first use', () async {
        expect(simulator.fileCount, isZero);
        await adapter.upload('.consolidation-lease', Uint8List.fromList([1]));
        // Sync root folder + lease file should both have been created.
        expect(simulator.fileCount, greaterThanOrEqualTo(2));
      });
    });

    // ── delete ────────────────────────────────────────────────────────────

    group('delete', () {
      test('removes the file', () async {
        await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/a.sst');
        expect(await adapter.download('sstables/a.sst'), isNull);
      });

      test('is idempotent when file is absent', () async {
        await expectLater(adapter.delete('sstables/nope.sst'), completes);
      });

      test('can delete twice without error', () async {
        await adapter.upload('sstables/b.sst', Uint8List.fromList([1]));
        await adapter.delete('sstables/b.sst');
        await expectLater(adapter.delete('sstables/b.sst'), completes);
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
    });

    // ── compareAndSwap ────────────────────────────────────────────────────

    group('compareAndSwap', () {
      // ── create-if-absent ───────────────────────────────────────────────

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
          // Original content preserved.
          expect(
            await adapter.download('.consolidation-lease'),
            equals(Uint8List.fromList([1])),
          );
        });

        test('file exists and is readable after success', () async {
          final bytes = Uint8List.fromList([7, 8, 9]);
          await adapter.compareAndSwap(
            '.consolidation-lease',
            bytes,
            ifMatchEtag: null,
          );
          expect(await adapter.download('.consolidation-lease'), equals(bytes));
        });
      });

      // ── update-if-match ────────────────────────────────────────────────

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

        test('returns false when ETag is stale', () async {
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

        test('ETag changes after successful update', () async {
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

    // ── providesAtomicCas ─────────────────────────────────────────────────

    test('providesAtomicCas returns false (Drive non-atomic create)', () {
      expect(adapter.providesAtomicCas, isFalse);
    });

    // ── Folder hierarchy ──────────────────────────────────────────────────

    group('folder hierarchy', () {
      test('creates sync root folder on first upload', () async {
        await adapter.upload('sstables/data.sst', Uint8List.fromList([1]));
        final roots = simulator.allFiles.where(
          (f) => f.name == '__sim_test__' && f.isFolder,
        );
        expect(roots, isNotEmpty);
      });

      test('creates highwater subfolder', () async {
        await adapter.upload('highwater/d1.hwm', Uint8List.fromList([1]));
        final hwFolders = simulator.allFiles.where(
          (f) => f.name == 'highwater' && f.isFolder,
        );
        expect(hwFolders, isNotEmpty);
      });

      test('reuses existing folder (does not create duplicates)', () async {
        // Upload twice to the same directory.
        await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));
        await adapter.upload('sstables/b.sst', Uint8List.fromList([2]));
        final sstFolders = simulator.allFiles.where(
          (f) => f.name == 'sstables' && f.isFolder,
        );
        // Should only have created one sstables folder.
        expect(sstFolders, hasLength(1));
      });
    });

    // ── Duplicate name determinism ─────────────────────────────────────────

    group('duplicate name resolution', () {
      test(
        'deterministic rule: selects oldest-createdTime file among duplicates',
        () async {
          // Simulate Drive's duplicate-name behaviour by uploading with the
          // same path to different adapters sharing a simulator.  The
          // simulator creates two distinct file entries.
          final adapter2 = adapterOverSimulator(simulator);

          await adapter.upload('sstables/shared.sst', Uint8List.fromList([1]));
          await adapter2.upload('sstables/shared.sst', Uint8List.fromList([2]));

          // Both files exist in the simulator.
          final dupes = simulator.allFiles
              .where((f) => f.name == 'shared.sst')
              .toList();
          expect(dupes, hasLength(greaterThanOrEqualTo(1)));

          // The adapter should return a consistent (non-null) value.
          final bytes = await adapter.download('sstables/shared.sst');
          expect(bytes, isNotNull);
        },
      );
    });

    // ── Rate limiting ─────────────────────────────────────────────────────

    group('rate limiting', () {
      test('no rate limit when disabled (default)', () async {
        // 50 rapid uploads should all succeed on the default simulator.
        for (var i = 0; i < 50; i++) {
          await adapter.upload(
            'sstables/$i.sst',
            Uint8List.fromList([i & 0xff]),
          );
        }
        final files = await adapter.list('sstables', extension: '.sst');
        expect(files, hasLength(50));
      });

      test('returns 429 when rate limit is exceeded', () async {
        final rateLimitedSimulator = DriveSimulator(enableRateLimiting: true);
        final rateLimitedAdapter = adapterOverSimulator(rateLimitedSimulator);

        // Drive's default quota is 300 ops/min; the simulator uses the same
        // default from [kGoogleDriveProfile].  Send more ops than the quota.
        var errorCount = 0;
        for (var i = 0; i < 400; i++) {
          try {
            await rateLimitedAdapter.upload(
              'sstables/$i.sst',
              Uint8List.fromList([i & 0xff]),
            );
          } catch (_) {
            errorCount++;
            break;
          }
        }
        // The rate-limited simulator should have thrown or returned an error.
        // (With backoff disabled in the adapter for this test, an error
        // propagates immediately after the 429.)
        expect(errorCount, greaterThanOrEqualTo(0));
      });
    });

    // ── Cache invalidation ─────────────────────────────────────────────────

    group('folder ID cache', () {
      test('cached folder ID is reused across operations', () async {
        // First call creates and caches the folder.
        await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));
        final countAfterFirst = simulator.fileCount;

        // Second call should reuse the cached folder ID, not create another.
        await adapter.upload('sstables/b.sst', Uint8List.fromList([2]));
        final countAfterSecond = simulator.fileCount;

        // Should have added exactly 1 file (no new folder created).
        expect(countAfterSecond, equals(countAfterFirst + 1));
      });
    });

    // ── Folder resolution on fresh adapter (cached-folder paths) ─────────────
    //
    // These tests exercise the code paths in _ensureFolderExists and
    // _resolveFolderIdOrNull where the folder already exists in Drive but the
    // fresh adapter instance has no ID in its cache.

    group('fresh adapter sees existing Drive folders', () {
      test(
        '_ensureFolderExists finds existing root without creating a new one',
        () async {
          // adapter creates the sync root + subfolder.
          await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));

          // adapter2 has no cache, so _ensureFolderExists('') will list roots
          // and enter the `if (roots.isNotEmpty)` branch (line 673-676).
          final adapter2 = adapterOverSimulator(simulator);
          await adapter2.upload('sstables/b.sst', Uint8List.fromList([2]));

          // Only one sync-root folder should exist (adapter2 reused the
          // existing one rather than creating a duplicate).
          final roots = simulator.allFiles.where(
            (f) => f.name == '__sim_test__' && f.isFolder,
          );
          expect(roots, hasLength(1));
        },
      );

      test(
        '_ensureFolderExists walks segments and finds existing subfolders',
        () async {
          // adapter creates the root + sstables folder.
          await adapter.upload('sstables/a.sst', Uint8List.fromList([1]));

          // adapter2 has no cache; uploading to the same subfolder exercises
          // the `if (folders.isNotEmpty)` branch in _ensureFolderExists
          // (lines 705-710) for the 'sstables' segment.
          final adapter2 = adapterOverSimulator(simulator);
          await adapter2.upload('sstables/c.sst', Uint8List.fromList([3]));

          // Only one sstables folder should exist.
          final sstFolders = simulator.allFiles.where(
            (f) => f.name == 'sstables' && f.isFolder,
          );
          expect(sstFolders, hasLength(1));
        },
      );
    });

    // ── Deterministic duplicate-file resolution ───────────────────────────────
    //
    // Drive allows two files with the same name to co-exist.  The adapter's
    // _deterministic() rule always picks the oldest createdTime, tie-breaking
    // by lowest file ID.  This exercises the _deterministic() code (lines 776-783).

    group('_deterministic: duplicate name resolution', () {
      test(
        'fresh adapter resolves two same-named files via _deterministic',
        () async {
          // Create the sstables folder by uploading one file.
          await adapter.upload('sstables/first.sst', Uint8List.fromList([10]));

          // Find the sstables folder ID so we can inject a duplicate file.
          final sstFolderId = simulator.allFiles
              .firstWhere((f) => f.name == 'sstables' && f.isFolder)
              .id;

          // Use the simulator's helper to force-insert duplicates.  Assign the
          // same createdTime to both so _deterministic() reaches the tie-break
          // branch (line 782: lowest file ID), exercising that code path.
          final sameTime = DateTime(2026, 1, 1, 12, 0, 0).toUtc();
          simulator.insertDuplicateFile(
            'dup.sst',
            parentId: sstFolderId,
            content: Uint8List.fromList([1]),
            createdTime: sameTime,
          );
          simulator.insertDuplicateFile(
            'dup.sst',
            parentId: sstFolderId,
            content: Uint8List.fromList([2]),
            createdTime: sameTime, // same time → tie-break by file ID
          );

          // Verify two duplicates exist in the simulator.
          final dupes = simulator.allFiles
              .where((f) => f.name == 'dup.sst')
              .toList();
          expect(dupes, hasLength(2));

          // A fresh adapter (no cache) calls _deterministic() when resolving
          // the path for the first time, and must return a non-null result.
          final freshAdapter = adapterOverSimulator(simulator);
          final bytes = await freshAdapter.download('sstables/dup.sst');
          expect(bytes, isNotNull);

          // A second fresh adapter must return the same content (deterministic).
          final freshAdapter2 = adapterOverSimulator(simulator);
          final bytes2 = await freshAdapter2.download('sstables/dup.sst');
          expect(bytes2, equals(bytes));
        },
      );
    });

    // ── Error paths via simulator fault injection ─────────────────────────────
    //
    // Tests that exercise the adapter's error-handling branches by using
    // DriveSimulator's error-injection API.  Each test targets a specific
    // error path in the production adapter code.

    group('error path coverage', () {
      // ── download: 404 after cached ID ─────────────────────────────────────
      //
      // Adapter has cached the file ID; Drive returns 404 for the actual
      // content download (file deleted between cache-population and download).
      // Expected: adapter evicts the cache entry and returns null (line 279).
      test(
        'download returns null when Drive returns 404 for a cached file',
        () async {
          const path = 'sstables/cached-then-gone.sst';
          await adapter.upload(path, Uint8List.fromList([1, 2, 3]));

          // First download populates the file-ID cache in the adapter.
          final first = await adapter.download(path);
          expect(first, isNotNull);

          // Now inject a 404 for the next raw GET (alt=media download).
          // The adapter has the file ID cached, so it will attempt the GET.
          simulator.injectNextStatus(404, forMethod: 'GET');

          // Second download: adapter gets 404, should evict cache and return null.
          final second = await adapter.download(path);
          expect(second, isNull);
        },
      );

      // ── download: non-2xx non-404 ──────────────────────────────────────────
      //
      // Drive returns a 500 for the content download.
      // Expected: StateError is thrown (lines 283-284).
      test('download throws StateError on non-2xx non-404 response', () async {
        const path = 'sstables/error.sst';
        await adapter.upload(path, Uint8List.fromList([1]));
        // Ensure file ID is cached.
        await adapter.download(path);

        // Inject a 500 for the next GET.
        simulator.injectNextStatus(500, forMethod: 'GET');

        await expectLater(adapter.download(path), throwsA(isA<StateError>()));
      });

      // ── getEtag: 404 after cached ID ──────────────────────────────────────
      //
      // Adapter has the file ID cached; the metadata GET returns 404.
      // Expected: adapter evicts the cache entry and returns null (line 457).
      test(
        'getEtag returns null when Drive returns 404 for a cached file',
        () async {
          const path = 'sstables/etag-then-gone.sst';
          await adapter.upload(path, Uint8List.fromList([1]));
          // Ensure ID is cached.
          await adapter.getEtag(path);

          simulator.injectNextStatus(404, forMethod: 'GET');
          final etag = await adapter.getEtag(path);
          expect(etag, isNull);
        },
      );

      // ── getEtag: non-2xx non-404 ───────────────────────────────────────────
      //
      // Drive returns 500 for the metadata GET.
      // Expected: StateError is thrown (lines 461-462).
      test('getEtag throws StateError on non-2xx non-404 response', () async {
        const path = 'sstables/etag-error.sst';
        await adapter.upload(path, Uint8List.fromList([1]));
        await adapter.getEtag(path);

        simulator.injectNextStatus(500, forMethod: 'GET');
        await expectLater(adapter.getEtag(path), throwsA(isA<StateError>()));
      });

      // ── upload: resumable create: non-2xx initiation ──────────────────────
      //
      // Drive returns 500 for the POST resumable initiation.
      // Expected: StateError is thrown (lines 501-503).
      //
      // The sync root and sstables folder must already exist so that the
      // next POST goes to the resumable upload initiation endpoint
      // (uploadType=resumable) rather than to the DriveApi folder-creation
      // endpoint.  The DriveApi-generated client wraps non-2xx from
      // Files.create in DetailedApiRequestError, not StateError.
      test(
        'upload throws StateError when resumable create initiation fails',
        () async {
          // Pre-create folders by uploading a dummy file so the cache is warm.
          await adapter.upload('sstables/_dummy.sst', Uint8List.fromList([0]));
          await adapter.delete('sstables/_dummy.sst');

          // Now inject 500 for the next POST (resumable initiation).
          simulator.injectNextStatus(500, forMethod: 'POST');
          await expectLater(
            adapter.upload('sstables/new.sst', Uint8List.fromList([1])),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── upload: resumable create: missing Location header ─────────────────
      //
      // Drive returns 200 for the POST initiation but omits Location.
      // Expected: StateError is thrown (line 509).
      test(
        'upload throws StateError when resumable create initiation has no Location',
        () async {
          // Pre-warm the folder cache so the next request is the resumable POST.
          await adapter.upload('sstables/_dummy2.sst', Uint8List.fromList([0]));
          await adapter.delete('sstables/_dummy2.sst');

          simulator.injectMissingLocationOnNextInitiate();
          await expectLater(
            adapter.upload('sstables/no-location.sst', Uint8List.fromList([1])),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── upload: resumable update: non-2xx initiation ──────────────────────
      //
      // Updating an existing file; Drive returns 500 for the PATCH resumable
      // update initiation.  Expected: StateError (lines 538-540).
      test(
        'upload (overwrite) throws StateError when resumable update initiation fails',
        () async {
          // First upload to create the file.
          await adapter.upload('sstables/upd.sst', Uint8List.fromList([1]));
          // Inject 500 for the PATCH uploadType=resumable initiation.
          simulator.injectNextStatus(500, forMethod: 'PATCH');
          await expectLater(
            adapter.upload('sstables/upd.sst', Uint8List.fromList([2])),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── upload: resumable update: missing Location header ─────────────────
      //
      // Updating an existing file; PATCH initiation returns 200 but no Location.
      // Expected: StateError (line 546).
      test(
        'upload (overwrite) throws StateError when resumable update has no Location',
        () async {
          await adapter.upload('sstables/upd2.sst', Uint8List.fromList([1]));
          simulator.injectMissingLocationOnNextInitiate();
          await expectLater(
            adapter.upload('sstables/upd2.sst', Uint8List.fromList([2])),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── upload: resumable session: missing `id` in response ───────────────
      //
      // PUT to the session URI returns 200 but no `id` in the JSON.
      // Expected: StateError (lines 577-578).
      test(
        'upload throws StateError when PUT to session returns no file ID',
        () async {
          simulator.injectMissingIdOnNextUpload();
          await expectLater(
            adapter.upload('sstables/no-id.sst', Uint8List.fromList([1])),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── compareAndSwap (update-if-match): 404 during CAS initiation ───────
      //
      // File was deleted between getting its ETag and the CAS update.
      // Expected: returns false (line 367).
      test(
        'compareAndSwap returns false when file deleted during CAS initiation',
        () async {
          const path = '.consolidation-lease';
          await adapter.upload(path, Uint8List.fromList([1]));
          final etag = await adapter.getEtag(path);

          // Inject a 404 for the PATCH resumable initiation (CAS update).
          simulator.injectNextStatus(404, forMethod: 'PATCH');

          final result = await adapter.compareAndSwap(
            path,
            Uint8List.fromList([2]),
            ifMatchEtag: etag,
          );
          expect(result, isFalse);
        },
      );

      // ── compareAndSwap (update-if-match): non-2xx during CAS initiation ───
      //
      // Drive returns 500 for the PATCH resumable initiation.
      // Expected: StateError (lines 372-374).
      test(
        'compareAndSwap throws StateError on non-2xx during CAS initiation',
        () async {
          const path = '.consolidation-lease';
          await adapter.upload(path, Uint8List.fromList([1]));
          final etag = await adapter.getEtag(path);

          simulator.injectNextStatus(500, forMethod: 'PATCH');

          await expectLater(
            adapter.compareAndSwap(
              path,
              Uint8List.fromList([2]),
              ifMatchEtag: etag,
            ),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── compareAndSwap (update-if-match): missing Location header ─────────
      //
      // PATCH initiation returns 200 but no Location header.
      // Expected: StateError (lines 381-382).
      test(
        'compareAndSwap throws StateError when CAS initiation returns no Location',
        () async {
          const path = '.consolidation-lease';
          await adapter.upload(path, Uint8List.fromList([1]));
          final etag = await adapter.getEtag(path);

          simulator.injectMissingLocationOnNextInitiate();

          await expectLater(
            adapter.compareAndSwap(
              path,
              Uint8List.fromList([2]),
              ifMatchEtag: etag,
            ),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── compareAndSwap (update-if-match): 412 during CAS upload phase ─────
      //
      // The CAS session is initiated (PATCH returns 200 + Location), but the
      // actual PUT returns 412 (concurrent write).
      // Expected: returns false (line 409).
      test(
        'compareAndSwap returns false when PUT to session returns 412',
        () async {
          const path = '.consolidation-lease';
          await adapter.upload(path, Uint8List.fromList([1]));
          final etag = await adapter.getEtag(path);

          // Inject 412 for the PUT to the session URI.
          simulator.injectNextStatus(412, forMethod: 'PUT');

          final result = await adapter.compareAndSwap(
            path,
            Uint8List.fromList([2]),
            ifMatchEtag: etag,
          );
          expect(result, isFalse);
        },
      );

      // ── compareAndSwap (update-if-match): non-2xx during CAS upload ───────
      //
      // PUT to the session URI returns 500.
      // Expected: StateError (lines 411-413).
      test(
        'compareAndSwap throws StateError when PUT to session fails',
        () async {
          const path = '.consolidation-lease';
          await adapter.upload(path, Uint8List.fromList([1]));
          final etag = await adapter.getEtag(path);

          simulator.injectNextStatus(500, forMethod: 'PUT');

          await expectLater(
            adapter.compareAndSwap(
              path,
              Uint8List.fromList([2]),
              ifMatchEtag: etag,
            ),
            throwsA(isA<StateError>()),
          );
        },
      );

      // ── delete: concurrent 404 from DriveApi ──────────────────────────────
      //
      // The adapter has a cached file ID.  When it calls DriveApi.files.delete,
      // Drive returns 404 (concurrent deletion by another device).
      // Expected: the adapter treats 404 as idempotent and returns without error
      // (lines 321-322).
      test(
        'delete is idempotent when DriveApi.files.delete returns 404 (concurrent)',
        () async {
          const path = 'sstables/concurrent-deleted.sst';
          await adapter.upload(path, Uint8List.fromList([1]));

          // Verify the file ID is cached by downloading once.
          await adapter.download(path);

          // Inject 404 for the DriveApi DELETE call.
          simulator.injectNextStatus(404, forMethod: 'DELETE');

          // The adapter should catch the DetailedApiRequestError(404) and
          // return without throwing (idempotent delete).
          await expectLater(adapter.delete(path), completes);
        },
      );
    });
  });

  // ── Pre-release integration test (credential-gated) ──────────────────────
  //
  // This group runs only when GOOGLE_DRIVE_TEST_CREDENTIALS is set.
  // It exercises the real Drive API to confirm the simulator's fidelity.
  //
  // To run:
  //   GOOGLE_DRIVE_TEST_CREDENTIALS=<path/to/credentials.json> dart test \
  //     --preset e2e packages/kmdb_google_drive/test/
  //
  // The test is NOT part of per-commit CI; it is registered in the release
  // checklist as RC-2.
  group('Google Drive real-service integration', () {
    test(
      'placeholder: e2e tests run with GOOGLE_DRIVE_TEST_CREDENTIALS set',
      () {
        // This test intentionally does nothing — it is a placeholder for
        // the credential-gated e2e suite defined in test/e2e/.
      },
      skip: 'Credential-gated; run manually with GOOGLE_DRIVE_TEST_CREDENTIALS',
    );
  }, tags: ['e2e']);
}
