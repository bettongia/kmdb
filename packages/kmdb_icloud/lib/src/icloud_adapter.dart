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
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

import 'icloud_sync_channel.dart';

/// Apple iCloud (CloudKit) sync adapter for KMDB.
///
/// Implements [SyncStorageAdapter] on top of the CloudKit framework via the
/// [ICloudSyncChannel] abstraction. Pass a [PlatformICloudSyncChannel] for
/// production use or a test-double (e.g. `FakeICloudSyncChannel` from the test
/// package) to exercise the adapter logic without a real CloudKit connection.
///
/// ## Sync storage model
///
/// Each KMDB sync file is stored as a `CKRecord` of type `"KMDBSyncFile"` in a
/// custom private zone `"kmdb-<syncRoot>"` within the app's CloudKit container.
/// Binary content is stored as a `CKAsset` blob attached to the record.
/// CloudKit's `recordChangeTag` is used as the ETag for conditional writes.
///
/// ## ETag strategy
///
/// CloudKit assigns an opaque `recordChangeTag` on every successful record save.
/// This adapter surfaces it as the ETag for both [getEtag] and
/// [compareAndSwap]. The tag is stable for a given revision and changes on
/// every write, satisfying the CAS contract.
///
/// ## `providesAtomicCas == false` — safe default
///
/// The create-if-absent atomicity of CloudKit (whether zone-level serialisation
/// guarantees a single winner for concurrent first-time record creates with the
/// same deterministic record ID) has not been empirically verified against the
/// real service. Until the Phase 4a probe confirms it, this adapter ships with:
///
/// ```dart
/// bool get providesAtomicCas => false;
/// ```
///
/// This causes [ConsolidationCoordinator] to skip consolidation rather than
/// risk a split-lease data loss (H5 invariant). Once Phase 4a confirms the
/// behaviour, set both `providesAtomicCas` and [kICloudProfile]'s
/// `atomicConditionalCreate` to `true`.
///
/// Conditional **update** (when `ifMatchEtag != null`) **is** atomic: the
/// channel uses `savePolicy: .ifServerRecordUnchanged`, and CloudKit returns
/// `CKError.serverRecordChanged` if the record's `recordChangeTag` has changed
/// since the local copy was fetched — exactly one writer wins.
///
/// ## Cancellation
///
/// All six methods call `ctx?.throwIfExpired()` at entry. Back-off sleeps on
/// [ICloudRateLimitException] use `Future.any([sleep, whenCancelled])` so that
/// cancellation wakes the sleep immediately rather than waiting for the full
/// delay. This behaviour satisfies the `expectsCancellation: true` bar in the
/// H5 conformance suite.
///
/// ## Thread safety
///
/// Not thread-safe; must be called from a single Flutter isolate (the main
/// isolate in a Flutter app).
final class ICloudAdapter implements SyncStorageAdapter {
  /// Creates an [ICloudAdapter].
  ///
  /// [channel] — the channel implementation to delegate to. Pass a
  /// [PlatformICloudSyncChannel] for production or a test double in tests.
  ///
  /// [syncRoot] — name used as the suffix for the CloudKit custom zone
  /// (`"kmdb-<syncRoot>"`). Must be consistent across all devices sharing the
  /// same sync folder.
  ///
  /// [retryConfig] — back-off configuration for [ICloudRateLimitException]
  /// retries. Defaults to [ICloudRetryConfig.defaultConfig].
  ICloudAdapter({
    required ICloudSyncChannel channel,
    required String syncRoot,
    ICloudRetryConfig retryConfig = ICloudRetryConfig.defaultConfig,
  }) : _channel = channel,
       _syncRoot = syncRoot,
       _retryConfig = retryConfig;

  final ICloudSyncChannel _channel;
  final String _syncRoot;
  final ICloudRetryConfig _retryConfig;

  // ── SyncStorageAdapter ─────────────────────────────────────────────────────

