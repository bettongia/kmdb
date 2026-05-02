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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_provider.dart';
import 'collection_provider.dart';
import 'error_provider.dart';
import 'async_operation_overlay.dart';
import 'database_columns.dart';
import 'layout/adaptive_layout.dart';
import 'new_database_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

/// The root widget for the KMDB Browser application.
class MyApp extends StatelessWidget {
  final SharedPreferences prefs;

  const MyApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ErrorProvider()),
        ChangeNotifierProvider(create: (_) => AppProvider(prefs)),
        // CollectionProvider is recreated whenever the selected collection
        // changes. It is null when no collection is selected.
        ChangeNotifierProxyProvider<AppProvider, CollectionProvider?>(
          create: (_) => null,
          update: (context, appProvider, previous) {
            final db = appProvider.database;
            final col = appProvider.selectedCollection;
            if (db != null && col != null) {
              // Reuse the existing provider when the collection is unchanged to
              // preserve scroll position and scan options.
              if (previous != null && previous.collectionName == col) {
                return previous;
              }
              // Read ErrorProvider from the tree so errors surface as snackbars.
              final errorProvider = context.read<ErrorProvider>();
              return CollectionProvider(db, col, errorProvider);
            }
            return null;
          },
        ),
      ],
      child: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          return MaterialApp(
            title: 'KMDB Browser',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
              useMaterial3: true,
              textTheme: GoogleFonts.interTextTheme(),
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blueGrey,
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
              textTheme: GoogleFonts.interTextTheme(
                ThemeData.dark().textTheme,
              ),
            ),
            themeMode: appProvider.themeMode,
            home: const HomePage(),
          );
        },
      ),
    );
  }
}

/// The application home page.
///
/// On macOS, a [PlatformMenuBar] provides the native menu bar.
/// On other platforms the menu bar is omitted.
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
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();

    // Wrap the entire scaffold in the error listener so snackbars are routed
    // to the nearest ScaffoldMessenger.
    final scaffold = ErrorListener(
      child: AsyncOperationOverlay(
        child: Scaffold(
          body: SafeArea(
            child: AdaptiveColumnLayout(
              wideBuilder: (_) => _buildWideLayout(context, appProvider),
              narrowBuilder: (_) => _buildNarrowLayout(context, appProvider),
            ),
          ),
        ),
      ),
    );

    // Guard PlatformMenuBar behind a macOS check. On other platforms the
    // native menu bar infrastructure is not available and calling
    // PlatformMenuBar would throw at runtime.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return _buildWithMenuBar(context, appProvider, scaffold);
    }
    return scaffold;
  }

  Widget _buildWithMenuBar(
    BuildContext context,
    AppProvider appProvider,
    Widget child,
  ) {
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'KMDB Browser',
          menus: [
            if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.about,
            ))
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
            if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.quit,
            ))
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit,
              ),
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
                  appProvider.selectDatabase(path);
                }
              },
              shortcut: const CharacterActivator('n', meta: true),
            ),
            PlatformMenuItem(
              label: 'Open...',
              onSelected: () => appProvider.openDatabase(),
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
                  onSelected: () =>
                      appProvider.setThemeMode(ThemeMode.light),
                ),
                PlatformMenuItem(
                  label: 'Dark',
                  onSelected: () =>
                      appProvider.setThemeMode(ThemeMode.dark),
                ),
                PlatformMenuItem(
                  label: 'System',
                  onSelected: () =>
                      appProvider.setThemeMode(ThemeMode.system),
                ),
              ],
            ),
          ],
        ),
      ],
      child: child,
    );
  }

  /// Multi-column side-by-side layout for wide screens.
  Widget _buildWideLayout(BuildContext context, AppProvider appProvider) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _dbWidth,
              child: const DatabaseHistoryColumn(),
            ),
            ColumnDivider(
              onDrag: (delta) {
                setState(() {
                  _dbWidth = (_dbWidth + delta).clamp(100.0, 500.0);
                });
              },
            ),
            if (appProvider.selectedDatabasePath != null) ...[
              SizedBox(
                width: _collectionWidth,
                child: const CollectionListColumn(),
              ),
              ColumnDivider(
                onDrag: (delta) {
                  setState(() {
                    _collectionWidth =
                        (_collectionWidth + delta).clamp(150.0, 600.0);
                  });
                },
              ),
            ],
            if (appProvider.selectedCollection != null) ...[
              SizedBox(
                width: _contentWidth,
                child: const DocumentContentColumn(),
              ),
              ColumnDivider(
                onDrag: (delta) {
                  setState(() {
                    _contentWidth =
                        (_contentWidth + delta).clamp(200.0, 800.0);
                  });
                },
              ),
            ],
            if (appProvider.selectedDocument != null) ...[
              SizedBox(
                width: _detailWidth,
                child: const DocumentDetailColumn(),
              ),
              ColumnDivider(
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
    );
  }

  /// Single-column Navigator-push layout for narrow screens.
  ///
  /// The database history list is the root page. Selecting a database pushes
  /// the collection list, selecting a collection pushes the document list,
  /// and selecting a document pushes the detail view.
  Widget _buildNarrowLayout(BuildContext context, AppProvider appProvider) {
    // The Navigator for narrow-screen navigation is managed by the system
    // Navigator (MaterialApp). We simply show one column at a time and rely
    // on AppProvider selection state to determine which column is topmost.
    if (appProvider.selectedDocument != null) {
      return const DocumentDetailColumn();
    }
    if (appProvider.selectedCollection != null) {
      return const DocumentContentColumn();
    }
    if (appProvider.selectedDatabasePath != null) {
      return const CollectionListColumn();
    }
    return const DatabaseHistoryColumn();
  }
}
