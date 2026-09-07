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

import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb_example_todo/src/codecs/project_codec.dart';
import 'package:kmdb_example_todo/src/models/project.dart';

void main() {
  const codec = ProjectCodec();

  group('ProjectCodec', () {
    test('keyOf returns the project id', () {
      final p = Project(
        id: 'abc',
        name: 'n',
        description: 'd',
        createdAt: DateTime.utc(2026),
      );
      expect(codec.keyOf(p), 'abc');
    });

    test('withKey stamps the key onto a new instance', () {
      final p = Project(
        id: '',
        name: 'n',
        description: 'd',
        createdAt: DateTime.utc(2026),
      );
      final keyed = codec.withKey(p, 'newkey');
      expect(keyed.id, 'newkey');
      expect(keyed.name, 'n');
    });

    test('encode emits no top-level `_`-prefixed key', () {
      final p = Project(
        id: 'abc',
        name: 'n',
        description: 'd',
        createdAt: DateTime.utc(2026),
      );
      final json = codec.encode(p);
      expect(json.keys.any((k) => k.startsWith('_')), isFalse);
    });

    test('round-trips a DateTime via ISO-8601', () {
      final createdAt = DateTime.utc(2026, 3, 4, 5, 6, 7);
      final p = Project(
        id: 'abc',
        name: 'n',
        description: 'd',
        createdAt: createdAt,
      );
      final json = codec.encode(p);
      expect(json['createdAt'], createdAt.toIso8601String());

      // decode() receives the map with '_id' injected by the framework.
      final decoded = codec.decode({...json, '_id': 'abc'});
      expect(decoded.createdAt, createdAt);
      expect(decoded.id, 'abc');
      expect(decoded.name, 'n');
      expect(decoded.description, 'd');
    });
  });
}
