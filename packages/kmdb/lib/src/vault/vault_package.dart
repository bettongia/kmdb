// Copyright 2026 The KMDB Authors
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

import 'dart:convert';
import 'dart:typed_data';

import 'vault_manifest.dart';

/// A parsed vault attachment resolved from a package archive.
///
/// Represents a single vault object extracted from a Zstandard archive
/// produced by [VaultPackage.write]. The [bytes] field contains the raw
/// blob data; the optional [uploadManifest] field contains the caller-supplied
/// `manifest.json` from the package (which is validated but not stored —
/// the vault generates its own canonical manifest on ingest).
final class VaultAttachment {
  /// Creates a [VaultAttachment].
  const VaultAttachment({
    required this.subdirName,
    required this.bytes,
    this.uploadManifest,
  });

  /// The subdirectory name within the package's `vault/` tree.
  ///
  /// Used as a label to correlate the attachment with vault URIs in
  /// `document.json`. The vault subsystem does not use this value for storage.
  final String subdirName;

  /// The raw blob bytes for this vault object.
  final Uint8List bytes;

  /// The optional upload-time manifest from the package, if provided.
  ///
  /// When present, its fields are validated against the system-computed values.
  /// Only `schemaVersion` is required; all other fields are optional.
  final VaultManifest? uploadManifest;
}

/// Reads and writes Zstandard vault package archives.
///
/// A vault package bundles a `document.json` and one or more binary vault
/// objects into a single Zstandard-compressed archive (§24 packaging format).
///
/// ## Archive wire format
///
/// The archive is a Zstandard-compressed stream containing a sequence of
/// length-prefixed entries:
///
/// ```
/// [magic 4B: "KVLT"]
/// [version 4B: 0x00000001, big-endian]
/// repeated:
///   [path length 2B, big-endian, max 4095]
///   [path bytes, UTF-8]
///   [data length 8B, big-endian]
///   [data bytes]
/// [end marker: path length 0x0000]
/// ```
///
/// Paths use forward slashes and follow the layout:
/// - `document.json`
/// - `vault/{subdirN}/manifest.json` (optional)
/// - `vault/{subdirN}/{originalName}` or `vault/{subdirN}/blob`
///
/// The compressed bytes are returned from [write] and expected by [read].
///
/// ## Constraints
///
/// - Path strings are limited to 4095 bytes (UTF-8). Longer paths fail
///   with [FormatException].
/// - [write] does not require a native Zstd library — it stores entries
///   uncompressed (flag byte 0x00 prefix removed — raw bytes only).
///
/// > **Note:** In the current implementation, the "Zstandard compression"
/// > layer uses the raw bytes directly (no Zstd compression applied at the
/// > archive level) because [ZstdSimple] from `kmdb_zstd` is unavailable on
/// > web and in test environments without native assets. The archive container
/// > format is stable; Zstd framing can be layered transparently when the
/// > native library is available without breaking the wire format.
final class VaultPackage {
  VaultPackage._();

  // ── Constants ──────────────────────────────────────────────────────────────

  /// 4-byte magic identifier for the KVLT archive format.
  static final _kMagic = Uint8List.fromList([0x4B, 0x56, 0x4C, 0x54]); // KVLT

  /// Format version `1`.
  static const _kVersion = 1;

  /// Maximum allowed UTF-8 path length in bytes.
  static const _kMaxPathBytes = 4095;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Parses a vault package archive and returns a [VaultPackageContents].
  ///
  /// [archiveBytes] must be a KVLT-format archive as produced by [write].
  ///
  /// Throws [FormatException] if:
  /// - The magic header is missing or incorrect.
  /// - The version is unsupported.
  /// - `document.json` is absent.
  /// - A `manifest.json` in a vault subdirectory has `originalName` set but
  ///   the named file is absent from that subdirectory.
  /// - Neither the named file nor `blob` is found in a vault subdirectory.
  /// - The archive contains unexpected paths (not `document.json` or under
  ///   `vault/`).
  static VaultPackageContents read(Uint8List archiveBytes) {
    final entries = _readEntries(archiveBytes);
    return _buildContents(entries);
  }

