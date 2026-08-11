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
/// @docImport 'pairing_code.dart';
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// The material minted once per sync remote and shared across every device
/// that syncs to it (0.10.01 WI-4 T1, Q-B/Q-C).
///
/// A [SyncSetKey] pairs:
///
/// - [rootKey] — the 256-bit sync-set root key that
///   [DefaultSyncAuthenticator]/`WebSyncAuthenticator` derive their six
///   per-artefact-class sub-keys from.
/// - [syncSetId] — an opaque identifier for the key-sharing group this key
///   belongs to. It is delivered *with* the key via [PairingCode] rather
///   than minted independently per device and synced through `$meta`,
///   closing an LWW-collision hazard: `$meta` syncs
///   (`isLocalOnly(r'$meta')` is `false`) and would let two independently-
///   minted identities collide unpredictably on first pull if each device
///   generated its own. [syncSetId] is not currently consumed by the sync
///   protocol itself (the MAC is computed from [rootKey] alone — see
///   `SyncAuthEnvelope`); it exists for diagnostics and as a sanity check a
///   host application can use to confirm two remotes were paired from the
///   same enrollment.
///
/// **One key per remote** — a database syncing to two remotes (e.g. Google
/// Drive and a NAS) holds two independent [SyncSetKey]s, each scoped to its
/// own remote by the storage layer (`kmdb_cli`'s `SecretStore` key naming;
/// see `dbScopedSecretKey`).
final class SyncSetKey {
  /// Creates a [SyncSetKey] from existing material.
  ///
  /// Prefer [SyncSetKey.generate] to mint new key material for a new remote.
  SyncSetKey({required Uint8List rootKey, required this.syncSetId})
    : rootKey = Uint8List.fromList(rootKey) {
    if (this.rootKey.length != kRootKeyLength) {
      throw ArgumentError.value(
        rootKey.length,
        'rootKey.length',
        'Sync-set root key must be exactly $kRootKeyLength bytes',
      );
    }
  }

  /// The required length, in bytes, of [rootKey] (256 bits).
  static const int kRootKeyLength = 32;

  /// The 256-bit sync-set root key.
  final Uint8List rootKey;

  /// An opaque identifier for the key-sharing group this key belongs to —
  /// see the class doc comment for what this is (and is not) used for.
  final String syncSetId;

  /// Generates a fresh [SyncSetKey]: a new 256-bit root key from
  /// [Random.secure] and a new v4 UUID sync-set identity.
  ///
  /// Called once at `remote add` time (never at database `init` — see the
  /// class doc comment for why).
  factory SyncSetKey.generate() {
    final random = Random.secure();
    final rootKey = Uint8List.fromList(
      List.generate(kRootKeyLength, (_) => random.nextInt(256)),
    );
    return SyncSetKey(rootKey: rootKey, syncSetId: const Uuid().v4());
  }

  /// Encodes this key as `[syncSetId length (1B)][syncSetId UTF-8][rootKey
  /// ($kRootKeyLength B)]`.
  ///
  /// Used both for [SecretStore] persistence (`kmdb_cli`) and as the payload
  /// [PairingCode] base32-encodes.
  ///
  /// Throws [ArgumentError] if the UTF-8 encoding of [syncSetId] exceeds 255
  /// bytes (a v4 UUID is 36 ASCII bytes, so this is generous headroom, not a
  /// practical constraint).
  Uint8List encode() {
    final idBytes = utf8.encode(syncSetId);
    if (idBytes.length > 255) {
      throw ArgumentError.value(
        syncSetId,
        'syncSetId',
        'Encoded syncSetId must be at most 255 bytes',
      );
    }
    final out = Uint8List(1 + idBytes.length + kRootKeyLength)
      ..[0] = idBytes.length
      ..setAll(1, idBytes)
      ..setAll(1 + idBytes.length, rootKey);
    return out;
  }

  /// Decodes a [SyncSetKey] previously produced by [encode].
  ///
  /// Throws [FormatException] if [bytes] is malformed: too short, the
  /// declared `syncSetId` length overruns the buffer, or there are trailing
  /// bytes beyond the expected `[len][syncSetId][rootKey]` layout.
  factory SyncSetKey.decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('Encoded SyncSetKey is empty');
    }
    final idLen = bytes[0];
    final expectedLength = 1 + idLen + kRootKeyLength;
    if (bytes.length != expectedLength) {
      throw FormatException(
        'Encoded SyncSetKey has the wrong length: expected '
        '$expectedLength bytes, got ${bytes.length}',
      );
    }
    final String syncSetId;
    try {
      syncSetId = utf8.decode(bytes.sublist(1, 1 + idLen));
    } on FormatException catch (e) {
      throw FormatException('Encoded SyncSetKey has invalid UTF-8: $e');
    }
    final rootKey = Uint8List.sublistView(bytes, 1 + idLen, expectedLength);
    return SyncSetKey(rootKey: rootKey, syncSetId: syncSetId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncSetKey &&
          syncSetId == other.syncSetId &&
          _bytesEqual(rootKey, other.rootKey);

  @override
  int get hashCode => Object.hash(syncSetId, Object.hashAll(rootKey));

  @override
  String toString() =>
      'SyncSetKey(syncSetId: $syncSetId, rootKey: <${rootKey.length} bytes>)';

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
