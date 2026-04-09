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
import 'package:kmdb_ui/database_provider.dart';
import 'package:kmdb_ui/collection_provider.dart';

class MockDatabaseProvider extends Mock implements DatabaseProvider {}

class MockCollectionProvider extends Mock implements CollectionProvider {}

void main() {
  late MockDatabaseProvider mockDatabaseProvider;

  setUp(() {
    mockDatabaseProvider = MockDatabaseProvider();

    // Default mock behaviors
    when(
      () => mockDatabaseProvider.recentDatabasePaths,
    ).thenReturn(['/path/to/db1']);
    when(() => mockDatabaseProvider.selectedDatabasePath).thenReturn(null);
    when(() => mockDatabaseProvider.selectedCollection).thenReturn(null);
    when(() => mockDatabaseProvider.selectedDocument).thenReturn(null);
    when(() => mockDatabaseProvider.themeMode).thenReturn(ThemeMode.light);
    when(() => mockDatabaseProvider.isOpening).thenReturn(false);
    when(() => mockDatabaseProvider.loadError).thenReturn(null);
    when(() => mockDatabaseProvider.collections).thenReturn([]);
  });

  Widget createTestWidget() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DatabaseProvider>.value(
          value: mockDatabaseProvider,
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
      () => mockDatabaseProvider.selectDatabase(any()),
    ).thenAnswer((_) async {});

    await tester.pumpWidget(createTestWidget());

    await tester.tap(find.text('db1'));
    await tester.pump();

    verify(() => mockDatabaseProvider.selectDatabase(any())).called(1);
  });
}
