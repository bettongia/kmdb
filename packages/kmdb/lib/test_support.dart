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

/// Test-support library for KMDB adapter conformance testing.
///
/// **Test-only.** This library exports utilities for use in test code —
/// specifically by `kmdb` adapter conformance tests and downstream packages
/// (e.g. `kmdb_google_drive`) that implement `SyncStorageAdapter`.  It must
/// not be imported by production code.
///
/// The library depends on `package:test` and is therefore not bundled in the
/// core `kmdb` library.  Downstream consumers must add `test` to their
/// `dev_dependencies`.
///
/// ## Typical usage (in a downstream adapter test)
///
/// ```dart
/// import 'package:kmdb/test_support.dart';
///
/// void main() {
///   group('MyAdapter conformance', () {
///     runSyncAdapterConformance(
///       factory: MyAdapter.new,
///       expectAtomicCas: true,
///       expectsCancellation: true,
///     );
///   });
/// }
/// ```
library;

export 'src/test_support/sync_adapter_conformance.dart'
    show runSyncAdapterConformance, runSyncAdapterContentionTest;
export 'src/test_support/gated_sync_adapter.dart' show GatedSyncAdapter;
