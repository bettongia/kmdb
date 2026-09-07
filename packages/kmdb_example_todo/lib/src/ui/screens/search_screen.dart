// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// coverage:ignore-file

import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';

import '../../models/task.dart';
import '../../repositories/task_repository.dart';
import 'task_detail_screen.dart';

/// The two search surfaces this screen toggles between.
enum _SearchTarget {
  /// `KmdbCollection.search()` over task title/description (BM25).
  taskFields,

  /// `KmdbCollection.searchVault()` over extracted attachment text.
  attachmentContent,
}

/// Screen 5 of 6 — "Search".
///
/// Demonstrates both text-search surfaces from spec §20–23 and §32: field FTS
/// (`TaskRepository.collection.search`) and attachment-content search
/// (`TaskRepository.collection.searchVault`), both using
/// [SearchMode.lexical] — see the guide's "going further" callout for
/// semantic/hybrid mode and `PdfTextExtractor`.
class SearchScreen extends StatefulWidget {
  /// Creates the [SearchScreen] for [db].
  const SearchScreen({required this.db, super.key});

  /// The open database.
  final KmdbDatabase db;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TaskRepository _taskRepo = TaskRepository(widget.db);
  final _queryController = TextEditingController();
  _SearchTarget _target = _SearchTarget.taskFields;

  List<SearchHit<Task>> _taskHits = const [];
  List<VaultSearchHit<Task>> _vaultHits = const [];
  bool _searching = false;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _taskHits = const [];
        _vaultHits = const [];
      });
      return;
    }

    setState(() => _searching = true);
    try {
      switch (_target) {
        case _SearchTarget.taskFields:
          final result = await _taskRepo.collection.search(
            query,
            fields: const ['title', 'description'],
            mode: SearchMode.lexical,
          );
          setState(() => _taskHits = result.hits);
        case _SearchTarget.attachmentContent:
          final result = await _taskRepo.collection.searchVault(
            query,
            mode: SearchMode.lexical,
          );
          setState(() => _vaultHits = result.hits);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: 'Search mode',
              child: SegmentedButton<_SearchTarget>(
                segments: const [
                  ButtonSegment(
                    value: _SearchTarget.taskFields,
                    label: Text('Task fields'),
                    icon: Icon(Icons.description_outlined),
                  ),
                  ButtonSegment(
                    value: _SearchTarget.attachmentContent,
                    label: Text('Attachment content'),
                    icon: Icon(Icons.attach_file),
                  ),
                ],
                selected: {_target},
                onSelectionChanged: (s) {
                  setState(() {
                    _target = s.first;
                    _taskHits = const [];
                    _vaultHits = const [];
                  });
                },
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _queryController,
              decoration: InputDecoration(
                labelText: 'Search',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Run search',
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            if (_searching) const LinearProgressIndicator(),
            Expanded(
              child: switch (_target) {
                _SearchTarget.taskFields => ListView.builder(
                  itemCount: _taskHits.length,
                  itemBuilder: (context, index) {
                    final hit = _taskHits[index];
                    return ListTile(
                      title: Text(hit.document.title),
                      subtitle: Text('score ${hit.score.toStringAsFixed(3)}'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              TaskDetailScreen(db: widget.db, taskId: hit.id),
                        ),
                      ),
                    );
                  },
                ),
                _SearchTarget.attachmentContent => ListView.builder(
                  itemCount: _vaultHits.length,
                  itemBuilder: (context, index) {
                    final hit = _vaultHits[index];
                    return ListTile(
                      title: Text(hit.document.title),
                      subtitle: Text(hit.chunkContext.snippet),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              TaskDetailScreen(db: widget.db, taskId: hit.id),
                        ),
                      ),
                    );
                  },
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
