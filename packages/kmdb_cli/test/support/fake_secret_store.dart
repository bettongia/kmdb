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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart' show SecretStore;

/// @docImport 'package:kmdb/kmdb.dart';
/// @docImport 'package:kmdb_cli/src/commands/credentials_command.dart';
/// @docImport 'package:kmdb_cli/src/commands/remote_command.dart';
/// @docImport 'package:kmdb_cli/src/config/remote_config.dart';
/// @docImport 'package:kmdb_cli/src/config/secret_store/directory_secret_store.dart';

/// An in-memory [SecretStore] for unit tests that exercise call sites
/// (`adapterFor`, `RemoteCommand`, `CredentialsCommand`) without touching the
/// real filesystem or its permission-hardening logic.
///
/// [DirectorySecretStore] pointed at a temp directory is already exactly as
/// safe as any other filesystem test — this fake exists for tests that want
/// to assert on *call-site* behaviour (e.g. "write was called with the right
/// key/value") without any filesystem I/O at all.
final class FakeSecretStore implements SecretStore {
  /// The in-memory backing map, keyed by secret key.
  ///
  /// Exposed directly so tests can seed or assert on stored secrets without
  /// going through [write]/[read].
  final Map<String, Uint8List> secrets = {};

  /// Keys passed to [write], in call order — lets tests assert on write
  /// history (e.g. that a refresh re-wrote the same key).
  final List<String> writeCalls = [];

  /// Keys passed to [delete], in call order — lets tests assert that
  /// `remote remove` deleted the right secret.
  final List<String> deleteCalls = [];

  /// When set, [read] throws this instead of returning a value — used to
  /// simulate [SecretPermissionException] without real loose-permission
  /// fixtures.
  Object? readError;

  @override
  Future<void> write(String key, Uint8List value) async {
    writeCalls.add(key);
    secrets[key] = value;
  }

  @override
  Future<Uint8List?> read(String key) async {
    if (readError != null) throw readError!;
    return secrets[key];
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls.add(key);
    secrets.remove(key);
  }

  @override
  Future<List<String>> list() async => secrets.keys.toList();
}
