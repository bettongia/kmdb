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
/// ## Preliminary `kICloudProfile` values
///
/// The [kICloudProfile] constant shipped with this package has **placeholder**
/// values for `maxPropagationDelayMs`, `jitterMs`, `maxOpsPerMinute`, and
/// `atomicConditionalCreate`.  These are finalised by the Phase 4a empirical
/// probe against the real CloudKit service (see
/// `docs/plans/plan_icloud_sync.md`).
library;

export 'src/icloud_adapter.dart' show ICloudAdapter, ICloudRetryConfig;
export 'src/icloud_profile.dart' show kICloudProfile;
export 'src/icloud_sync_channel.dart'
    show
        ICloudSyncChannel,
        ICloudRateLimitException,
        PlatformICloudSyncChannel,
        kICloudMethodChannel;
