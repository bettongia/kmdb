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

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../db/app_database.dart';
import '../../repositories/project_repository.dart';
import '../../repositories/sync_service.dart';
import '../../repositories/task_repository.dart';

/// Screen 6 of 6 — "Sync/Settings".
///
/// Demonstrates authenticated sync (spec §12, 0.10.01 WI-4) via
/// [SyncService]: a "Sync now" button against a shared local folder, and a
/// self-contained two-device demo that opens a **second** [KmdbDatabase]
/// instance (`device_b`) at a different local path — mirroring the guide's
/// `LocalDirectoryAdapter` two-instance sync mechanic — inside this same
/// running app, so the convergence is directly observable without needing a
/// second app launch.
class SyncSettingsScreen extends StatefulWidget {
  /// Creates the [SyncSettingsScreen] for the primary database [db].
  const SyncSettingsScreen({required this.db, super.key});

  /// The primary ("device A") database.
  final KmdbDatabase db;

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  late final SyncService _syncServiceA = SyncService(
    widget.db,
    _sharedSyncDirPath,
  );

  String? _deviceIdA;
  String? _log;
  bool _busy = false;

  KmdbDatabase? _deviceB;
  String? _deviceIdB;

  static String? _sharedSyncDirCache;
  static String? _deviceBPathCache;

  String get _sharedSyncDirPath => _sharedSyncDirCache!;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDeviceIdA());
  }

  @override
  void dispose() {
    // Best-effort: this is a demo secondary instance, not durable app state.
    unawaited(_deviceB?.close());
    super.dispose();
  }

  Future<void> _loadDeviceIdA() async {
    final info = await widget.db.store.storeInfo();
    if (mounted) setState(() => _deviceIdA = info.deviceId);
  }

  /// Resolves (and caches for the process lifetime) the demo paths used by
  /// the second-instance sync demo: a shared sync folder and the `device_b`
  /// database directory, both under the platform's application-support
  /// directory.
  static Future<void> _ensureDemoPathsResolved() async {
    if (_sharedSyncDirCache != null) return;
    final supportDir = await getApplicationSupportDirectory();
    _sharedSyncDirCache = p.join(
      supportDir.path,
      'kmdb_example_todo',
      'sync_demo',
    );
    _deviceBPathCache = p.join(
      supportDir.path,
      'kmdb_example_todo',
      'device_b',
    );
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _log = null;
    });
    try {
      await _ensureDemoPathsResolved();
      final result = await _syncServiceA.syncNow();
      setState(() {
        _log =
            'Device A synced. Quarantined: '
            '${result.pull.quarantined.length}, deferred: '
            '${result.pull.deferred.length}.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runTwoDeviceDemo() async {
    setState(() {
      _busy = true;
      _log = null;
    });
    try {
      await _ensureDemoPathsResolved();

      // Open (or reuse) the second local instance. It is unencrypted for
      // simplicity — the demo's point is the sync mechanic, not encryption.
      _deviceB ??= await AppDatabase.open(path: _deviceBPathCache!);
      final infoB = await _deviceB!.store.storeInfo();
      _deviceIdB = infoB.deviceId;

      final syncServiceB = SyncService(_deviceB!, _sharedSyncDirPath);

      // Push device A's data, then have device B pull it (and vice versa) —
      // the pattern from the guide's sync section.
      final resultA = await _syncServiceA.syncNow();
      final resultB = await syncServiceB.syncNow();
      // A second round so A also picks up anything only B had produced.
      await _syncServiceA.syncNow();

      final projectsB = await ProjectRepository(_deviceB!).listAll();
      final tasksOnB = <String>[];
      for (final project in projectsB) {
        final tasks = await TaskRepository(_deviceB!).listByProject(project.id);
        tasksOnB.addAll(tasks.map((t) => t.title));
      }

      setState(() {
        _log =
            'Device A (${_deviceIdA ?? '?'}) <-> Device B ($_deviceIdB): '
            'A quarantined ${resultA.pull.quarantined.length}, '
            'B quarantined ${resultB.pull.quarantined.length}. '
            "Device B now sees ${projectsB.length} project(s): "
            '${tasksOnB.length} task(s) — ${tasksOnB.join(', ')}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync & Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device A ID: ${_deviceIdA ?? 'loading…'}'),
            if (_deviceIdB != null) Text('Device B ID: $_deviceIdB'),
            const SizedBox(height: 16),
            // DEMO ONLY — never hard-code a sync root key in production. See
            // kDemoSyncRootKey's doc comment for the real enrolment story
            // (`remote pair` / an app-owned out-of-band key transfer).
            const Text(
              'DEMO ONLY: this screen uses a fixed, hard-coded sync root '
              'key shared by both demo instances. A real application must '
              'generate this key once, store it in a SecretStore, and '
              'transfer it to each additional device out of band — never '
              'hard-code it.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _runTwoDeviceDemo,
              icon: const Icon(Icons.devices),
              label: const Text('Demo: sync with a second local instance'),
            ),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            if (_log != null) Semantics(liveRegion: true, child: Text(_log!)),
          ],
        ),
      ),
    );
  }
}
