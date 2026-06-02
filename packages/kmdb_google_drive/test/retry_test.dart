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

import 'dart:async';

import 'package:googleapis/drive/v3.dart' show DetailedApiRequestError;
import 'package:kmdb/kmdb.dart'
    show CancellationToken, SyncCancelledException, SyncContext;
import 'package:kmdb_google_drive/src/retry.dart'
    show DriveOperationCancelledException, RetryConfig, retryWithBackoff;
import 'package:test/test.dart';

// ── Helpers ────────────────────────────────────────────────────────────────

/// A [RetryConfig] with very small delays to make tests fast.
///
/// Uses 0 ms initial delay and 0 ms jitter so tests are deterministic and
/// do not slow down the suite with real back-off waits.
const _fastConfig = RetryConfig(
  maxAttempts: 3,
  initialDelayMs: 0,
  maxDelayMs: 0,
  jitterMs: 0,
);

/// Creates a [DetailedApiRequestError] with the given [status] code.
///
/// [DetailedApiRequestError] is the type [retryWithBackoff] checks — wrapping
/// the status in this type mimics a real Drive API error response.
DetailedApiRequestError _apiError(int status) =>
    DetailedApiRequestError(status, 'error', jsonResponse: null);

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  // ── Basic retry behaviour ──────────────────────────────────────────────────

  group('retryWithBackoff — basic behaviour', () {
    test('returns value immediately when operation succeeds', () async {
      final result = await retryWithBackoff(
        () async => 42,
        config: _fastConfig,
      );
      expect(result, equals(42));
    });

    test('retries on 429 and succeeds on subsequent attempt', () async {
      var calls = 0;
      final result = await retryWithBackoff(() async {
        calls++;
        if (calls < 2) throw _apiError(429);
        return 'ok';
      }, config: _fastConfig);
      expect(result, equals('ok'));
      expect(calls, equals(2));
    });

    test('retries on 503 and succeeds on subsequent attempt', () async {
      var calls = 0;
      final result = await retryWithBackoff(() async {
        calls++;
        if (calls < 2) throw _apiError(503);
        return 'ok';
      }, config: _fastConfig);
      expect(result, equals('ok'));
      expect(calls, equals(2));
    });

    test('rethrows after maxAttempts is exhausted', () async {
      var calls = 0;
      await expectLater(
        retryWithBackoff(
          () async {
            calls++;
            throw _apiError(429);
          },
          config: _fastConfig, // maxAttempts = 3
        ),
        throwsA(isA<DetailedApiRequestError>()),
      );
      // 1 initial + 2 retries = 3 total (maxAttempts).
      expect(calls, equals(3));
    });

    test('does not retry on non-transient error codes', () async {
      // 412 is a meaningful CAS signal — must NOT be retried.
      var calls = 0;
      await expectLater(
        retryWithBackoff(() async {
          calls++;
          throw _apiError(412);
        }, config: _fastConfig),
        throwsA(isA<DetailedApiRequestError>()),
      );
      // Only one call — error is rethrown immediately without retry.
      expect(calls, equals(1));
    });

    test('does not retry on 404', () async {
      var calls = 0;
      await expectLater(
        retryWithBackoff(() async {
          calls++;
          throw _apiError(404);
        }, config: _fastConfig),
        throwsA(isA<DetailedApiRequestError>()),
      );
      expect(calls, equals(1));
    });

    test('propagates non-DetailedApiRequestError immediately', () async {
      await expectLater(
        retryWithBackoff(
          () async => throw StateError('unexpected'),
          config: _fastConfig,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('retries up to maxAttempts then rethrows on 503', () async {
      var calls = 0;
      await expectLater(
        retryWithBackoff(
          () async {
            calls++;
            throw _apiError(503);
          },
          config: _fastConfig, // maxAttempts = 3
        ),
        throwsA(isA<DetailedApiRequestError>()),
      );
      expect(calls, equals(3));
    });
  });

  // ── Cancellation token wakes back-off sleep ────────────────────────────────

  group('retryWithBackoff — cancellation via SyncContext', () {
    test(
      'CancellationToken cancel wakes the back-off sleep immediately',
      () async {
        // Use a long initial delay so the test only passes quickly if
        // cancellation wakes the sleep.
        const longConfig = RetryConfig(
          maxAttempts: 5,
          initialDelayMs: 5000,
          maxDelayMs: 30000,
          jitterMs: 0,
        );

        final token = CancellationToken();
        final ctx = SyncContext(cancel: token);

        var calls = 0;
        final future = retryWithBackoff(
          () async {
            calls++;
            throw _apiError(429);
          },
          config: longConfig,
          ctx: ctx,
        );

        // Cancel during the first back-off sleep.  Since the sleep is
        // Future.any([delay, whenCancelled]), the cancel future completes first
        // and wakes the back-off.  The subsequent ctx.throwIfExpired() then
        // throws SyncCancelledException.
        token.cancel();

        await expectLater(future, throwsA(isA<SyncCancelledException>()));
        // Only one operation attempt before cancel was applied.
        expect(calls, equals(1));
      },
    );

    test(
      'throwIfExpired is checked before sleeping (pre-cancelled token)',
      () async {
        final token = CancellationToken()..cancel(); // already cancelled
        final ctx = SyncContext(cancel: token);

        var calls = 0;
        await expectLater(
          retryWithBackoff(
            () async {
              calls++;
              throw _apiError(429);
            },
            config: _fastConfig,
            ctx: ctx,
          ),
          throwsA(isA<SyncCancelledException>()),
        );
        // Operation runs once; cancel is detected before the first retry sleep.
        expect(calls, equals(1));
      },
    );

    test(
      'deadline exceeded during back-off throws SyncCancelledException',
      () async {
        // Set a deadline that has already passed.
        final pastDeadline = DateTime.now().subtract(
          const Duration(seconds: 1),
        );
        final ctx = SyncContext(deadline: pastDeadline);

        var calls = 0;
        await expectLater(
          retryWithBackoff(
            () async {
              calls++;
              throw _apiError(429);
            },
            config: _fastConfig,
            ctx: ctx,
          ),
          throwsA(isA<SyncCancelledException>()),
        );
        // The deadline check fires before the sleep or after waking, not before
        // the first operation attempt.
        expect(calls, greaterThanOrEqualTo(1));
      },
    );

    test(
      'deadline exceeded during back-off does not sleep (rethrows immediately)',
      () async {
        // Deadline in the past: the back-off must not sleep before rethrowing.
        final pastDeadline = DateTime.now().subtract(
          const Duration(seconds: 1),
        );
        final ctx = SyncContext(deadline: pastDeadline);

        // Use a long delay to confirm we are NOT sleeping (test would time out
        // if we slept 30 s).
        const longConfig = RetryConfig(
          maxAttempts: 5,
          initialDelayMs: 30000,
          maxDelayMs: 30000,
          jitterMs: 0,
        );

        final stopwatch = Stopwatch()..start();
        await expectLater(
          retryWithBackoff(
            () async => throw _apiError(429),
            config: longConfig,
            ctx: ctx,
          ),
          throwsA(isA<SyncCancelledException>()),
        );
        stopwatch.stop();

        // Should complete nearly instantaneously — well under 5 seconds.
        expect(stopwatch.elapsedMilliseconds, lessThan(5000));
      },
    );

    test('no cancellation context: retries without interference', () async {
      var calls = 0;
      final result = await retryWithBackoff(
        () async {
          calls++;
          if (calls < 3) throw _apiError(429);
          return 'done';
        },
        config: _fastConfig,
        ctx: null, // no SyncContext
      );
      expect(result, equals('done'));
      expect(calls, equals(3));
    });

    // ── Future deadline that has not yet expired ───────────────────────────
    //
    // SyncContext with a deadline far in the future: throwIfExpired() passes
    // (deadline not yet reached), then the deadline check at lines 117-118 in
    // retry.dart evaluates to false (not yet expired), and the sleep proceeds.
    // This exercises the `final deadline = ctx?.deadline` / `isAfter` check
    // when the deadline is still in the future.
    test(
      'future deadline: deadline check evaluates to false, retry proceeds',
      () async {
        // Deadline one hour from now — will never expire during the test.
        final futureDeadline = DateTime.now().add(const Duration(hours: 1));
        final ctx = SyncContext(deadline: futureDeadline);

        var calls = 0;
        final result = await retryWithBackoff(
          () async {
            calls++;
            if (calls < 3) throw _apiError(429);
            return 'future-deadline-ok';
          },
          config: _fastConfig, // 0 ms delays — fast
          ctx: ctx,
        );
        expect(result, equals('future-deadline-ok'));
        expect(calls, equals(3));
      },
    );

    // ── Cancel via token during back-off sleep (async cancel) ─────────────
    //
    // The token is NOT cancelled when throwIfExpired() runs before the sleep,
    // but IS cancelled during the sleep via Future.delayed(Duration.zero).
    // This exercises the Future.any([sleep, cancelFuture]) branch (lines 138-143)
    // and the post-sleep throwIfExpired() check (line 149).
    test('cancel token fires during back-off sleep via async cancel', () async {
      // Use a medium delay so the sleep outlasts the scheduled cancel.
      const medConfig = RetryConfig(
        maxAttempts: 5,
        initialDelayMs: 500, // long enough for the cancel to fire first
        maxDelayMs: 5000,
        jitterMs: 0,
      );

      final token = CancellationToken();
      final ctx = SyncContext(cancel: token);

      var calls = 0;
      final future = retryWithBackoff(
        () async {
          calls++;
          throw _apiError(429); // always fails → retries
        },
        config: medConfig,
        ctx: ctx,
      );

      // Schedule the cancel on the next event-loop tick.  By that point,
      // retryWithBackoff has already passed throwIfExpired() (line 114) but
      // is suspended in Future.any([sleep, whenCancelled]) (line 140).
      // The cancel wakes the sleep; post-sleep throwIfExpired() (line 149)
      // then throws SyncCancelledException.
      //
      // Use unawaited so that we do not await the cancel future itself —
      // just schedule it to fire on the next event loop tick while we
      // await the retry future directly.
      unawaited(Future<void>.delayed(Duration.zero, token.cancel));

      await expectLater(future, throwsA(isA<SyncCancelledException>()));
      expect(calls, greaterThanOrEqualTo(1));
    });
  });

  // ── DriveOperationCancelledException ──────────────────────────────────────

  group('DriveOperationCancelledException', () {
    test('extends SyncCancelledException', () {
      final e = DriveOperationCancelledException('test');
      expect(e, isA<SyncCancelledException>());
      expect(e.message, equals('test'));
    });

    test('has default message when constructed with no args', () {
      final e = DriveOperationCancelledException();
      expect(e.message, isNotEmpty);
    });

    test('toString includes class name and message', () {
      final e = DriveOperationCancelledException('cancelled by deadline');
      expect(e.toString(), contains('DriveOperationCancelledException'));
      expect(e.toString(), contains('cancelled by deadline'));
    });

    test('is caught by SyncCancelledException handler', () {
      // Throw a DriveOperationCancelledException and catch it as
      // SyncCancelledException — verifying the inheritance relationship holds.
      Object? caught;
      try {
        throw DriveOperationCancelledException('woke early');
      } on SyncCancelledException catch (e) {
        caught = e;
      }
      expect(caught, isA<SyncCancelledException>());
      expect(
        (caught as SyncCancelledException).message,
        contains('woke early'),
      );
    });
  });

  // ── RetryConfig ────────────────────────────────────────────────────────────

  group('RetryConfig', () {
    test('defaultConfig has expected values', () {
      expect(RetryConfig.defaultConfig.maxAttempts, equals(5));
      expect(RetryConfig.defaultConfig.initialDelayMs, equals(1000));
      expect(RetryConfig.defaultConfig.maxDelayMs, equals(32000));
      expect(RetryConfig.defaultConfig.jitterMs, equals(1000));
    });

    test('custom config values are stored correctly', () {
      const cfg = RetryConfig(
        maxAttempts: 2,
        initialDelayMs: 100,
        maxDelayMs: 400,
        jitterMs: 50,
      );
      expect(cfg.maxAttempts, equals(2));
      expect(cfg.initialDelayMs, equals(100));
      expect(cfg.maxDelayMs, equals(400));
      expect(cfg.jitterMs, equals(50));
    });
  });
}
