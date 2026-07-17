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

import 'package:kmdb_cli/src/config/credential_store.dart';

/// An in-memory [CredentialStore] for unit tests that exercise call sites
/// (`adapterFor`, `RemoteCommand`) without touching the real filesystem or
/// its permission-hardening logic.
///
/// [DirectoryCredentialStore] pointed at a temp directory is already exactly
/// as safe as any other filesystem test — this fake exists for tests that
/// want to assert on *call-site* behaviour (e.g. "write was called with the
/// right account/secret") without any filesystem I/O at all.
final class FakeCredentialStore implements CredentialStore {
  /// The in-memory backing map, keyed by account name.
  ///
  /// Exposed directly so tests can seed or assert on stored secrets without
  /// going through [write]/[read].
  final Map<String, String> secrets = {};

  /// Accounts passed to [write], in call order — lets tests assert on write
  /// history (e.g. that a refresh re-wrote the same account).
  final List<String> writeCalls = [];

  /// Accounts passed to [delete], in call order — lets tests assert that
  /// `remote remove` deleted the right credential.
  final List<String> deleteCalls = [];

  /// When set, [read] throws this instead of returning a value — used to
  /// simulate [CredentialPermissionException] without real loose-permission
  /// fixtures.
  Object? readError;

  @override
  Future<void> write(String account, String secretJson) async {
    writeCalls.add(account);
    secrets[account] = secretJson;
  }

  @override
  Future<String?> read(String account) async {
    if (readError != null) throw readError!;
    return secrets[account];
  }

  @override
  Future<void> delete(String account) async {
    deleteCalls.add(account);
    secrets.remove(account);
  }
}
