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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

class DatabaseProvider with ChangeNotifier {
  Directory? _databaseDirectory;
  List<String> _collections = [];
  Directory? _selectedCollection;

  Directory? get databaseDirectory => _databaseDirectory;
  List<String> get collections => _collections;
  Directory? get selectedCollection => _selectedCollection;

  Future<void> selectDatabase() async {
    final selectedDirectory = await FilePicker.getDirectoryPath();

    if (selectedDirectory != null) {
      _databaseDirectory = Directory(selectedDirectory);
      _loadCollections();
      notifyListeners();
    }
  }

  void selectCollection(String collectionName) {
    if (_databaseDirectory != null) {
      _selectedCollection = Directory(
        p.join(_databaseDirectory!.path, collectionName),
      );
      notifyListeners();
    }
  }

  void _loadCollections() {
    if (_databaseDirectory != null) {
      _collections = _databaseDirectory!
          .listSync()
          .whereType<Directory>()
          .map((entity) => p.basename(entity.path))
          .toList();
    }
  }
}
