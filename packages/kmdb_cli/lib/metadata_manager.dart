class MetadataManager {
  /// Lists the databases available.
  /// Currently, the core engine is single-file, so this just returns the
  /// current database path if provided.
  Future<List<String>> listDatabases(String? currentDb) async {
    if (currentDb == null) return [];
    return [currentDb];
  }

  /// Lists the namespaces in the specified database.
  /// Note: The current core engine does not yet support multiple namespaces.
  /// It defaults to a single 'default' namespace.
  Future<List<String>> listNamespaces(String dbPath) async {
    // For now, return a default namespace as a stub.
    return ['default'];
  }

  /// Lists the secondary indexes in the specified database.
  /// Note: The current core engine does not yet support secondary indexes.
  Future<List<String>> listIndexes(String dbPath) async {
    // Return an empty list as a stub.
    return [];
  }
}
