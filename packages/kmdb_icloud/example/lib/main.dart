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

/// Phase 4a probe runner.
///
/// Each button runs one probe function from [icloud_sync_example.dart] and
/// streams its log output into the scrollable pane.
///
/// Edit [_containerIdentifier] to match the CloudKit container configured in
/// `macos/Runner.xcworkspace` → Signing & Capabilities → iCloud → Containers.
class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  static const _containerIdentifier = 'iCloud.com.bettongia.kmdb.probe';
  static const _syncRoot = 'kmdb-example-sync';

  final List<String> _log = [];
  bool _running = false;

  Future<void> _runProbe(
    Future<void> Function({
      String containerIdentifier,
      String syncRoot,
      void Function(String)? onLog,
    })
    probe,
  ) async {
    setState(() {
      _running = true;
      _log.clear();
    });
    try {
      await probe(
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _running
                      ? null
                      : () => _runProbe(runICloudSyncExample),
                  child: const Text('Basic sync'),
                ),
                FilledButton(
                  onPressed: _running ? null : () => _runProbe(runCasProbe),
                  child: const Text('CAS probe'),
                ),
                FilledButton(
                  onPressed: _running
                      ? null
                      : () => _runProbe(runLargeFileProbe),
                  child: const Text('Large files'),
                ),
                FilledButton(
                  onPressed: _running
                      ? null
                      : () => _runProbe(runListPropagationProbe),
                  child: const Text('List propagation delay'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
