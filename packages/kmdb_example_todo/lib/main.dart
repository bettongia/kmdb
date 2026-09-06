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

// coverage:ignore-file
//
// UI/app-shell entry point — excluded from the coverage gate. See the
// Integration Guide's "Coverage scope" note: the measured bar (>=90%)
// applies to lib/src/repositories/, lib/src/codecs/, and
// lib/src/db/schemas.dart, not lib/src/ui/** or this file.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/ui/screens/unlock_screen.dart';

/// Entry point. Resolves a per-user application-support directory and opens
/// [TodoApp] pointed at a `device_a` sub-directory within it — the sample
/// app's "primary" device. The Sync/Settings screen additionally opens a
/// second, ephemeral `device_b` instance under the same support directory to
/// demonstrate two-device sync (see `SyncSettingsScreen`).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final dbPath = p.join(supportDir.path, 'kmdb_example_todo', 'device_a');
  runApp(TodoApp(dbPath: dbPath));
}

/// Root widget for the kmdb Integration Guide sample to-do app.
class TodoApp extends StatelessWidget {
  /// Creates the app, rooted at [dbPath] for its primary database.
  const TodoApp({required this.dbPath, super.key});

  /// Filesystem path for the primary (`device_a`) database.
  final String dbPath;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'kmdb Example To-Do',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: UnlockScreen(dbPath: dbPath),
  );
}
