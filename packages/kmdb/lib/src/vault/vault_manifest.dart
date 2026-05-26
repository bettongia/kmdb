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

/// @docImport 'media_type_detector.dart';
library;

import 'dart:convert';

/// Immutable metadata record written alongside every vault blob.
///
/// `manifest.json` is created once at ingestion time and never mutated. It
/// records the canonical identity information for the blob — hash, size,
/// secondary checksum — and the human-readable metadata (media type, original
/// filename, creation timestamp).
///
/// ## Schema version
///
/// All manifests in v1 carry `schemaVersion: "1"`. Future schema changes will
/// increment this field; readers that encounter an unknown version should
/// reject the manifest.
///
/// ## Example
///
/// ```dart
/// final manifest = VaultManifest(
///   sha256: 'dd92c2600e...',
///   size: 12345,
///   crc32c: 'a1b2c3d4',
///   mediaType: 'image/jpeg',
///   originalName: 'photo.jpg',
///   createdAt: '2026-04-08T12:00:00.000Z',
/// );
/// final json = manifest.toJson();
/// final decoded = VaultManifest.fromJson(json);
/// ```
final class VaultManifest {
  /// Creates a [VaultManifest] with the given fields.
  ///
  /// All fields are required. The [schemaVersion] defaults to `"1"`.
  const VaultManifest({
    this.schemaVersion = kSchemaVersion,
    required this.sha256,
    required this.size,
    required this.crc32c,
    required this.mediaType,
    required this.originalName,
    required this.createdAt,
  });

  /// The current manifest schema version (`"1"`).
  static const String kSchemaVersion = '1';

  /// The manifest schema version stored in this record.
  ///
  /// Always `"1"` for manifests created by this implementation.
  final String schemaVersion;

  /// The SHA-256 hex digest (64 characters) of the raw blob bytes.
  ///
  /// This is the primary identity key. The blob is stored under
  /// `vault/blobs/sha256/{sha256[0..1]}/{sha256[2..63]}/blob`.
  final String sha256;

  /// The exact byte count of the raw blob.
  final int size;

  /// The CRC32C checksum of the raw blob, expressed as an 8-hex-character
  /// lower-case string (e.g. `"a1b2c3d4"`).
  ///
  /// Used as a secondary identity discriminator (ISS pattern). If two blobs
  /// share the same SHA-256 and size but differ in CRC32C, they are treated as
  /// distinct objects and the incoming blob is rejected.
  final String crc32c;

  /// The detected MIME type of the blob (e.g. `"image/jpeg"`).
  ///
  /// Determined by file-signature inspection at ingestion time, not by
  /// file extension. The value stored here is the best match returned by the
  /// [MediaTypeDetector].
  final String mediaType;

  /// The original filename at the time of ingestion (e.g. `"photo.jpg"`).
  ///
  /// This is informational only. The blob is stored by hash, not by name.
  final String originalName;

  /// The HLC timestamp string at the time of ingestion.
  ///
  /// Passed in by the caller; the vault subsystem does not read the clock
  /// directly (see §24 for the one-directional dependency rationale).
  final String createdAt;

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Encodes this manifest as a JSON-serialisable [Map].
  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'sha256': sha256,
    'size': size,
    'crc32c': crc32c,
    'mediaType': mediaType,
    'originalName': originalName,
    'createdAt': createdAt,
  };

  /// Encodes this manifest as a UTF-8 JSON string.
  ///
  /// The output is pretty-printed with 2-space indentation for
  /// human-readability.
  String toJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toJson());
  }

  /// Decodes a [VaultManifest] from a JSON [Map].
  ///
  /// Throws [FormatException] if required fields are missing or have the wrong
  /// type, or if [schemaVersion] is not `"1"`.
  factory VaultManifest.fromJson(Map<String, dynamic> json) {
    // Validate schema version first — reject unknown versions immediately
    // so callers know to handle forward-compatibility themselves.
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion == null) {
      throw const FormatException(
        'VaultManifest: missing required field "schemaVersion"',
      );
    }
    if (schemaVersion is! String) {
      throw FormatException(
        'VaultManifest: "schemaVersion" must be a string, got ${schemaVersion.runtimeType}',
      );
    }
    if (schemaVersion != kSchemaVersion) {
      throw FormatException(
        'VaultManifest: unsupported schemaVersion "$schemaVersion" '
        '(expected "$kSchemaVersion")',
      );
    }

    // Validate and extract required fields.
    _requireString(json, 'sha256');
    _requireInt(json, 'size');
    _requireString(json, 'crc32c');
    _requireString(json, 'mediaType');
    _requireString(json, 'originalName');
    _requireString(json, 'createdAt');

    // Validate sha256 format — must be exactly 64 lower-case hex characters.
    final sha256 = json['sha256'] as String;
    if (sha256.length != 64 || !_kHex64.hasMatch(sha256)) {
      throw FormatException(
        'VaultManifest: "sha256" must be a 64-character hex string, got "$sha256"',
      );
    }

    // Validate crc32c format — must be exactly 8 hex characters.
    final crc32c = json['crc32c'] as String;
    if (crc32c.length != 8 || !_kHex8.hasMatch(crc32c)) {
      throw FormatException(
        'VaultManifest: "crc32c" must be an 8-character hex string, got "$crc32c"',
      );
    }

    return VaultManifest(
      schemaVersion: schemaVersion,
      sha256: sha256,
      size: json['size'] as int,
      crc32c: crc32c,
      mediaType: json['mediaType'] as String,
      originalName: json['originalName'] as String,
      createdAt: json['createdAt'] as String,
    );
  }

  /// Decodes a [VaultManifest] from a JSON string.
  ///
  /// Throws [FormatException] on parse or validation error.
  factory VaultManifest.fromJsonString(String jsonString) {
    final Object? decoded;
    try {
      decoded = json.decode(jsonString);
    } on FormatException catch (e) {
      throw FormatException('VaultManifest: invalid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('VaultManifest: JSON root must be an object');
    }
    return VaultManifest.fromJson(decoded);
  }

  // ── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultManifest &&
          schemaVersion == other.schemaVersion &&
          sha256 == other.sha256 &&
          size == other.size &&
          crc32c == other.crc32c &&
          mediaType == other.mediaType &&
          originalName == other.originalName &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    sha256,
    size,
    crc32c,
    mediaType,
    originalName,
    createdAt,
  );

  @override
  String toString() =>
      'VaultManifest(sha256: ${sha256.substring(0, 8)}..., '
      'size: $size, mediaType: $mediaType, originalName: $originalName)';

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Pattern for exactly 64 lower-case hex characters.
  static final _kHex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Pattern for exactly 8 lower-case hex characters.
  static final _kHex8 = RegExp(r'^[0-9a-f]{8}$');

  static void _requireString(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value == null) {
      throw FormatException('VaultManifest: missing required field "$field"');
    }
    if (value is! String) {
      throw FormatException(
        'VaultManifest: "$field" must be a string, got ${value.runtimeType}',
      );
    }
  }

  static void _requireInt(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value == null) {
      throw FormatException('VaultManifest: missing required field "$field"');
    }
    if (value is! int) {
      throw FormatException(
        'VaultManifest: "$field" must be an integer, got ${value.runtimeType}',
      );
    }
  }
}
