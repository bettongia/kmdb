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

// Conditional export that makes `StorageAdapterSahPool` — the OPFS-backed
// web `StorageAdapter` — resolvable from the public barrel
// (`packages/kmdb/lib/kmdb.dart`) on every platform (0.10.01 WI-9 Phase C,
// release-ninja finding #2).
//
// `storage_adapter_sahpool.dart` (the real adapter) imports `dart:js_interop`
// via `package:web` — verified directly that a native `dart compile exe` of
// a fixture importing that file fails with "Dart library 'dart:js_interop'
// is not available on this platform." So an unconditional
// `export 'storage_adapter_sahpool.dart'` from the barrel would break every
// native compile of `package:kmdb`. This is the asymmetric opposite of the
// `dart:io`-on-wasm finding that let `StorageAdapterNative` be exported
// unconditionally (see `docs/spec/19_platform.md`): `dart:io` compiles on
// dart2wasm, but `dart:js_interop` does not compile on the native VM.
//
// Therefore this needs the same native-stub conditional-export seam used
// elsewhere in the package (`local_directory_adapter_stub.dart`,
// `embedding_model_stub.dart`): the pure-Dart stub
// (`storage_adapter_sahpool_stub.dart`) is the unconditional/default branch,
// and the real `dart:js_interop`-based adapter sits behind
// `if (dart.library.js_interop)`.
//
// Polarity note: `dart analyze` (and `dart compile exe` / the native VM)
// always resolve a conditional export to its *unconditional* branch,
// regardless of which `dart.library.*` condition would actually be true at
// runtime. Putting the stub on the unconditional branch means the
// analyzer/VM/native-compile all see the pure-Dart stub (no
// `dart:js_interop` in the graph); only a web compile
// (`dart.library.js_interop` true) pulls in the real adapter. This is the
// exact dual of the already-shipped `local_directory_adapter` seam at
// `kmdb.dart` (`if (dart.library.io)` picks the *native* branch there,
// because that seam's stub is web-only) — see that seam and
// `default_local_adapter.dart` for the sibling precedents.
//
// `show StorageAdapterSahPool` is sufficient: the constructor is
// parameterless and every method parameter/return type is either a Dart
// core type or `StorageException`/`LockException`, both already exported
// from the barrel — no companion type crosses the API boundary.
export 'storage_adapter_sahpool_stub.dart'
    if (dart.library.js_interop) 'storage_adapter_sahpool.dart'
    show StorageAdapterSahPool;