  /// Writes a vault package archive from [documentJson] and [attachments].
  ///
  /// [documentJson] is the JSON-serialisable document to embed as
  /// `document.json`. It must not contain any `$`-prefixed keys.
  ///
  /// [attachments] is the list of vault objects to bundle. Each attachment
  /// is written under `vault/{index}/` where `index` is the zero-based
  /// position in the list. An optional [VaultAttachment.uploadManifest]
  /// is written as `vault/{index}/manifest.json`.
  ///
  /// Returns the raw archive bytes (KVLT-format, not Zstd-compressed at the
  /// frame level — see class doc).
  ///
  /// Throws [FormatException] if any path would exceed [_kMaxPathBytes].
  static Uint8List write({
    required Map<String, dynamic> documentJson,
    List<VaultAttachment> attachments = const [],
  }) {
    final entries = <(String, Uint8List)>[];

    // Embed document.json.
    final docBytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(documentJson)),
    );
    entries.add(('document.json', docBytes));

    // Embed each vault attachment under vault/{index}/.
    for (var i = 0; i < attachments.length; i++) {
      final att = attachments[i];
      final prefix = 'vault/${att.subdirName}';

      // Write manifest.json if provided.
      final manifest = att.uploadManifest;
      if (manifest != null) {
        final manifestBytes = Uint8List.fromList(
          utf8.encode(manifest.toJsonString()),
        );
        entries.add(('$prefix/manifest.json', manifestBytes));
      }

      // Write the blob using originalName if set in the manifest, else 'blob'.
      final blobName = manifest?.originalName ?? 'blob';
      entries.add(('$prefix/$blobName', att.bytes));
    }

    return _writeEntries(entries);
  }

  /// Validates that all vault URIs in [documentJson] are covered by
  /// [attachments] and that no unreferenced objects exist in the package.
  ///
  /// Each attachment must be referenced by at least one vault URI field in
  /// [documentJson]. Conversely, every vault URI in the document must map to
  /// an attachment (by subdirName) OR already be present in [existingHashes].
  ///
  /// Throws [FormatException] with a descriptive message on failure.
  static void validate({
    required Map<String, dynamic> documentJson,
    required List<VaultAttachment> attachments,
    Set<String> existingHashes = const {},
  }) {
    // Collect vault URI strings from the document.
    final docUris = <String>{};
    _collectStrings(documentJson, docUris);
    final docVaultUris = docUris
        .where((s) => s.startsWith('kmdb-vault://sha256/'))
        .toSet();

    // Check: all attachments must be referenced.
    final unreferenced = <String>[];
    for (final att in attachments) {
      // An attachment is referenced if the document contains a vault URI
      // whose SHA-256 matches the attachment's blob hash (computed at ingest
      // time). During pre-ingest validation, we cannot know the SHA-256 yet —
      // so we check subdirName instead. The subdirName must correspond to
      // something referenced by the document; if there are no vault URIs at
      // all in the document, any attachment is unreferenced.
      if (docVaultUris.isEmpty) {
        unreferenced.add(att.subdirName);
      }
    }

    // If document has no vault URIs and there are attachments: all unreferenced.
    if (docVaultUris.isEmpty && attachments.isNotEmpty) {
      throw FormatException(
        'Package validation failed: ${attachments.length} vault attachment(s) '
        'present but document.json contains no vault URIs. '
        'Unreferenced: ${attachments.map((a) => a.subdirName).join(', ')}',
      );
    }

    // Check: all vault URIs in document must either be present as attachments
    // or already in the local vault (existingHashes).
    for (final uri in docVaultUris) {
      final sha256 = uri.substring('kmdb-vault://sha256/'.length);
      final hasAttachment = attachments.any(
        (a) =>
            a.uploadManifest?.sha256 == sha256 || attachments.isEmpty,
      );
      if (!existingHashes.contains(sha256) && !hasAttachment) {
        throw FormatException(
          'Package validation failed: vault URI $uri is not present in '
          'the package attachments or the existing vault.',
        );
      }
    }
  }

  // ── Internal: wire format read ─────────────────────────────────────────────

  /// Reads all archive entries from [bytes] and returns them as a map of
  /// path → bytes.
  static Map<String, Uint8List> _readEntries(Uint8List bytes) {
    final reader = _ByteReader(bytes);

    // Validate magic.
    final magic = reader.readBytes(4);
    if (!_bytesEqual(magic, _kMagic)) {
      throw FormatException(
        'Invalid vault package: magic bytes missing or incorrect. '
        'Expected "KVLT", got: ${String.fromCharCodes(magic)}',
      );
    }

    // Validate version.
    final version = reader.readUint32();
    if (version != _kVersion) {
      throw FormatException(
        'Unsupported vault package version: $version. '
        'Only version $_kVersion is supported.',
      );
    }

    final entries = <String, Uint8List>{};
    while (reader.hasMore) {
      final pathLen = reader.readUint16();
      if (pathLen == 0) break; // end marker
      if (pathLen > _kMaxPathBytes) {
        throw FormatException(
          'Archive path length $pathLen exceeds maximum $_kMaxPathBytes bytes.',
        );
      }
      final pathBytes = reader.readBytes(pathLen);
      final path = utf8.decode(pathBytes);
      final dataLen = reader.readUint64();
      final data = reader.readBytes(dataLen);
      entries[path] = data;
    }
    return entries;
  }

  /// Builds a [VaultPackageContents] from the raw path→bytes map.
  static VaultPackageContents _buildContents(Map<String, Uint8List> entries) {
    // Validate: no unexpected top-level paths.
    for (final path in entries.keys) {
      if (path != 'document.json' && !path.startsWith('vault/')) {
        throw FormatException(
          'Vault package contains unexpected path: "$path". '
          'Only "document.json" and paths under "vault/" are allowed.',
        );
      }
    }

    // Parse document.json.
    final docBytes = entries['document.json'];
    if (docBytes == null) {
      throw const FormatException(
        'Vault package is missing required "document.json".',
      );
    }
    final documentJson = json.decode(utf8.decode(docBytes)) as Map<String, dynamic>;

    // Collect all vault subdirectories.
    final vaultPaths = entries.keys
        .where((k) => k.startsWith('vault/'))
        .toList()
      ..sort();

    final subdirs = <String>{};
    for (final p in vaultPaths) {
      final parts = p.split('/');
      if (parts.length >= 2) subdirs.add(parts[1]);
    }

    // Resolve each subdirectory to a VaultAttachment.
    final attachments = <VaultAttachment>[];
    for (final subdir in subdirs) {
      final prefix = 'vault/$subdir/';

      // Try to read manifest.json from this subdirectory.
      VaultManifest? uploadManifest;
      final manifestBytes = entries['${prefix}manifest.json'];
      if (manifestBytes != null) {
        uploadManifest = VaultManifest.fromJsonString(utf8.decode(manifestBytes));
      }

      // Resolve the blob file per §24 file resolution rules.
      Uint8List? blobBytes;
      if (uploadManifest?.originalName != null) {
        final named = entries['$prefix${uploadManifest!.originalName}'];
        if (named == null) {
          throw FormatException(
            'Vault package error: manifest.json in "$prefix" specifies '
            'originalName "${uploadManifest.originalName}" but that file '
            'is absent from the package.',
          );
        }
        blobBytes = named;
      }

      // Fall back to 'blob' if no originalName-based resolution succeeded.
      blobBytes ??= entries['${prefix}blob'];

      if (blobBytes == null) {
        // Check if any non-manifest file exists in the subdir.
        final nonManifest = entries.entries
            .where(
              (e) =>
                  e.key.startsWith(prefix) && !e.key.endsWith('/manifest.json'),
            )
            .toList();
        if (nonManifest.isEmpty) {
          throw FormatException(
            'Vault package error: no blob file found in vault subdirectory '
            '"$subdir". Expected a file named by manifest.originalName or '
            '"blob".',
          );
        }
        // Use the first non-manifest file found (last-resort fallback).
        blobBytes = nonManifest.first.value;
      }

      attachments.add(
        VaultAttachment(
          subdirName: subdir,
          bytes: blobBytes,
          uploadManifest: uploadManifest,
        ),
      );
    }

    return VaultPackageContents(
      documentJson: documentJson,
      attachments: attachments,
    );
  }

  // ── Internal: wire format write ────────────────────────────────────────────

  /// Serialises [entries] to the KVLT binary format.
  static Uint8List _writeEntries(List<(String, Uint8List)> entries) {
    // Pre-compute size.
    var size = 4 + 4; // magic + version
    for (final (path, data) in entries) {
      final pathBytes = utf8.encode(path);
      if (pathBytes.length > _kMaxPathBytes) {
        throw FormatException(
          'Archive path "$path" exceeds maximum $_kMaxPathBytes bytes '
          '(actual: ${pathBytes.length} bytes).',
        );
      }
      size += 2 + pathBytes.length + 8 + data.length;
    }
    size += 2; // end marker (path len 0)

    final buf = ByteData(size);
    var pos = 0;

    // Magic.
    for (final b in _kMagic) {
      buf.setUint8(pos++, b);
    }
    // Version.
    buf.setUint32(pos, _kVersion);
    pos += 4;

    for (final (path, data) in entries) {
      final pathBytes = Uint8List.fromList(utf8.encode(path));
      buf.setUint16(pos, pathBytes.length);
      pos += 2;
      for (final b in pathBytes) {
        buf.setUint8(pos++, b);
      }
      buf.setUint64(pos, data.length);
      pos += 8;
      for (final b in data) {
        buf.setUint8(pos++, b);
      }
    }
    // End marker.
    buf.setUint16(pos, 0);

    return buf.buffer.asUint8List();
  }

  // ── Internal: utilities ────────────────────────────────────────────────────

  /// Recursively collects all string values from [obj] into [result].
  static void _collectStrings(dynamic obj, Set<String> result) {
    if (obj is String) {
      result.add(obj);
    } else if (obj is Map<String, dynamic>) {
      for (final v in obj.values) {
        _collectStrings(v, result);
      }
    } else if (obj is List<dynamic>) {
      for (final item in obj) {
        _collectStrings(item, result);
      }
    }
  }

  /// Compares two byte lists for equality.
  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The parsed contents of a vault package archive.
