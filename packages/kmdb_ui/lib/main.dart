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
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_provider.dart';
import 'collection_provider.dart';
import 'database_columns.dart';
import 'new_database_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

class MyApp extends StatelessWidget {
  final SharedPreferences prefs;

  const MyApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DatabaseProvider(prefs)),
        ChangeNotifierProxyProvider<DatabaseProvider, CollectionProvider?>(
          create: (_) => null,
          update: (_, databaseProvider, previous) {
            if (databaseProvider.store != null &&
                databaseProvider.selectedCollection != null) {
              return CollectionProvider(
                databaseProvider.store!,
                databaseProvider.selectedCollection!,
              );
            }
            return null;
          },
        ),
      ],
      child: Consumer<DatabaseProvider>(
        builder: (context, provider, child) {
          return MaterialApp(
            title: 'KMDB Browser',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
              useMaterial3: true,
              textTheme: GoogleFonts.interTextTheme(),
            ),
            home: const HomePage(),
            themeMode: provider.themeMode,
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blueGrey,
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
              textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
            ),
          );
        },
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  double _dbWidth = 200;
  double _collectionWidth = 250;
  double _contentWidth = 400;
  double _detailWidth = 500;
  final ScrollController _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();

    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'KMDB Browser',
          menus: [
            if (PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.about))
              const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.about),
            if (PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.quit))
              const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.quit),
          ],
        ),
        PlatformMenu(
          label: 'Database',
          menus: [
            PlatformMenuItem(
              label: 'New...',
              onSelected: () async {
                final String? path = await showDialog<String>(
                  context: context,
                  builder: (_) => const NewDatabaseDialog(),
                );
                if (path != null) {
                  provider.selectDatabase(path);
                }
              },
              shortcut: const CharacterActivator('n', meta: true),
            ),
            PlatformMenuItem(
              label: 'Open...',
              onSelected: () => provider.openDatabase(),
              shortcut: const CharacterActivator('o', meta: true),
            ),
          ],
        ),
        PlatformMenu(
          label: 'View',
          menus: [
            PlatformMenu(
              label: 'Mode',
              menus: [
                PlatformMenuItem(
                  label: 'Light',
                  onSelected: () => provider.setThemeMode(ThemeMode.light),
                ),
                PlatformMenuItem(
                  label: 'Dark',
                  onSelected: () => provider.setThemeMode(ThemeMode.dark),
                ),
                PlatformMenuItem(
                  label: 'System',
                  onSelected: () => provider.setThemeMode(ThemeMode.system),
                ),
              ],
            ),
          ],
        ),
      ],
      child: Scaffold(
        body: SafeArea(
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: _dbWidth, child: const DatabaseHistoryColumn()),
                  _ColumnDivider(
                    onDrag: (delta) {
                      setState(() {
                        _dbWidth = (_dbWidth + delta).clamp(100.0, 500.0);
                      });
                    },
                  ),
                  if (provider.selectedDatabasePath != null) ...[
                    SizedBox(
                        width: _collectionWidth,
                        child: const CollectionListColumn()),
                    _ColumnDivider(
                      onDrag: (delta) {
                        setState(() {
                          _collectionWidth =
                              (_collectionWidth + delta).clamp(150.0, 600.0);
                        });
                      },
                    ),
                  ],
                  if (provider.selectedCollection != null) ...[
                    SizedBox(
                        width: _contentWidth,
                        child: const DocumentContentColumn()),
                    _ColumnDivider(
                      onDrag: (delta) {
                        setState(() {
                          _contentWidth =
                              (_contentWidth + delta).clamp(200.0, 800.0);
                        });
                      },
                    ),
                  ],
                  if (provider.selectedDocument != null) ...[
                    SizedBox(
                      width: _detailWidth,
                      child: const DocumentDetailColumn(),
                    ),
                    _ColumnDivider(
                      onDrag: (delta) {
                        setState(() {
                          _detailWidth =
                              (_detailWidth + delta).clamp(200.0, 1000.0);
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColumnDivider extends StatelessWidget {
  final Function(double) onDrag;

  const _ColumnDivider({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: Container(
          width: 8,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 1,
              color: Colors.grey.shade300,
            ),
          ),
        ),
      ),
    );
  }
}
