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
import 'package:kmdb/kmdb_config.dart';

// Re-export the config types so existing CLI imports of this file continue to
// resolve without change.  New code should import from
// `package:kmdb/kmdb_config.dart` directly.
export 'package:kmdb/kmdb_config.dart' show LocalRemoteConfig, RemoteConfig;

// ── Adapter factory ──────────────────────────────────────────────────────────

/// Constructs the [SyncStorageAdapter] appropriate for [remote].
///
/// This CLI-only factory bridges a [RemoteConfig] subtype (now defined in
/// `package:kmdb/kmdb_config.dart`) to its concrete [SyncStorageAdapter]
/// constructor.  Non-CLI consumers construct adapters directly.
///
/// Throws [UnsupportedError] if [remote] is of an unrecognised type.
/// (This should not normally occur since [RemoteConfig.fromJson] already
/// validates the type, but guards against future subclasses added without a
/// corresponding factory entry.)
SyncStorageAdapter adapterFor(RemoteConfig remote) {
  switch (remote) {
    case LocalRemoteConfig(:final path):
      return LocalDirectoryAdapter(path);
  }
}
