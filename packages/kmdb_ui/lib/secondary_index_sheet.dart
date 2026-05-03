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
import 'package:kmdb/kmdb.dart';
import 'package:provider/provider.dart';

import 'app_provider.dart';

/// Shows the secondary-index management bottom sheet for [collectionName].
void showSecondaryIndexSheet(BuildContext context, String collectionName) {
  final appProvider = context.read<AppProvider>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: appProvider,
      child: _SecondaryIndexSheet(collectionName: collectionName),
    ),
  );
}

class _SecondaryIndexSheet extends StatelessWidget {
  const _SecondaryIndexSheet({required this.collectionName});

  final String collectionName;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _SecondaryIndexContent(
        collectionName: collectionName,
        scrollController: scrollController,
      ),
    );
  }
}

class _SecondaryIndexContent extends StatelessWidget {
  const _SecondaryIndexContent({
    required this.collectionName,
    required this.scrollController,
  });

  final String collectionName;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final paths = appProvider.secondaryIndexPathsForCollection(collectionName);

    return Column(
      children: [
        // Handle bar.
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Header row.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Secondary Indexes — $collectionName',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilledButton.tonal(
                onPressed: () =>
                    _showCreateDialog(context, appProvider),
                child: const Text('Create'),
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Body.
        if (paths.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.account_tree_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No secondary indexes for "$collectionName".',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap Create to add a field-path index.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              controller: scrollController,
              itemCount: paths.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final path = paths[index];
                return _IndexTile(
                  collectionName: collectionName,
                  path: path,
                  appProvider: appProvider,
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _showCreateDialog(
    BuildContext context,
    AppProvider appProvider,
  ) async {
    final controller = TextEditingController();
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Create Index — $collectionName'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Field path',
              hintText: 'e.g. email  or  address.city  or  tags[]',
              border: const OutlineInputBorder(),
              errorText: errorText,
            ),
            onSubmitted: (_) => _submit(context, setState, controller,
                appProvider, (e) => errorText = e),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => _submit(
                context, setState, controller, appProvider,
                (e) => errorText = e,
              ),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _submit(
    BuildContext context,
    StateSetter setState,
    TextEditingController controller,
    AppProvider appProvider,
    void Function(String?) setError,
  ) async {
    final path = controller.text.trim();
    if (path.isEmpty) {
      setState(() => setError('Field path cannot be empty.'));
      return;
    }
    if (path.startsWith('_')) {
      setState(() => setError('Field paths must not start with "_".'));
      return;
    }

    try {
      await appProvider.runBusy(
        'Creating index…',
        () => appProvider.createSecondaryIndex(collectionName, path),
      );
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => setError('Failed: $e'));
    }
  }
}

/// A single list tile for one secondary index, showing its status and a delete
/// action.
class _IndexTile extends StatefulWidget {
  const _IndexTile({
    required this.collectionName,
    required this.path,
    required this.appProvider,
  });

  final String collectionName;
  final String path;
  final AppProvider appProvider;

  @override
  State<_IndexTile> createState() => _IndexTileState();
}

class _IndexTileState extends State<_IndexTile> {
  IndexState? _state;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final state = await widget.appProvider.getIndexState(
      widget.collectionName,
      widget.path,
    );
    if (mounted) setState(() { _state = state; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final status = _state?.status;
    final statusLabel = _loading ? 'loading…' : _statusLabel(status);
    final statusColor = _statusColor(context, status);

    return ListTile(
      leading: Icon(Icons.account_tree_outlined, color: statusColor),
      title: Text(widget.path),
      subtitle: Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 11)),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 20),
        tooltip: 'Delete index',
        color: Theme.of(context).colorScheme.error,
        onPressed: () => _confirmDelete(context),
      ),
    );
  }

  String _statusLabel(IndexStatus? status) {
    return switch (status) {
      IndexStatus.undefined => 'pending first query',
      IndexStatus.building => 'building…',
      IndexStatus.current => 'current',
      IndexStatus.stale => 'stale — needs rebuild',
      null => 'unknown',
    };
  }

  Color _statusColor(BuildContext context, IndexStatus? status) {
    return switch (status) {
      IndexStatus.current => Theme.of(context).colorScheme.primary,
      IndexStatus.building => Colors.orange,
      IndexStatus.stale => Colors.orange,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Index'),
        content: Text(
          'Delete the secondary index on "${widget.path}" in '
          '"${widget.collectionName}"?\n\n'
          'The stored index data will be removed immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await widget.appProvider.runBusy(
        'Deleting index…',
        () => widget.appProvider.deleteSecondaryIndex(
          widget.collectionName,
          widget.path,
        ),
      );
    }
  }
}
