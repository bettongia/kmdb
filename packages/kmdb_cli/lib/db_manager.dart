import 'dart:io';

class DatabaseManager {
  /// Ensures that a database file exists at the specified [path].
  /// If it does not exist, it creates an empty file.
  Future<void> ensureDatabaseExists(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
  }
}
