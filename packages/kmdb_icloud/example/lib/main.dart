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

import 'package:flutter/material.dart';

import 'icloud_sync_example.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KmdbICloudExampleApp());
}

class KmdbICloudExampleApp extends StatelessWidget {
  const KmdbICloudExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KMDB iCloud Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const _ProbePage(),
    );
  }
}

/// A minimal page that runs [runICloudSyncExample] and displays its log output.
///
/// Edit [_containerIdentifier] to match the CloudKit container configured in
/// `macos/Runner.xcworkspace` → Signing & Capabilities → iCloud → Containers.
class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  // Replace with the container identifier from your Xcode entitlements.
  static const _containerIdentifier = 'iCloud.au.com.bettongia.kmdb.probe';
  static const _syncRoot = 'kmdb-example-sync';

  final List<String> _log = [];
  bool _running = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _log.clear();
    });
    try {
      await runICloudSyncExample(
        containerIdentifier: _containerIdentifier,
        syncRoot: _syncRoot,
        onLog: (msg) => setState(() => _log.add(msg)),
      );
    } catch (e, st) {
      setState(() {
        _log.add('ERROR: $e');
        _log.add(st.toString());
      });
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KMDB iCloud Adapter Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Container: $_containerIdentifier\nSync root: $_syncRoot',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? 'Running…' : 'Run Sync Example'),
            ),
          ),
        ],
      ),
    );
  }
}
