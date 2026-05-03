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
import 'package:kmdb/kmdb.dart';
import 'package:provider/provider.dart';

import 'app_provider.dart';
import 'import_export_dialogs.dart';

/// Shows the database info, stats, and maintenance bottom sheet.
void showDatabaseInfoSheet(BuildContext context) {
  final appProvider = context.read<AppProvider>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: appProvider,
      child: const _DatabaseInfoSheet(),
    ),
  );
}

class _DatabaseInfoSheet extends StatefulWidget {
  const _DatabaseInfoSheet();

  @override
  State<_DatabaseInfoSheet> createState() => _DatabaseInfoSheetState();
}

class _DatabaseInfoSheetState extends State<_DatabaseInfoSheet> {
  StoreInfo? _info;
  StoreStats? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final appProvider = context.read<AppProvider>();
    final info = await appProvider.storeInfo();
    final stats = await appProvider.storeStats();
    if (mounted) {
      setState(() {
        _info = info;
        _stats = stats;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
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
                const Icon(Icons.storage_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Database Info & Maintenance',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh',
                  onPressed: () {
                    setState(() => _loading = true);
                    _load();
                  },
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Body.
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_info != null) ...[
                        _SectionHeader('Database'),
                        _InfoRow('Directory', _info!.dbDir, copyable: true),
                        _InfoRow('Device ID', _info!.deviceId, copyable: true),
                        _InfoRow('Current HLC', _info!.currentHlc),
                        const SizedBox(height: 16),
                      ],

                      if (_stats != null) ...[
                        _SectionHeader('Storage'),
                        _InfoRow('L0 SSTables', '${_stats!.l0Count}'),
                        _InfoRow('L1 SSTables', '${_stats!.l1Count}'),
                        _InfoRow('L2 SSTables', '${_stats!.l2Count}'),
                        _InfoRow(
                          'SSTable size',
                          _formatBytes(_stats!.totalSstBytes),
                        ),
                        _InfoRow(
                          'Total DB size',
                          _formatBytes(_stats!.totalDbBytes),
                        ),
                        const SizedBox(height: 16),
                      ],

                      _SectionHeader('Actions'),
                      const SizedBox(height: 8),

                      // Maintenance buttons.
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _ActionButton(
                            icon: Icons.upload_outlined,
                            label: 'Flush',
                            tooltip: 'Flush the memtable to an SSTable',
                            onPressed: () => _runAction(
                              context,
                              appProvider,
                              'Flushing…',
                              appProvider.flushDatabase,
                              'Flush complete.',
                            ),
                          ),
                          _ActionButton(
                            icon: Icons.compress_outlined,
                            label: 'Compact',
                            tooltip: 'Run full compaction',
                            onPressed: () => _runAction(
                              context,
                              appProvider,
                              'Compacting…',
                              appProvider.compactDatabase,
                              'Compaction complete.',
                            ),
                          ),
                          _ActionButton(
                            icon: Icons.verified_outlined,
                            label: 'Verify',
                            tooltip:
                                'Scan and decode every document to check integrity',
                            onPressed: () => _runVerify(context, appProvider),
                          ),
                          _ActionButton(
                            icon: Icons.download_outlined,
                            label: 'Dump',
                            tooltip: 'Dump all collections to NDJSON',
                            onPressed: () {
                              Navigator.pop(context);
                              showDumpDialog(context, appProvider);
                            },
                          ),
                          _ActionButton(
                            icon: Icons.restore_outlined,
                            label: 'Restore',
                            tooltip: 'Restore from an NDJSON dump file',
                            onPressed: () {
                              Navigator.pop(context);
                              showRestoreDialog(context, appProvider);
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),
                      _SectionHeader('Danger Zone'),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(
                          Icons.device_unknown_outlined,
                          size: 16,
                        ),
                        label: const Text('Rotate Device ID'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        onPressed: () =>
                            _confirmRotateDeviceId(context, appProvider),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Rotating the device ID is irreversible. Existing '
                        'SSTables will be renamed and any in-flight sync '
                        'should be completed first.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    AppProvider appProvider,
    String busyMessage,
    Future<void> Function() action,
    String successMessage,
  ) async {
    await appProvider.runBusy(busyMessage, action);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
      // Refresh stats after maintenance.
      setState(() => _loading = true);
      _load();
    }
  }

  Future<void> _runVerify(BuildContext context, AppProvider appProvider) async {
    final (:checked, :errors) = await appProvider.runBusy(
      'Verifying…',
      appProvider.verifyDatabase,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            errors == 0
                ? 'Verify OK — $checked document(s) checked.'
                : 'Verify found $errors error(s) in $checked document(s).',
          ),
        ),
      );
    }
  }

  Future<void> _confirmRotateDeviceId(
    BuildContext context,
    AppProvider appProvider,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rotate Device ID'),
        content: const Text(
          'This generates a new random device identity. All SSTables will be '
          'renamed to use the new ID.\n\n'
          'Ensure no sync is currently running. This action cannot be undone.',
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
            child: const Text('Rotate'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final error = await appProvider.runBusy(
      'Rotating device ID…',
      appProvider.rotateDeviceId,
    );

    if (!context.mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $error')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device ID rotated successfully.')),
      );
      Navigator.pop(context);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ── Shared sub-widgets ────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.copyable = false});

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (copyable)
            InkWell(
              onTap: () => Clipboard.setData(ClipboardData(text: value)),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.copy_outlined,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        icon: Icon(icon, size: 16),
        label: Text(label),
        onPressed: onPressed,
      ),
    );
  }
}
