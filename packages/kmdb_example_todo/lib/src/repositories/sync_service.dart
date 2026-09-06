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

import 'package:kmdb/kmdb.dart';

/// **DEMO ONLY — never hard-code a sync root key in production.**
///
/// [SyncService] uses `LocalDirectoryAdapter` so the guide's two-instance
/// sync demo works without any real cloud credentials — two `KmdbDatabase`
/// instances point at different local directories and sync through one
/// shared folder. Since 0.10.01 (WI-4), sync artefacts are authenticated:
/// every device in a sync set must wrap its adapter in the same
/// `SyncAuthenticatingAdapter` built from the same 256-bit root key, or the
/// peer **quarantines** the artefact instead of applying it
/// (`SyncAuthException`, `PullResult.quarantined`, the `$$quarantine` log —
/// see the Integration Guide's "Handle faults" section).
///
/// A real application must **never** hard-code this key. Instead:
///
/// - At the **CLI level**, `kmdb remote add` mints a key automatically for
///   the first device; a second device joins via `kmdb remote pair show`
///   on the enrolled device (prints a pairing code) followed by
///   `kmdb remote pair import` on the new device.
/// - At the **app level**, the equivalent is: generate a 32-byte root key
///   once (e.g. `Uint8List` from a cryptographically secure random source),
///   store it in a `SecretStore`, and transfer it to each additional device
///   out of band (QR code, paired-device handshake, etc.) — the application
///   owns this key-sharing UX. This fixed constant stands in for that flow
///   purely so the two co-located demo instances in this sample app have
///   *something* to share without building a real enrolment UI, which would
///   be artificial anyway for two processes on the same machine.
final Uint8List kDemoSyncRootKey = Uint8List.fromList(
  List<int>.generate(
    32,
    (i) => i,
  ), // 0x00, 0x01, ..., 0x1f — a fixed, non-secret demo value.
);

/// Wraps `KmdbDatabase.sync`/`pull` against a shared local directory (see
/// [kDemoSyncRootKey] for why this is a **demo-only** mechanism, not a
/// template for production sync).
class SyncService {
  /// Creates a [SyncService] that syncs [db] through [sharedSyncDir], using
  /// [rootKey] to authenticate artefacts (defaults to [kDemoSyncRootKey]).
  SyncService(this._db, this._sharedSyncDir, {Uint8List? rootKey})
    : _rootKey = rootKey ?? kDemoSyncRootKey;

  final KmdbDatabase _db;
  final String _sharedSyncDir;
  final Uint8List _rootKey;

  /// Pushes local SSTables and pulls peer SSTables through the shared
  /// directory in one call.
  ///
  /// Returns the [SyncResult] — inspect `result.pull.quarantined` and
  /// `result.pull.deferred` to detect artefacts this call rejected or
  /// skipped. A mismatched [rootKey] between devices manifests here as a
  /// non-empty `quarantined` list (and a `SyncAuthException` for any file
  /// this device itself tried to push that a differently-keyed peer would
  /// reject), never as a thrown error from this method itself.
  Future<SyncResult> syncNow() => _db.sync(syncAdapter: _buildAdapter());

  /// Returns every quarantined SSTable ever logged on this device — the
  /// durable counterpart to a single [syncNow] call's `PullResult`, useful
  /// for surfacing a "some data could not be synced" banner after a missed
  /// result (e.g. the app was killed mid-sync).
  Future<List<QuarantinedSstable>> quarantinedSstables() =>
      _db.quarantinedSstables();

  /// Clears the durable quarantine log after the user has seen and
  /// acknowledged it. Does not un-quarantine the underlying files — see
  /// `KmdbDatabase.clearQuarantineLog`'s doc comment.
  Future<void> clearQuarantineLog() => _db.clearQuarantineLog();

  SyncAuthenticatingAdapter _buildAdapter() => SyncAuthenticatingAdapter(
    LocalDirectoryAdapter(_sharedSyncDir),
    DefaultSyncAuthenticator(_rootKey),
  );
}
