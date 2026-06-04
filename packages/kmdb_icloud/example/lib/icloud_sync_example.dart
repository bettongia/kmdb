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

/// Phase 4a empirical probe functions for [ICloudAdapter].
///
/// Import and call from a Flutter app after
/// `WidgetsFlutterBinding.ensureInitialized()`.  See `main.dart` for the
/// host app that drives these functions and displays their output.
///
/// ## Prerequisites (see §30 of the KMDB spec for full setup instructions)
///
/// 1. Open `macos/Runner.xcworkspace` in Xcode, add the iCloud + CloudKit
///    capability, and create/select a CloudKit container.
/// 2. In CloudKit Dashboard, create the `KMDBSyncFile` record type with a
///    queryable `path` (String) field and a `content` (Asset) field.
/// 3. Pass the matching `containerIdentifier` to the probe functions.
library;

import 'dart:typed_data';

import 'package:kmdb_icloud/kmdb_icloud.dart';

ICloudAdapter _makeAdapter(String containerIdentifier, String syncRoot) {
  final channel = PlatformICloudSyncChannel(
    containerIdentifier: containerIdentifier,
    syncRoot: syncRoot,
  );
  return ICloudAdapter(channel: channel, syncRoot: syncRoot);
}

// ── Probe 1: basic upload / list / download / delete ─────────────────────────

