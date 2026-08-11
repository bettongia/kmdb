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

/// @docImport 'sync_auth_envelope.dart';
/// @docImport 'sync_authenticating_adapter.dart';
library;

/// Thrown when a sync-folder artefact fails sync authentication (0.10.01
/// WI-4 T1).
///
/// Raised in two situations:
///
/// - **Bad or missing MAC** — [SyncAuthEnvelope.unwrap] found no valid
///   `[magic][version][mac]` header, or the recomputed MAC did not match the
///   one carried in the envelope. The artefact was not produced by a holder
///   of this sync-set's key: it may be forged by an attacker with mere
///   write access to the sync folder, corrupted in transit, relocated from
///   another path, or — for a remote that predates sync authentication —
///   simply an old, un-enveloped file (R-5; see [message] for the
///   re-provisioning pointer in that case).
/// - **No key enrolled for this remote** (R-4) — the database has a remote
///   configured but this device has never run `remote pair` (or `remote
///   add`, which mints a key automatically) for it. `open()` itself never
///   throws this — a purely local-only database has no sync-auth key and
///   that is valid — but `push`/`pull`/`sync` do, immediately, before any
///   network I/O.
///
/// Callers that need to distinguish "propagate as a hard failure" from
/// "skip this one artefact and continue" apply that policy themselves at
/// the call site — see `docs/spec/32_sync_authentication.md`'s per-site
/// rejection-policy table. [SyncAuthException] itself carries no such
/// distinction; it is a uniform detection signal.
final class SyncAuthException implements Exception {
  /// Creates a [SyncAuthException].
  ///
  /// [path] is the sync-root-relative remote path of the offending artefact,
  /// when known (omitted for the no-key-enrolled case, which is not tied to
  /// any one file).
  SyncAuthException(this.message, {this.path});

  /// Human-readable description of the failure, including a pointer at the
  /// fix (`kmdb <db> remote pair`).
  final String message;

  /// The sync-root-relative remote path of the offending artefact, or `null`
  /// when this exception was not raised for a specific file (e.g. R-4's
  /// no-key-enrolled case).
  final String? path;

  @override
  String toString() => 'SyncAuthException: $message';
}
