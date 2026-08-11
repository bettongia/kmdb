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

/// @docImport 'default_sync_authenticator.dart';
/// @docImport 'sync_auth_envelope.dart';
library;

import 'dart:typed_data';

import 'sync_artifact_class.dart';

/// Computes and verifies the sync-set MAC used to authenticate sync-folder
/// artefacts against an untrusted provider (0.10.01 WI-4 T1).
///
/// ## Not get-key shaped
///
/// This interface deliberately exposes only `mac`/`verify` over caller-
/// supplied bytes — never a method that returns the raw key material. A
/// get-key-shaped interface (`Uint8List key()`) would foreclose backends
/// where the key can never leave its secure boundary: a non-extractable
/// WebCrypto `CryptoKey` (see the web implementation), a StrongBox-backed
/// Android key, or a Secure Enclave key on iOS/macOS. All of those can
/// compute a MAC or verify one without ever exposing the underlying bytes to
/// Dart-visible memory; none of them can hand back a `Uint8List` key.
///
/// ## Six sub-keys, one per [SyncArtifactClass]
///
/// A single sync-set root key never signs directly. Every [mac]/[verify]
/// call names the [SyncArtifactClass] of the artefact being processed, and
/// implementations derive (or resolve) a distinct sub-key per class — see
/// [DefaultSyncAuthenticator] for the HKDF derivation. This keeps a MAC
/// valid for one artefact class from being replayable as another.
///
/// ## Message construction
///
/// [message] is not the raw artefact payload — callers (chiefly
/// [SyncAuthEnvelope]) construct it as `lenPrefixed(relativePath) ‖
/// payload`, binding the MAC to the artefact's own remote location so a
/// genuine artefact cannot be relocated to another path and re-accepted
/// there. [SyncAuthenticator] implementations do not need to know this
/// structure — they treat [message] as an opaque byte string.
abstract interface class SyncAuthenticator {
  /// Computes the 16-byte (128-bit) MAC of [message] under the sub-key for
  /// [artifactClass].
  Future<Uint8List> mac(SyncArtifactClass artifactClass, Uint8List message);

  /// Returns `true` if [mac] is the correct MAC of [message] under the
  /// sub-key for [artifactClass].
  ///
  /// Implementations must compare in constant time with respect to the
  /// *content* of [mac] (timing must not depend on which byte, if any,
  /// first differs) — see [DefaultSyncAuthenticator]'s implementation.
  Future<bool> verify(
    SyncArtifactClass artifactClass,
    Uint8List message,
    Uint8List mac,
  );
}
