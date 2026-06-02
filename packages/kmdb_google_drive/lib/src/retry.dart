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

import 'dart:math' as math;

import 'package:googleapis/drive/v3.dart' show DetailedApiRequestError;

/// Thrown when an operation is cancelled before completing.
final class DriveOperationCancelledException implements Exception {
  /// Creates a [DriveOperationCancelledException].
  const DriveOperationCancelledException([this.message]);

  /// Optional description of why the operation was cancelled.
  final String? message;

  @override
  String toString() =>
      'DriveOperationCancelledException(${message ?? 'cancelled'})';
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

/// A simple cancellation token for long-running async operations.
///
/// Call [cancel] to request cancellation.  The operation checks
/// [isCancelled] at each back-off boundary and throws
/// [DriveOperationCancelledException] if set.
final class CancellationToken {
  bool _cancelled = false;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Requests cancellation.  Idempotent — calling more than once has no
  /// additional effect.
  void cancel() => _cancelled = true;
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
/// If [cancellationToken] is provided, each back-off wait checks for
/// cancellation and throws [DriveOperationCancelledException] if set.
/// If [deadline] is provided, no retry is attempted once the deadline has
/// passed.
Future<T> retryWithBackoff<T>(
  Future<T> Function() operation, {
  RetryConfig config = RetryConfig.defaultConfig,
  CancellationToken? cancellationToken,
  DateTime? deadline,
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

      // Check cancellation before sleeping.
      if (cancellationToken?.isCancelled ?? false) {
        throw const DriveOperationCancelledException();
      }

      // Check deadline before sleeping.
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

      await Future<void>.delayed(Duration(milliseconds: actualDelay));

      // Check cancellation again after sleeping.
      if (cancellationToken?.isCancelled ?? false) {
        throw const DriveOperationCancelledException();
      }

      // Update delay for next iteration.
      delayMs = math.min(delayMs * 2, config.maxDelayMs);
    }
  }
}
