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
/// Values are derived from the Phase 4a empirical probe documented in
/// `docs/spec/30_icloud_adapter.md` and `docs/plans/plan_icloud_sync.md`.
/// The probe was run on macOS on a fast broadband connection (≈500 Mbps down /
/// 40 Mbps up); real-world values on mobile or congested connections will be
/// higher.
///
/// ## Key characteristics
///
/// - **`atomicConditionalCreate: false` (permanent)** — Phase 4a confirmed that
///   `savePolicy: .allKeys` on a fresh local `CKRecord` (nil `recordChangeTag`)
///   is an unconditional overwrite. CloudKit does NOT return
///   `CKError.serverRecordChanged` when a record with the same ID already
///   exists. Create-if-absent is therefore not atomic, and
///   [ICloudAdapter.providesAtomicCas] is permanently `false`.
///   `ConsolidationCoordinator` skips consolidation for this adapter.
///
///   Conditional **update** (`savePolicy: .ifServerRecordUnchanged`) **is**
///   atomic: exactly one concurrent updater wins when both hold the same
///   `recordChangeTag` as the precondition (Phase 4a confirmed).
///
/// - **`allowsDuplicateNames: false`** — CloudKit zones use a deterministic
///   `CKRecord.ID` derived from the file path. Exactly one record per ID per
///   zone is possible.
///
/// - **`consistency: EventualConsistency`** — `CKQuery` results are eventually
///   consistent even on the uploading device. Phase 4a measured ~5–7 s
///   same-device propagation delay on fast broadband; `maxPropagationDelayMs`
///   is set conservatively to accommodate slow mobile connections.
///
/// - **`quota`** — Apple does not publish per-app CloudKit rate-limit values.
///   The value below is a conservative safe default. Rate-limit errors are
///   handled defensively via `CKErrorRetryAfterKey` backoff in the Swift plugin.
///
/// See also: `kGoogleDriveProfile` in `package:kmdb_google_drive` for the
/// analogous constant for the Google Drive adapter.
const kICloudProfile = CloudProfile(
  // Phase 4a: same-device CKQuery propagation measured at ~5–7 s on fast
  // broadband. 60 s upper bound and 15 s jitter are conservative to cover
  // slow mobile connections and cross-device propagation (not yet measured).
  consistency: EventualConsistency(
    maxPropagationDelayMs: 60000,
    jitterMs: 15000,
  ),

  // Phase 4a confirmed: create-if-absent is NOT atomic (savePolicy: .allKeys
  // overwrites unconditionally). Permanently false — do not set to true.
  // Must equal ICloudAdapter.providesAtomicCas.
  atomicConditionalCreate: false,

  /// CloudKit zones: one record per record ID, no duplicate record names.
  allowsDuplicateNames: false,

  // Apple does not publish exact per-app CloudKit rate limits. Conservative
  // default; rate-limit errors are handled via CKErrorRetryAfterKey backoff.
  quota: QuotaProfile(
    maxOpsPerMinute: 60,
    maxUploadBytesPerDay:
        null, // CloudKit enforces storage quota, not byte-rate
  ),
);
