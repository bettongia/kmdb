// Copyright 2026 The Authors
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

import 'app_provider.dart';
import 'collection_provider.dart';
import 'new_collection_dialog.dart';
import 'add_document_dialog.dart';
import 'edit_document_dialog.dart';
import 'search_sheet.dart';
import 'schema_sheet.dart';
import 'secondary_index_sheet.dart';
import 'import_export_dialogs.dart';
import 'database_info_sheet.dart';
import 'sync_sheet.dart';
import 'layout/adaptive_layout.dart';

/// Column showing the list of recently opened databases.
class DatabaseHistoryColumn extends StatelessWidget {
  const DatabaseHistoryColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'DATABASES',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: provider.recentDatabasePaths.length,
              itemBuilder: (context, index) {
                final path = provider.recentDatabasePaths[index];
                final isSelected = provider.selectedDatabasePath == path;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 2.0,
                  ),
                  child: _DatabaseTile(
                    path: path,
                    isSelected: isSelected,
                    provider: provider,
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

/// Custom tile for a database list entry.
///
/// Uses a plain [Row] instead of [ListTile] so the close button can be
/// top-aligned with the database name rather than centred across the full
/// tile height (which includes the subtitle actions row).
class _DatabaseTile extends StatelessWidget {
  const _DatabaseTile({
    required this.path,
    required this.isSelected,
    required this.provider,
  });

  final String path;
  final bool isSelected;
  final AppProvider provider;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final selectedBg = Theme.of(
      context,
    ).colorScheme.primaryContainer.withValues(alpha: 0.4);

    return Material(
      color: isSelected ? selectedBg : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => provider.selectDatabase(path),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Leading icon — top-aligned with the name.
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 16),
                child: isSelected
                    ? Icon(Icons.storage, size: 18, color: primaryColor)
                    : const Icon(Icons.storage_outlined, size: 18),
              ),
              // Name + actions.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(path),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected ? primaryColor : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _DatabaseActions(
                      path: path,
                      provider: provider,
                      isSelected: isSelected,
                    ),
                  ],
                ),
              ),
              // Close button — top-aligned with the name.
              IconButton(
                icon: const Icon(Icons.close, size: 14),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                onPressed: () => provider.removeDatabase(path),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact row of action buttons shown beneath each database name.
///
/// Selecting a non-current database is handled automatically: tapping an
/// action first opens the database if it isn't already selected, then shows
/// the relevant sheet.
class _DatabaseActions extends StatelessWidget {
  const _DatabaseActions({
    required this.path,
    required this.provider,
    required this.isSelected,
  });

  final String path;
  final AppProvider provider;
  final bool isSelected;

  Future<void> _open(BuildContext context) async {
    if (!isSelected) await provider.selectDatabase(path);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionChip(
          icon: Icons.sync_outlined,
          label: 'Sync',
          color: color,
          onTap: () async {
            await _open(context);
            if (context.mounted) showSyncSheet(context);
          },
        ),
        const SizedBox(width: 6),
        _ActionChip(
          icon: Icons.info_outline,
          label: 'Info',
          color: color,
          onTap: () async {
            await _open(context);
            if (context.mounted) showDatabaseInfoSheet(context);
          },
        ),
      ],
    );
  }
}

/// Tiny icon + label button used inside [_DatabaseActions].
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}

/// Column showing all collections in the open database.
///
/// Right-click (secondary tap) on a collection shows a context menu with a
/// Delete option. Deletion requires explicit confirmation.
class CollectionListColumn extends StatelessWidget {
  const CollectionListColumn({super.key});

