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

// A basic smoke test for the app shell. The UI layer (`lib/src/ui/**` and
// `main.dart`) is excluded from the coverage gate (`// coverage:ignore-file`)
// — the measured bar applies to `repositories/`, `codecs/`, and
// `db/schemas.dart` — so this is a cheap sanity check that the widget tree
// builds without crashing, not a substitute for that coverage.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb_example_todo/main.dart';

import 'support/temp_dir.dart';

void main() {
  testWidgets('TodoApp boots to the Unlock/Create screen for a fresh path', (
    WidgetTester tester,
  ) async {
    final dir = createTempDir();
    addTearDown(() => dir.deleteSync(recursive: true));

    await tester.pumpWidget(TodoApp(dbPath: dir.path));
    await tester.pump();

    // No database exists yet at this path, so the Unlock/Create screen must
    // present the "create" branch.
    expect(find.text('Create your database'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create'), findsOneWidget);
  });
}
