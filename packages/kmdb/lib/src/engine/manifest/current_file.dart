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

import 'dart:convert';

import '../platform/storage_adapter_interface.dart';

/// Manages the `CURRENT` pointer file in the database directory.
///
/// `CURRENT` contains only the name of the active Manifest file followed by
/// a newline:
/// ```
/// MANIFEST-00001\n
/// ```
///
/// Updates are atomic *and* durable via write-fsync-rename-syncDir:
/// 1. Write the new content to a temp file (`CURRENT.tmp`).
/// 2. `syncFile(CURRENT.tmp)` — the temp's content is durable before it is named
///    `CURRENT`.
/// 3. `renameFile(CURRENT.tmp → CURRENT)` — atomic on POSIX.
/// 4. `syncDir(dbDir)` — the rename (a directory-entry change) is durable.
///
/// This ensures a crash leaves either the old or the new `CURRENT` intact, and
/// that the surviving `CURRENT` always names a manifest whose content is already
/// on disk. Without steps 2 and 4 the rename is atomic but not durable: after
/// power loss `CURRENT` could revert or point at bytes that were never flushed
/// (review finding M3).
final class CurrentFile {
  const CurrentFile({required this.dbDir, required this.adapter});

  /// Database root directory.
  final String dbDir;

  /// Storage adapter for all I/O.
  final StorageAdapter adapter;

  String get _currentPath => '$dbDir/CURRENT';
  String get _tmpPath => '$dbDir/CURRENT.tmp';

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Reads the active Manifest filename from `CURRENT`.
  ///
  /// Returns the filename without a trailing newline, e.g. `"MANIFEST-00001"`.
  ///
  /// Throws [StorageException] if `CURRENT` does not exist (fresh database).
  Future<String> read() async {
    final bytes = await adapter.readFile(_currentPath);
    return utf8.decode(bytes).trimRight();
  }

  /// Returns the full path of the active Manifest file.
  Future<String> manifestPath() async => '$dbDir/${await read()}';

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Atomically updates `CURRENT` to point to [manifestFilename].
  ///
  /// [manifestFilename] is just the bare filename (e.g. `"MANIFEST-00002"`),
  /// not a full path.
  Future<void> write(String manifestFilename) async {
    final content = utf8.encode('$manifestFilename\n');
    await adapter.writeFile(_tmpPath, content);
    await adapter.syncFile(_tmpPath);
    await adapter.renameFile(_tmpPath, _currentPath);
    await adapter.syncDir(dbDir);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns whether the `CURRENT` file exists (indicates an existing db).
  Future<bool> exists() => adapter.fileExists(_currentPath);

  /// Returns the next Manifest filename given the current one.
  ///
  /// Increments the 5-digit zero-padded sequence number:
  /// `"MANIFEST-00001"` → `"MANIFEST-00002"`.
  ///
  /// Throws [FormatException] if [currentName] does not match the expected
  /// `MANIFEST-{nnnnn}` pattern.
  static String nextManifestName(String currentName) {
    const prefix = 'MANIFEST-';
    if (!currentName.startsWith(prefix)) {
      throw FormatException('Invalid Manifest name: $currentName');
    }
    final seqStr = currentName.substring(prefix.length);
    final seq = int.tryParse(seqStr);
    if (seq == null) {
      throw FormatException('Invalid Manifest sequence in: $currentName');
    }
    return '$prefix${(seq + 1).toString().padLeft(5, '0')}';
  }

  /// Generates the first Manifest filename: `"MANIFEST-00001"`.
  static String initialManifestName() => 'MANIFEST-00001';
}
