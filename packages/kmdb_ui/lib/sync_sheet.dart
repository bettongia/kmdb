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

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:provider/provider.dart';

import 'app_provider.dart';

/// Shows the sync and remote management bottom sheet.
///
/// On non-macOS platforms the sheet displays an informational message instead
/// of the sync controls, since filesystem-based sync requires macOS entitlements
/// and the [LocalDirectoryAdapter] uses dart:io directly.
void showSyncSheet(BuildContext context) {
  final appProvider = context.read<AppProvider>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: appProvider,
      child: const _SyncSheet(),
    ),
  );
}

class _SyncSheet extends StatefulWidget {
  const _SyncSheet();

  @override
  State<_SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<_SyncSheet> {
  Map<String, RemoteConfig> _remotes = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRemotes();
  }

  Future<void> _loadRemotes() async {
    final appProvider = context.read<AppProvider>();
    final remotes = await appProvider.remotes();
    if (mounted) {
      setState(() {
        _remotes = remotes;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
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

          // Header.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.sync_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sync & Remotes',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh',
                  onPressed: () {
                    setState(() => _loading = true);
                    _loadRemotes();
                  },
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Body.
          Expanded(
            child: defaultTargetPlatform != TargetPlatform.macOS
                ? _buildUnsupportedPlatform(context)
                : _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _buildContent(context, scrollController),
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupportedPlatform(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.sync_disabled,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Sync is not available on this platform.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Filesystem-based sync requires macOS.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ScrollController scrollController,
  ) {
    final appProvider = context.watch<AppProvider>();

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        // ── Remotes section ───────────────────────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'REMOTES',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Remote'),
              onPressed: () => _showAddRemoteDialog(context, appProvider),
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (_remotes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No remotes configured. Add a remote to enable sync.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          )
        else
          ..._remotes.entries.map(
            (entry) => _RemoteTile(
              name: entry.key,
              remote: entry.value,
              appProvider: appProvider,
              onChanged: _loadRemotes,
            ),
          ),

        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),

        // ── Quick sync row (only when remotes exist) ───────────────────────
        if (_remotes.isNotEmpty) ...[
          Text(
            'QUICK SYNC',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          if (_remotes.length == 1)
            _SyncButtons(
              remoteName: _remotes.keys.first,
              appProvider: appProvider,
            )
          else
            ..._remotes.keys.map(
              (name) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 4),
                  _SyncButtons(remoteName: name, appProvider: appProvider),
                  const SizedBox(height: 8),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _showAddRemoteDialog(
    BuildContext context,
    AppProvider appProvider,
  ) async {
    final nameController = TextEditingController();
    String? selectedPath;
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add Remote'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. origin',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selectedPath ?? 'No directory selected',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: selectedPath == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      final path = await FilePicker.getDirectoryPath();
                      if (path != null) {
                        setState(() {
                          selectedPath = path;
                          errorText = null;
                        });
                      }
                    },
                    child: const Text('Browse…'),
                  ),
                ],
              ),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorText!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  setState(() => errorText = 'Name cannot be empty.');
                  return;
                }
                if (selectedPath == null) {
                  setState(() => errorText = 'Select a sync directory.');
                  return;
                }

                final err = await appProvider.addRemote(name, selectedPath!);
                if (err != null) {
                  setState(() => errorText = err);
                } else if (context.mounted) {
                  Navigator.pop(context);
                  _loadRemotes();
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
  }
}

// ── Remote tile ───────────────────────────────────────────────────────────────

class _RemoteTile extends StatelessWidget {
  const _RemoteTile({
    required this.name,
    required this.remote,
    required this.appProvider,
    required this.onChanged,
  });

  final String name;
  final RemoteConfig remote;
  final AppProvider appProvider;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final subtitle = remote is LocalRemoteConfig
        ? (remote as LocalRemoteConfig).path
        : remote.type;

    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(name),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 20),
        color: Theme.of(context).colorScheme.error,
        tooltip: 'Remove remote',
        onPressed: () => _confirmRemove(context),
      ),
      dense: true,
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Remote'),
        content: Text(
          'Remove the remote "$name"?\n\n'
          'This only removes the configuration entry — it does not delete any '
          'files in the sync folder.',
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final err = await appProvider.removeRemote(name);
      if (err != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err)));
      } else {
        onChanged();
      }
    }
  }
}

// ── Sync buttons for one remote ───────────────────────────────────────────────

class _SyncButtons extends StatelessWidget {
  const _SyncButtons({required this.remoteName, required this.appProvider});

  final String remoteName;
  final AppProvider appProvider;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.upload_outlined, size: 16),
          label: const Text('Push'),
          onPressed: () => _run(
            context,
            'Pushing to "$remoteName"…',
            () => appProvider.pushTo(remoteName),
            'Push to "$remoteName" complete.',
          ),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('Pull'),
          onPressed: () => _run(
            context,
            'Pulling from "$remoteName"…',
            () => appProvider.pullFrom(remoteName),
            'Pull from "$remoteName" complete.',
          ),
        ),
        FilledButton.tonal(
          onPressed: () => _run(
            context,
            'Syncing with "$remoteName"…',
            () => appProvider.syncWith(remoteName),
            'Sync with "$remoteName" complete.',
          ),
          child: const Text('Sync'),
        ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    String busyMessage,
    Future<String?> Function() action,
    String successMessage,
  ) async {
    final err = await appProvider.runBusy(busyMessage, action);
    if (!context.mounted) return;

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    }
  }
}