  void _confirmDelete(BuildContext context, AppProvider provider, String name) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Collection'),
        content: Text(
          'Delete "$name" and all its documents?\n\n'
          'This action cannot be undone.',
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
              await provider.runBusy(
                'Deleting collection "$name"…',
                () => provider.deleteCollection(name),
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
    final provider = context.watch<AppProvider>();
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
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Back button shown only in narrow layout.
                if (MediaQuery.of(context).size.width <
                    LayoutBreakpoints.multiColumn)
                  IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
                    tooltip: 'Back to Databases',
                    onPressed: () => provider.deselectDatabase(),
                  ),
                Text(
                  'COLLECTIONS',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.secondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'Add Collection',
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => const NewCollectionDialog(),
                    );
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: provider.isOpening
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2),
                        SizedBox(height: 16),
                        Text(
                          'Opening database...',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : provider.loadError != null
                ? Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 24,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Error loading collections:',
                          style: Theme.of(context).textTheme.titleSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          provider.loadError!,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: provider.collections.length,
                    itemBuilder: (context, index) {
                      final name = provider.collections[index];
                      final count = provider.getCollectionCount(name);
                      final isSelected = provider.selectedCollection == name;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 2.0,
                        ),
                        child: GestureDetector(
                          onSecondaryTap: () =>
                              _confirmDelete(context, provider, name),
                          child: ListTile(
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            selected: isSelected,
                            selectedTileColor: Theme.of(context)
                                .colorScheme
                                .secondaryContainer
                                .withValues(alpha: 0.4),
                            title: Text(
                              name,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.secondary
                                    : null,
                              ),
                            ),
                            trailing: Text(
                              '$count',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                            ),
                            onTap: () => provider.selectCollection(name),
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

/// Column showing the document list for the selected collection.
///
/// Features:
/// - Text filter field (wired to [CollectionProvider.setQuery]).
/// - Sort row: order-by field name text field and ASC/DESC toggle.
/// - Auto-refresh toggle via [CollectionProvider.setAutoRefresh].
/// - Manual refresh button when auto-refresh is off.
/// - Find-by-ID button that opens an input dialog.
/// - Pagination bar (page size selector + prev/next page controls).
class DocumentContentColumn extends StatefulWidget {
  const DocumentContentColumn({super.key});

  @override
  State<DocumentContentColumn> createState() => _DocumentContentColumnState();
}

class _DocumentContentColumnState extends State<DocumentContentColumn> {
  final _queryController = TextEditingController();
  final _sortFieldController = TextEditingController();

  static const List<int?> _pageSizeOptions = [10, 25, 50, null];

  @override
  void dispose() {
    _queryController.dispose();
    _sortFieldController.dispose();
    super.dispose();
  }

  Future<void> _showFindByIdDialog(
    BuildContext context,
    CollectionProvider collectionProvider,
    AppProvider appProvider,
  ) async {
    final controller = TextEditingController();
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Find Document by ID'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Document ID',
              hintText: 'Enter the UUIDv7 key',
              border: const OutlineInputBorder(),
              errorText: errorText,
            ),
            onSubmitted: (_) async {
              final id = controller.text.trim();
              if (id.isEmpty) return;
              final doc = await collectionProvider.getDocumentById(id);
              if (doc != null) {
                // Pop before notifying so no dialog widgets rebuild mid-dismiss.
                if (context.mounted) Navigator.pop(context);
                appProvider.selectDocument(doc);
              } else {
                setDialogState(
                  () => errorText = 'No document found with that ID.',
                );
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final id = controller.text.trim();
                if (id.isEmpty) return;
                final doc = await collectionProvider.getDocumentById(id);
                if (doc != null) {
                  if (context.mounted) Navigator.pop(context);
                  appProvider.selectDocument(doc);
                } else {
                  setDialogState(
                    () => errorText = 'No document found with that ID.',
                  );
                }
              },
              child: const Text('Find'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final collectionProvider = context.watch<CollectionProvider?>();

    if (collectionProvider == null) {
      return const Center(child: Text('Select a collection'));
    }

    // Keep the filter text field in sync with provider state without looping.
    final currentQuery = collectionProvider.query;
    if (_queryController.text != currentQuery) {
      _queryController.text = currentQuery;
    }

    final opts = collectionProvider.scanOptions;
    final limit = opts.limit ?? 25;
    final offset = opts.offset;
    final currentPage = offset ~/ limit + 1;
    final totalPages = collectionProvider.totalCount == 0
        ? 1
        : (collectionProvider.totalCount / limit).ceil();
    final hasPrev = offset > 0;
    final hasNext = offset + limit < collectionProvider.totalCount;

    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        children: [
          AppBar(
            leading:
                MediaQuery.of(context).size.width <
                    LayoutBreakpoints.multiColumn
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back to Collections',
                    onPressed: () => appProvider.clearCollectionSelection(),
                  )
                : null,
            title: Text(
              '${collectionProvider.collectionName}'
              ' (${collectionProvider.totalCount})',
              style: const TextStyle(fontSize: 14),
            ),
            actions: [
              if (appProvider.hasFtsCapability)
                IconButton(
                  icon: const Icon(Icons.manage_search, size: 18),
                  tooltip: 'Search & FTS Indexes',
                  onPressed: () => showSearchSheet(
                    context,
                    collectionProvider.collectionName,
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.search, size: 18),
                tooltip: 'Find by ID',
                onPressed: () => _showFindByIdDialog(
                  context,
                  collectionProvider,
                  appProvider,
                ),
              ),
              IconButton(
                icon: Icon(
                  collectionProvider.autoRefresh
                      ? Icons.sync
                      : Icons.sync_disabled,
                  size: 18,
                ),
                tooltip: collectionProvider.autoRefresh
                    ? 'Auto-refresh on — tap to disable'
                    : 'Auto-refresh off — tap to enable',
                onPressed: () => collectionProvider.setAutoRefresh(
                  !collectionProvider.autoRefresh,
                ),
              ),
              if (!collectionProvider.autoRefresh)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Refresh documents',
                  onPressed: collectionProvider.loadDocuments,
                ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                tooltip: 'Add Document',
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => AddDocumentDialog(
                      onAddJson: (json) async {
                        await collectionProvider.addDocument(json);
                        await appProvider.refreshCollections();
                      },
                    ),
                  );
                },
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                tooltip: 'More actions',
                onSelected: (value) {
                  final col = collectionProvider.collectionName;
                  switch (value) {
                    case 'schema':
                      showSchemaSheet(context, col);
                    case 'indexes':
                      showSecondaryIndexSheet(context, col);
                    case 'export':
                      showExportCollectionDialog(context, col, appProvider);
                    case 'import':
                      showImportCollectionDialog(context, col, appProvider);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'schema',
                    child: ListTile(
                      leading: Icon(Icons.rule_outlined),
                      title: Text('Schema'),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'indexes',
                    child: ListTile(
                      leading: Icon(Icons.account_tree_outlined),
                      title: Text('Secondary Indexes'),
                      dense: true,
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                      leading: Icon(Icons.upload_outlined),
                      title: Text('Export Collection…'),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'import',
                    child: ListTile(
                      leading: Icon(Icons.download_outlined),
                      title: Text('Import Collection…'),
                      dense: true,
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Filter row.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: TextField(
              controller: _queryController,
              decoration: const InputDecoration(
                hintText: 'Filter...',
                prefixIcon: Icon(Icons.filter_list, size: 16),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => collectionProvider.setQuery(value),
            ),
          ),

          // Sort row: order-by field + ASC/DESC toggle.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sortFieldController,
                    decoration: const InputDecoration(
                      hintText: 'Sort field (optional)',
                      prefixIcon: Icon(Icons.sort, size: 16),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) {
                      final field = value.trim().isEmpty ? null : value.trim();
                      collectionProvider.setScanOptions(
                        opts.copyWith(
                          orderByField: field,
                          clearOrderByField: field == null,
                          offset: 0,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    opts.descending ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 18,
                  ),
                  tooltip: opts.descending ? 'Descending' : 'Ascending',
                  onPressed: () {
                    collectionProvider.setScanOptions(
                      opts.copyWith(descending: !opts.descending, offset: 0),
                    );
                  },
                ),
              ],
            ),
          ),

          if (collectionProvider.isLoading)
            const LinearProgressIndicator(minHeight: 2),

          Expanded(
            child: ListView.builder(
              itemCount: collectionProvider.documents.length,
              itemBuilder: (context, index) {
                final document = collectionProvider.documents[index];
                final isSelected =
                    appProvider.selectedDocument?['_id'] == document['_id'];

                final title =
                    document['title'] ??
                    document['name'] ??
                    document['subject'] ??
                    'Document';

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 2.0,
                  ),
                  child: ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    selected: isSelected,
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.tertiaryContainer.withValues(alpha: 0.4),
                    title: Text(
                      title.toString(),
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? Theme.of(context).colorScheme.tertiary
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      document['_id']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete Document',
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Document'),
                            content: const Text(
                              'Are you sure you want to delete this document?'
                              ' This action cannot be undone.',
                            ),
                            actions: [
                              TextButton(
                                child: const Text('Cancel'),
                                onPressed: () => Navigator.pop(context),
                              ),
                              TextButton(
                                child: const Text(
                                  'Delete',
                                  style: TextStyle(color: Colors.red),
                                ),
                                onPressed: () async {
                                  Navigator.pop(context);
                                  final id = document['_id']?.toString();
                                  if (id != null) {
                                    await collectionProvider.deleteDocument(id);
                                    await appProvider.refreshCollections();
                                    if (isSelected) {
                                      appProvider.selectDocument(null);
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    onTap: () => appProvider.selectDocument(document),
                  ),
                );
              },
            ),
          ),

          // Pagination bar.
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                // Page size selector.
                DropdownButton<int?>(
                  value: opts.limit,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: _pageSizeOptions
                      .map(
                        (n) => DropdownMenuItem(
                          value: n,
                          child: Text(
                            n == null ? 'All' : '$n',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (n) {
                    collectionProvider.setScanOptions(
                      opts.copyWith(limit: n, clearLimit: n == null, offset: 0),
                    );
                  },
                ),
                const SizedBox(width: 4),
                Text('per page', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                // Page info.
                Text(
                  opts.limit == null
                      ? 'All ${collectionProvider.totalCount}'
                      : 'Page $currentPage of $totalPages',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                // Prev / next buttons.
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 18),
                  tooltip: 'Previous page',
                  onPressed: hasPrev
                      ? () {
                          collectionProvider.setScanOptions(
                            opts.copyWith(
                              offset: (offset - limit).clamp(0, offset),
                            ),
                          );
                        }
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 18),
                  tooltip: 'Next page',
                  onPressed: hasNext
                      ? () {
                          collectionProvider.setScanOptions(
                            opts.copyWith(offset: offset + limit),
                          );
                        }
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Column showing the full JSON detail of the selected document.
///
/// The Edit button opens [EditDocumentDialog] to update the document in place.
class DocumentDetailColumn extends StatelessWidget {
  const DocumentDetailColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final collectionProvider = context.watch<CollectionProvider?>();
    final doc = appProvider.selectedDocument;

    if (doc == null) {
      return const SizedBox.shrink();
    }

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(
            leading:
                MediaQuery.of(context).size.width <
                    LayoutBreakpoints.multiColumn
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back to Documents',
                    onPressed: () => appProvider.selectDocument(null),
                  )
                : null,
            title: const Text('Details', style: TextStyle(fontSize: 16)),
            actions: [
              if (collectionProvider != null)
                IconButton(
                  tooltip: 'Edit Document',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => EditDocumentDialog(
                        document: doc,
                        onSave: (json) async {
                          final id = doc['_id'] as String;
                          await collectionProvider.updateDocument(id, json);
                          // Refresh the selected document to show updated content.
                          final updated = await collectionProvider
                              .getDocumentById(id);
                          if (updated != null) {
                            appProvider.selectDocument(updated);
                          }
                          await appProvider.refreshCollections();
                        },
                      ),
                    );
                  },
                ),
              IconButton(
                tooltip: 'Copy JSON',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: const JsonEncoder.withIndent('  ').convert(doc),
                    ),
                  );
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
                onPressed: () => appProvider.selectDocument(null),
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
    );
  }
}