/// Basic smoke test: upload, list, download, getEtag, delete.
///
/// Records the read-your-writes consistency of [ICloudAdapter.list] — i.e.
/// whether a CKQuery immediately returns a record that was just uploaded on
/// the same device.
Future<void> runICloudSyncExample({
  String containerIdentifier = 'iCloud.com.bettongia.kmdb',
  String syncRoot = 'kmdb-example-sync',
  void Function(String)? onLog,
}) async {
  void log(String msg) => (onLog ?? print)(msg);

  final adapter = _makeAdapter(containerIdentifier, syncRoot);
  log('Adapter ready (providesAtomicCas: ${adapter.providesAtomicCas}).');

  final path = 'sstables/test-${DateTime.now().millisecondsSinceEpoch}.sst';
  final bytes = Uint8List.fromList(List.generate(16, (i) => i));

  log('Uploading $path …');
  await adapter.upload(path, bytes);

  final files = await adapter.list('sstables', extension: '.sst');
  log('Files in sstables/ immediately after upload: $files');

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

// ── Probe 2: CAS (compareAndSwap) atomicity ───────────────────────────────────

/// Probes [ICloudAdapter.compareAndSwap] semantics:
///
/// - Create-if-absent when absent → expect true.
/// - Create-if-absent when already present → expect false.
/// - Update-if-match with correct ETag → expect true.
/// - Update-if-match with stale ETag → expect false.
///
/// These are sequential (single-device) tests.  True concurrent atomicity
/// (two devices racing) requires running on two devices simultaneously.
Future<void> runCasProbe({
  String containerIdentifier = 'iCloud.com.bettongia.kmdb',
  String syncRoot = 'kmdb-example-sync',
  void Function(String)? onLog,
}) async {
  void log(String msg) => (onLog ?? print)(msg);

  final adapter = _makeAdapter(containerIdentifier, syncRoot);
  log('--- CAS probe ---');

  final path =
      'sstables/cas-probe-${DateTime.now().millisecondsSinceEpoch}.sst';
  final v1 = Uint8List.fromList([1, 2, 3]);
  final v2 = Uint8List.fromList([4, 5, 6]);
  final v3 = Uint8List.fromList([7, 8, 9]);

  // 1. Create-if-absent when record does not exist — should succeed.
  log('CAS create-if-absent (no record) …');
  final created = await adapter.compareAndSwap(path, v1);
  log('  result: $created (expected: true)');

  // 2. Create-if-absent when record already exists — should fail.
  log('CAS create-if-absent (record exists) …');
  final createdAgain = await adapter.compareAndSwap(path, v2);
  log('  result: $createdAgain (expected: false)');

  // 3. Update-if-match with correct ETag — should succeed.
  final etag = await adapter.getEtag(path);
  log('Current ETag: $etag');
  log('CAS update-if-match with correct ETag …');
  final updated = await adapter.compareAndSwap(path, v2, ifMatchEtag: etag);
  log('  result: $updated (expected: true)');

  // 4. Update-if-match with stale ETag — should fail.
  log('CAS update-if-match with stale ETag …');
  final stale = await adapter.compareAndSwap(
    path,
    v3,
    ifMatchEtag: etag, // etag is now stale after the successful update above
  );
  log('  result: $stale (expected: false)');

  // Cleanup.
  await adapter.delete(path);
  log('Cleaned up. Done.');
}

// ── Probe 3: large file upload / download ─────────────────────────────────────

/// Probes CKAsset upload/download at 1 MB, 10 MB, and 50 MB.
///
/// Records upload and download durations and verifies byte-for-byte integrity.
Future<void> runLargeFileProbe({
  String containerIdentifier = 'iCloud.com.bettongia.kmdb',
  String syncRoot = 'kmdb-example-sync',
  void Function(String)? onLog,
}) async {
  void log(String msg) => (onLog ?? print)(msg);

  final adapter = _makeAdapter(containerIdentifier, syncRoot);
  log('--- Large file probe ---');

  for (final sizeBytes in [1 << 20, 10 << 20, 50 << 20]) {
    final sizeLabel = '${sizeBytes >> 20} MB';
    final path =
        'sstables/large-$sizeBytes-${DateTime.now().millisecondsSinceEpoch}.sst';
    final bytes = Uint8List(sizeBytes)
      ..setAll(0, List.generate(sizeBytes, (i) => i & 0xff));

    log('Uploading $sizeLabel …');
    final uploadStart = DateTime.now();
    await adapter.upload(path, bytes);
    final uploadMs = DateTime.now().difference(uploadStart).inMilliseconds;
    log('  Uploaded in ${uploadMs}ms.');

    log('Downloading $sizeLabel …');
    final downloadStart = DateTime.now();
    final downloaded = await adapter.download(path);
    final downloadMs = DateTime.now().difference(downloadStart).inMilliseconds;

    if (downloaded == null) {
      log('  ERROR: download returned null.');
    } else if (downloaded.length != bytes.length) {
      log(
        '  ERROR: length mismatch: got ${downloaded.length}, want ${bytes.length}.',
      );
    } else {
      var mismatch = false;
      for (var i = 0; i < bytes.length; i++) {
        if (downloaded[i] != bytes[i]) {
          log('  ERROR: byte mismatch at offset $i.');
          mismatch = true;
          break;
        }
      }
      if (!mismatch) log('  Downloaded in ${downloadMs}ms. Integrity OK.');
    }

    await adapter.delete(path);
    log('  Deleted.');
  }

  log('Done.');
}

// ── Probe 4: query propagation delay ─────────────────────────────────────────

/// Probes how long it takes for a newly uploaded record to appear in a
/// [ICloudAdapter.list] query on the same device.
///
/// Polls up to [maxWaitSeconds] in [intervalSeconds] increments.
Future<void> runListPropagationProbe({
  String containerIdentifier = 'iCloud.com.bettongia.kmdb',
  String syncRoot = 'kmdb-example-sync',
  void Function(String)? onLog,
  int maxWaitSeconds = 30,
  int intervalSeconds = 2,
}) async {
  void log(String msg) => (onLog ?? print)(msg);

  final adapter = _makeAdapter(containerIdentifier, syncRoot);
  log('--- List propagation delay probe ---');

  final path = 'sstables/prop-${DateTime.now().millisecondsSinceEpoch}.sst';
  final bytes = Uint8List.fromList([42, 43, 44]);

  log('Uploading $path …');
  final uploadTime = DateTime.now();
  await adapter.upload(path, bytes);
  log('Uploaded. Polling list every ${intervalSeconds}s …');

  var found = false;
  for (var waited = 0; waited <= maxWaitSeconds; waited += intervalSeconds) {
    final files = await adapter.list('sstables', extension: '.sst');
    if (files.contains(path.split('/').last)) {
      final ms = DateTime.now().difference(uploadTime).inMilliseconds;
      log('  Record visible after ${ms}ms (${waited}s poll interval).');
      found = true;
      break;
    }
    log('  Not visible yet at ${waited}s.');
    if (waited < maxWaitSeconds) {
      await Future<void>.delayed(Duration(seconds: intervalSeconds));
    }
  }

  if (!found) log('  Record NOT visible after ${maxWaitSeconds}s.');

  await adapter.delete(path);
  log('Cleaned up. Done.');
}
