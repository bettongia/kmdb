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

/// The [CloudProfile] for the Apple iCloud (CloudKit) sync adapter.
///
/// ## Preliminary values (Phase 4a not yet run)
///
/// The numeric fields in this constant — `maxPropagationDelayMs`, `jitterMs`,
/// `quota.maxOpsPerMinute`, and `atomicConditionalCreate` — are **placeholder
/// values** pending the Phase 4a empirical probe against the real CloudKit
/// service.  Once the probe is complete these values will be replaced with
/// measured results.
///
/// ## Key characteristics
///
/// - **`allowsDuplicateNames: false`** — CloudKit zones use a deterministic
///   `CKRecord.ID` derived from the file's relative path.  CloudKit guarantees
///   exactly one record per record ID per zone, so duplicate names are
///   structurally impossible.
///
/// - **`atomicConditionalCreate: false` (safe default)** — whether CloudKit's
///   zone-level serialisation guarantees a single winner for concurrent
///   first-time record creates with the same deterministic record ID has not
///   been empirically verified.  Until the Phase 4a probe confirms this
///   behaviour, the adapter ships with `providesAtomicCas == false`, and
///   `ConsolidationCoordinator` skips consolidation rather than risk a
///   split-lease data loss (H5 invariant).
///
///   Conditional **update** (`savePolicy: .ifServerRecordUnchanged`) **is**
///   atomic on CloudKit: exactly one concurrent updater wins when both use the
///   same `recordChangeTag` as the precondition.
///
/// - **`consistency: EventualConsistency`** — CloudKit's private database
///   eventually propagates writes to other devices.  The values below are
///   conservative estimates; update them from the Phase 4a probe results.
///
/// - **`quota`** — Apple does not publish per-app CloudKit rate-limit values
///   publicly.  The placeholder below (60 ops/minute) is a conservative safe
///   default; update from the Phase 4a probe or Apple documentation.
///
/// ## Phase 4a probe
///
/// Before flipping `atomicConditionalCreate` to `true` and finalising the
/// numeric values, run the empirical probe described in the Phase 4a section
/// of `docs/plans/plan_icloud_sync.md`.  Record the findings in that plan,
/// then update this constant accordingly.
///
/// See also: [kGoogleDriveProfile] in `package:kmdb_google_drive` for the
/// analogous constant for the Google Drive adapter.
const kICloudProfile = CloudProfile(
  /// Eventually consistent: CloudKit propagates writes to other devices
  /// within a bounded window.  The values below are conservative estimates;
  /// they will be replaced with Phase 4a measured results.
  consistency: EventualConsistency(
    maxPropagationDelayMs: 60000, // 60 s conservative upper bound (placeholder)
    jitterMs: 10000, // ±10 s realistic variation (placeholder)
  ),

  /// Phase 4a probe has NOT yet confirmed atomic create-if-absent.
  /// Kept as `false` (loss-free default) until verified.
  /// Set to `true` only if Phase 4a confirms zone-level serialisation
  /// guarantees a single winner for concurrent creates with the same record ID.
  ///
  /// Must equal [ICloudAdapter.providesAtomicCas].
  atomicConditionalCreate: false,

  /// CloudKit zones: one record per record ID, no duplicate record names.
  allowsDuplicateNames: false,

  /// Conservative default rate limit (placeholder pending Phase 4a probe).
  /// Apple does not publish exact per-app CloudKit rate limits publicly.
  quota: QuotaProfile(
    maxOpsPerMinute: 60, // placeholder; update from Phase 4a results
    maxUploadBytesPerDay:
        null, // CloudKit enforces storage quota, not byte-rate
  ),
);
