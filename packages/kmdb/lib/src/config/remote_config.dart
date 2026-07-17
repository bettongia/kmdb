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

/// A sealed hierarchy describing a named sync remote.
///
/// Each subclass corresponds to one adapter type.  The [type] field is
/// stored in `config.json` and used to reconstruct the correct subclass on
/// load.
///
/// ## Adding a new remote type
///
/// 1. Add a new `final class` extending [RemoteConfig].
/// 2. Handle the new `type` string in [RemoteConfig.fromJson].
/// 3. Update the error message in the `default` branch of [RemoteConfig.fromJson]
///    to list the new type.
/// 4. In `kmdb_cli`, add the corresponding adapter construction to
///    `adapterFor` in `remote_config.dart`.
///
/// ## Note on package dependencies
///
/// [RemoteConfig] subtypes are **config-only** — they carry the data needed to
/// describe a remote but do NOT construct the adapter.  Adapter construction
/// lives in `kmdb_cli` (the only package that depends on both `kmdb` and the
/// provider packages such as `kmdb_google_drive`).  This keeps heavy OAuth
/// and provider dependencies out of core `kmdb`.
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
  /// Throws [FormatException] if the `type` field is missing or unknown, or
  /// if a required field for the given type is absent.
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
      case 'google-drive':
        return GoogleDriveRemoteConfig.fromJson(json);
      default:
        throw FormatException(
          "Unknown remote type '$type'.  Supported types: local, google-drive.",
        );
    }
  }
}

// ── Local remote ──────────────────────────────────────────────────────────────

/// A sync remote backed by a local directory (e.g. a NAS mount or a Dropbox
/// folder).
///
/// The [path] must be an absolute filesystem path on the current machine.
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
  /// Creates a [LocalRemoteConfig] with the given absolute [path].
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

// ── Google Drive remote ───────────────────────────────────────────────────────

/// A sync remote backed by Google Drive.
///
/// The adapter constructs a Drive folder hierarchy under [syncRoot] in the
/// user's My Drive.  Auth credentials are loaded from [credentialsPath]
/// (relative to `{dbDir}/local/`).  The CLI's `adapterFor` function loads and
/// refreshes the credentials and constructs the adapter.
///
/// **Note:** This class is **config-only** — it carries the data needed to
/// describe the remote but does NOT construct the adapter.  Construction
/// happens in `kmdb_cli`'s `adapterFor`, which is the only layer that depends
/// on both `kmdb` and `kmdb_google_drive`.
///
/// ## Example config entry
///
/// ```json
/// {
///   "type": "google-drive",
///   "syncRoot": "kmdb-sync",
///   "credentialsPath": "google_credentials.json"
/// }
/// ```
final class GoogleDriveRemoteConfig extends RemoteConfig {
  /// Creates a [GoogleDriveRemoteConfig].
  ///
  /// [syncRoot] — the name of the top-level Drive folder used for sync.
  /// [credentialsPath] — the credential filename within the
  /// permission-hardened `{dbDir}/local/` directory (see the `kmdb_cli`
  /// `CredentialStore`/`DirectoryCredentialStore` design).  Defaults to
  /// `google_credentials.json`.
  GoogleDriveRemoteConfig({
    required this.syncRoot,
    this.credentialsPath = 'google_credentials.json',
  });

  /// The name of the Drive folder that acts as the sync root.
  ///
  /// The folder is created lazily on first sync if it does not exist.
  final String syncRoot;

  /// The credential filename within the permission-hardened `local/`
  /// directory (`{dbDir}/local/{credentialsPath}`), relative to `local/`.
  ///
  /// The file is created by `kmdb remote add --type google-drive` after a
  /// successful OAuth consent flow, via `kmdb_cli`'s `CredentialStore`
  /// (`DirectoryCredentialStore` on all platforms today — see
  /// `docs/spec/` for the CLI credential store design and `docs/roadmap/
  /// 9_99.md` for the deferred OS-native-keychain alternative). It is
  /// never synced to the cloud. This field is what lets two `google-drive`
  /// remotes on the same database (each with an explicit `--credentials`)
  /// address distinct files within the same `local/` directory.
  final String credentialsPath;

  @override
  String get type => 'google-drive';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'google-drive',
    'syncRoot': syncRoot,
    'credentialsPath': credentialsPath,
  };

  /// Deserialises a [GoogleDriveRemoteConfig] from [json].
  ///
  /// Throws [FormatException] if required fields are missing or invalid.
  static GoogleDriveRemoteConfig fromJson(Map<String, dynamic> json) {
    final syncRoot = json['syncRoot'];
    if (syncRoot == null) {
      throw const FormatException(
        "Google Drive remote config is missing required field 'syncRoot'.",
      );
    }
    if (syncRoot is! String) {
      throw FormatException(
        "Google Drive remote config field 'syncRoot' must be a string, "
        'got: $syncRoot',
      );
    }

    final credentialsPath = json['credentialsPath'];
    if (credentialsPath != null && credentialsPath is! String) {
      throw FormatException(
        "Google Drive remote config field 'credentialsPath' must be a string, "
        'got: $credentialsPath',
      );
    }

    return GoogleDriveRemoteConfig(
      syncRoot: syncRoot,
      credentialsPath:
          (credentialsPath as String?) ?? 'google_credentials.json',
    );
  }

  @override
  String toString() =>
      'GoogleDriveRemoteConfig(syncRoot: $syncRoot, '
      'credentialsPath: $credentialsPath)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GoogleDriveRemoteConfig &&
          runtimeType == other.runtimeType &&
          syncRoot == other.syncRoot &&
          credentialsPath == other.credentialsPath;

  @override
  int get hashCode => Object.hash(syncRoot, credentialsPath);
}
