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
/// Updates are atomic via write-then-rename:
/// 1. Write the new content to a temp file (`CURRENT.tmp`).
/// 2. `renameFile(CURRENT.tmp → CURRENT)` — atomic on POSIX.
///
/// This ensures a crash between steps 1 and 2 leaves either the old or the new
/// `CURRENT` intact; a partially written `CURRENT.tmp` is harmless and is
/// cleaned up on the next open.
final class CurrentFile {
  const CurrentFile({
    required this.dbDir,
    required this.adapter,
  });

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
    await adapter.renameFile(_tmpPath, _currentPath);
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
