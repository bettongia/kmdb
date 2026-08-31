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

// Dedicated type-identity regression test for the `embedding_model.dart`
// seam (0.10.01 WI-9 Phase C, release-blocker #1: make `package:kmdb/kmdb.dart`
// compile for web).
//
// `lib/src/search/semantic/embedding_model_native.dart` must **re-export**
// (never redeclare) `package:betto_inferencing`'s `EmbeddingModel`/
// `EmbeddingKind` on native platforms. If a future edit accidentally
// redeclared these types instead, every existing test that passes a
// concrete `betto_inferencing.EmbeddingModel` implementation (e.g.
// `OnnxEmbeddingModel`, or any test fake) into `KmdbDatabase.open` would
// still "happen" to compile as long as the fake `implements
// kmdb.EmbeddingModel` directly — that incidental coverage does not prove
// the two types are actually *the same declaration*. This file makes that
// property an explicit, standalone assertion: a value statically typed as
// `betto_inferencing.EmbeddingModel` is assigned to a `kmdb.EmbeddingModel`
// variable — and back — with **no cast**. That only type-checks if the
// native branch of the seam is a re-export.
//
// Both packages export a type named `EmbeddingModel`, so this file imports
// each under a distinct prefix to keep them referable without a name
// collision.
import 'dart:typed_data';

import 'package:betto_inferencing/betto_inferencing.dart' as inferencing;
import 'package:kmdb/kmdb.dart' as kmdb;
import 'package:test/test.dart';

/// A minimal concrete [inferencing.EmbeddingModel] implementation.
///
/// Never actually invoked — this test only exercises static type
/// assignability, not embedding behaviour.
final class _RealEmbeddingModel implements inferencing.EmbeddingModel {
  @override
  String get modelId => 'identity-probe-v1';

  @override
  int get dimensions => 1;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    inferencing.EmbeddingKind kind = inferencing.EmbeddingKind.document,
  }) async => (Float32List(dimensions), false);

  @override
  void dispose() {}
}

void main() {
  group('embedding_model.dart seam — native type identity', () {
    test('a betto_inferencing.EmbeddingModel value is assignable to a '
        'kmdb.EmbeddingModel variable with no cast, and vice versa', () {
      final inferencing.EmbeddingModel real = _RealEmbeddingModel();

      // The load-bearing line: this only compiles if
      // `embedding_model_native.dart` re-exports (rather than redeclares)
      // betto_inferencing's EmbeddingModel — a redeclaration would make
      // this an `argument_type_not_assignable` / assignment error at
      // analysis time.
      final kmdb.EmbeddingModel viaKmdb = real;
      expect(identical(viaKmdb, real), isTrue);

      // And the reverse direction, for completeness — proves this isn't
      // a one-way subtype relationship but genuine type identity.
      final inferencing.EmbeddingModel back = viaKmdb;
      expect(identical(back, real), isTrue);
    });

    test('kmdb.EmbeddingKind and betto_inferencing.EmbeddingKind share the '
        'same enum values (re-export, not redeclaration)', () {
      // A redeclared (rather than re-exported) enum would still compile
      // this line (it declares the same member names), so this is a
      // weaker check than the EmbeddingModel identity test above — but it
      // documents the same seam invariant for the enum half of the
      // barrel's `show EmbeddingModel, EmbeddingKind` export.
      const kmdb.EmbeddingKind viaKmdb = inferencing.EmbeddingKind.query;
      expect(identical(viaKmdb, inferencing.EmbeddingKind.query), isTrue);
    });
  });
}