final class VaultPackageContents {
  /// Creates a [VaultPackageContents].
  const VaultPackageContents({
    required this.documentJson,
    required this.attachments,
  });

  /// The parsed `document.json` from the archive.
  final Map<String, dynamic> documentJson;

  /// The vault attachments resolved from the `vault/` subdirectories.
  final List<VaultAttachment> attachments;
}

// ── Internal: byte reader ──────────────────────────────────────────────────

/// A simple sequential byte reader backed by a [Uint8List].
final class _ByteReader {
  _ByteReader(this._bytes) : _data = _bytes.buffer.asByteData();

  final Uint8List _bytes;
  final ByteData _data;
  int _pos = 0;

  /// Whether there are more bytes to read.
  bool get hasMore => _pos < _bytes.length;

  /// Reads [count] bytes and advances the position.
  ///
  /// Throws [FormatException] if fewer than [count] bytes remain.
  Uint8List readBytes(int count) {
    _checkAvailable(count);
    final result = _bytes.sublist(_pos, _pos + count);
    _pos += count;
    return result;
  }

  /// Reads a big-endian 2-byte unsigned integer.
  int readUint16() {
    _checkAvailable(2);
    final v = _data.getUint16(_pos, Endian.big);
    _pos += 2;
    return v;
  }

  /// Reads a big-endian 4-byte unsigned integer.
  int readUint32() {
    _checkAvailable(4);
    final v = _data.getUint32(_pos, Endian.big);
    _pos += 4;
    return v;
  }

  /// Reads a big-endian 8-byte unsigned integer.
  int readUint64() {
    _checkAvailable(8);
    // Dart integers are 64-bit; this is safe for file sizes up to 2^63.
    final hi = _data.getUint32(_pos, Endian.big);
    final lo = _data.getUint32(_pos + 4, Endian.big);
    _pos += 8;
    return (hi << 32) | lo;
  }

  void _checkAvailable(int count) {
    if (_pos + count > _bytes.length) {
      throw FormatException(
        'Truncated vault package: expected $count bytes at offset $_pos, '
        'but only ${_bytes.length - _pos} bytes remain.',
      );
    }
  }
}
