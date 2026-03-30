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

/// Platform-agnostic file I/O abstraction used by the LSM engine.
///
/// Conditional exports select the correct implementation at compile time:
/// - Native (dart:io): [StorageAdapterNative]
/// - Web (OPFS via dart:js_interop): [StorageAdapterWeb] (Phase 8)
/// - In-memory (tests): [MemoryStorageAdapter]
library;

export 'storage_adapter_interface.dart';
export 'storage_adapter_memory.dart';
export 'storage_adapter_impl.dart'
    if (dart.library.io) 'storage_adapter_native.dart'
    if (dart.library.js_interop) 'storage_adapter_web.dart';
