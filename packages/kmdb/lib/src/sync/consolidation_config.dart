// Copyright 2026 The KMDB Authors
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

/// Configuration for the [ConsolidationCoordinator].
///
/// Controls the thresholds and timing for cross-device SSTable consolidation.
/// Consolidation merges multiple small SSTables from different devices into a
/// single larger SSTable, reducing the number of files that each device must
/// download on pull.
///
/// ## Usage
///
/// ```dart
/// // Production defaults:
/// const config = ConsolidationConfig();
///
/// // Tests with short lease TTL:
/// final testConfig = ConsolidationConfig.forTesting();
/// ```
final class ConsolidationConfig {
  /// Creates a [ConsolidationConfig] with the given parameters.
  const ConsolidationConfig({
    this.threshold = 8,
    this.ttlMs = 120000,
    this.renewalFraction = 0.5,
    this.staleDays = 90,
  });

  /// Number of cross-device SSTables in the sync folder that triggers a
  /// consolidation round.
  ///
  /// When the number of non-local SSTables exceeds this threshold, a device
  /// that successfully acquires the lease will perform an N-way merge.
  /// Default: 8 files.
  final int threshold;

  /// Lease time-to-live in milliseconds.
  ///
  /// A device that holds the consolidation lease must complete the operation
  /// within [ttlMs] or risk having its lease claimed by another device.
  /// Default: 120,000 ms (2 minutes).
  final int ttlMs;

  /// Fraction of [ttlMs] at which the lease holder should attempt renewal.
  ///
  /// If consolidation takes longer than `ttlMs * renewalFraction` milliseconds,
  /// the coordinator attempts to renew the lease before it expires.
  /// Default: 0.5 (attempt renewal at the halfway point).
  final double renewalFraction;

  /// Number of days since a peer's last update before it is
  /// considered stale and excluded from consolidation input selection.
  ///
  /// Default: 90 days.
  final int staleDays;

  /// Configuration for unit tests with short TTL and low threshold.
  ///
  /// Uses a 5-second lease TTL and a 3-file consolidation threshold, making
  /// it practical to test lease expiry and re-acquisition within tests.
  factory ConsolidationConfig.forTesting() => const ConsolidationConfig(
    threshold: 3,
    ttlMs: 5000, // 5 seconds
    renewalFraction: 0.5,
    staleDays: 90,
  );
}
