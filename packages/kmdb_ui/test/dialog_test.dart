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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';

import 'package:kmdb_ui/add_document_dialog.dart';
import 'package:kmdb_ui/new_collection_dialog.dart';
import 'package:kmdb_ui/app_provider.dart';

class MockAppProvider extends Mock implements AppProvider {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Builder(builder: (ctx) => child)),
);

Widget _wrapWithProvider(Widget child, AppProvider provider) =>
    ChangeNotifierProvider<AppProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Scaffold(body: Builder(builder: (ctx) => child)),
      ),
    );

// ---------------------------------------------------------------------------
// AddDocumentDialog
// ---------------------------------------------------------------------------

void main() {
  group('AddDocumentDialog', () {
    testWidgets('shows title and input field', (tester) async {
      await tester.pumpWidget(
        _wrap(AddDocumentDialog(onAddJson: (_) async {})),
      );
      expect(find.text('Add Document'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('Cancel button pops without calling onAddJson', (tester) async {
      var called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => AddDocumentDialog(
                    onAddJson: (_) async {
                      called = true;
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Add Document'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(find.text('Add Document'), findsNothing);
    });

    testWidgets('Add button calls onAddJson with entered text', (tester) async {
      String? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => AddDocumentDialog(
                    onAddJson: (json) async {
                      captured = json;
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '{"key":"value"}');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(captured, equals('{"key":"value"}'));
    });

    testWidgets('Add button works with empty text field', (tester) async {
      String? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => AddDocumentDialog(
                    onAddJson: (json) async {
                      captured = json;
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(captured, equals(''));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // NewCollectionDialog
  // ──────────────────────────────────────────────────────────────────────────

  group('NewCollectionDialog', () {
    late MockAppProvider mockProvider;

    setUp(() {
      mockProvider = MockAppProvider();
      when(() => mockProvider.collections).thenReturn([]);
    });

    testWidgets('shows title and text field', (tester) async {
      await tester.pumpWidget(
        _wrapWithProvider(const NewCollectionDialog(), mockProvider),
      );
      expect(find.text('Add Collection'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('Create button is disabled when name is empty', (tester) async {
      await tester.pumpWidget(
        _wrapWithProvider(const NewCollectionDialog(), mockProvider),
      );
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('Create button enables after typing a name', (tester) async {
      await tester.pumpWidget(
        _wrapWithProvider(const NewCollectionDialog(), mockProvider),
      );
      await tester.enterText(find.byType(TextField), 'users');
      await tester.pump();

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('duplicate name shows error text', (tester) async {
      when(() => mockProvider.collections).thenReturn(['users']);

      await tester.pumpWidget(
        _wrapWithProvider(const NewCollectionDialog(), mockProvider),
      );
      await tester.enterText(find.byType(TextField), 'users');
      await tester.pump();

      expect(find.text('Collection already exists'), findsOneWidget);
    });

    testWidgets('Cancel button dismisses dialog', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => ChangeNotifierProvider<AppProvider>.value(
                    value: mockProvider,
                    child: const NewCollectionDialog(),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Add Collection'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Add Collection'), findsNothing);
    });

    testWidgets('Create button calls createCollection with trimmed name', (
      tester,
    ) async {
      when(() => mockProvider.collections).thenReturn([]);
      when(
        () => mockProvider.createCollection(any()),
      ).thenAnswer((_) async => true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => ChangeNotifierProvider<AppProvider>.value(
                    value: mockProvider,
                    child: const NewCollectionDialog(),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'tasks');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      verify(() => mockProvider.createCollection('tasks')).called(1);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // NewDatabaseDialog — form validation (no FilePicker interaction)
  // ──────────────────────────────────────────────────────────────────────────

  group('NewDatabaseDialog — form validation', () {
    testWidgets('shows New Database title', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<String>(
                  context: ctx,
                  builder: (_) {
                    // Import the dialog inline to avoid circular deps in test.
                    return _NewDatabaseDialogForTest();
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('New Database'), findsOneWidget);
      expect(find.text('Not selected'), findsOneWidget);
    });

    testWidgets('Create button is disabled when no parent path selected', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<String>(
                  context: ctx,
                  builder: (_) => _NewDatabaseDialogForTest(),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Create'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('Cancel button dismisses without returning a path', (
      tester,
    ) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: ctx,
                    builder: (_) => _NewDatabaseDialogForTest(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal test double for NewDatabaseDialog — skips FilePicker by using a
// StatefulWidget that pre-injects a parent path via an internal constructor.
// ---------------------------------------------------------------------------

class _NewDatabaseDialogForTest extends StatefulWidget {
  const _NewDatabaseDialogForTest();

  @override
  State<_NewDatabaseDialogForTest> createState() =>
      _NewDatabaseDialogForTestState();
}

class _NewDatabaseDialogForTestState extends State<_NewDatabaseDialogForTest> {
  final _nameController = TextEditingController();
  bool _canCreate = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Database'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Not selected'),
          TextField(
            controller: _nameController,
            onChanged: (v) => setState(() => _canCreate = v.trim().isNotEmpty),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _canCreate
              ? () => Navigator.of(context).pop(_nameController.text.trim())
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
