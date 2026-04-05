// Copyright 2026 The KMDB Authors.
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

import 'package:kmdb/kmdb.dart';

/// A sealed hierarchy describing a named sync remote.
///
/// Each subclass corresponds to one adapter type. The [type] field is stored
/// in `config.json` and used to reconstruct the correct subclass on load.
///
/// ## Adding a new type
///
/// 1. Add a new `final class` extending [RemoteConfig].
/// 2. Handle the new `type` string in [RemoteConfig.fromJson].
/// 3. Add the new adapter construction to [adapterFor].
sealed class RemoteConfig {
  /// The type discriminator stored in `config.json`.
  ///
  /// Must be a stable lowercase identifier such as `'local'`.
  String get type;

  /// Serialises this remote config to a JSON-compatible map.
  Map<String, dynamic> toJson();

  /// Deserialises a [RemoteConfig] from [json].
  ///
  /// The `type` field in [json] determines which subclass is constructed.
  ///
  /// Throws [FormatException] if the `type` field is missing or unknown, or if
  /// a required field for the given type is absent.
  static RemoteConfig fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type == null) {
      throw const FormatException(
        "Remote config is missing required field 'type'.",
      );
    }
    if (type is! String) {
      throw FormatException(
        "Remote config field 'type' must be a string, got: $type",
      );
    }
    switch (type) {
      case 'local':
        return LocalRemoteConfig.fromJson(json);
      default:
        throw FormatException(
          "Unknown remote type '$type'. "
          "Supported types: local.",
        );
    }
  }
}

// ── Local remote ──────────────────────────────────────────────────────────────

/// A sync remote backed by a local directory (e.g. a NAS mount or Dropbox
/// folder).
///
/// Uses [LocalDirectoryAdapter] under the hood. The [path] must be an
/// absolute filesystem path on the current machine.
///
/// ## Example config entry
///
/// ```json
/// {
///   "type": "local",
///   "path": "/Volumes/NAS/myapp-sync"
/// }
/// ```
final class LocalRemoteConfig extends RemoteConfig {
  /// Creates a [LocalRemoteConfig] with the given [path].
  LocalRemoteConfig({required this.path});

  /// The absolute local filesystem path to the sync directory.
  final String path;

  @override
  String get type => 'local';

  @override
  Map<String, dynamic> toJson() => {'type': 'local', 'path': path};

  /// Deserialises a [LocalRemoteConfig] from [json].
  ///
  /// Throws [FormatException] if the `path` field is missing or not a string.
  static LocalRemoteConfig fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    if (path == null) {
      throw const FormatException(
        "Local remote config is missing required field 'path'.",
      );
    }
    if (path is! String) {
      throw FormatException(
        "Local remote config field 'path' must be a string, got: $path",
      );
    }
    return LocalRemoteConfig(path: path);
  }

  @override
  String toString() => 'LocalRemoteConfig(path: $path)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalRemoteConfig &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}

// ── Adapter factory ──────────────────────────────────────────────────────────

/// Constructs the [SyncStorageAdapter] appropriate for [remote].
///
/// This factory function encapsulates adapter-specific construction logic,
/// keeping it out of the command layer.
///
/// Throws [FormatException] if [remote] is of an unrecognised type.
/// (This should not normally occur since [RemoteConfig.fromJson] already
/// validates the type, but guards against future subclasses added without a
/// corresponding factory entry.)
SyncStorageAdapter adapterFor(RemoteConfig remote) {
  switch (remote) {
    case LocalRemoteConfig(:final path):
      return LocalDirectoryAdapter(path);
  }
}
