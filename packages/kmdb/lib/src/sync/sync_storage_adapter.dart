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

import 'sync_context.dart';

/// Thrown by [SyncStorageAdapter.compareAndSwap] when an optimistic concurrency
/// check fails and the caller has opted for an exception over a boolean return.
///
/// The standard [SyncStorageAdapter.compareAndSwap] returns `false` when the
/// ETag check fails (another writer won the race). Implementations that use
/// [LockConflictException] instead are free to throw it for conditions that are
/// definitively unrecoverable (e.g. the local lock file was preemptively deleted
/// by another coordinator holding a valid lease).
///
/// Callers should catch this exception and either back off and retry, or
/// surface it as a sync error to the application.
///
/// Example:
/// ```dart
/// try {
///   await adapter.compareAndSwap(leasePath, newBytes, ifMatchEtag: etag);
/// } on LockConflictException catch (e) {
///   log.warn('Lost lease race: $e');
/// }
/// ```
final class LockConflictException implements Exception {
  const LockConflictException(this.path, {this.reason});

  /// The remote path where the conflict occurred.
  final String path;

  /// Optional description of why the conflict occurred.
  final String? reason;

  @override
  String toString() {
    final suffix = reason != null ? ': $reason' : '';
    return 'LockConflictException($path)$suffix';
  }
}

/// Abstract interface for the shared sync folder.
///
/// The sync folder is the shared location where SSTables and per-device
/// high-water mark (HWM) files are stored. It is distinct from the local
/// database directory (which uses [StorageAdapter]) and may be backed by any
/// storage system: a cloud provider (Google Drive, iCloud, GCS), a network
/// share (SMB/NFS), a locally-synced cloud folder (Dropbox, OneDrive), or an
/// in-memory structure for tests.
///
/// ## File naming conventions
///
/// - SSTables: `{syncRoot}/sstables/{filename}.sst`
/// - HWM files: `{syncRoot}/highwater/{deviceId}.hwm`
/// - Lease: `{syncRoot}/.consolidation-lease`
///
/// ## Concurrency
///
/// Implementations must be safe to call from a single isolate. For operations
/// that require optimistic concurrency control (e.g. lease acquisition),
/// [compareAndSwap] provides an atomic conditional-write primitive.
///
/// ## Cancellation and deadline
///
/// Every method accepts an optional [SyncContext] via the `ctx` named
/// parameter. When a [SyncContext] is supplied, the adapter **should** honour
/// both [SyncContext.cancel] and [SyncContext.deadline] at I/O boundaries and
/// back-off sleeps:
///
/// - At I/O boundaries: call `ctx?.throwIfExpired()` before each I/O
///   operation. This throws [SyncCancelledException] promptly when the context
///   is cancelled or has exceeded its deadline.
/// - During back-off sleeps: use `Future.any([Future.delayed(d),
///   ctx.cancel?.whenCancelled ?? Completer().future])` so the sleep wakes
///   immediately on cancellation rather than waiting for the next polling
///   boundary.
///
/// Adapters with no long-running waits (e.g. [MemorySyncAdapter]) are
/// **permitted to ignore** the `ctx` parameter — the contract is advisory for
/// adapters where all operations complete in the same microtask. Ignoring `ctx`
/// does **not** cause a conformance-suite failure unless the adapter declares
/// `expectsCancellation: true`.
///
/// Note: [SyncCancelledException] is unrelated to [LockConflictException].
/// Callers must not confuse the two. The engine does not catch
/// [SyncCancelledException] — it propagates to the caller of
/// [KmdbDatabase.sync], [KmdbDatabase.push], or [KmdbDatabase.pull].
abstract interface class SyncStorageAdapter {
  /// Lists all files in [remoteDir], optionally filtering by [extension].
  ///
  /// Returns bare filenames only (no path prefix). Returns an empty list
  /// if the directory does not exist or is empty.
  ///
  /// If [ctx] is non-null, the adapter should call `ctx.throwIfExpired()`
  /// before initiating the I/O operation.
  ///
  /// Example:
  /// ```dart
  /// final files = await adapter.list('sync/sstables', extension: '.sst');
  /// // ['a1b2c3d4-....sst', 'f9e8d7c6-....sst']
  /// ```
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  });

  /// Downloads the file at [remotePath] and returns its bytes.
  ///
  /// Returns `null` if the file does not exist. Throws on I/O errors.
  ///
  /// If [ctx] is non-null, the adapter should call `ctx.throwIfExpired()`
  /// before initiating the download.
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx});

  /// Uploads [bytes] to [remotePath], overwriting any existing file.
  ///
  /// Throws on I/O errors. The write is not guaranteed to be atomic unless
  /// the implementation uses a write-then-rename strategy.
  ///
  /// If [ctx] is non-null, the adapter should call `ctx.throwIfExpired()`
  /// before initiating the upload.
  Future<void> upload(String remotePath, Uint8List bytes, {SyncContext? ctx});

  /// Deletes [remotePath]. No-op if the file does not exist.
  ///
  /// Throws on I/O errors other than file-not-found.
  ///
  /// If [ctx] is non-null, the adapter should call `ctx.throwIfExpired()`
  /// before initiating the delete.
  Future<void> delete(String remotePath, {SyncContext? ctx});

  /// Atomically writes [newBytes] to [path] if the current ETag matches.
  ///
  /// If [ifMatchEtag] is `null`, the write succeeds only when the file does
  /// not currently exist (if-none-match: * semantics). If [ifMatchEtag] is
  /// non-null, the write succeeds only when the file's current ETag equals
  /// [ifMatchEtag].
  ///
  /// Returns `true` on success, `false` if the ETag check failed (another
  /// writer won the race). Throws on other errors.
  ///
  /// This primitive is used by [ConsolidationCoordinator] to implement the
  /// lease file protocol without external locking infrastructure.
  ///
  /// If [ctx] is non-null, the adapter should call `ctx.throwIfExpired()`
  /// before initiating the CAS operation.
  ///
  /// ## ETag semantics
  ///
  /// The ETag format is implementation-specific. `MemorySyncAdapter` uses
  /// a monotonically-increasing version counter. `LocalDirectoryAdapter`
  /// uses the file's content hash.
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  });

  /// Returns the current ETag for [path], or `null` if the file does not exist.
  ///
  /// The ETag is an opaque string that changes whenever the file content
  /// changes. Callers should not attempt to interpret the format.
  ///
  /// If [ctx] is non-null, the adapter should call `ctx.throwIfExpired()`
  /// before initiating the operation.
  Future<String?> getEtag(String path, {SyncContext? ctx});

  /// Whether [compareAndSwap] provides the atomicity guarantee documented above.
  ///
  /// The contract: for a given `(path, ifMatchEtag)` precondition, at most one
  /// concurrent caller may observe `true`. Implementations that cannot honour
  /// this — typically because the backend is an eventually-consistent replica
  /// with no cross-device locking (e.g. a Dropbox or OneDrive folder seen as a
  /// local filesystem) — must return `false`.
  ///
  /// `ConsolidationCoordinator` reads this getter and skips consolidation when
  /// it is `false`: consolidation is a storage-shape optimisation, not a
  /// correctness requirement, so a non-atomic backend simply accumulates more
  /// un-consolidated SSTables rather than risking a split-lease data loss.
  ///
  /// This is declared on the interface — rather than as a marker interface —
  /// because some adapters (notably [LocalDirectoryAdapter]) have an atomicity
  /// claim that depends on the directory they were constructed against, not on
  /// their type.
  bool get providesAtomicCas;
}
