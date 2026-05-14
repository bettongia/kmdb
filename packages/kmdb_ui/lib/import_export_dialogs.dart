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
import 'package:flutter/material.dart';

import 'app_provider.dart';

// ── Export collection ─────────────────────────────────────────────────────────

/// Prompts for a save path and exports [collectionName] to an NDJSON file.
Future<void> showExportCollectionDialog(
  BuildContext context,
  String collectionName,
  AppProvider appProvider,
) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Export "$collectionName"',
    fileName: '$collectionName.ndjson',
    type: FileType.custom,
    allowedExtensions: ['ndjson', 'json', 'jsonl'],
  );

  if (path == null || !context.mounted) return;

  try {
    final count = await appProvider.runBusy(
      'Exporting "$collectionName"…',
      () => appProvider.exportCollection(collectionName, path),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported $count document(s) to $path')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}

// ── Import collection ─────────────────────────────────────────────────────────

/// Prompts for an NDJSON file and imports it into [collectionName].
Future<void> showImportCollectionDialog(
  BuildContext context,
  String collectionName,
  AppProvider appProvider,
) async {
  // Step 1: pick file.
  final result = await FilePicker.pickFiles(
    dialogTitle: 'Import into "$collectionName"',
    type: FileType.custom,
    allowedExtensions: ['ndjson', 'json', 'jsonl'],
    allowMultiple: false,
  );

  if (result == null || result.files.isEmpty || !context.mounted) return;
  final filePath = result.files.single.path;
  if (filePath == null) return;

  // Step 2: choose conflict mode.
  final onConflict = await showDialog<String>(
    context: context,
    builder: (_) => const _ConflictModeDialog(),
  );
  if (onConflict == null || !context.mounted) return;

  // Step 3: run import.
  try {
    final (:imported, :skipped, :errors) = await appProvider.runBusy(
      'Importing into "$collectionName"…',
      () => appProvider.importCollection(
        collectionName,
        filePath,
        onConflict: onConflict,
      ),
    );

    if (!context.mounted) return;

    final message = errors.isEmpty
        ? 'Imported $imported, skipped $skipped.'
        : 'Imported $imported, skipped $skipped, ${errors.length} error(s).';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: errors.isEmpty
            ? null
            : SnackBarAction(
                label: 'Details',
                onPressed: () => _showErrorDetails(context, errors),
              ),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}

/// Dialog for choosing the on-conflict behaviour for import.
class _ConflictModeDialog extends StatefulWidget {
  const _ConflictModeDialog();

  @override
  State<_ConflictModeDialog> createState() => _ConflictModeDialogState();
}

class _ConflictModeDialogState extends State<_ConflictModeDialog> {
  String _mode = 'ignore';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('On Conflict'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RadioOption(
            value: 'ignore',
            selected: _mode,
            label: 'Ignore',
            subtitle: 'Skip documents that already exist.',
            onChanged: (v) => setState(() => _mode = v),
          ),
          _RadioOption(
            value: 'replace',
            selected: _mode,
            label: 'Replace',
            subtitle:
                'Overwrite existing documents.\n\n'
                'Warning: each replaced document\'s import timestamp wins '
                'on all synced devices after the next sync.',
            subtitleColor: Theme.of(context).colorScheme.error,
            onChanged: (v) => setState(() => _mode = v),
          ),
          _RadioOption(
            value: 'error',
            selected: _mode,
            label: 'Error',
            subtitle: 'Stop on the first conflict.',
            onChanged: (v) => setState(() => _mode = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _mode),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

// ── Dump database ─────────────────────────────────────────────────────────────

/// Prompts for a save path and dumps the entire database to NDJSON.
Future<void> showDumpDialog(
  BuildContext context,
  AppProvider appProvider,
) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Dump database',
    fileName: 'kmdb-dump.ndjson',
    type: FileType.custom,
    allowedExtensions: ['ndjson', 'json', 'jsonl'],
  );

  if (path == null || !context.mounted) return;

  try {
    final (:total, :collections) = await appProvider.runBusy(
      'Dumping database…',
      () => appProvider.dumpDatabase(path),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Dumped $total document(s) across $collections collection(s) to $path',
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Dump failed: $e')));
    }
  }
}

// ── Restore database ──────────────────────────────────────────────────────────

/// Prompts for a dump file and restores the database from it.
Future<void> showRestoreDialog(
  BuildContext context,
  AppProvider appProvider,
) async {
  // Warn that restore adds / overwrites documents.
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Restore Database'),
      content: const Text(
        'This will import all documents from the dump file into the current '
        'database.\n\n'
        'Existing documents with matching IDs will be overwritten. After the '
        'next sync each restored document\'s timestamp will win against older '
        'versions on peer devices.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;

  final result = await FilePicker.pickFiles(
    dialogTitle: 'Select dump file',
    type: FileType.custom,
    allowedExtensions: ['ndjson', 'json', 'jsonl'],
    allowMultiple: false,
  );

  if (result == null || result.files.isEmpty || !context.mounted) return;
  final filePath = result.files.single.path;
  if (filePath == null) return;

  try {
    final (:restored, :collections) = await appProvider.runBusy(
      'Restoring database…',
      () => appProvider.restoreDatabase(filePath),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored $restored document(s) across $collections collection(s).',
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// ── Shared widgets ────────────────────────────────────────────────────────────

class _RadioOption extends StatelessWidget {
  const _RadioOption({
    required this.value,
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.onChanged,
    this.subtitleColor,
  });

  final String value;
  final String selected;
  final String label;
  final String subtitle;
  final Color? subtitleColor;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Radio<String>(
            value: value,
            groupValue: selected,
            onChanged: (v) => onChanged(v!),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          subtitleColor ??
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _showErrorDetails(BuildContext context, List<String> errors) {
  showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Import Errors'),
      content: SizedBox(
        width: 480,
        height: 300,
        child: ListView.builder(
          itemCount: errors.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(errors[i], style: const TextStyle(fontSize: 12)),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