  /// CloudKit's create-if-absent atomicity is unverified pending the Phase 4a
  /// empirical probe.  Ships as `false` (loss-free default) until confirmed.
  ///
  /// This value must equal [kICloudProfile]'s `atomicConditionalCreate`.
  /// A conformance test in the package's test suite asserts this invariant.
  @override
  bool get providesAtomicCas => false;

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    return _retryOnRateLimit(
      () => _channel.list(remoteDir, extension: extension),
      ctx: ctx,
    );
  }

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    return _retryOnRateLimit(() => _channel.download(remotePath), ctx: ctx);
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    return _retryOnRateLimit(
      () => _channel.upload(remotePath, bytes),
      ctx: ctx,
    );
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    return _retryOnRateLimit(() => _channel.delete(remotePath), ctx: ctx);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    return _retryOnRateLimit(
      () => _channel.compareAndSwap(path, newBytes, ifMatchEtag: ifMatchEtag),
      ctx: ctx,
    );
  }

  @override
  Future<String?> getEtag(String remotePath, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    return _retryOnRateLimit(() => _channel.getEtag(remotePath), ctx: ctx);
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  /// Executes [operation] with exponential back-off on [ICloudRateLimitException].
  ///
  /// Other exceptions (including CAS failures and not-found sentinels) are
  /// rethrown immediately without retry. Cancellation via [ctx] wakes any
  /// back-off sleep immediately.
  Future<T> _retryOnRateLimit<T>(
    Future<T> Function() operation, {
    SyncContext? ctx,
  }) async {
    final rng = math.Random();
    var attempt = 0;
    var delayMs = _retryConfig.initialDelayMs;

    while (true) {
      try {
        return await operation();
      } on ICloudRateLimitException catch (e) {
        attempt++;
        if (attempt >= _retryConfig.maxAttempts) {
          rethrow; // Exhausted retries.
        }

        // Check cancellation before sleeping.
        ctx?.throwIfExpired();

        // Respect the deadline: if it has already passed, do not sleep.
        final deadline = ctx?.deadline;
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          rethrow;
        }

        // Compute back-off: use the CloudKit retryAfter hint if available,
        // otherwise use exponential back-off with jitter.
        final int actualDelay;
        if (e.retryAfterMs != null) {
          actualDelay =
              math.min(e.retryAfterMs!, _retryConfig.maxDelayMs) +
              rng.nextInt(_retryConfig.jitterMs + 1);
        } else {
          final baseDelay = math.min(
            _retryConfig.initialDelayMs * (1 << (attempt - 1)),
            _retryConfig.maxDelayMs,
          );
          actualDelay = baseDelay + rng.nextInt(_retryConfig.jitterMs + 1);
        }

        // Sleep while watching for cancellation so the back-off wakes
        // immediately if the context is cancelled.
        final cancelFuture = ctx?.cancel?.whenCancelled;
        if (cancelFuture != null) {
          await Future.any([
            Future<void>.delayed(Duration(milliseconds: actualDelay)),
            cancelFuture,
          ]);
        } else {
          await Future<void>.delayed(Duration(milliseconds: actualDelay));
        }

        // Re-check cancellation after waking from sleep.
        ctx?.throwIfExpired();

        // Update delay for next iteration (exponential growth).
        delayMs = math.min(delayMs * 2, _retryConfig.maxDelayMs);
      }
    }
  }

  /// Returns the zone name for this adapter's [_syncRoot].
  ///
  /// The CloudKit custom zone is named `"kmdb-<syncRoot>"`.  This accessor is
  /// not used by the Dart adapter directly (the Swift plugin derives the zone
  /// name from the `initialize` call), but is available for logging and tests.
  String get zoneName => 'kmdb-$_syncRoot';
}

/// Configuration for the exponential back-off strategy used by [ICloudAdapter]
/// when CloudKit returns a rate-limit error ([ICloudRateLimitException]).
///
/// Uses the same structure as `RetryConfig` in `kmdb_google_drive`.
final class ICloudRetryConfig {
  /// Creates an [ICloudRetryConfig].
  const ICloudRetryConfig({
    this.maxAttempts = 5,
    this.initialDelayMs = 1000,
    this.maxDelayMs = 32000,
    this.jitterMs = 1000,
  });

  /// Maximum number of attempts (including the first).
  final int maxAttempts;

  /// Initial back-off delay in milliseconds.
  final int initialDelayMs;

  /// Maximum back-off delay in milliseconds (cap).
  final int maxDelayMs;

  /// Maximum random jitter in milliseconds added to each delay.
  final int jitterMs;

  /// The default retry configuration used by [ICloudAdapter].
  static const defaultConfig = ICloudRetryConfig();
}
