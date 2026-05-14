// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'vault_manifest.dart';
import 'vault_store.dart';

/// A typed reference to a vault object, wrapping a `kmdb-vault://` URI.
///
/// A [VaultRef] is immutable. URI format is validated eagerly at construction
/// time — malformed URIs throw [FormatException] immediately rather than at
/// access time.
///
/// Fields in a document model that reference vault objects should be typed as
/// [VaultRef]. The [KmdbCodec] for the model is responsible for mapping between
/// [VaultRef] and the raw URI string.
///
/// ## URI format
///
/// ```
/// kmdb-vault://sha256/{64-hex-char-sha256}
/// ```
///
/// ## Example
///
/// ```dart
/// final ref = VaultRef(
///   'kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8',
/// );
/// print(ref.sha256); // dd92c2600e...
/// final bytes = await ref.getBlob(); // Uint8List
/// final meta  = await ref.getMetadata(); // VaultManifest
/// ```
final class VaultRef {
  /// Constructs a [VaultRef] from a `kmdb-vault://` URI string.
  ///
  /// Validates the URI format eagerly. Throws [FormatException] immediately
  /// if the URI does not conform to the `kmdb-vault://sha256/{64-hex}` pattern.
  VaultRef(this.uri) {
    // Parse and validate eagerly so callers discover problems at object
    // construction time, not when they try to use the reference.
    _sha256 = _parseAndValidate(uri);
  }

  /// The full `kmdb-vault://` URI.
  final String uri;

  late final String _sha256;

  /// The URI scheme used for vault references.
  static const String kScheme = 'kmdb-vault';

  /// The SHA-256 hash component extracted from the URI.
  ///
  /// This is the 64-character lower-case hex digest — the primary identity key
  /// for the vault object.
  String get sha256 => _sha256;

  /// The optional [VaultStore] backing blob and metadata retrieval.
  ///
  /// Set by [VaultStore.wireRef] after construction. When `null`, [getBlob]
  /// and [getMetadata] throw [StateError].
  VaultStore? _store;

  // ── Accessors ──────────────────────────────────────────────────────────────

  /// Retrieves the raw binary blob for this vault object.
  ///
  /// If the object is a stub (metadata present, blob absent), and a sync
  /// remote is configured, this triggers on-demand hydration before returning
  /// the bytes.
  ///
  /// Throws [StateError] if no [VaultStore] has been wired to this ref
  /// (i.e. the ref was created outside of a live database session).
  Future<Uint8List> getBlob() {
    final store = _store;
    if (store == null) {
      throw StateError(
        'VaultRef.getBlob(): no VaultStore wired. '
        'Obtain VaultRef instances through KmdbCollection.get() rather than '
        'constructing them directly.',
      );
    }
    return store.getBytes(_sha256);
  }

  /// Retrieves the [VaultManifest] metadata for this vault object.
  ///
  /// Throws [StateError] if no [VaultStore] has been wired to this ref.
  Future<VaultManifest> getMetadata() {
    final store = _store;
    if (store == null) {
      throw StateError(
        'VaultRef.getMetadata(): no VaultStore wired. '
        'Obtain VaultRef instances through KmdbCollection.get() rather than '
        'constructing them directly.',
      );
    }
    return store.getManifest(_sha256);
  }

  // ── String representation ──────────────────────────────────────────────────

  /// Returns the full `kmdb-vault://` URI string.
  @override
  String toString() => uri;

  // ── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is VaultRef && uri == other.uri);

  @override
  int get hashCode => uri.hashCode;

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Wires this ref to a [VaultStore] so that [getBlob] and [getMetadata] work.
  ///
  /// Called by the Query Layer when decoding a document that contains vault
  /// URIs — allows [VaultRef] instances in decoded documents to be used
  /// directly without passing the store around externally.
  // ignore: use_setters_to_change_properties
  void wire(VaultStore store) {
    _store = store;
  }

  /// Parses [uri] and returns the SHA-256 hex string, or throws [FormatException].
  static String _parseAndValidate(String uri) {
    // Expected format: kmdb-vault://sha256/{64-hex-chars}
    const prefix = 'kmdb-vault://sha256/';
    if (!uri.startsWith(prefix)) {
      throw FormatException(
        'Invalid VaultRef URI: must start with "kmdb-vault://sha256/". '
        'Got: "$uri"',
        uri,
        0,
      );
    }

    final hash = uri.substring(prefix.length);
    if (hash.length != 64) {
      throw FormatException(
        'Invalid VaultRef URI: SHA-256 hash must be exactly 64 hex characters, '
        'got ${hash.length}. URI: "$uri"',
        uri,
        prefix.length,
      );
    }

    if (!_kHex64.hasMatch(hash)) {
      throw FormatException(
        'Invalid VaultRef URI: SHA-256 hash must contain only lowercase hex '
        'characters (0-9, a-f). URI: "$uri"',
        uri,
        prefix.length,
      );
    }

    return hash;
  }

  /// Returns `true` if [candidate] is a valid `kmdb-vault://` URI.
  static bool isVaultUri(String candidate) {
    try {
      _parseAndValidate(candidate);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Pattern for exactly 64 lower-case hex characters.
  static final _kHex64 = RegExp(r'^[0-9a-f]{64}$');
}
