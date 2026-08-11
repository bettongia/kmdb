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

/// @docImport 'sync_authenticating_adapter.dart';
/// @docImport '../../vault/local_directory_vault_adapter.dart';
library;

import 'dart:convert';
import 'dart:typed_data';

import 'sync_artifact_class.dart';
import 'sync_auth_exception.dart';
import 'sync_authenticator.dart';

/// Wraps and unwraps the sync-authentication transport envelope (0.10.01
/// WI-4 T1).
///
/// Authenticity is a property of the *sync channel*, not the artefact's own
/// file format — SSTables (and vault blobs/manifests) are immutable and
/// locally identical across devices regardless of which device wrote them.
/// [wrap] is applied at upload time and [unwrap] at download time; the
/// artefact's own bytes are never touched.
///
/// ## Wire format
///
/// ```
/// [magic "KSA" (3B)][version 0x01 (1B)][MAC (16B)][payload]
/// ```
///
/// Self-describing, mirroring [EncryptionEnvelope]'s `[flag][payload]`
/// framing: the magic + version lets the frame evolve unambiguously in a
/// future KMDB version.
///
/// ## What the MAC covers
///
/// The MAC is computed over `lenPrefixed(relativePath) ‖ payload` — a
/// 4-byte big-endian length prefix, the UTF-8 bytes of [relativePath]
/// (forward-slash normalised), then the raw payload. Binding the path into
/// the MAC means a genuine artefact cannot be relocated to a different
/// remote path and re-accepted there (e.g. a real peer's `.hwm` file copied
/// over another peer's path).
final class SyncAuthEnvelope {
  const SyncAuthEnvelope._();

  /// The 3-byte magic prefix: ASCII `"KSA"`.
  static const List<int> kMagic = [0x4b, 0x53, 0x41];

  /// The current envelope format version.
  static const int kVersion = 0x01;

  /// The MAC length in bytes (128 bits) — matches
  /// [DefaultSyncAuthenticator.kMacLength].
  static const int kMacLength = 16;

  /// Total header length: magic (3) + version (1) + MAC (16).
  static const int kHeaderLength = 3 + 1 + kMacLength;

  /// Wraps [payload] with a sync-auth envelope, computing the MAC via
  /// [authenticator] over `lenPrefixed(relativePath) ‖ payload` under the
  /// sub-key for [artifactClass].
  ///
  /// Throws [StateError] if [authenticator] returns a MAC that is not
  /// exactly [kMacLength] bytes (a contract violation by the
  /// [SyncAuthenticator] implementation, not a runtime/network condition).
  static Future<Uint8List> wrap(
    Uint8List payload,
    SyncAuthenticator authenticator, {
    required SyncArtifactClass artifactClass,
    required String relativePath,
  }) async {
    final message = _message(relativePath, payload);
    final mac = await authenticator.mac(artifactClass, message);
    if (mac.length != kMacLength) {
      throw StateError(
        'SyncAuthenticator.mac must return $kMacLength bytes for '
        '$artifactClass, got ${mac.length}',
      );
    }
    final out = Uint8List(kHeaderLength + payload.length)
      ..setRange(0, kMagic.length, kMagic)
      ..[kMagic.length] = kVersion
      ..setRange(kMagic.length + 1, kHeaderLength, mac)
      ..setRange(kHeaderLength, kHeaderLength + payload.length, payload);
    return out;
  }

  /// Reverses [wrap]: verifies the envelope in [bytes] and returns the
  /// original payload.
  ///
  /// Throws [SyncAuthException] if:
  /// - [bytes] is too short to contain a header, or the magic/version does
  ///   not match — including the R-5 case of a legacy, un-enveloped artefact
  ///   from before sync authentication was enabled on this remote.
  /// - The recomputed MAC does not match the one carried in the envelope.
  ///
  /// Both cases produce the same exception type by design (Q2/round 2): the
  /// decorator's detection is uniform even though callers apply different
  /// *dispositions* (quarantine-and-continue vs. propagate) depending on
  /// which call site is affected — see
  /// `docs/spec/32_sync_authentication.md`'s rejection-policy table.
  static Future<Uint8List> unwrap(
    Uint8List bytes,
    SyncAuthenticator authenticator, {
    required SyncArtifactClass artifactClass,
    required String relativePath,
  }) async {
    if (bytes.length < kHeaderLength ||
        bytes[0] != kMagic[0] ||
        bytes[1] != kMagic[1] ||
        bytes[2] != kMagic[2] ||
        bytes[3] != kVersion) {
      throw SyncAuthException(
        'Missing or malformed sync-auth envelope at "$relativePath". This '
        'artefact was not authenticated with this sync-set\'s key — it may '
        'be forged, corrupted, or (for a remote configured before sync '
        'authentication was enabled) simply predate it. Re-provision this '
        'remote: `kmdb <db> remote pair show` on an already-enrolled '
        'device, then `kmdb <db> remote pair import <remote> <code>` here.',
        path: relativePath,
      );
    }
    final mac = Uint8List.sublistView(bytes, kMagic.length + 1, kHeaderLength);
    final payload = Uint8List.sublistView(bytes, kHeaderLength);
    final message = _message(relativePath, payload);
    final ok = await authenticator.verify(artifactClass, message, mac);
    if (!ok) {
      throw SyncAuthException(
        'Sync-auth MAC verification failed for "$relativePath". The file '
        'may have been tampered with, relocated from another path, or '
        'produced under a different sync-set key. Re-provision this '
        'remote: `kmdb <db> remote pair`.',
        path: relativePath,
      );
    }
    return payload;
  }

  /// Builds the MAC input: `lenPrefixed(relativePath) ‖ payload`.
  ///
  /// [relativePath] is normalised to forward slashes before encoding, so the
  /// MAC is stable regardless of which OS path-separator convention (if any)
  /// a caller's path string happened to use — see the class doc comment.
  static Uint8List _message(String relativePath, Uint8List payload) {
    final normalized = relativePath.replaceAll('\\', '/');
    final pathBytes = utf8.encode(normalized);
    final out = BytesBuilder(copy: false)
      ..add(_uint32be(pathBytes.length))
      ..add(pathBytes)
      ..add(payload);
    return out.toBytes();
  }

  static Uint8List _uint32be(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.big);
    return data.buffer.asUint8List();
  }
}
