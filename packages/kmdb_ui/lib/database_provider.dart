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

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:kmdb/kmdb.dart';

class DatabaseProvider with ChangeNotifier {
  final List<String> _recentDatabasePaths = [];
  String? _selectedDatabasePath;
  Map<String, int> _collections = {};
  String? _selectedCollection;
  Map<String, dynamic>? _selectedDocument;

  List<String> get recentDatabasePaths => _recentDatabasePaths;
  String? get selectedDatabasePath => _selectedDatabasePath;
  List<String> get collections => _collections.keys.toList();
  int getCollectionCount(String name) => _collections[name] ?? 0;
  String? get selectedCollection => _selectedCollection;
  Map<String, dynamic>? get selectedDocument => _selectedDocument;

  Future<void> openDatabase() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null) {
      await selectDatabase(path);
    }
  }

  Future<void> selectDatabase(String path) async {
    if (!_recentDatabasePaths.contains(path)) {
      _recentDatabasePaths.add(path);
    }
    
    if (_selectedDatabasePath != path) {
      _selectedDatabasePath = path;
      _selectedCollection = null;
      _selectedDocument = null;
      await _loadCollections();
    }
    notifyListeners();
  }

  void removeDatabase(String path) {
    _recentDatabasePaths.remove(path);
    if (_selectedDatabasePath == path) {
      _selectedDatabasePath = null;
      _collections = {};
      _selectedCollection = null;
      _selectedDocument = null;
    }
    notifyListeners();
  }

  void selectCollection(String collectionName) {
    if (_selectedDatabasePath != null) {
      _selectedCollection = collectionName;
      _selectedDocument = null;
      notifyListeners();
    }
  }

  void selectDocument(Map<String, dynamic>? doc) {
    _selectedDocument = doc;
    notifyListeners();
  }

  Future<void> _loadCollections() async {
    final path = _selectedDatabasePath;
    if (path == null) return;

    final adapter = StorageAdapterNative();
    try {
      final (store, _) = await KvStoreImpl.open(path, adapter);
      try {
        final names = await store.listNamespaces();
        final Map<String, int> newCollections = {};
        for (final name in names) {
          int count = 0;
          await for (final _ in store.scan(name)) {
            count++;
          }
          newCollections[name] = count;
        }
        _collections = newCollections;
      } finally {
        await store.close();
      }
    } catch (e) {
      _collections = {};
      debugPrint('Error loading collections: $e');
    }
    notifyListeners();
  }
}
