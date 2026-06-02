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
/// ## Running
///
/// ```
/// dart run example/google_drive_sync_example.dart
/// ```
///
/// On the first run the script opens a browser for OAuth consent and writes
/// the resulting credentials to `~/.config/myapp/drive_credentials.json`.
/// Subsequent runs load the cached credentials automatically.
library;

import 'dart:io';

import 'package:kmdb_google_drive/kmdb_google_drive.dart';

Future<void> main() async {
  // ── Step 1: Obtain an AuthClient ──────────────────────────────────────────

  // Replace these with your OAuth 2.0 Desktop client credentials.
  const clientId = 'YOUR_CLIENT_ID.apps.googleusercontent.com';
  const clientSecret = 'YOUR_CLIENT_SECRET';

  // Path where credentials are cached between runs.
  final credsCachePath = [
    Platform.environment['HOME'] ?? '.',
    '.config',
    'myapp',
    'drive_credentials.json',
  ].join(Platform.pathSeparator);

  final authClient = await GoogleDriveAuthHelper.fromUserConsent(
    // ClientId is re-exported from googleapis_auth via this package.
    // ignore: avoid_dynamic_calls
    (await _resolveClientId(clientId, clientSecret)),
    credentialsCachePath: credsCachePath,
  );

  // ── Step 2: Create the adapter ────────────────────────────────────────────

  final adapter = GoogleDriveAdapter(
    authClient,
    syncRoot: 'myapp-kmdb-sync', // Drive folder name
  );

  print('Google Drive adapter ready (providesAtomicCas: ${adapter.providesAtomicCas}).');

  // ── Step 3: Use the adapter with SyncEngine ───────────────────────────────

  // In a real application you would open a KmdbDatabase and call:
  //
  //   await db.sync(syncAdapter: adapter);
  //
  // For this example we just demonstrate the adapter's low-level API.

  final path = 'sstables/test-${DateTime.now().millisecondsSinceEpoch}.sst';
  final bytes = List.generate(16, (i) => i).toList();

  print('Uploading $path ...');
  await adapter.upload(path, bytes as dynamic);

  final files = await adapter.list('sstables', extension: '.sst');
  print('Files in sstables/: $files');

  final downloaded = await adapter.download(path);
  print('Downloaded ${downloaded?.length} bytes.');

  await adapter.delete(path);
  print('Deleted $path.');

  authClient.close();
  print('Done.');
}

/// Placeholder helper — in a real app this would read from config or args.
Future<dynamic> _resolveClientId(String id, String secret) async {
  // This import is illustrative; replace with your actual ClientId construction.
  // import 'package:googleapis_auth/googleapis_auth.dart' show ClientId;
  // return ClientId(id, secret);
  throw UnsupportedError(
    'Replace this with: return ClientId(clientId, clientSecret);',
  );
}
