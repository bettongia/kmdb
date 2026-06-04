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

import 'package:flutter/services.dart';

import 'icloud_sync_channel_interface.dart';

export 'icloud_sync_channel_interface.dart';

/// The name of the Flutter MethodChannel used to communicate with the native
/// CloudKit plugin.
const kICloudMethodChannel = 'kmdb_icloud/sync';

/// Production implementation of [ICloudSyncChannel] backed by a Flutter
/// [MethodChannel] to the native Swift `ICloudSyncPlugin`.
///
/// All six operations are routed through the `kmdb_icloud/sync` channel as
/// method invocations. Arguments are serialised via the standard Flutter
/// [StandardMessageCodec] (path strings as `String`, bytes as `Uint8List`,
/// ETags as `String?`, file lists as `List<String>`).
///
/// ## Initialisation
///
/// The channel sends an `initialize` call on first use, passing the
/// [containerIdentifier] and [syncRoot] to the Swift side so that
/// `CKContainer(identifier:)`, the private database, and the custom zone
/// `CKRecordZone(zoneName: "kmdb-\(syncRoot)")` can be bootstrapped lazily.
///
/// ## Thread safety
///
/// Not thread-safe; must be called from a single Flutter isolate (the main
/// isolate in a Flutter app).
final class PlatformICloudSyncChannel implements ICloudSyncChannel {
  /// Creates a [PlatformICloudSyncChannel].
  ///
  /// [containerIdentifier] — the CloudKit container identifier for the app,
  /// e.g. `'iCloud.au.com.bettongia.kmdb'`.  This is passed to the Swift
  /// plugin's `CKContainer(identifier:)` call.  It must match the container
  /// configured in the app's entitlements.
  ///
  /// [syncRoot] — the sync root name used to derive the CloudKit custom zone
  /// name (`"kmdb-<syncRoot>"`).  Must match the [ICloudAdapter.syncRoot]
  /// value for consistency.
  ///
  /// [channelName] — the MethodChannel name to use.  Defaults to
  /// [kICloudMethodChannel].  Override in tests to isolate multiple channel
  /// instances.
  PlatformICloudSyncChannel({
    required String containerIdentifier,
    required String syncRoot,
    String channelName = kICloudMethodChannel,
  }) : _containerIdentifier = containerIdentifier,
       _syncRoot = syncRoot,
       _channel = MethodChannel(channelName);

  final String _containerIdentifier;
  final String _syncRoot;
  final MethodChannel _channel;

  // Whether the Swift plugin has been initialised for this container.
  bool _initialised = false;

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Ensures the Swift plugin is initialised with [_containerIdentifier] and
  /// [_syncRoot].
  ///
  /// Called lazily before the first channel operation so that construction of
  /// [PlatformICloudSyncChannel] is synchronous. The Swift plugin uses the
  /// [_syncRoot] to derive the custom zone name (`"kmdb-<syncRoot>"`).
  Future<void> _ensureInitialised() async {
    if (_initialised) return;
    await _channel.invokeMethod<void>('initialize', {
      'containerIdentifier': _containerIdentifier,
      'syncRoot': _syncRoot,
    });
    _initialised = true;
  }

  // ── ICloudSyncChannel ──────────────────────────────────────────────────────

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) async {
    await _ensureInitialised();
    final result = await _channel.invokeMethod<List<Object?>>('list', {
      'remoteDir': remoteDir,
      'extension': ?extension,
    });
    return (result ?? []).cast<String>();
  }

  @override
  Future<Uint8List?> download(String remotePath) async {
    await _ensureInitialised();
    final bytes = await _channel.invokeMethod<Uint8List>('download', {
      'remotePath': remotePath,
    });
    return bytes;
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    await _ensureInitialised();
    await _channel.invokeMethod<void>('upload', {
      'remotePath': remotePath,
      'bytes': bytes,
    });
  }

  @override
  Future<void> delete(String remotePath) async {
    await _ensureInitialised();
    await _channel.invokeMethod<void>('delete', {'remotePath': remotePath});
  }

  @override
  Future<bool> compareAndSwap(
    String remotePath,
    Uint8List bytes, {
    String? ifMatchEtag,
  }) async {
    await _ensureInitialised();
    final result = await _channel.invokeMethod<bool>('compareAndSwap', {
      'remotePath': remotePath,
      'bytes': bytes,
      'ifMatchEtag': ?ifMatchEtag,
    });
    return result ?? false;
  }

  @override
  Future<String?> getEtag(String remotePath) async {
    await _ensureInitialised();
    return _channel.invokeMethod<String>('getEtag', {'remotePath': remotePath});
  }
}
