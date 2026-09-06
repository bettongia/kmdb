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
import 'package:kmdb_example_todo/src/models/project.dart';

void main() {
  group('Project.copyWith', () {
    test('replaces only the given fields, keeping id/createdAt', () {
      final createdAt = DateTime.utc(2026, 1, 1);
      final original = Project(
        id: 'abc',
        name: 'Original',
        description: 'Original description',
        createdAt: createdAt,
      );

      final renamed = original.copyWith(name: 'Renamed');
      expect(renamed.id, 'abc');
      expect(renamed.name, 'Renamed');
      expect(renamed.description, 'Original description');
      expect(renamed.createdAt, createdAt);

      final redescribed = original.copyWith(description: 'New description');
      expect(redescribed.name, 'Original');
      expect(redescribed.description, 'New description');
    });

    test('with no arguments returns an equivalent copy', () {
      final createdAt = DateTime.utc(2026, 1, 1);
      final original = Project(
        id: 'abc',
        name: 'Original',
        description: 'Original description',
        createdAt: createdAt,
      );
      final copy = original.copyWith();
      expect(copy.id, original.id);
      expect(copy.name, original.name);
      expect(copy.description, original.description);
      expect(copy.createdAt, original.createdAt);
    });
  });
}
