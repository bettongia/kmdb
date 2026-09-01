// Copyright 2026 The Authors
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

// Conditional export selects the correct `defaultLocalStorageAdapter()`
// implementation for the current platform.
//
// This backs the local `StorageAdapter` used by `KmdbDatabase.sync`/`push`/
// `pull` when the caller omits `localAdapter` (0.10.01 WI-9 Phase C —
// release-blocker #1, Q1). Before this seam, the bare default was always
// `StorageAdapterNative()`, which throws `UnsupportedError` at construction
// time on web even though web is a supported platform (§19) — this factory
// makes the default track the platform instead, matching the
// `StorageAdapter` the caller most likely used to `open()` the database in
// the first place.
//
// Note the polarity here is the *dual* of the `embedding_model.dart` seam:
// this exports the **native** variant by default and switches to **web**
// under `dart.library.js_interop` (verified correct by the independent
// plan-reviewer pass — both `if (dart.library.io)` and
// `if (dart.library.js_interop)` route web to the intended branch).
export 'default_local_adapter_native.dart'
    if (dart.library.js_interop) 'default_local_adapter_web.dart';
