import 'dart:io';
import 'package:kmdb/kmdb.dart';

class MaintenanceManager {
  /// Compacts the specified database file.
  Future<void> compact(String dbPath) async {
    final engine = StorageEngine(dbPath);
    try {
      await engine.open();
      await engine.compact();
    } finally {
      await engine.close();
    }
  }

  /// Checks the integrity of the specified database file.
  Future<bool> checkIntegrity(String dbPath) async {
    final engine = StorageEngine(dbPath);
    try {
      await engine.open();
      // If open succeeds without throwing corruption errors, we consider it valid for now.
      // The current engine performs checksum verification during load.
      return true;
    } catch (e) {
      return false;
    } finally {
      await engine.close();
    }
  }

  /// Creates a backup of the specified database file.
  Future<void> backup(String dbPath, String backupPath) async {
    final source = File(dbPath);
    if (!await source.exists()) {
      throw FileSystemException('Source database file not found', dbPath);
    }
    await source.copy(backupPath);
  }
}
