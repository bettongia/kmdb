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

import 'dart:async';

/// An imperative cancellation signal that can wake awaiting operations
/// immediately.
///
/// Call [cancel] from any code path to signal cancellation. Adapter
/// implementations can poll [isCancelled] at I/O boundaries, or await
/// [whenCancelled] inside a `Future.any()` to wake immediately when the
/// token is cancelled during an in-flight wait (e.g. a back-off sleep).
///
/// The token is single-use: once cancelled it remains cancelled. Calling
/// [cancel] multiple times is safe.
///
/// Example — polling at a boundary:
/// ```dart
/// ctx?.throwIfExpired();
/// final bytes = await adapter.readFile(path);
/// ```
///
/// Example — waking from a back-off sleep:
/// ```dart
/// await Future.any([
///   Future.delayed(backoffDuration),
///   ctx.cancel?.whenCancelled ?? Completer<void>().future,
/// ]);
/// ctx?.throwIfExpired();
/// ```
final class CancellationToken {
  final _completer = Completer<void>.sync();

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// A future that completes when [cancel] is called.
  ///
  /// Adapters can use this in a `Future.any()` to wake immediately from a
  /// back-off sleep or other awaitable wait when cancellation is requested,
  /// rather than waiting for the next polling boundary.
  Future<void> get whenCancelled => _completer.future;

  /// Signals cancellation. No-op if already cancelled.
  ///
  /// After this call, [isCancelled] is `true` and any futures returned by
  /// [whenCancelled] complete.
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Immutable per-sync-run context threaded through every [SyncStorageAdapter]
/// call.
///
/// A [SyncContext] is constructed once at the public sync entry point
/// ([KmdbDatabase.sync], [KmdbDatabase.push], [KmdbDatabase.pull]) and passed
/// unchanged through [SyncEngine] and [ConsolidationCoordinator] to each
/// adapter call site.
///
/// The two control signals it carries are orthogonal:
/// - [cancel]: an imperative signal that any code path may fire at any time
///   (e.g. the user tapped Cancel, the app is shutting down).
/// - [deadline]: an absolute wall-clock expiry computed once from the caller's
///   `timeout: Duration` argument. Using an absolute deadline rather than a
///   per-call timeout ensures back-off comparisons against `DateTime.now()` are
///   consistent across the entire sync run.
///
/// Adapters call [throwIfExpired] at I/O boundaries; it throws
/// [SyncCancelledException] if either signal is active.
///
/// Example:
/// ```dart
/// final ctx = SyncContext(
///   cancel: token,
///   deadline: DateTime.now().add(const Duration(seconds: 30)),
/// );
/// await engine.push(ctx: ctx);
/// ```
final class SyncContext {
  /// Creates a [SyncContext].
  ///
  /// Both [cancel] and [deadline] are optional; a context with neither set is a
  /// no-op: [throwIfExpired] never throws. Constructing `SyncContext()` is
  /// equivalent to passing `null` for the context altogether.
  const SyncContext({this.cancel, this.deadline});

  /// Imperative cancellation signal, or `null` if no cancellation is wired.
  final CancellationToken? cancel;

  /// Absolute wall-clock deadline, or `null` if no timeout is set.
  final DateTime? deadline;

  /// Throws [SyncCancelledException] if [cancel] has been called or if
  /// [deadline] has passed.
  ///
  /// Call this at the start of each adapter method and before each I/O
  /// operation to ensure the operation does not proceed after the sync has
  /// been cancelled or has timed out.
  ///
  /// The cancel check takes priority over the deadline check so that the
  /// thrown message correctly identifies a user-initiated cancel vs. a
  /// timeout.
  void throwIfExpired() {
    if (cancel?.isCancelled == true) {
      throw const SyncCancelledException('Sync cancelled');
    }
    final dl = deadline;
    if (dl != null && DateTime.now().isAfter(dl)) {
      throw const SyncCancelledException('Sync deadline exceeded');
    }
  }
}

/// Thrown when a [SyncContext] is cancelled or its deadline is exceeded.
///
/// Cloud adapter implementations should also throw this (or a subclass) when
/// they detect cancellation internally (e.g. from a provider-specific
/// cancellation signal).
///
/// The engine's catch sites do not catch [SyncCancelledException] — it is
/// allowed to propagate to the caller of [KmdbDatabase.sync], [KmdbDatabase.push], or
/// [KmdbDatabase.pull], which is where the cancellation originated.
///
/// Note: [SyncCancelledException] is unrelated to [LockConflictException].
/// Lock conflicts are internal coordinator races that the coordinator handles
/// itself; they must not be confused with or absorbed as cancellation signals.
class SyncCancelledException implements Exception {
  /// Creates a [SyncCancelledException] with [message].
  const SyncCancelledException(this.message);

  /// Human-readable description of why the sync was cancelled.
  ///
  /// Typical values: `'Sync cancelled'` (user-initiated) or
  /// `'Sync deadline exceeded'` (timeout). Provider adapters may supply more
  /// specific messages.
  final String message;

  @override
  String toString() => 'SyncCancelledException: $message';
}
