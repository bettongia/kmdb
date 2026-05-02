// Copyright 2026 The KMDB Authors
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
import 'package:kmdb_ui/main.dart';
import 'package:kmdb_ui/app_provider.dart';
import 'package:kmdb_ui/error_provider.dart';
import 'package:kmdb_ui/collection_provider.dart';

class MockAppProvider extends Mock implements AppProvider {}

void main() {
  late MockAppProvider mockAppProvider;

  setUp(() {
    mockAppProvider = MockAppProvider();

    // Default mock behaviours required by HomePage widgets.
    when(
      () => mockAppProvider.recentDatabasePaths,
    ).thenReturn(['/path/to/db1']);
    when(() => mockAppProvider.selectedDatabasePath).thenReturn(null);
    when(() => mockAppProvider.selectedCollection).thenReturn(null);
    when(() => mockAppProvider.selectedDocument).thenReturn(null);
    when(() => mockAppProvider.themeMode).thenReturn(ThemeMode.light);
    when(() => mockAppProvider.isOpening).thenReturn(false);
    when(() => mockAppProvider.loadError).thenReturn(null);
    when(() => mockAppProvider.collections).thenReturn([]);
    when(() => mockAppProvider.isBusy).thenReturn(false);
    when(() => mockAppProvider.busyMessage).thenReturn('');
  });

  Widget createTestWidget() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ErrorProvider>(
          create: (_) => ErrorProvider(),
        ),
        ChangeNotifierProvider<AppProvider>.value(
          value: mockAppProvider,
        ),
        Provider<CollectionProvider?>.value(value: null),
      ],
      child: MaterialApp(home: const HomePage()),
    );
  }

  testWidgets('HomePage shows DATABASES column', (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());

    expect(find.text('DATABASES'), findsOneWidget);
    expect(find.text('db1'), findsOneWidget);
  });

  testWidgets('Selecting a database calls provider', (
    WidgetTester tester,
  ) async {
    when(
      () => mockAppProvider.selectDatabase(any()),
    ).thenAnswer((_) async {});

    await tester.pumpWidget(createTestWidget());

    await tester.tap(find.text('db1'));
    await tester.pump();

    verify(() => mockAppProvider.selectDatabase(any())).called(1);
  });

  testWidgets('HomePage shows narrow layout when window is narrow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(createTestWidget());

    // On narrow screens, only the database history column is visible (root).
    expect(find.text('DATABASES'), findsOneWidget);
    // No collection list since no database is selected.
    expect(find.text('COLLECTIONS'), findsNothing);
  });

  testWidgets('HomePage shows wide layout when window is wide', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(createTestWidget());

    expect(find.text('DATABASES'), findsOneWidget);
  });
}
