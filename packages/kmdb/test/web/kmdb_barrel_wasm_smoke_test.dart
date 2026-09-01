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

// Web barrel-compile smoke (0.10.01 WI-9 Phase C, release-blocker #1: make
// `package:kmdb/kmdb.dart` compile for web).
//
// This is a pure *compile-time* regression fence, run with `--compiler
// dart2wasm` (wasm-only per the plan's Q2 decision — dart2js is not a
// supported web target for kmdb). The assertion inside `main()` is
// deliberately trivial; the value of this file is entirely in the compile
// succeeding at all.
//
// Before the `embedding_model.dart` seam existed, compiling this exact
// one-line import with `dart compile wasm` failed with:
//
//   Error: Dart library 'dart:ffi' is not available on this platform.
//
// because `package:kmdb/kmdb.dart:116` unconditionally re-exported
// `package:betto_inferencing`, whose barrel unconditionally re-exports
// `package:betto_onnxrt`, which imports `dart:ffi`. Tree-shaking cannot help
// here — an unconditional `export`/`import` is a front-end *resolution*
// error, raised before any tree-shaking pass runs, regardless of whether the
// exported symbols are ever referenced. See the plan's Investigation section
// (`docs/plans/completed/plan_0_10_01_web_barrel_compile.md`) for the full
// root-cause trace.
@TestOn('browser')
library;

// The load-bearing line: merely importing the barrel is enough to force the
// compiler to resolve (and therefore fail on, before this fix) every
// unconditional import/export it transitively reaches.
import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

void main() {
  test('package:kmdb/kmdb.dart compiles and resolves under dart2wasm', () {
    // Reference a barrel-exported symbol so this file cannot be optimised
    // away as a no-op import before the compile step is exercised (imports
    // are already resolved well before that could happen, but referencing a
    // symbol also documents intent for a future reader).
    expect(EmbeddingKind.values, hasLength(2));
  });
}
