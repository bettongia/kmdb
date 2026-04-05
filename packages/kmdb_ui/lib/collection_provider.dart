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
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class CollectionProvider with ChangeNotifier {
  final Directory _collectionDirectory;
  final List<Map<String, dynamic>> _documents = [];
  int _displayLimit = 25;
  String _query = '';

  List<Map<String, dynamic>> get documents => _documents;
  int get displayLimit => _displayLimit;
  String get query => _query;
  String get collectionName => p.basename(_collectionDirectory.path);

  CollectionProvider(this._collectionDirectory) {
    loadDocuments();
  }

  void loadDocuments() {
    _documents.clear();
    try {
      final files = _collectionDirectory.listSync().where(
        (entity) => entity is File && p.extension(entity.path) == '.json',
      );

      var filteredFiles = files;
      if (_query.isNotEmpty) {
        filteredFiles = files.where((file) {
          try {
            final content = File(file.path).readAsStringSync();
            return content.contains(_query);
          } catch (e) {
            return false;
          }
        });
      }

      var limitedFiles = (_displayLimit == -1)
          ? filteredFiles
          : filteredFiles.take(_displayLimit);

      for (var fileEntity in limitedFiles) {
        try {
          final file = File(fileEntity.path);
          final content = file.readAsStringSync();
          final data = jsonDecode(content) as Map<String, dynamic>;
          data['__filename'] = p.basename(file.path);
          _documents.add(data);
        } catch (e) {
          _documents.add({
            '__filename': p.basename(fileEntity.path),
            '__error': 'Failed to load document: $e',
          });
        }
      }
    } catch (e) {
      _documents.add({
        '__filename': 'Error',
        '__error': 'Failed to read collection directory: $e',
      });
    }
    notifyListeners();
  }

  void setDisplayLimit(int limit) {
    if (_displayLimit != limit) {
      _displayLimit = limit;
      loadDocuments();
    }
  }

  void setQuery(String query) {
    if (_query != query) {
      _query = query;
      loadDocuments();
    }
  }

  Future<void> addDocument(String jsonContent) async {
    try {
      final decodedJson = jsonDecode(jsonContent);
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final filename = '$id.json';
      final file = File(p.join(_collectionDirectory.path, filename));
      await file.writeAsString(jsonEncode(decodedJson));
      loadDocuments();
    } catch (e) {
      // Handle error
      print('Error adding document: $e');
    }
  }
}
