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

/// Per-database configuration management for KMDB.
///
/// This library provides [KmdbConfig], which reads and writes the
/// `local/config.json` file stored inside each database directory.  The
/// config file holds local-only, non-synced settings: named sync remotes,
/// secondary index definitions, FTS index definitions, and an optional
/// embedding model path.
///
/// ## Quick start (native platforms)
///
/// ```dart
/// import 'package:kmdb/kmdb_config.dart';
///
/// // Load (or create) config for a database directory:
/// final config = await KmdbConfig.forDatabase('/path/to/db');
///
/// // Add a named sync remote:
/// config.addRemote('origin', LocalRemoteConfig(path: '/mnt/nas/sync'));
///
/// // Add a secondary index:
/// config.addIndex('contacts', 'address.city');
///
/// // Persist:
/// await config.save();
/// ```
///
/// ## Web platforms
///
/// [IoKmdbConfigStore] uses `dart:io` and is **not supported on web**.
/// Web callers must implement [KmdbConfigStore] themselves (e.g. backed by
/// IndexedDB or localStorage) and pass it to [KmdbConfig.load] directly.
library;

export 'src/config/io_kmdb_config_store.dart' show IoKmdbConfigStore;
export 'src/config/kmdb_config.dart'
    show EmbeddingModelConfig, FtsIndexRecord, IndexRecord, KmdbConfig;
export 'src/config/kmdb_config_store.dart' show KmdbConfigStore;
export 'src/config/remote_config.dart' show LocalRemoteConfig, RemoteConfig;
