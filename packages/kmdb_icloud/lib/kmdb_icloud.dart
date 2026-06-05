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

/// Apple iCloud (CloudKit) sync adapter for KMDB.
///
/// Provides [ICloudAdapter] — a [SyncStorageAdapter] implementation backed by
/// the CloudKit framework via a Flutter MethodChannel plugin.  Callers are
/// responsible for constructing a [PlatformICloudSyncChannel] (passing the
/// app's CloudKit container identifier and sync root name) and passing it to
/// the adapter constructor.
///
/// **Platform:** iOS and macOS only.  CloudKit requires an active iCloud
/// account on the device.  Android, web, Windows, and Linux callers should use
/// `package:kmdb_google_drive` instead.
///
/// ## Quick start
///
/// ```dart
/// import 'package:kmdb/kmdb.dart';
/// import 'package:kmdb_icloud/kmdb_icloud.dart';
///
/// final channel = PlatformICloudSyncChannel(
///   containerIdentifier: 'iCloud.au.com.bettongia.kmdb',
///   syncRoot: 'myapp-kmdb-sync',
/// );
/// final adapter = ICloudAdapter(
///   channel: channel,
///   syncRoot: 'myapp-kmdb-sync',
/// );
///
/// await db.sync(syncAdapter: adapter);
/// ```
///
/// ## Test usage
///
/// In tests, import the non-Flutter parts of this library using the Dart-only
/// library path to avoid pulling in `dart:ui`:
///
/// ```dart
/// import 'package:kmdb_icloud/src/icloud_adapter.dart';
/// import 'package:kmdb_icloud/src/icloud_sync_channel_interface.dart';
/// import 'package:kmdb_icloud/src/icloud_profile.dart';
/// ```
///
/// Or use the `FakeICloudSyncChannel` from the test support file:
///
/// ```dart
/// import 'package:kmdb_icloud/test/support/fake_icloud_sync_channel.dart';
/// ```
library;

export 'src/icloud_adapter.dart' show ICloudAdapter, ICloudRetryConfig;
export 'src/icloud_profile.dart' show kICloudProfile;
// ICloudSyncChannel interface and ICloudRateLimitException (no Flutter dep).
export 'src/icloud_sync_channel_interface.dart'
    show ICloudSyncChannel, ICloudRateLimitException;
// PlatformICloudSyncChannel and kICloudMethodChannel require Flutter.
export 'src/icloud_sync_channel.dart'
    show PlatformICloudSyncChannel, kICloudMethodChannel;
