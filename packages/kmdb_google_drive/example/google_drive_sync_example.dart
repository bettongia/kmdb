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

/// Example: syncing a KMDB database via Google Drive.
///
/// This example shows the minimal steps to authenticate with Google Drive and
/// run a KMDB sync cycle on a native (desktop / server) platform.
///
/// ## Prerequisites
///
/// 1. Create a Google Cloud project and enable the Drive API.
/// 2. Create an OAuth 2.0 "Desktop" client and download the credentials JSON.
/// 3. Extract the `client_id` and `client_secret` from the file.
///
/// ## Supplying credentials
///
/// Set the environment variables before running:
///
/// ```bash
/// export KMDB_DRIVE_CLIENT_ID='YOUR_CLIENT_ID.apps.googleusercontent.com'
/// export KMDB_DRIVE_CLIENT_SECRET='YOUR_CLIENT_SECRET'
/// dart run example/google_drive_sync_example.dart
/// ```
///
/// On the first run the script opens a browser for OAuth consent and writes
/// the resulting credentials to `~/.config/myapp/drive_credentials.json`.
/// Subsequent runs load the cached credentials automatically.
library;

import 'dart:io';
import 'dart:typed_data';

// ClientId lives in googleapis_auth; it is not re-exported by this package
// because it is an auth-layer type — callers that need it should import
// googleapis_auth directly.
import 'package:googleapis_auth/googleapis_auth.dart' show ClientId;
import 'package:kmdb_google_drive/kmdb_google_drive.dart';

Future<void> main() async {
  // ── Step 1: Obtain an AuthClient ──────────────────────────────────────────

  // Read OAuth 2.0 Desktop client credentials from environment variables.
  // In production, read these from a config file or secret manager.
  final clientIdValue = Platform.environment['KMDB_DRIVE_CLIENT_ID'];
  final clientSecretValue = Platform.environment['KMDB_DRIVE_CLIENT_SECRET'];

  if (clientIdValue == null || clientIdValue.isEmpty) {
    stderr.writeln(
      'Error: KMDB_DRIVE_CLIENT_ID environment variable is not set.',
    );
    exit(1);
  }

  // Path where credentials are cached between runs.
  final credsCachePath = [
    Platform.environment['HOME'] ?? '.',
    '.config',
    'myapp',
    'drive_credentials.json',
  ].join(Platform.pathSeparator);

  final authClient = await GoogleDriveAuthHelper.fromUserConsent(
    ClientId(clientIdValue, clientSecretValue ?? ''),
    credentialsCachePath: credsCachePath,
  );

  // ── Step 2: Create the adapter ────────────────────────────────────────────

  final adapter = GoogleDriveAdapter(
    authClient,
    syncRoot: 'myapp-kmdb-sync', // Drive folder name
  );

  print(
    'Google Drive adapter ready '
    '(providesAtomicCas: ${adapter.providesAtomicCas}).',
  );

  // ── Step 3: Use the adapter with SyncEngine ───────────────────────────────

  // In a real application you would open a KmdbDatabase and call:
  //
  //   await db.sync(syncAdapter: adapter);
  //
  // For this example we demonstrate the adapter's low-level API.

  final path = 'sstables/test-${DateTime.now().millisecondsSinceEpoch}.sst';
  final bytes = Uint8List.fromList(List.generate(16, (i) => i));

  print('Uploading $path ...');
  await adapter.upload(path, bytes);

  final files = await adapter.list('sstables', extension: '.sst');
  print('Files in sstables/: $files');

  final downloaded = await adapter.download(path);
  print('Downloaded ${downloaded?.length} bytes.');

  await adapter.delete(path);
  print('Deleted $path.');

  authClient.close();
  print('Done.');
}
