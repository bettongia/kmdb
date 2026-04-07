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

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';

class CollectionProvider with ChangeNotifier {
  final String _databasePath;
  final String _collectionName;
  final List<Map<String, dynamic>> _documents = [];
  int _displayLimit = 25;
  String _query = '';
  int _totalCount = 0;

  List<Map<String, dynamic>> get documents => _documents;
  int get displayLimit => _displayLimit;
  String get query => _query;
  String get collectionName => _collectionName;
  int get totalCount => _totalCount;

  CollectionProvider(this._databasePath, this._collectionName) {
    loadDocuments();
  }

  Future<void> loadDocuments() async {
    _documents.clear();
    _totalCount = 0;
    final adapter = StorageAdapterNative();
    try {
      final (store, _) = await KvStoreImpl.open(_databasePath, adapter);
      try {
        final stream = store.scan(_collectionName);
        int count = 0;
        await for (final entry in stream) {
          final doc = ValueCodec.decode(entry.value);
          _totalCount++;

          // Simple in-memory filter for the UI
          if (_query.isNotEmpty) {
            final docString = doc.toString().toLowerCase();
            if (!docString.contains(_query.toLowerCase())) continue;
          }

          if (_displayLimit == -1 || count < _displayLimit) {
            _documents.add(doc);
            count++;
          }
        }
      } finally {
        await store.close();
      }
    } catch (e) {
      _documents.add({'error': 'Failed to load documents: $e'});
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
      final decoded = json.decode(jsonContent);
      final Map<String, dynamic> doc;
      if (decoded is Map<String, dynamic>) {
        doc = decoded;
      } else {
        throw const FormatException('Input must be a JSON object.');
      }

      final key = const UuidV7KeyGenerator().next();
      doc['_id'] = key;
      final encoded = ValueCodec.encode(doc);

      final adapter = StorageAdapterNative();
      final (store, _) = await KvStoreImpl.open(_databasePath, adapter);
      try {
        await store.put(_collectionName, key, encoded);
      } finally {
        await store.close();
      }

      await loadDocuments();
    } catch (e) {
      _documents.add({'error': 'Failed to add document: $e'});
      notifyListeners();
    }
  }
}
