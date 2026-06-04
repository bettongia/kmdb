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

/// Example: exercising the [ICloudAdapter] low-level API on iOS/macOS.
///
/// Import and call [runICloudSyncExample] from a Flutter app after
/// `WidgetsFlutterBinding.ensureInitialized()`.  See `main.dart` for the
/// minimal host app that drives this function and displays its output.
///
/// ## Prerequisites (see §30 of the KMDB spec for full setup instructions)
///
/// 1. Open `macos/Runner.xcworkspace` in Xcode, add the iCloud + CloudKit
///    capability, and create/select a CloudKit container.
/// 2. In CloudKit Dashboard, create the `KMDBSyncFile` record type with a
///    queryable `path` (String) field and a `content` (Asset) field.
/// 3. Pass the matching `containerIdentifier` to [runICloudSyncExample].
library;

import 'dart:typed_data';

import 'package:kmdb_icloud/kmdb_icloud.dart';

/// Exercises the [ICloudAdapter] low-level API against a real CloudKit
/// container.
///
/// This function is the primary integration test vehicle for the
/// Dart → MethodChannel → Swift → CloudKit stack.  In a production app you
/// would open a [KmdbDatabase] and call `db.sync(syncAdapter: adapter)`
/// instead.
///
/// [containerIdentifier] — the CloudKit container identifier configured in
/// Xcode (e.g. `'iCloud.au.com.bettongia.kmdb.probe'`).
///
/// [onLog] — optional callback for log lines.  Defaults to [print] so the
/// function can also be run from the command line.
Future<void> runICloudSyncExample({
  String containerIdentifier = 'iCloud.au.com.bettongia.kmdb',
  String syncRoot = 'kmdb-example-sync',
  void Function(String)? onLog,
}) async {
  void log(String msg) => (onLog ?? print)(msg);

  // PlatformICloudSyncChannel wraps the MethodChannel to the native Swift
  // plugin.  Both containerIdentifier and syncRoot are sent to the Swift side
  // in the lazy `initialize` call on first use.
  final channel = PlatformICloudSyncChannel(
    containerIdentifier: containerIdentifier,
    syncRoot: syncRoot,
  );
  final adapter = ICloudAdapter(channel: channel, syncRoot: syncRoot);

  log('Adapter ready (providesAtomicCas: ${adapter.providesAtomicCas}).');

  final path = 'sstables/test-${DateTime.now().millisecondsSinceEpoch}.sst';
  final bytes = Uint8List.fromList(List.generate(16, (i) => i));

  log('Uploading $path …');
  await adapter.upload(path, bytes);

  final files = await adapter.list('sstables', extension: '.sst');
  log('Files in sstables/: $files');

  final downloaded = await adapter.download(path);
  log('Downloaded ${downloaded?.length} bytes.');

  final etag = await adapter.getEtag(path);
  log('ETag: $etag');

  await adapter.delete(path);
  log('Deleted $path.');

  final filesAfter = await adapter.list('sstables', extension: '.sst');
  log('Files after delete: $filesAfter');

  log('Done.');
}
