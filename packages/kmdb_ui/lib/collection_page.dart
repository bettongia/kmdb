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
import 'package:provider/provider.dart';

import 'collection_provider.dart';
import 'document_page.dart';
import 'add_document_dialog.dart';

class CollectionPage extends StatefulWidget {
  const CollectionPage({super.key});

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  final _queryController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final collectionProvider = Provider.of<CollectionProvider>(context);
    _queryController.text = collectionProvider.query;

    return Scaffold(
      appBar: AppBar(
        title: Text('Collection: ${collectionProvider.collectionName}'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    decoration: const InputDecoration(
                      hintText: 'Query documents',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => collectionProvider.setQuery(value),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _queryController.clear();
                    collectionProvider.setQuery('');
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text('Show: '),
                DropdownButton<int>(
                  value: collectionProvider.displayLimit,
                  onChanged: (int? newValue) {
                    if (newValue != null) {
                      collectionProvider.setDisplayLimit(newValue);
                    }
                  },
                  items: const [
                    DropdownMenuItem(value: 25, child: Text('25')),
                    DropdownMenuItem(value: 50, child: Text('50')),
                    DropdownMenuItem(value: 100, child: Text('100')),
                    DropdownMenuItem(value: 200, child: Text('200')),
                    DropdownMenuItem(value: -1, child: Text('All')),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: collectionProvider.documents.length,
              itemBuilder: (context, index) {
                final document = collectionProvider.documents[index];
                return ListTile(
                  title: Text(document['__filename'] ?? 'No filename'),
                  subtitle: Text(
                    document.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DocumentPage(document: document),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showDialog(
            context: context,
            builder: (_) => AddDocumentDialog(
              onAddJson: (json) {
                collectionProvider.addDocument(json);
              },
            ),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
