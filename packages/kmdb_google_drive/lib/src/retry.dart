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
import 'dart:math' as math;

import 'package:googleapis/drive/v3.dart' show DetailedApiRequestError;
import 'package:kmdb/kmdb.dart';

/// Thrown when a Drive operation is cancelled.
///
/// Extends [SyncCancelledException] so that the engine's generic cancellation
/// catch sites work without needing to know about Drive-specific types. Existing
/// Drive-specific catch clauses that catch [DriveOperationCancelledException]
/// remain valid — [SyncCancelledException] is the base class.
final class DriveOperationCancelledException extends SyncCancelledException {
  /// Creates a [DriveOperationCancelledException].
  const DriveOperationCancelledException([String message = 'Cancelled'])
    : super(message);

  @override
  String toString() => 'DriveOperationCancelledException: $message';
}

/// Configuration for the exponential back-off strategy used by
/// [retryWithBackoff].
///
/// Follows the Drive API best-practice of exponential back-off with jitter on
/// 429 (quota exceeded) and 503 (service unavailable) responses.
/// See <https://developers.google.com/drive/api/guides/handle-errors#exponential-backoff>.
final class RetryConfig {
  /// Creates a [RetryConfig].
  const RetryConfig({
    this.maxAttempts = 5,
    this.initialDelayMs = 1000,
    this.maxDelayMs = 32000,
    this.jitterMs = 1000,
  });

  /// Maximum number of attempts (including the first).
  final int maxAttempts;

  /// Initial back-off delay in milliseconds.
  final int initialDelayMs;

  /// Maximum back-off delay in milliseconds.
  final int maxDelayMs;

  /// Maximum random jitter in milliseconds added to each delay.
  final int jitterMs;

  /// The default retry configuration used by [GoogleDriveAdapter].
  static const defaultConfig = RetryConfig();
}

/// Executes [operation] with exponential back-off on transient Drive errors.
///
/// Retries on:
/// - HTTP 429 (quota exceeded / rate limited)
/// - HTTP 503 (service unavailable)
///
/// All other errors (including 412 Precondition Failed, which is a meaningful
/// CAS signal) are rethrown immediately without retry.
///
/// ## Cancellation and deadline
///
/// If [ctx] is provided, each back-off sleep is implemented as
/// `Future.any([Future.delayed(d), ctx.cancel?.whenCancelled ?? <never>])`,
/// followed by `ctx.throwIfExpired()`. This wakes the back-off immediately
/// when the context is cancelled rather than waiting for the next polling
/// boundary.
///
/// The deadline check (`ctx.deadline`) is also applied before each retry
/// attempt: if the deadline has passed, the last error is rethrown immediately
/// without sleeping.
///
/// Note: cancellation / deadline checks apply only to the back-off path. The
/// first attempt is not checked here — callers that want entry cancellation
/// should call `ctx?.throwIfExpired()` before invoking [retryWithBackoff].
Future<T> retryWithBackoff<T>(
  Future<T> Function() operation, {
  RetryConfig config = RetryConfig.defaultConfig,
  SyncContext? ctx,
}) async {
  final rng = math.Random();
  var attempt = 0;
  var delayMs = config.initialDelayMs;

  while (true) {
    try {
      return await operation();
    } on DetailedApiRequestError catch (e) {
      // Only retry on 429 and 503.
      if (e.status != 429 && e.status != 503) {
        rethrow;
      }

      attempt++;
      if (attempt >= config.maxAttempts) {
        rethrow; // Exhausted retries.
      }

      // Check cancellation / deadline before sleeping.
      ctx?.throwIfExpired();

      // Check deadline before sleeping: if it has already passed, do not sleep.
      final deadline = ctx?.deadline;
      if (deadline != null && DateTime.now().isAfter(deadline)) {
        rethrow;
      }

      // Exponential back-off with full jitter.
      // actual_delay = min(initialDelay * 2^(attempt-1), maxDelay)
      //                + random(0, jitterMs)
      final baseDelay = math.min(
        config.initialDelayMs * (1 << (attempt - 1)),
        config.maxDelayMs,
      );
      final jitter = rng.nextInt(config.jitterMs + 1);
      final actualDelay = baseDelay + jitter;

      // Sleep while watching for cancellation.
      //
      // Await Future.any([sleep, whenCancelled]) so that an in-flight back-off
      // wakes immediately on cancel rather than sleeping out the full delay.
      // The neverCompleter is used when no cancel signal is available, giving
      // identical behaviour to a plain Future.delayed in that case.
      final cancelFuture = ctx?.cancel?.whenCancelled;
      if (cancelFuture != null) {
        await Future.any([
          Future<void>.delayed(Duration(milliseconds: actualDelay)),
          cancelFuture,
        ]);
      } else {
        await Future<void>.delayed(Duration(milliseconds: actualDelay));
      }

      // Check cancellation again after waking from sleep.
      ctx?.throwIfExpired();

      // Update delay for next iteration.
      delayMs = math.min(delayMs * 2, config.maxDelayMs);
    }
  }
}
