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

/// Google Drive sync adapter for KMDB.
///
/// Provides [GoogleDriveAdapter] — a `SyncStorageAdapter` implementation
/// backed by the Google Drive REST API (Drive v3).  Callers are responsible
/// for constructing an authenticated [AuthClient] (from `googleapis_auth`)
/// and passing it to the adapter constructor.
///
/// ## Quick start
///
/// ```dart
/// import 'package:googleapis_auth/googleapis_auth.dart';
/// import 'package:kmdb_google_drive/kmdb_google_drive.dart';
///
/// // Obtain an AuthClient via your preferred flow (CLI redirect, google_sign_in…)
/// final AuthClient authClient = await GoogleDriveAuthHelper.fromUserConsent(
///   ClientId('YOUR_CLIENT_ID', 'YOUR_CLIENT_SECRET'),
///   credentialsCachePath: '/home/user/.config/myapp/drive_credentials.json',
/// );
///
/// final adapter = GoogleDriveAdapter(
///   authClient,
///   syncRoot: 'myapp-kmdb-sync',
/// );
/// ```
library;

export 'src/google_drive_adapter.dart' show GoogleDriveAdapter;
export 'src/google_drive_auth_helper.dart'
    show GoogleDriveAuthHelper, kDriveFileScope;
export 'src/google_drive_profile.dart' show kGoogleDriveProfile;
export 'src/retry.dart' show DriveOperationCancelledException, RetryConfig;
