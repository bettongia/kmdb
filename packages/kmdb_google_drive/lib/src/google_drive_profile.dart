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

import 'package:kmdb/kmdb_test_cloud_support.dart';

/// The [CloudProfile] for Google Drive.
///
/// ## Key characteristics
///
/// - **`allowsDuplicateNames: true`** — Drive identifies files by ID, not name,
///   and explicitly permits multiple files with the same name in a folder.
///   The adapter applies the deterministic resolution rule (oldest
///   `createdTime`, tie-broken by lowest file ID) when multiple same-named
///   items exist.
///
/// - **`atomicConditionalCreate: false`** — Phase 4a probe confirmed that
///   Drive does NOT provide atomic create-if-absent guarantees when using a
///   name-keyed file.  Two concurrent `Files.create` calls with the same name
///   in the same folder both succeed, producing two distinct Drive files.
///   The adapter therefore declares `providesAtomicCas == false`, and
///   `ConsolidationCoordinator` skips consolidation rather than risk a
///   split-lease data-loss (per H5).
///
///   Conditional **update** (`If-Match` on a known file ID) IS atomic — once a
///   lease file has been created and its Drive file ID is known, the lease can
///   be held safely.  The non-atomic concern applies only to the very first
///   create-if-absent CAS attempt.
///
/// - **`consistency: EventualConsistency`** — `Files.list` is
///   read-your-writes consistent for the issuing client, but results visible
///   to other clients may lag by up to several seconds.  The values below are
///   conservative estimates from the Phase 4a probe; tune them once a
///   controlled measurement is available.
///
/// - **`quota`** — Values reflect the Google Drive API default limits
///   documented at <https://developers.google.com/drive/api/guides/limits>.
///   As of 2026: 20,000 read requests per 100 seconds per user; 10,000 write
///   requests per 100 seconds per user.  The `maxOpsPerMinute` below uses 300
///   (a conservative 5 ops/s) to leave headroom when running alongside other
///   Drive-enabled apps.  Update this value if Google revises the limits.
const kGoogleDriveProfile = CloudProfile(
  /// Eventually consistent: new writes are visible to other clients within
  /// ~5 seconds in practice; 30 s is the conservative upper bound.
  consistency: EventualConsistency(
    maxPropagationDelayMs: 30000, // 30 s upper bound
    jitterMs: 5000, // ±5 s realistic variation
  ),

  /// Drive does NOT guarantee atomic create-if-absent for name-keyed files.
  /// Two concurrent `Files.create` calls with the same name both succeed.
  /// See class-level doc for the safety rationale.
  atomicConditionalCreate: false,

  /// Drive allows multiple files with the same name in the same folder.
  allowsDuplicateNames: true,

  /// Conservative quota: 300 ops/minute (5 ops/s) per user.
  /// See <https://developers.google.com/drive/api/guides/limits>.
  quota: QuotaProfile(
    maxOpsPerMinute: 300,
    maxUploadBytesPerDay: null, // Drive enforces storage quota, not byte-rate
  ),
);
