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
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

/// A [SyncStorageAdapter] test decorator that can block individual method calls
/// mid-flight via awaitable barriers.
///
/// Each of the six [SyncStorageAdapter] methods has a corresponding
/// [Completer] barrier. When a barrier is active (not yet completed), the
/// corresponding method suspends at the barrier before delegating to the
/// underlying adapter. The test controls when each call unblocks by completing
/// the appropriate barrier.
///
/// This vehicle is used by the cancellation conformance tests (D4) to assert
/// the property that matters: a [SyncContext] cancellation wakes an in-flight
/// call that is suspended mid-wait, not merely a call that is about to start.
///
/// ## Usage
///
/// ```dart
/// final inner = MemorySyncAdapter();
/// final gated = GatedSyncAdapter(inner);
///
/// // Block the next list() call.
/// gated.holdList();
///
/// // Start list() — it will block at the barrier.
/// final listFuture = gated.list('sstables', extension: '.sst',
///   ctx: SyncContext(cancel: token));
///
/// // Cancel the token while the call is suspended.
/// token.cancel();
///
/// // The list() future should now complete with SyncCancelledException.
/// await expectLater(listFuture, throwsA(isA<SyncCancelledException>()));
/// ```
///
/// A [GatedSyncAdapter] does NOT itself throw [SyncCancelledException] at
/// the barrier — it yields until the barrier is released OR the [SyncContext]
/// is cancelled; the cancellation is detected by the call after it wakes.
/// This models a real adapter that is mid-flight when cancellation arrives
/// (e.g. waiting on a network response).
///
/// Because the adapter calls `ctx?.throwIfExpired()` after waking from the
/// barrier, the cancellation is detected and propagated correctly.
final class GatedSyncAdapter implements SyncStorageAdapter {
  /// Creates a [GatedSyncAdapter] wrapping [_delegate].
  GatedSyncAdapter(this._delegate);

  final SyncStorageAdapter _delegate;

  // Per-method barriers. Each is reset to a completed completer (no hold)
  // by default, so methods pass through immediately unless held.
  Completer<void> _listBarrier = Completer<void>()..complete();
  Completer<void> _downloadBarrier = Completer<void>()..complete();
  Completer<void> _uploadBarrier = Completer<void>()..complete();
  Completer<void> _deleteBarrier = Completer<void>()..complete();
  Completer<void> _casBarrier = Completer<void>()..complete();
  Completer<void> _etagBarrier = Completer<void>()..complete();

  // ── Barrier control ───────────────────────────────────────────────────────

  /// Installs a barrier on [list]. The next [list] call will suspend until
  /// [releaseList] is called or the barrier's future is otherwise completed.
  Completer<void> holdList() => _listBarrier = Completer<void>();

  /// Releases the [list] barrier.
  void releaseList() {
    if (!_listBarrier.isCompleted) _listBarrier.complete();
  }

  /// Installs a barrier on [download].
  Completer<void> holdDownload() => _downloadBarrier = Completer<void>();

  /// Releases the [download] barrier.
  void releaseDownload() {
    if (!_downloadBarrier.isCompleted) _downloadBarrier.complete();
  }

  /// Installs a barrier on [upload].
  Completer<void> holdUpload() => _uploadBarrier = Completer<void>();

  /// Releases the [upload] barrier.
  void releaseUpload() {
    if (!_uploadBarrier.isCompleted) _uploadBarrier.complete();
  }

  /// Installs a barrier on [delete].
  Completer<void> holdDelete() => _deleteBarrier = Completer<void>();

  /// Releases the [delete] barrier.
  void releaseDelete() {
    if (!_deleteBarrier.isCompleted) _deleteBarrier.complete();
  }

  /// Installs a barrier on [compareAndSwap].
  Completer<void> holdCompareAndSwap() => _casBarrier = Completer<void>();

  /// Releases the [compareAndSwap] barrier.
  void releaseCompareAndSwap() {
    if (!_casBarrier.isCompleted) _casBarrier.complete();
  }

  /// Installs a barrier on [getEtag].
  Completer<void> holdGetEtag() => _etagBarrier = Completer<void>();

  /// Releases the [getEtag] barrier.
  void releaseGetEtag() {
    if (!_etagBarrier.isCompleted) _etagBarrier.complete();
  }

  // ── Helper: await barrier, then check cancellation ────────────────────────

  /// Awaits [barrier], racing against [ctx.cancel?.whenCancelled] if available.
  ///
  /// After the barrier completes or the context is cancelled (whichever comes
  /// first), calls `ctx?.throwIfExpired()` so that a cancellation wakes the
  /// call and propagates immediately without delegating to [_delegate].
  Future<void> _awaitBarrier(Completer<void> barrier, SyncContext? ctx) async {
    // Race the barrier against the cancellation signal if one is available.
    // This models a real adapter that is mid-flight when cancellation arrives.
    final cancelFuture = ctx?.cancel?.whenCancelled;
    if (cancelFuture != null) {
      await Future.any([barrier.future, cancelFuture]);
    } else {
      await barrier.future;
    }
    // Force an async boundary before calling throwIfExpired(). Without this,
    // CancellationToken's Completer.sync() can propagate exceptions synchronously
    // back through the Future.any callback chain to the caller of cancel(),
    // rather than delivering the error to the returned future. The explicit
    // Future.value() microtask ensures the exception always lands in the future.
    await Future<void>.value();
    // After waking (either because the barrier was released or the context was
    // cancelled), check expiry and throw if cancelled/timed-out.
    ctx?.throwIfExpired();
  }

  // ── SyncStorageAdapter ────────────────────────────────────────────────────

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) async {
    await _awaitBarrier(_listBarrier, ctx);
    return _delegate.list(remoteDir, extension: extension, ctx: ctx);
  }

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    await _awaitBarrier(_downloadBarrier, ctx);
    return _delegate.download(remotePath, ctx: ctx);
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    await _awaitBarrier(_uploadBarrier, ctx);
    return _delegate.upload(remotePath, bytes, ctx: ctx);
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) async {
    await _awaitBarrier(_deleteBarrier, ctx);
    return _delegate.delete(remotePath, ctx: ctx);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    await _awaitBarrier(_casBarrier, ctx);
    return _delegate.compareAndSwap(
      path,
      newBytes,
      ifMatchEtag: ifMatchEtag,
      ctx: ctx,
    );
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) async {
    await _awaitBarrier(_etagBarrier, ctx);
    return _delegate.getEtag(path, ctx: ctx);
  }

  @override
  bool get providesAtomicCas => _delegate.providesAtomicCas;
}
