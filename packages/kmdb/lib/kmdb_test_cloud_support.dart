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

/// Cloud-simulation test-support types for the KMDB harness.
///
/// **Test-only.** This library is intended for use in test code — specifically
/// by `kmdb_harness` scenario tests and `kmdb` adapter conformance tests. It
/// must not be imported by production code.
///
/// Provides the shared-backend / cloud-semantics infrastructure that allows
/// multiple device adapters to share a single logical remote while modelling
/// realistic cloud-provider behaviour (eventual consistency, propagation delay,
/// conditional-write atomicity).
///
/// Per decision D3 in `plan_harness_mixed_storage.md`, these types live in
/// `kmdb` test-support so both the adapter conformance suite and
/// `kmdb_harness` can import the same definitions without circular dependencies.
///
/// ## Typical usage
///
/// ```dart
/// import 'package:kmdb/kmdb_test_cloud_support.dart';
///
/// // Strongly-consistent: multiple devices share one logical remote.
/// final backend = SharedCloudBackend();
/// final adapterA = SharedBackendAdapter(backend, deviceId: 'dev-0');
/// final adapterB = SharedBackendAdapter(backend, deviceId: 'dev-1');
///
/// // Eventually-consistent decorator.
/// final profile = CloudProfile.eventual(maxPropagationDelayMs: 200);
/// final eventual = CloudSemanticsAdapter(
///   backend: adapterA,
///   profile: profile,
/// );
/// eventual.advancePropagationClock(); // settle all pending writes
/// ```
library;

export 'src/test_cloud/visibility_cursor_adapter.dart'
    show VisibilityCursorAdapter;
export 'src/test_cloud/cloud_profile.dart'
    show
        CloudProfile,
        ConsistencyModel,
        ConsistencyModelX,
        EventualConsistency,
        QuotaProfile,
        StrongConsistency;
export 'src/test_cloud/cloud_semantics_adapter.dart' show CloudSemanticsAdapter;
export 'src/test_cloud/shared_backend_adapter.dart' show SharedBackendAdapter;
export 'src/test_cloud/shared_cloud_backend.dart'
    show SharedCloudBackend, StoredFile;
