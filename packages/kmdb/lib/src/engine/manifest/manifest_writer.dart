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

import 'dart:typed_data';

import '../platform/storage_adapter_interface.dart';
import '../util/xxhash.dart';
import 'version_edit.dart';

/// Maximum Manifest file size before rotation.
///
/// When the active Manifest exceeds this threshold the engine writes a snapshot
/// Manifest and atomically updates CURRENT to point to it. 1 MB keeps replay
/// fast even on large databases.
const int kManifestRotationThreshold = 1 * 1024 * 1024; // 1 MB

/// Appends [VersionEdit] records to the active Manifest file.
///
/// Each record is encoded as:
/// ```
/// [checksum 8B][length 4B BE][CBOR bytes]
/// ```
///
/// The checksum covers `[length bytes][CBOR bytes]`.
///
/// [ManifestWriter] is used by the engine to persist flush and compaction
/// outcomes. It is not responsible for CURRENT file management — that is
/// handled by [CurrentFile].
final class ManifestWriter {
  ManifestWriter({required this.path, required this.adapter}) : _byteCount = 0;

  /// Full path of the Manifest file being written.
  final String path;

  /// Storage adapter for all I/O.
  final StorageAdapter adapter;

  /// Running byte count — used to detect when rotation is needed.
  int _byteCount;

  /// Approximate size of the Manifest file in bytes.
  int get byteCount => _byteCount;

  /// Whether this Manifest has grown beyond [kManifestRotationThreshold].
  bool get shouldRotate => _byteCount >= kManifestRotationThreshold;

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Appends [edit] to the Manifest.
  ///
  /// Encodes the edit to CBOR, prepends a [length + checksum] header, and
  /// appends to the file. No fsync is issued here — the caller (engine) is
  /// responsible for fsyncing the SSTable first to ensure the data block is
  /// durable before the Manifest records it.
  Future<void> append(VersionEdit edit) async {
    final payload = _encode(edit);
    await adapter.appendFile(path, payload);
    _byteCount += payload.length;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static Uint8List _encode(VersionEdit edit) {
    final cborBytes = edit.toCbor();
    // Header = checksum(8) + length(4)
    final buf = Uint8List(12 + cborBytes.length);
    final bd = ByteData.sublistView(buf);

    // Write length at offset 8.
    bd.setUint32(8, cborBytes.length, Endian.big);

    // Copy CBOR bytes at offset 12.
    buf.setAll(12, cborBytes);

    // Compute checksum over [length(4) + cbor(N)].
    final toHash = Uint8List.sublistView(buf, 8);
    final checksum = XxHash64.digest(toHash);
    bd.setInt64(0, checksum, Endian.big);

    return buf;
  }
}
