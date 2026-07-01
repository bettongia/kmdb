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

/// A snapshot of vault content indexing progress.
///
/// Returned by [KmdbDatabase.vaultIndexingStatus] and emitted by
/// [KmdbDatabase.watchVaultIndexingStatus]. Provides integer counts for
/// each lifecycle status bucket so callers can display progress and decide
/// whether search results may be incomplete.
///
/// ## Stub handling
///
/// [stub] counts blobs that are known to exist (via the `$vault` ref-count
/// namespace) but have not yet been downloaded to this device. These blobs
/// have no `$$vault:extract` entry and are therefore absent from
/// [searchVault] results. When [stub] > 0, search results may be silently
/// incomplete.
///
/// ## Completeness signals
///
/// - [isComplete]: all downloaded blobs are indexed (no pending or in-progress
///   work). Does NOT account for stubs.
/// - [isSearchComplete]: all blobs are downloaded AND indexed. Only true when
///   [stub] == 0 AND [isComplete]. This is the signal a UI should use to
///   decide whether to show an "incomplete results" warning.
///
/// ## Example
///
/// ```dart
/// final status = await db.vaultIndexingStatus();
/// if (!status.isSearchComplete) {
///   print('Warning: ${status.stub} blobs not yet downloaded; '
///       '${status.pending} indexing tasks pending.');
/// }
/// ```
final class VaultIndexingStatus {
  /// Creates a [VaultIndexingStatus].
  const VaultIndexingStatus({
    required this.total,
    required this.indexed,
    required this.pending,
    required this.extracting,
    required this.failed,
    required this.unsupported,
    required this.stub,
  });

  /// Total number of vault blobs known to this device (downloaded + stubs).
  ///
  /// Computed as: `indexed + pending + extracting + failed + unsupported + stub`.
  final int total;

  /// Number of blobs that have been fully extracted and indexed.
  final int indexed;

  /// Number of blobs queued for extraction but not yet started.
  final int pending;

  /// Number of blobs currently being extracted/indexed (in-flight in the
  /// indexing isolate).
  ///
  /// Under normal operation this is 0 or 1 (one-at-a-time processing). A
  /// non-zero value that persists across opens indicates a crash mid-extraction.
  final int extracting;

  /// Number of blobs that failed to extract or index.
  ///
  /// Check the `error` field in the `$$vault:extract:{sha256}` entry for
  /// the failure reason.
  final int failed;

  /// Number of blobs whose media type has no registered extractor.
  ///
  /// These blobs are accessible normally but do not participate in
  /// [searchVault] queries.
  final int unsupported;

  /// Number of blobs present in `$vault` ref-count entries (known to exist)
  /// but not yet downloaded to this device.
  ///
  /// Stubs have no `$$vault:extract` entry. A device with stubs has
  /// potentially incomplete [searchVault] results.
  final int stub;

  /// `true` if all downloaded blobs have been indexed (none pending or
  /// in-progress).
  ///
  /// Does NOT indicate whether stub blobs are present — use
  /// [isSearchComplete] for that check.
  bool get isComplete => pending == 0 && extracting == 0;

  /// `true` if all blobs (including stubs) are downloaded and indexed.
  ///
  /// This is the signal a UI should use to decide whether to show an
  /// "incomplete results" warning for [searchVault] queries.
  bool get isSearchComplete => isComplete && stub == 0;

  /// Returns a zero status (no blobs known).
  static const zero = VaultIndexingStatus(
    total: 0,
    indexed: 0,
    pending: 0,
    extracting: 0,
    failed: 0,
    unsupported: 0,
    stub: 0,
  );

  @override
  String toString() =>
      'VaultIndexingStatus(total: $total, indexed: $indexed, '
      'pending: $pending, extracting: $extracting, failed: $failed, '
      'unsupported: $unsupported, stub: $stub)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultIndexingStatus &&
          total == other.total &&
          indexed == other.indexed &&
          pending == other.pending &&
          extracting == other.extracting &&
          failed == other.failed &&
          unsupported == other.unsupported &&
          stub == other.stub;

  @override
  int get hashCode => Object.hash(
    total,
    indexed,
    pending,
    extracting,
    failed,
    unsupported,
    stub,
  );
}
