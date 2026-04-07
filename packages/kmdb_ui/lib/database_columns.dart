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
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_json_view/flutter_json_view.dart';
import 'dart:convert';
import 'database_provider.dart';
import 'collection_provider.dart';
import 'add_document_dialog.dart';

class DatabaseHistoryColumn extends StatelessWidget {
  const DatabaseHistoryColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'DATABASES',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: provider.recentDatabasePaths.length,
              itemBuilder: (context, index) {
                final path = provider.recentDatabasePaths[index];
                final isSelected = provider.selectedDatabasePath == path;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                  child: ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    selected: isSelected,
                    selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4),
                    title: Text(
                      p.basename(path),
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Theme.of(context).colorScheme.primary : null,
                      ),
                    ),
                    leading: isSelected 
                      ? Icon(Icons.storage, size: 18, color: Theme.of(context).colorScheme.primary)
                      : const Icon(Icons.storage_outlined, size: 18),
                    onTap: () => provider.selectDatabase(path),
                    trailing: isSelected
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 14),
                            onPressed: () => provider.removeDatabase(path),
                          ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class CollectionListColumn extends StatelessWidget {
  const CollectionListColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final isVisible = provider.selectedDatabasePath != null;

    if (!isVisible) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'COLLECTIONS',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.secondary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: provider.collections.length,
              itemBuilder: (context, index) {
                final name = provider.collections[index];
                final count = provider.getCollectionCount(name);
                final isSelected = provider.selectedCollection == name;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                  child: ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    selected: isSelected,
                    selectedTileColor: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.4),
                    title: Text(
                      name,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Theme.of(context).colorScheme.secondary : null,
                      ),
                    ),
                    trailing: Text(
                      '$count',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onTap: () => provider.selectCollection(name),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class DocumentContentColumn extends StatefulWidget {
  const DocumentContentColumn({super.key});

  @override
  State<DocumentContentColumn> createState() => _DocumentContentColumnState();
}

class _DocumentContentColumnState extends State<DocumentContentColumn> {
  final _queryController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final databaseProvider = context.watch<DatabaseProvider>();
    final collectionProvider = context.watch<CollectionProvider?>();

    if (collectionProvider == null) {
      return const Expanded(
        child: Center(child: Text('Select a collection')),
      );
    }

    _queryController.text = collectionProvider.query;

    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        children: [
          AppBar(
            title: Text(
              '${collectionProvider.collectionName} (${collectionProvider.totalCount})',
              style: const TextStyle(fontSize: 14),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.add, size: 18),
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
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _queryController,
              decoration: const InputDecoration(
                hintText: 'Filter...',
                prefixIcon: Icon(Icons.search, size: 16),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => collectionProvider.setQuery(value),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: collectionProvider.documents.length,
              itemBuilder: (context, index) {
                final document = collectionProvider.documents[index];
                final isSelected =
                    databaseProvider.selectedDocument?['_id'] == document['_id'];
                
                final title = document['title'] ??
                    document['name'] ??
                    document['subject'] ??
                    'Document';
                
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                  child: ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    selected: isSelected,
                    selectedTileColor: Theme.of(context).colorScheme.tertiaryContainer.withOpacity(0.4),
                    title: Text(
                      title,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Theme.of(context).colorScheme.tertiary : null,
                      ),
                    ),
                    subtitle: Text(
                      document['_id'] ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onTap: () => databaseProvider.selectDocument(document),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class DocumentDetailColumn extends StatelessWidget {
  const DocumentDetailColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final doc = provider.selectedDocument;

    if (doc == null) {
      return const SizedBox.shrink();
    }

    return Expanded(
      flex: 2,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppBar(
              title: const Text('Details', style: TextStyle(fontSize: 16)),
              actions: [
                IconButton(
                  tooltip: 'Copy JSON',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                        text: const JsonEncoder.withIndent('  ').convert(doc)));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        behavior: SnackBarBehavior.floating,
                        width: 200,
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => provider.selectDocument(null),
                ),
              ],
            ),
            Expanded(
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: JsonView.map(
                    doc,
                    theme: JsonViewTheme(
                      viewType: JsonViewType.collapsible,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      keyStyle: GoogleFonts.robotoMono(
                        color: Colors.indigo.shade800,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      stringStyle: GoogleFonts.robotoMono(
                        color: Colors.teal.shade700,
                        fontSize: 13,
                      ),
                      intStyle: GoogleFonts.robotoMono(
                        color: Colors.orange.shade800,
                        fontSize: 13,
                      ),
                      doubleStyle: GoogleFonts.robotoMono(
                        color: Colors.orange.shade800,
                        fontSize: 13,
                      ),
                      boolStyle: GoogleFonts.robotoMono(
                        color: Colors.pink.shade700,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
