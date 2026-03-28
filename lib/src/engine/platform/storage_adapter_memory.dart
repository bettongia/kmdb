import 'dart:typed_data';

import 'storage_adapter_interface.dart';

/// In-memory [StorageAdapter] for use in tests and [KvStoreConfig.forTesting].
///
/// All file contents live in a [Map] keyed by absolute path. Operations are
/// synchronous under the hood — [Future]s complete in the same microtask.
/// `syncFile` and `syncDir` are no-ops; `renameFile` is atomic by construction.
///
/// The lock mechanism prevents two [MemoryStorageAdapter] instances from
/// locking the same path simultaneously, mirroring the single-process
/// exclusion guarantee of the native adapter.
final class MemoryStorageAdapter implements StorageAdapter {
  MemoryStorageAdapter();

  // Visible for testing — allows inspection of raw file contents.
  final Map<String, Uint8List> files = {};

  // Tracks which lock paths are currently held.
  static final Set<String> _heldLocks = {};

  @override
  Future<Uint8List> readFile(String path) async {
    final data = files[path];
    if (data == null) throw StorageException('File not found', path: path);
    return Uint8List.fromList(data);
  }

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    final data = files[path];
    if (data == null) throw StorageException('File not found', path: path);
    if (offset < 0 || offset + length > data.length) {
      throw StorageException(
        'Range [$offset, ${offset + length}) out of bounds (file length ${data.length})',
        path: path,
      );
    }
    return Uint8List.fromList(data.sublist(offset, offset + length));
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    final existing = files[path];
    if (existing == null) {
      files[path] = Uint8List.fromList(bytes);
    } else {
      final combined = Uint8List(existing.length + bytes.length);
      combined.setAll(0, existing);
      combined.setAll(existing.length, bytes);
      files[path] = combined;
    }
  }

  @override
  Future<void> syncFile(String path) async {
    // No-op: in-memory writes are immediately durable by construction.
  }

  @override
  Future<void> syncDir(String dirPath) async {
    // No-op: no directory entries in the in-memory model.
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
  }

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) async {
    // Normalise: ensure dirPath ends with '/' for prefix matching.
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final results = <String>[];
    for (final path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      // Only include direct children (no deeper subdirectory entries).
      final remainder = path.substring(prefix.length);
      if (remainder.contains('/')) continue;
      if (extension != null && !remainder.endsWith(extension)) continue;
      results.add(remainder);
    }
    return results;
  }

  @override
  Future<int> fileSize(String path) async {
    final data = files[path];
    if (data == null) throw StorageException('File not found', path: path);
    return data.length;
  }

  @override
  Future<void> renameFile(String from, String to) async {
    final data = files.remove(from);
    if (data == null) throw StorageException('File not found', path: from);
    files[to] = data;
  }

  @override
  Future<void> createDirectory(String dirPath) async {
    // No-op: the memory adapter uses flat path keys — no real directories.
  }

  @override
  Future<void> acquireLock(String lockPath) async {
    if (_heldLocks.contains(lockPath)) throw LockException(lockPath);
    _heldLocks.add(lockPath);
    files[lockPath] = Uint8List(0);
  }

  @override
  Future<void> releaseLock(String lockPath) async {
    _heldLocks.remove(lockPath);
  }

  /// Releases all locks held by any [MemoryStorageAdapter].
  ///
  /// Call in test tearDown to prevent lock state leaking between tests.
  static void releaseAllLocks() => _heldLocks.clear();
}
