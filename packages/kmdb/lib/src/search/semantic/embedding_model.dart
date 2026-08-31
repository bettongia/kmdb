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

// Conditional export selects the correct `EmbeddingModel`/`EmbeddingKind`
// surface for the current platform.
//
// `betto_inferencing`'s barrel unconditionally re-exports `betto_onnxrt`,
// which imports `dart:ffi` — a front-end resolution error on web (fails
// before tree-shaking even runs), so `show EmbeddingKind` alone is not
// enough to keep it out of a web compile. This kmdb-owned indirection is
// the seam: every kmdb `lib/` file that needs `EmbeddingModel`/
// `EmbeddingKind` imports *this* file, never `package:betto_inferencing`
// directly.
//
// - Native (default/unconditional branch): re-exports the real
//   `betto_inferencing` types (type *identity* preserved — see
//   `embedding_model_native.dart`'s doc comment for why this must be a
//   re-export, not a redeclaration).
// - Web (`dart.library.js_interop` true, including `dart2wasm` — verified
//   directly against this file with `dart compile wasm`): a pure-Dart stub
//   redeclaring the same interface/enum shape, so `VecManager` and friends
//   still type-check on web even though no concrete `EmbeddingModel`
//   implementation exists there.
//
// Deliberately native-default / web-conditional (the same polarity as the
// `default_local_adapter.dart` seam), NOT `if (dart.library.io)` with a
// stub default as the plan's Investigation originally suggested: `dart
// analyze` does not evaluate conditional-import/export conditions at all —
// it always statically resolves to the *unconditional* branch, regardless
// of `dart.library.io`/`dart.library.js_interop`. Since this seam's whole
// point is that native code re-exports (not redeclares) betto_inferencing's
// `EmbeddingModel` so type identity is preserved, having the analyzer
// default to the *stub* branch would make every native call site — and the
// dedicated type-identity regression test — fail `dart analyze` with an
// `argument_type_not_assignable` error, even though the real (VM/dart2wasm)
// compile is correct either way. Making native the default branch keeps the
// analyzer, the VM, and dart2wasm all in agreement.
export 'embedding_model_native.dart'
    if (dart.library.js_interop) 'embedding_model_stub.dart';
