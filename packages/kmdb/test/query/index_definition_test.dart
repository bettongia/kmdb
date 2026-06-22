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

import 'package:kmdb/src/query/exceptions.dart';
import 'package:kmdb/src/query/index/index_definition.dart';
import 'package:test/test.dart';

void main() {
  group('IndexDefinition path normalisation', () {
    test('bare path stored as-is', () {
      final def = IndexDefinition('users', 'city');
      expect(def.path, equals('city'));
    });

    test('leading dollar-dot prefix is stripped', () {
      final def = IndexDefinition('users', r'$.address.city');
      expect(def.path, equals('address.city'));
    });

    test('dollar-dot and plain path produce same indexNamespace', () {
      final a = IndexDefinition('users', r'$.address.city');
      final b = IndexDefinition('users', 'address.city');
      expect(a.indexNamespace, equals(b.indexNamespace));
    });

    test('[*] wildcard rewritten to []', () {
      final def = IndexDefinition('posts', r'tags[*]');
      expect(def.path, equals('tags[]'));
    });

    test('[*] rewrite produces same indexNamespace as []', () {
      final a = IndexDefinition('posts', r'tags[*]');
      final b = IndexDefinition('posts', 'tags[]');
      expect(a.indexNamespace, equals(b.indexNamespace));
    });

    test('indexNamespace format is correct', () {
      final def = IndexDefinition('contacts', 'email');
      expect(def.indexNamespace, equals(r'$$index:contacts:email'));
    });
  });

  group('IndexDefinition validation', () {
    test('bare dollar path throws ArgumentError', () {
      expect(
        () => IndexDefinition('users', r'$'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('underscore-prefixed path throws ReservedIndexPathException', () {
      expect(
        () => IndexDefinition('users', '_id'),
        throwsA(isA<ReservedIndexPathException>()),
      );
    });

    test(
      'underscore-prefixed after dollar-dot throws ReservedIndexPathException',
      () {
        // $._ normalises to _<something> which is reserved
        expect(
          () => IndexDefinition('users', r'$._id'),
          throwsA(isA<ReservedIndexPathException>()),
        );
      },
    );
  });

  group('IndexDefinition equality', () {
    test('same namespace and path are equal', () {
      final a = IndexDefinition('users', 'city');
      final b = IndexDefinition('users', 'city');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different path produces different instance', () {
      final a = IndexDefinition('users', 'city');
      final b = IndexDefinition('users', 'country');
      expect(a, isNot(equals(b)));
    });

    test('normalised paths considered equal', () {
      final a = IndexDefinition('users', r'$.city');
      final b = IndexDefinition('users', 'city');
      expect(a, equals(b));
    });

    test('toString contains namespace and path', () {
      final def = IndexDefinition('contacts', 'address.city');
      expect(def.toString(), contains('contacts'));
      expect(def.toString(), contains('address.city'));
    });
  });
}
