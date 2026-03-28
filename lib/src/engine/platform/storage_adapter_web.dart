import 'dart:typed_data';

import 'storage_adapter_interface.dart';

/// Web [StorageAdapter] stub — full OPFS implementation is deferred to Phase 8.
///
/// Throws [UnsupportedError] on all operations so that any accidental use
/// during development fails loudly rather than silently.
final class StorageAdapterWeb implements StorageAdapter {
  const StorageAdapterWeb();

  static Never _unimplemented() =>
      throw UnsupportedError('OPFS StorageAdapter not yet implemented (Phase 8)');

  @override
  Future<Uint8List> readFile(String path) async => _unimplemented();
  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async =>
      _unimplemented();
  @override
  Future<void> writeFile(String path, Uint8List bytes) async => _unimplemented();
  @override
  Future<void> appendFile(String path, Uint8List bytes) async => _unimplemented();
  @override
  Future<void> syncFile(String path) async => _unimplemented();
  @override
  Future<void> syncDir(String dirPath) async => _unimplemented();
  @override
  Future<void> deleteFile(String path) async => _unimplemented();
  @override
  Future<bool> fileExists(String path) async => _unimplemented();
  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) async =>
      _unimplemented();
  @override
  Future<int> fileSize(String path) async => _unimplemented();
  @override
  Future<void> renameFile(String from, String to) async => _unimplemented();
  @override
  Future<void> createDirectory(String dirPath) async => _unimplemented();
  @override
  Future<void> acquireLock(String lockPath) async => _unimplemented();
  @override
  Future<void> releaseLock(String lockPath) async => _unimplemented();
}
