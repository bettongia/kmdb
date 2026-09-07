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

// Accessibility guideline coverage for the sample app's UI.
//
// The UI layer is excluded from the *line-coverage* gate
// (`// coverage:ignore-file`), but the Integration Guide ships an accessibility
// note and the app is a reference other developers copy — so it must model the
// accessibility baseline, not just describe it. These tests assert Flutter's
// built-in accessibility guidelines (contrast, labelled/large-enough tap
// targets) against real widgets, per the `bettongia:inclusivity` standard.
//
// Tap-target guidelines: this is a desktop-only app (macOS/Linux/Windows, per
// the plan's Q3), where the iOS/Android minimum-size guidelines are not the
// governing platform contract; `androidTapTargetGuideline` is included anyway
// as the stricter of the two (Material's default controls satisfy it) so any
// future regression to an undersized custom control is caught.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb_example_todo/main.dart';
import 'package:kmdb_example_todo/src/models/task.dart';
import 'package:kmdb_example_todo/src/ui/widgets/status_priority_chips.dart';

import 'support/temp_dir.dart';

void main() {
  group('Unlock/Create screen meets accessibility guidelines', () {
    testWidgets('contrast, labelled tap targets, tap-target size', (
      tester,
    ) async {
      final dir = createTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      await tester.pumpWidget(TodoApp(dbPath: dir.path));
      await tester.pump();

      // Every interactive control (the Create button, the passphrase field)
      // has an accessible name.
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      // Text and UI components clear the WCAG AA contrast thresholds.
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      // Interactive controls are large enough to hit.
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
  });

  group('StatusPriorityChip', () {
    // Build every priority/status variant at once so the contrast check covers
    // all colour pairs (the highest-risk element for accessibility — small,
    // colour-coded UI).
    Widget harness() => MaterialApp(
      home: Scaffold(
        body: Wrap(
          children: [
            for (final priority in TaskPriority.values)
              StatusPriorityChip.priority(priority),
            for (final status in TaskStatus.values)
              StatusPriorityChip.status(status),
          ],
        ),
      ),
    );

    testWidgets('every colour pair meets the contrast guideline', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets(
      'value is exposed to screen readers, not conveyed by colour alone',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(harness());

        // Each chip carries a "Priority: <value>" / "Status: <value>" label,
        // so a screen-reader user gets the value without perceiving colour.
        expect(
          find.bySemanticsLabel('Priority: ${TaskPriority.high}'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Status: ${TaskStatus.done}'),
          findsOneWidget,
        );

        handle.dispose();
      },
    );
  });
}
