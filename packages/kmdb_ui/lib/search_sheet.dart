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
import 'package:kmdb/kmdb.dart';

import 'app_provider.dart';

/// Opens the search/FTS-index bottom sheet for [collectionName].
Future<void> showSearchSheet(BuildContext context, String collectionName) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<AppProvider>(),
      child: SearchSheet(collectionName: collectionName),
    ),
  );
}

/// A bottom sheet with two tabs: Search (BM25/lexical query) and Indexes
/// (FTS index management for the collection).
///
/// The sheet is stateful so that search results, query text, and the index form
/// are preserved while the sheet is open.
class SearchSheet extends StatefulWidget {
  /// The collection namespace to search / manage indexes for.
  final String collectionName;

  const SearchSheet({super.key, required this.collectionName});

  @override
  State<SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<SearchSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          // Drag handle.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Tab bar.
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.manage_search, size: 18), text: 'Search'),
              Tab(icon: Icon(Icons.tune, size: 18), text: 'Indexes'),
            ],
          ),
          // Tab content.
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _SearchTab(
                  collectionName: widget.collectionName,
                  scrollController: scrollController,
                ),
                _IndexesTab(
                  collectionName: widget.collectionName,
                  scrollController: scrollController,
                  onIndexChanged: () => _tabController.animateTo(0),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Search tab ────────────────────────────────────────────────────────────────

class _SearchTab extends StatefulWidget {
  final String collectionName;
  final ScrollController scrollController;

  const _SearchTab({
    required this.collectionName,
    required this.scrollController,
  });

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _queryController = TextEditingController();
  SearchMode _mode = SearchMode.lexical;
  SearchResult<Map<String, dynamic>>? _result;
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;

    final appProvider = context.read<AppProvider>();
    final db = appProvider.database;
    if (db == null) return;

    setState(() {
      _searching = true;
      _searchError = null;
      _result = null;
    });

    try {
      final col = db.rawCollection(widget.collectionName);
      final result = await col.search(query, mode: _mode, limit: 50);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _searchError = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final hasVec = appProvider.hasVecCapability;
    final indexedFields = appProvider.ftsIndexedFieldsForCollection(
      widget.collectionName,
    );
    final hasFts = indexedFields.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Query row.
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: hasFts
                        ? 'Search ${widget.collectionName}…'
                        : 'No FTS indexes — go to Indexes tab to create one',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
                  enabled: hasFts,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: hasFts && !_searching ? _search : null,
                child: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Search'),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Mode selector — always Lexical; add Semantic only when vecManager
          // is active (macOS + ONNX Runtime configured).
          SegmentedButton<SearchMode>(
            segments: [
              const ButtonSegment(
                value: SearchMode.lexical,
                label: Text('Lexical'),
                icon: Icon(Icons.text_fields, size: 16),
              ),
              const ButtonSegment(
                value: SearchMode.auto,
                label: Text('Auto'),
                icon: Icon(Icons.auto_awesome, size: 16),
              ),
              if (hasVec)
                const ButtonSegment(
                  value: SearchMode.semantic,
                  label: Text('Semantic'),
                  icon: Icon(Icons.psychology, size: 16),
                ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),

          const SizedBox(height: 12),

          // Results area.
          Expanded(child: _buildResults(context, appProvider)),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context, AppProvider appProvider) {
    if (_searchError != null) {
      return Center(
        child: Text(
          _searchError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }

    final result = _result;
    if (result == null) {
      return Center(
        child: Text(
          appProvider
                  .ftsIndexedFieldsForCollection(widget.collectionName)
                  .isEmpty
              ? 'Create an FTS index in the Indexes tab, then search.'
              : 'Enter a query and press Search.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (result.hits.isEmpty) {
      final skipped = result.metadata.skipped;
      return Center(
        child: Text(
          skipped.isNotEmpty
              ? 'No results. Fields without indexes: ${skipped.join(', ')}'
              : 'No results for "${result.metadata.query}".',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${result.hits.length} result${result.hits.length == 1 ? '' : 's'}'
          '${result.metadata.total > result.hits.length ? ' (of ${result.metadata.total})' : ''}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            controller: widget.scrollController,
            itemCount: result.hits.length,
            itemBuilder: (context, index) {
              final hit = result.hits[index];
              final doc = hit.document;
              final title =
                  doc['title'] ?? doc['name'] ?? doc['subject'] ?? hit.id;
              return ListTile(
                dense: true,
                leading: _RankBadge(rank: hit.rank),
                title: Text(title.toString()),
                subtitle: Text(
                  hit.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10),
                ),
                trailing: Text(
                  hit.score.toStringAsFixed(3),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontFamily: 'monospace',
                  ),
                ),
                onTap: () {
                  appProvider.selectDocument(doc);
                  Navigator.of(context).pop();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Small circular badge showing a search result rank.
class _RankBadge extends StatelessWidget {
  final int rank;
  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 12,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        '$rank',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

// ── Indexes tab ───────────────────────────────────────────────────────────────

class _IndexesTab extends StatelessWidget {
  final String collectionName;
  final ScrollController scrollController;

  /// Called after a successful create/delete so the caller can switch tabs.
  final VoidCallback onIndexChanged;

  const _IndexesTab({
    required this.collectionName,
    required this.scrollController,
    required this.onIndexChanged,
  });

  void _showCreateDialog(BuildContext context, AppProvider appProvider) {
    showDialog<void>(
      context: context,
      builder: (_) => _CreateIndexDialog(
        collectionName: collectionName,
        appProvider: appProvider,
        onCreated: onIndexChanged,
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    AppProvider appProvider,
    String field,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete FTS Index'),
        content: Text(
          'Remove the FTS index on "$field" in "$collectionName"?\n\n'
          'The index data will be deleted and the database will be reopened.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await appProvider.runBusy(
                'Removing FTS index…',
                () => appProvider.deleteFtsIndex(collectionName, field),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final fields = appProvider.ftsIndexedFieldsForCollection(collectionName);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'FTS INDEXES — $collectionName',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Create'),
                onPressed: () => _showCreateDialog(context, appProvider),
              ),
            ],
          ),

          const SizedBox(height: 12),

          if (fields.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  'No FTS indexes configured for this collection.\n'
                  'Tap Create to add one.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                itemCount: fields.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final field = fields[index];
                  final active =
                      appProvider.database?.ftsManager?.hasIndex(
                        collectionName,
                        field,
                      ) ??
                      false;

                  return ListTile(
                    leading: Icon(
                      Icons.text_snippet_outlined,
                      color: active
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                    ),
                    title: Text(field),
                    subtitle: Text(
                      active ? 'Active' : 'Registered (write to activate)',
                      style: TextStyle(
                        fontSize: 11,
                        color: active
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete index',
                      onPressed: () =>
                          _confirmDelete(context, appProvider, field),
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

// ── Create index dialog ───────────────────────────────────────────────────────

class _CreateIndexDialog extends StatefulWidget {
  final String collectionName;
  final AppProvider appProvider;
  final VoidCallback onCreated;

  const _CreateIndexDialog({
    required this.collectionName,
    required this.appProvider,
    required this.onCreated,
  });

  @override
  State<_CreateIndexDialog> createState() => _CreateIndexDialogState();
}

class _CreateIndexDialogState extends State<_CreateIndexDialog> {
  final _fieldController = TextEditingController();
  bool _stopWords = false;
  double _k1 = 1.2;
  double _b = 0.75;
  String? _fieldError;
  bool _saving = false;

  @override
  void dispose() {
    _fieldController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final field = _fieldController.text.trim();
    if (field.isEmpty) {
      setState(() => _fieldError = 'Field name is required.');
      return;
    }
    if (field.startsWith('_')) {
      setState(() => _fieldError = 'Field name must not start with "_".');
      return;
    }

    setState(() {
      _fieldError = null;
      _saving = true;
    });

    try {
      await widget.appProvider.runBusy(
        'Creating FTS index…',
        () => widget.appProvider.createFtsIndex(
          collection: widget.collectionName,
          field: field,
          stopWords: _stopWords,
          k1: _k1,
          b: _b,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onCreated();
      }
    } catch (e) {
      if (mounted) setState(() => _fieldError = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create FTS Index'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _fieldController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Field name',
                hintText: 'e.g. body, title, description',
                border: const OutlineInputBorder(),
                errorText: _fieldError,
                isDense: true,
              ),
              onSubmitted: (_) => _create(),
            ),

            const SizedBox(height: 16),

            SwitchListTile(
              title: const Text('Remove stopwords'),
              subtitle: const Text('Filter common English words (the, a, is…)'),
              value: _stopWords,
              onChanged: (v) => setState(() => _stopWords = v),
              contentPadding: EdgeInsets.zero,
            ),

            const SizedBox(height: 8),

            // BM25 k1 parameter.
            _SliderRow(
              label: 'k₁ (TF saturation)',
              value: _k1,
              min: 0.5,
              max: 3.0,
              divisions: 25,
              onChanged: (v) => setState(() => _k1 = v),
            ),

            // BM25 b parameter.
            _SliderRow(
              label: 'b (length normalisation)',
              value: _b,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: (v) => setState(() => _b = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _create,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

/// Compact slider row with label and formatted value.
class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          flex: 4,
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.toStringAsFixed(2),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
