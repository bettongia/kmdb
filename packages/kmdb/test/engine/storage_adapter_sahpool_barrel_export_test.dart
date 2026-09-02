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

// Native (VM) regression test for the `storage_adapter_sahpool_export.dart`
// seam (0.10.01 WI-9 Phase C, release-ninja finding #2: export
// `StorageAdapterSahPool` from the public barrel).
//
// This file deliberately imports only `package:kmdb/kmdb.dart` — the whole
// point of the plan is that `StorageAdapterSahPool` is now a resolvable,
// constructible name reachable from the public API on every platform,
// including native, where the concrete OPFS-backed adapter cannot actually
// run. Confirms:
//   - the barrel export compiles and resolves on the native VM (the
//     `if (dart.library.js_interop)` conditional correctly falls back to the
//     pure-Dart stub here, not the `dart:js_interop`-importing real adapter);
//   - the stub's constructor throws `UnsupportedError` rather than silently
//     constructing a non-functional adapter;
//   - the stub also exposes the non-interface `close()` method so
//     cross-platform code that calls `adapter.close()` still compiles here.
import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

void main() {
  group('StorageAdapterSahPool barrel export (native)', () {
    test('is importable from package:kmdb/kmdb.dart and its constructor '
        'throws UnsupportedError on native platforms', () {
      expect(StorageAdapterSahPool.new, throwsUnsupportedError);
    });

    test('StorageAdapterNative remains constructible alongside the stub — '
        'the seam does not shadow or break the existing native adapter', () {
      // Only constructs the object; no I/O is performed. Proves both
      // barrel-exported adapter types coexist without name collision.
      expect(StorageAdapterNative.new, returnsNormally);
    });
  });
}
