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

/// Abstract interface between the Dart [ICloudAdapter] and the native Swift
/// CloudKit plugin.
///
/// This is the primary test seam for the package: the real implementation
/// ([PlatformICloudSyncChannel]) calls the native Swift plugin via a Flutter
/// [MethodChannel], while test implementations (e.g. `FakeICloudSyncChannel`)
/// operate entirely in Dart over an in-memory backend.
///
/// Every method mirrors one of the six [SyncStorageAdapter] operations at the
/// channel boundary. Arguments are primitive types that serialise cleanly over
/// the MethodChannel codec (path strings, [Uint8List] bytes, nullable ETag
/// strings, nullable filename lists).
///
/// ## CloudKit error contract
///
/// Implementations must translate CloudKit-specific error conditions to the
/// following sentinel values that [ICloudAdapter] can act on:
///
/// - `CKError.unknownItem` (file not found): [download] and [getEtag] return
///   `null`; [delete] is a no-op; [compareAndSwap] returns `false` on an
///   update-if-match when the record does not exist.
/// - `CKError.serverRecordChanged` (ETag mismatch or create-if-absent
///   conflict): [compareAndSwap] returns `false`.
/// - `CKError.requestRateLimited`: throw a [ICloudRateLimitException] so the
///   adapter can back off and retry.
/// - Other errors: rethrow as a `PlatformException` or a suitable Dart
///   exception.
abstract interface class ICloudSyncChannel {
  /// Lists the relative paths of all records whose `path` field begins with
  /// [remoteDir] followed by `"/"`, optionally filtered to paths ending with
  /// [extension].
  ///
  /// Returns bare filenames only (the [remoteDir] prefix and trailing slash are
  /// stripped). Returns an empty list if no matching records exist.
  ///
  /// Example: `list('sstables', extension: '.sst')` returns `['abc.sst']` for
  /// a record with path `'sstables/abc.sst'`.
  Future<List<String>> list(String remoteDir, {String? extension});

  /// Downloads the bytes of the record at [remotePath].
  ///
  /// Returns `null` if no record exists at [remotePath] (maps
  /// `CKError.unknownItem` to `null`).
  Future<Uint8List?> download(String remotePath);

  /// Uploads [bytes] as the content of the record at [remotePath], creating
  /// the record if it does not exist or overwriting it if it does.
  ///
  /// Uses `savePolicy: .changedKeys` on the Swift side, which creates a new
  /// record when none exists and updates an existing record's fields
  /// otherwise — avoiding the need for a separate existence check.
  Future<void> upload(String remotePath, Uint8List bytes);

  /// Deletes the record at [remotePath].
  ///
  /// No-op if no record exists at [remotePath] (swallows
  /// `CKError.unknownItem`).
  Future<void> delete(String remotePath);

  /// Conditionally writes [bytes] to the record at [remotePath].
  ///
  /// If [ifMatchEtag] is `null` (create-if-absent): succeeds only when no
  /// record currently exists at [remotePath].  Uses `savePolicy: .allKeys`
  /// with a local record that has no `recordChangeTag`.  Returns `false` when
  /// CloudKit returns `CKError.serverRecordChanged` (record already exists).
  ///
  /// If [ifMatchEtag] is non-null (update-if-match): succeeds only when the
  /// record's current `recordChangeTag` equals [ifMatchEtag].  Uses
  /// `savePolicy: .ifServerRecordUnchanged`.  Returns `false` when CloudKit
  /// returns `CKError.serverRecordChanged` (tag mismatch — another writer won
  /// the race).
  ///
  /// Returns `true` on success, `false` on CAS failure.
  Future<bool> compareAndSwap(
    String remotePath,
    Uint8List bytes, {
    String? ifMatchEtag,
  });

  /// Returns the current ETag (`recordChangeTag`) for the record at
  /// [remotePath], or `null` if no such record exists.
  ///
  /// Fetches only the record metadata (no asset download) by passing
  /// `desiredKeys: []` on the Swift side.
  Future<String?> getEtag(String remotePath);
}

/// Thrown by [ICloudSyncChannel] implementations when CloudKit reports a
/// rate-limit error (`CKError.requestRateLimited`).
///
/// The [retryAfterMs] field reflects the `retryAfterSeconds` value from the
/// CloudKit error, if available.  [ICloudAdapter] uses this to drive
/// exponential back-off.
final class ICloudRateLimitException implements Exception {
  /// Creates an [ICloudRateLimitException].
  ///
  /// [retryAfterMs] is the hint from CloudKit's `retryAfterSeconds` field
  /// (converted to milliseconds), or `null` if not provided.
  const ICloudRateLimitException({this.retryAfterMs});

  /// Hint for how long (in milliseconds) to wait before retrying.
  ///
  /// Derived from CloudKit's `CKError.userInfo[CKErrorRetryAfterKey]`.
  /// May be `null` if CloudKit did not include this hint.
  final int? retryAfterMs;

  @override
  String toString() {
    if (retryAfterMs != null) {
      return 'ICloudRateLimitException(retryAfter: ${retryAfterMs}ms)';
    }
    return 'ICloudRateLimitException';
  }
}
