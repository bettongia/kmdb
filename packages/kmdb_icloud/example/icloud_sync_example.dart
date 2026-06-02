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

// ignore_for_file: avoid_print

/// Example: syncing a KMDB database via Apple iCloud (CloudKit).
///
/// This example shows the minimal steps to construct an [ICloudAdapter] and
/// run a KMDB sync cycle on an iOS or macOS Flutter application.
///
/// ## Prerequisites
///
/// 1. Enable the iCloud + CloudKit capability in your Xcode target.
/// 2. Create a CloudKit container in the Apple Developer portal
///    (e.g. `iCloud.au.com.bettongia.myapp`).
/// 3. In the CloudKit Dashboard, create the `KMDBSyncFile` record type with:
///    - `path`: `String` (queryable — required for `list()` BEGINSWITH queries)
///    - `content`: `Asset`
/// 4. Add the container identifier to your app's entitlements.
///
/// ## Running this example
///
/// This file is designed to run inside a Flutter iOS or macOS application.
/// Import and call [runICloudSyncExample] from your app's main widget after
/// setting up the Flutter plugin registry.
///
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   runApp(const MyApp());
/// }
/// ```
library;

import 'dart:typed_data';

import 'package:kmdb_icloud/kmdb_icloud.dart';

/// Demonstrates the [ICloudAdapter] low-level API.
///
/// In a real application you would open a [KmdbDatabase] and call
/// `await db.sync(syncAdapter: adapter)`.  This function exercises the
/// adapter directly so it can be used as a minimal integration test vehicle
/// for the Dart → MethodChannel → Swift → CloudKit stack.
///
/// [containerIdentifier] — the CloudKit container, e.g.
/// `'iCloud.au.com.bettongia.myapp'`.
Future<void> runICloudSyncExample({
  String containerIdentifier = 'iCloud.au.com.bettongia.kmdb',
  String syncRoot = 'kmdb-example-sync',
}) async {
  // ── Step 1: Construct the channel and adapter ─────────────────────────────

  // PlatformICloudSyncChannel wraps the MethodChannel to the native Swift
  // plugin.  Both containerIdentifier and syncRoot are sent to the Swift side
  // in the lazy `initialize` call on first use.
  final channel = PlatformICloudSyncChannel(
    containerIdentifier: containerIdentifier,
    syncRoot: syncRoot,
  );

  final adapter = ICloudAdapter(channel: channel, syncRoot: syncRoot);

  print(
    'iCloud adapter ready '
    '(providesAtomicCas: ${adapter.providesAtomicCas}).',
  );

  // ── Step 2: Use the adapter's low-level API ───────────────────────────────

  final path = 'sstables/test-${DateTime.now().millisecondsSinceEpoch}.sst';
  final bytes = Uint8List.fromList(List.generate(16, (i) => i));

  print('Uploading $path ...');
  await adapter.upload(path, bytes);

  final files = await adapter.list('sstables', extension: '.sst');
  print('Files in sstables/: $files');

  final downloaded = await adapter.download(path);
  print('Downloaded ${downloaded?.length} bytes.');

  final etag = await adapter.getEtag(path);
  print('ETag: $etag');

  await adapter.delete(path);
  print('Deleted $path.');

  final filesAfter = await adapter.list('sstables', extension: '.sst');
  print('Files after delete: $filesAfter');

  print('Done.');
}
